const std = @import("std");
const linux = @import("std").os.linux;
const debug_mode = @import("builtin").mode == @import("std").builtin.OptimizeMode.Debug;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;

const mini = @import("miniaudio");

const c = @cImport({
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("linux/input.h");
});

const handmade = @import("handmade.zig");

pub const DEBUGReadFileResult = struct {
    content_size: u32,
    content: ?*anyopaque,
};

const LinuxGamepadManager = struct {
    inotify_fd: std.posix.fd_t,
    watch_fd: i32,
    slots: [4]LinuxGamepadSlot,

    fn init() !LinuxGamepadManager {
        const inotify_fd = try std.posix.inotify_init1(std.os.linux.IN.CLOEXEC | std.os.linux.IN.NONBLOCK);
        errdefer std.posix.close(inotify_fd);

        const watch_fd = try std.posix.inotify_add_watch(inotify_fd, "/dev/input/", std.os.linux.IN.CREATE | std.os.linux.IN.DELETE);

        var manager = LinuxGamepadManager{
            .inotify_fd = inotify_fd,
            .watch_fd = watch_fd,
            .slots = .{LinuxGamepadSlot{
                .fd = null,
                .device_path = undefined,
                .device_path_len = 0,
                .is_valid = false,
            }} ** 4,
        };

        try manager.enumerateDevices();

        return manager;
    }

    fn deinit(self: *LinuxGamepadManager) void {
        for (&self.slots) |*slot| {
            if (slot.fd) |fd| {
                std.posix.close(fd);
                slot.fd = null;
            }
            slot.is_valid = false;
        }

        std.posix.inotify_rm_watch(self.inotify_fd, self.watch_fd);
        std.posix.close(self.inotify_fd);
    }

    fn is_gamepad(fd: std.posix.fd_t) bool {
        var key_bits: [(c.KEY_MAX + 7) / 8]u8 = undefined;

        const IOC_READ: u32 = 2;
        const IOC_NRBITS: u32 = 8;
        const IOC_TYPEBITS: u32 = 8;
        const IOC_SIZEBITS: u32 = 14;

        const ioc_nrshift: u32 = 0;
        const ioc_typeshift: u32 = ioc_nrshift + IOC_NRBITS;
        const ioc_sizeshift: u32 = ioc_typeshift + IOC_TYPEBITS;
        const ioc_dirshift: u32 = ioc_sizeshift + IOC_SIZEBITS;

        const EVIOCGBIT_KEY = (IOC_READ << ioc_dirshift) |
            (@as(u32, 'E') << ioc_typeshift) |
            ((0x20 + c.EV_KEY) << ioc_nrshift) |
            (@as(u32, @sizeOf(@TypeOf(key_bits))) << ioc_sizeshift);

        const rc = std.os.linux.ioctl(fd, EVIOCGBIT_KEY, @intFromPtr(&key_bits));

        if (std.posix.errno(rc) != .SUCCESS) return false;

        const btn_south: usize = 0x130;
        const byte_index = btn_south / 8;
        const bit_index: u3 = @intCast(btn_south % 8);
        return (key_bits[byte_index] & (@as(u8, 1) << bit_index)) != 0;
    }

    fn enumerateDevices(self: *LinuxGamepadManager) !void {
        var slot_index: usize = 0;

        var event_num: u32 = 0;
        while (event_num < 32 and slot_index < 4) : (event_num += 1) {
            var path_buf: [64]u8 = undefined;
            const path = std.fmt.bufPrintZ(&path_buf, "/dev/input/event{d}", .{event_num}) catch continue;

            const fd = std.posix.openZ(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0) catch continue;

            if (is_gamepad(fd)) {
                var slot = &self.slots[slot_index];
                slot.fd = fd;

                @memcpy(slot.device_path[0..path.len], path);
                slot.device_path_len = path.len;
                slot.is_valid = true;

                slot_index += 1;
            } else {
                std.posix.close(fd);
            }
        }
    }

    fn checkHotplug(self: *LinuxGamepadManager) !void {
        var event_buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;

        const bytes_read = std.posix.read(self.inotify_fd, &event_buf) catch |err| {
            if (err == error.WouldBlock) return;
            return err;
        };

        if (bytes_read == 0) {
            return;
        }

        var offset: usize = 0;
        while (offset < bytes_read) {
            const event_ptr: *const linux.inotify_event = @ptrCast(@alignCast(&event_buf[offset]));
            const event = event_ptr.*;

            if (event_ptr.getName()) |name| {
                if (std.mem.startsWith(u8, name, "event")) {
                    if (event.mask & linux.IN.CREATE != 0) {
                        try self.handleDeviceAdded(name);
                    } else if (event.mask & linux.IN.DELETE != 0) {
                        try self.handleDeviceRemoved(name);
                    }
                }
            }

            offset += @sizeOf(linux.inotify_event) + event.len;
        }
    }

    fn handleDeviceAdded(self: *LinuxGamepadManager, file_name: [:0]const u8) !void {
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buf, "/dev/input/{s}", .{file_name});

        var retries: u32 = 0;
        const max_retries: u32 = 10;
        const retry_delay_ms: u32 = 10;

        while (retries < max_retries) : (retries += 1) {
            const fd = std.posix.openZ(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0) catch |err| {
                std.Thread.sleep(retry_delay_ms * std.time.ns_per_ms);
                if (err == error.AccessDenied and retries < max_retries - 1) continue;
                return;
            };

            if (!is_gamepad(fd)) {
                std.posix.close(fd);
                return;
            }

            for (&self.slots) |*slot| {
                if (!slot.is_valid) {
                    slot.fd = fd;
                    @memcpy(slot.device_path[0..path.len], path);
                    slot.device_path_len = path.len;
                    slot.is_valid = true;
                    return;
                }
            }
            std.posix.close(fd);
            return;
        }
    }

    fn handleDeviceRemoved(self: *LinuxGamepadManager, file_name: [:0]const u8) !void {
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buf, "/dev/input/{s}", .{file_name});

        for (&self.slots) |*slot| {
            if (slot.is_valid and std.mem.eql(u8, slot.device_path[0..slot.device_path_len], path)) {
                if (slot.fd) |fd| {
                    std.posix.close(fd);
                }

                slot.fd = null;
                slot.is_valid = false;
                return;
            }
        }
    }
};

const LinuxGamepadSlot = struct {
    fd: ?std.posix.fd_t,
    device_path: [64]u8,
    device_path_len: usize,
    is_valid: bool,
};

const LinuxAudioState = struct {
    ring_buffer: []i16,
    ring_buffer_size: u32,

    write_cursor: std.atomic.Value(u32),
    read_cursor: std.atomic.Value(u32),

    sound_is_valid: std.atomic.Value(bool),

    samples_per_second: u32,
    bytes_per_sample: u32,
    underrun_count: std.atomic.Value(u32),
};

const LinuxReplayBuffer = struct {
    file_handle: ?*anyopaque,
    memory_map: ?*anyopaque,
    file_name: [260:0]u8,
    memory_block: ?*anyopaque,
};

const LinuxState = struct {
    game_memory_block: ?*anyopaque,
    total_size: usize,
    replay_buffers: [4]LinuxReplayBuffer,

    recording_handle: ?*anyopaque,
    input_recording_index: u32,

    playback_handle: ?*anyopaque,
    input_playing_index: u32,

    exe_file_path: [260:0]u8,
    one_past_last_exe_file_name_slash: ?[*:0]u8,
};

const LinuxRecordedInput = struct {
    input_count: i32,
    input_stream: *handmade.GameInput,
};

const LinuxGameCode = struct {
    game_code_dll: ?*anyopaque,
    dll_last_write_time: bool,

    updateAndRender: ?handmade.UpdateAndRenderFnPtr,
    getSoundSamples: ?handmade.GetSoundSamplesFnPtr,

    is_valid: bool,
};

const LinuxDebugTimeMarker = struct {
    output_play_cursor: u32,
    output_write_cursor: u32,
    output_location: u32,
    output_byte_count: u32,

    expected_flip_play_cursor: u32,
    flip_play_cursor: u32,
    flip_write_cursor: u32,
};

const LinuxOffscreenBuffer = struct {
    buffer: ?*wl.Buffer,
    memory: []align(4096) u8,
    width: i32,
    height: i32,
    pitch: usize,
};

const WlKeyboardContext = struct {
    context: *WlContext,
    keyboard_controller: ?*handmade.GameControllerInput,
};

const WlContext = struct {
    shm: ?*wl.Shm,
    compositor: ?*wl.Compositor,
    wm_base: ?*xdg.WmBase,
    seat: ?*wl.Seat,
    keyboard: ?*wl.Keyboard,
    mouse: ?*wl.Pointer,
    frame_callback: ?*wl.Callback = null,
    waiting_for_frame: bool,

    xkb_context: ?*c.struct_xkb_context,
    xkb_keymap: ?*c.struct_xkb_keymap,
    xkb_state: ?*c.struct_xkb_state,

    width: i32 = 1280,
    height: i32 = 720,
    configured: bool = false,
    running: bool = true,
};

const NUM_EVENTS: u32 = 8;

var global_pause = false;
var global_back_buffer = std.mem.zeroInit(LinuxOffscreenBuffer, .{});

inline fn rdtsc() usize {
    var a: u32 = undefined;
    var b: u32 = undefined;
    asm volatile ("rdtsc"
        : [a] "={edx}" (a),
          [b] "={eax}" (b),
    );
    return (@as(u64, a) << 32) | b;
}

inline fn linuxGetWallClock() !std.posix.timespec {
    const result = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC_RAW);
    return result;
}

inline fn linuxGetSecondsElapsed(start: std.posix.timespec, end: std.posix.timespec) f32 {
    const result: f32 = @as(f32, @floatFromInt(end.sec - start.sec)) + @as(f32, @floatFromInt(end.nsec - start.nsec)) / 1_000_000_000.0;
    return result;
}

// NOTE: (CASEY) Start-->
// These are NOT for doing anything in the shipping game - they are
// blocking and the write doesn't protect against lost data!

pub fn debugPlatformReadEntireFile(thread: *handmade.ThreadContext, file_path: [*:0]const u8) DEBUGReadFileResult {
    _ = thread;

    var result = DEBUGReadFileResult{
        .content_size = 0,
        .content = null,
    };

    std.debug.print("file_path: {s}\n", .{file_path});

    const fd: std.posix.fd_t = std.posix.openZ(file_path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0) catch |err| {
        std.debug.print("Failed to open file: {}.\n", .{err});
        return result;
    };
    defer std.posix.close(fd);

    const stat = std.posix.fstat(fd) catch |err| {
        std.debug.print("Failed to get file stats: {}.\n", .{err});
        return result;
    };

    std.debug.assert(stat.size <= 0xFFFFFFFF);
    const file_size: u32 = @intCast(stat.size);
    const content = std.posix.mmap(null, file_size, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0) catch |err| {
        std.debug.print("Failed to map memory: {}.\n", .{err});
        return result;
    };

    const file = std.fs.File{ .handle = fd };
    const bytes_read = file.readAll(content) catch |err| {
        std.debug.print("Failed to read file: {}.\n", .{err});
        std.posix.munmap(content);
        return result;
    };

    if (bytes_read == file_size) {
        result.content = content.ptr;
        result.content_size = file_size;
        std.debug.print("File read successfully.\n", .{});
    } else {
        std.debug.print("Failed to read entire file.\n", .{});
        std.posix.munmap(content);
    }

    return result;
}

pub fn debugPlatformFreeFileMemory(thread: *handmade.ThreadContext, file: DEBUGReadFileResult) void {
    _ = thread;
    if (file.content) |content| {
        const aligned_memory: [*]align(4096) u8 = @ptrCast(@alignCast(content));
        std.posix.munmap(aligned_memory[0..file.content_size]);
    }
}

pub fn debugPlatformWriteEntireFile(thread: *handmade.ThreadContext, file_name: [*:0]const u8, memory_size: u32, memory: ?*anyopaque) bool {
    _ = thread;
    var result = false;

    const fd: std.posix.fd_t = std.posix.openZ(file_name, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch |err| {
        std.debug.print("Failed to open file: {}.\n", .{err});
        return result;
    };
    defer std.posix.close(fd);

    if (memory) |mem| {
        const buffer: [*]const u8 = @ptrCast(mem);
        const bytes_to_write = buffer[0..memory_size];

        const file = std.fs.File{ .handle = fd };
        file.writeAll(bytes_to_write) catch |err| {
            std.debug.print("Failed to write file: {}.\n", .{err});
            return result;
        };

        result = true;
        std.debug.print("File written successfully.\n", .{});
    }

    return result;
}

// NOTE: END-->

fn miniCallback(pDevice: ?*anyopaque, pOutput: ?*anyopaque, pInput: ?*const anyopaque, frame_count: u32) callconv(.c) void {
    _ = pInput;

    const device: *mini.ma_device = @ptrCast(@alignCast(pDevice));
    const audio_state: *LinuxAudioState = @ptrCast(@alignCast(device.pUserData));

    const channels: u32 = device.playback.channels;
    const samples_to_read = frame_count * channels;
    const output: [*]f32 = @ptrCast(@alignCast(pOutput));

    if (!audio_state.sound_is_valid.load(.acquire)) {
        @memset(output[0..samples_to_read], 0.0);
        return;
    }

    const write_cursor = audio_state.write_cursor.load(.acquire);
    const read_cursor = audio_state.read_cursor.load(.acquire);

    const available_samples = if (write_cursor >= read_cursor)
        write_cursor - read_cursor
    else
        (audio_state.ring_buffer_size - read_cursor) + write_cursor;

    if (available_samples >= samples_to_read) {
        for (0..samples_to_read) |i| {
            const buffer_index = (read_cursor + @as(u32, @intCast(i))) % audio_state.ring_buffer_size;
            output[i] = @as(f32, @floatFromInt(audio_state.ring_buffer[buffer_index])) / 32768.0;
        }

        const new_read_cursor = (read_cursor + samples_to_read) % audio_state.ring_buffer_size;
        audio_state.read_cursor.store(new_read_cursor, .release);
    } else {
        @memset(output[0..samples_to_read], 0.0);
        _ = audio_state.underrun_count.fetchAdd(1, .monotonic);
        // std.debug.print("Audio underrun! Available: {}, Needed {}, count: {}.\n", .{ available_samples, samples_to_read, audio_state.underrun_count.load(.acquire) });
    }
}

fn linuxProcessGamepads(fd: std.posix.fd_t, events: *[NUM_EVENTS]c.struct_input_event, new_controller: *handmade.GameControllerInput) bool {
    while (true) {
        const event_buffer = std.mem.sliceAsBytes(events);
        const num_bytes = std.posix.read(fd, event_buffer) catch |err| {
            if (err == error.WouldBlock) {
                return true;
            }
            return false;
        };

        const num_events = num_bytes / @sizeOf(c.struct_input_event);

        for (events[0..num_events]) |ev| {
            if (ev.type == c.EV_KEY) {
                const is_down: bool = (ev.value == 1);
                switch (ev.code) {
                    c.BTN_Y => linuxProcessKeyboardMessage(&new_controller.button.input.action_up, is_down),
                    c.BTN_X => linuxProcessKeyboardMessage(&new_controller.button.input.action_left, is_down),
                    c.BTN_A => linuxProcessKeyboardMessage(&new_controller.button.input.action_down, is_down),
                    c.BTN_B => linuxProcessKeyboardMessage(&new_controller.button.input.action_right, is_down),

                    c.BTN_DPAD_UP => linuxProcessKeyboardMessage(&new_controller.button.input.move_up, is_down),
                    c.BTN_DPAD_LEFT => linuxProcessKeyboardMessage(&new_controller.button.input.move_left, is_down),
                    c.BTN_DPAD_DOWN => linuxProcessKeyboardMessage(&new_controller.button.input.move_down, is_down),
                    c.BTN_DPAD_RIGHT => linuxProcessKeyboardMessage(&new_controller.button.input.move_right, is_down),

                    c.BTN_START => linuxProcessKeyboardMessage(&new_controller.button.input.start, is_down),
                    c.BTN_SELECT => linuxProcessKeyboardMessage(&new_controller.button.input.back, is_down),

                    c.BTN_TL => linuxProcessKeyboardMessage(&new_controller.button.input.left_shoulder, is_down),
                    c.BTN_TR => linuxProcessKeyboardMessage(&new_controller.button.input.right_shoulder, is_down),
                    else => {},
                }
            } else if (ev.type == c.EV_ABS) {
                const left_deadzone: i32 = 7849;
                const right_deadzone: i32 = 8689;
                switch (ev.code) {
                    c.ABS_HAT0X => {
                        linuxProcessKeyboardMessage(&new_controller.button.input.move_left, ev.value < 0);
                        linuxProcessKeyboardMessage(&new_controller.button.input.move_right, ev.value > 0);
                    },

                    c.ABS_HAT0Y => {
                        linuxProcessKeyboardMessage(&new_controller.button.input.move_up, ev.value < 0);
                        linuxProcessKeyboardMessage(&new_controller.button.input.move_down, ev.value > 0);
                    },

                    c.ABS_X => {
                        new_controller.left_stick_average_x = linuxProcessEvDevStickValue(ev.value, left_deadzone);
                    },

                    c.ABS_Y => {
                        new_controller.left_stick_average_y = -linuxProcessEvDevStickValue(ev.value, left_deadzone);
                    },

                    c.ABS_RX => {
                        new_controller.right_stick_average_x = -linuxProcessEvDevStickValue(ev.value, right_deadzone);
                    },

                    c.ABS_RY => {
                        new_controller.right_stick_average_y = linuxProcessEvDevStickValue(ev.value, right_deadzone);
                    },

                    else => {},
                }
            }
        }
    }
    return true;
}

fn linuxProcessEvDevStickValue(value: i32, deadzone_threshold: i32) f32 {
    var result: f32 = 0.0;

    if (value < -deadzone_threshold) {
        result = @as(f32, @floatFromInt(value + deadzone_threshold)) / (32768.0 - @as(f32, @floatFromInt(deadzone_threshold)));
    } else if (value > deadzone_threshold) {
        result = @as(f32, @floatFromInt(@as(i32, value) - @as(i32, deadzone_threshold))) / (32767.0 - @as(f32, @floatFromInt(deadzone_threshold)));
    }
    return result;
}

fn linuxProcessKeySym(keyboard_controller: *handmade.GameControllerInput, key_sym: c.xkb_keysym_t, is_down: bool, context: *WlContext) void {
    switch (key_sym) {
        c.XKB_KEY_w, c.XKB_KEY_W => linuxProcessKeyboardMessage(&keyboard_controller.button.input.move_up, is_down),
        c.XKB_KEY_a, c.XKB_KEY_A => linuxProcessKeyboardMessage(&keyboard_controller.button.input.move_left, is_down),
        c.XKB_KEY_s, c.XKB_KEY_S => linuxProcessKeyboardMessage(&keyboard_controller.button.input.move_down, is_down),
        c.XKB_KEY_d, c.XKB_KEY_D => linuxProcessKeyboardMessage(&keyboard_controller.button.input.move_right, is_down),

        c.XKB_KEY_q, c.XKB_KEY_Q => linuxProcessKeyboardMessage(&keyboard_controller.button.input.left_shoulder, is_down),
        c.XKB_KEY_e, c.XKB_KEY_E => linuxProcessKeyboardMessage(&keyboard_controller.button.input.right_shoulder, is_down),

        c.XKB_KEY_p, c.XKB_KEY_P => {
            if (debug_mode) {
                if (is_down) global_pause = !global_pause;
            }
        },

        c.XKB_KEY_UP => linuxProcessKeyboardMessage(&keyboard_controller.button.input.action_up, is_down),
        c.XKB_KEY_Left => linuxProcessKeyboardMessage(&keyboard_controller.button.input.action_left, is_down),
        c.XKB_KEY_DOWN => linuxProcessKeyboardMessage(&keyboard_controller.button.input.action_down, is_down),
        c.XKB_KEY_Right => linuxProcessKeyboardMessage(&keyboard_controller.button.input.action_right, is_down),

        c.XKB_KEY_Escape => {
            linuxProcessKeyboardMessage(&keyboard_controller.button.input.back, is_down);
            if (debug_mode and is_down) {
                context.running = false;
            }
        },

        else => {},
    }
}

fn linuxProcessKeyboardMessage(new_state: *handmade.GameButtonState, is_down: bool) void {
    if (new_state.ended_down != is_down) {
        new_state.ended_down = is_down;
        new_state.half_transition_count += 1;
    }
}

fn wlCreateBuffer(buffer: *LinuxOffscreenBuffer, shm: *wl.Shm, width: i32, height: i32) !void {
    buffer.width = width;
    buffer.height = height;
    buffer.pitch = @intCast(width * 4);
    const size: u64 = @intCast(buffer.pitch * @as(u64, @intCast(height)));
    const fd = try std.posix.memfd_create("handmade_hero", 0);
    try std.posix.ftruncate(fd, size);

    buffer.memory = try std.posix.mmap(null, size, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .SHARED }, fd, 0);

    const pool = try shm.createPool(fd, @intCast(size));
    defer pool.destroy();

    buffer.buffer = try pool.createBuffer(0, @intCast(width), @intCast(height), @intCast(buffer.pitch), wl.Shm.Format.argb8888);
}

fn wlRegistryListener(registry: *wl.Registry, event: wl.Registry.Event, context: *WlContext) void {
    switch (event) {
        .global => |global| {
            if (std.mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                context.compositor = registry.bind(global.name, wl.Compositor, 1) catch |err| {
                    std.debug.print("Failed to bind to compositor interface: {}.\n", .{err});
                    return;
                };
            } else if (std.mem.orderZ(u8, global.interface, wl.Shm.interface.name) == .eq) {
                context.shm = registry.bind(global.name, wl.Shm, 1) catch |err| {
                    std.debug.print("Failed bind to shm interface: {}\n", .{err});
                    return;
                };
            } else if (std.mem.orderZ(u8, global.interface, xdg.WmBase.interface.name) == .eq) {
                context.wm_base = registry.bind(global.name, xdg.WmBase, 1) catch |err| {
                    std.debug.print("Failed bind to wm_base interface: {}\n", .{err});
                    return;
                };
            } else if (std.mem.orderZ(u8, global.interface, wl.Seat.interface.name) == .eq) {
                context.seat = registry.bind(global.name, wl.Seat, 7) catch |err| {
                    std.debug.print("Failed to bind seat interface {}\n", .{err});
                    return;
                };
                if (context.seat) |seat| {
                    seat.setListener(*WlContext, wlSeatListener, context);
                }
            }
        },
        .global_remove => {},
    }
}

fn wlKeyboardListener(_: *wl.Keyboard, event: wl.Keyboard.Event, kb_context: *WlKeyboardContext) void {
    switch (event) {
        .enter => {},
        .key => |key| {
            const is_down = key.state == .pressed;

            if (kb_context.context.xkb_state) |state| {
                const xkb_keycode: c.xkb_keycode_t = key.key + 8;
                const key_sym = c.xkb_state_key_get_one_sym(state, xkb_keycode);

                if (kb_context.keyboard_controller) |controller| {
                    linuxProcessKeySym(controller, key_sym, is_down, kb_context.context);
                }
            }
        },
        .keymap => |keymap_info| {
            if (kb_context.context.xkb_state) |state| {
                c.xkb_state_unref(state);
                kb_context.context.xkb_state = null;
            }
            if (kb_context.context.xkb_keymap) |km| {
                c.xkb_keymap_unref(km);
                kb_context.context.xkb_keymap = null;
            }

            const keymap_size: usize = @intCast(keymap_info.size);
            const keymap_string = std.posix.mmap(null, keymap_size, std.posix.PROT.READ, .{ .TYPE = .PRIVATE }, keymap_info.fd, 0) catch {
                std.debug.print("Failed to map keymap\n", .{});
                return;
            };
            defer std.posix.munmap(keymap_string);

            if (kb_context.context.xkb_context) |xkb_ctx| {
                kb_context.context.xkb_keymap = c.xkb_keymap_new_from_string(xkb_ctx, @ptrCast(keymap_string.ptr), c.XKB_KEYMAP_FORMAT_TEXT_V1, c.XKB_KEYMAP_COMPILE_NO_FLAGS);

                if (kb_context.context.xkb_keymap) |km| {
                    kb_context.context.xkb_state = c.xkb_state_new(km);
                    if (kb_context.context.xkb_state == null) {
                        std.debug.print("Failed to create XKB state.\n", .{});
                    }
                } else {
                    std.debug.print("Failed to create XKB keymap.\n", .{});
                }
            }
        },
        .leave => {},
        .modifiers => |mods| {
            if (kb_context.context.xkb_state) |state| {
                _ = c.xkb_state_update_mask(state, mods.mods_depressed, mods.mods_latched, mods.mods_locked, 0, 0, mods.group);
            }
        },
        .repeat_info => {},
    }
}

fn wlFrameListener(_: *wl.Callback, event: wl.Callback.Event, context: *WlContext) void {
    switch (event) {
        .done => {
            context.waiting_for_frame = false;
        },
    }
}

fn wlSeatListener(seat: *wl.Seat, event: wl.Seat.Event, context: *WlContext) void {
    switch (event) {
        .capabilities => |cap| {
            if (cap.capabilities.keyboard) {
                context.keyboard = seat.getKeyboard() catch null;
            }
        },
        .name => {},
    }
}

fn wlXDGSurfaceListener(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, context: *WlContext) void {
    switch (event) {
        .configure => |configure| {
            xdg_surface.ackConfigure(configure.serial);
            context.configured = true;
        },
    }
}

fn wlXDGToplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, context: *WlContext) void {
    switch (event) {
        .configure => |configure| {
            if (configure.width > 0 and configure.height > 0) {
                const new_width: i32 = @intCast(configure.width);
                const new_height: i32 = @intCast(configure.height);
                if (new_width != context.width or new_height != context.height) {
                    context.width = new_width;
                    context.height = new_height;
                    context.configured = false;
                }
            }
        },
        .close => context.running = false,
    }
}

fn wlWMBaseListener(_: *xdg.WmBase, event: xdg.WmBase.Event, wm_base: *xdg.WmBase) void {
    switch (event) {
        .ping => |ping| {
            wm_base.pong(ping.serial);
        },
    }
}

pub fn run() !void {
    var state = std.mem.zeroes(LinuxState);

    const display = try wl.Display.connect(null);
    defer display.disconnect();

    const registry = try wl.Display.getRegistry(display);
    defer registry.destroy();

    var context = std.mem.zeroInit(WlContext, .{});

    registry.setListener(*WlContext, wlRegistryListener, &context);
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    std.debug.print("Connection established!\n", .{});

    const shm = context.shm orelse return error.NoWlShm;
    const compositor = context.compositor orelse return error.NoWlCompositor;
    const wm_base = context.wm_base orelse return error.NoXdgWmBase;

    const surface = try compositor.createSurface();
    defer surface.destroy();

    const xdg_surface = try wm_base.getXdgSurface(surface);
    defer xdg_surface.destroy();

    const xdg_toplevel = try xdg_surface.getToplevel();
    defer xdg_toplevel.destroy();

    xdg_toplevel.setTitle("Handmade Hero");
    xdg_toplevel.setAppId("Handmade Hero");

    wm_base.setListener(*xdg.WmBase, wlWMBaseListener, wm_base);
    xdg_surface.setListener(*WlContext, wlXDGSurfaceListener, &context);
    xdg_toplevel.setListener(*WlContext, wlXDGToplevelListener, &context);

    surface.commit();
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    while (!context.configured and context.running) {
        if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
    }

    if (!context.running) return;

    const monitor_refresh_hz: f32 = 144.0;
    const game_update_hz: f32 = monitor_refresh_hz / 2.0;
    const target_seconds_per_frame: f32 = 1.0 / game_update_hz;
    _ = target_seconds_per_frame;

    const samples_per_second: u32 = 48000;
    const channels: u32 = 2;

    const samples_per_second_float: f32 = @floatFromInt(samples_per_second);
    const channels_float: f32 = @floatFromInt(channels);

    const ring_buffer_seconds: f32 = 1.0;
    const ring_buffer_size: u32 = @intFromFloat(samples_per_second_float * ring_buffer_seconds * channels_float);
    const ring_buffer_size_in_bytes: usize = ring_buffer_size * @sizeOf(i16);

    const ring_buffer_memory = try std.posix.mmap(
        null,
        ring_buffer_size_in_bytes,
        std.posix.PROT.READ | std.posix.PROT.WRITE,
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    defer std.posix.munmap(ring_buffer_memory);
    @memset(ring_buffer_memory, 0);

    const ring_buffer: []align(4096) i16 = @alignCast(std.mem.bytesAsSlice(i16, ring_buffer_memory));

    const expected_frames_per_update: u32 = @intFromFloat(samples_per_second_float / game_update_hz);
    const total_samples = expected_frames_per_update * channels;
    const temp_buffer_size_in_bytes: usize = total_samples * @sizeOf(i16);

    const temp_buffer_memory = try std.posix.mmap(
        null,
        temp_buffer_size_in_bytes,
        std.posix.PROT.READ | std.posix.PROT.WRITE,
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    defer std.posix.munmap(temp_buffer_memory);
    @memset(temp_buffer_memory, 0);

    const temp_buffer: []align(4096) i16 = @alignCast(std.mem.bytesAsSlice(i16, temp_buffer_memory));

    var audio_state = LinuxAudioState{
        .ring_buffer = ring_buffer,
        .ring_buffer_size = ring_buffer_size,
        .write_cursor = std.atomic.Value(u32).init(0),
        .read_cursor = std.atomic.Value(u32).init(0),
        .sound_is_valid = std.atomic.Value(bool).init(false),
        .samples_per_second = samples_per_second,
        .bytes_per_sample = @sizeOf(i16) * channels,
        .underrun_count = std.atomic.Value(u32).init(0),
    };

    var mini_device_config = mini.ma_device_config_init(mini.ma_device_type_playback);
    mini_device_config.playback.format = mini.ma_format_f32;
    mini_device_config.playback.channels = channels;
    mini_device_config.sampleRate = samples_per_second;
    mini_device_config.dataCallback = miniCallback;
    mini_device_config.pUserData = &audio_state;

    var device: mini.ma_device = undefined;
    var mini_result = mini.ma_device_init(null, &mini_device_config, &device);
    if (mini_result != mini.MA_SUCCESS) {
        std.debug.print("Failed to initialize device {}\n", .{mini_result});
        return error.MiniDeviceInitFailed;
    }
    defer mini.ma_device_uninit(&device);

    const base_address: ?[*]align(4096) u8 = if (debug_mode) @ptrFromInt(handmade.teraBytes(2)) else null;

    var game_memory = std.mem.zeroInit(handmade.GameMemory, .{
        .permanent_storage_size = handmade.megaBytes(64),
        .transient_storage_size = handmade.gigaBytes(1),

        .debugPlatformReadEntireFile = debugPlatformReadEntireFile,
        .debugPlatformFreeFileMemory = debugPlatformFreeFileMemory,
        .debugPlatformWriteEntireFile = debugPlatformWriteEntireFile,
    });

    state.total_size = game_memory.permanent_storage_size + game_memory.transient_storage_size;
    state.game_memory_block = @ptrCast(@alignCast(std.posix.mmap(
        base_address,
        state.total_size,
        std.posix.PROT.READ | std.posix.PROT.WRITE,
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    ) catch |err| {
        std.debug.print("mmap failed: {}\n", .{err});
        return err;
    }));
    game_memory.permanent_storage = state.game_memory_block;
    game_memory.transient_storage = @as([*]u8, @ptrCast(game_memory.permanent_storage)) + game_memory.permanent_storage_size;

    context.xkb_context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);
    if (context.xkb_context == null) {
        std.debug.print("Failed to create XKB context.\n", .{});
        return error.XKBContextFailed;
    }

    defer {
        if (context.xkb_state) |kb_state| c.xkb_state_unref(kb_state);
        if (context.xkb_keymap) |km| c.xkb_keymap_unref(km);
        if (context.xkb_context) |ctx| c.xkb_context_unref(ctx);
    }

    var gamepad_manager = try LinuxGamepadManager.init();
    defer gamepad_manager.deinit();

    var events: [NUM_EVENTS]c.struct_input_event = undefined;

    var input = [_]handmade.GameInput{std.mem.zeroInit(handmade.GameInput, .{})} ** 2;
    var new_input: *handmade.GameInput = &input[0];
    var old_input: *handmade.GameInput = &input[1];

    var flip_wall_clock = try linuxGetWallClock();

    try wlCreateBuffer(&global_back_buffer, shm, context.width, context.height);
    defer if (global_back_buffer.buffer) |buf| buf.destroy();

    var keyboard_context = WlKeyboardContext{
        .context = &context,
        .keyboard_controller = null,
    };

    if (context.keyboard) |kbd| {
        kbd.setListener(*WlKeyboardContext, wlKeyboardListener, &keyboard_context);
    }

    while (context.running) {
        const frame_start = try linuxGetWallClock();
        const frame_start_cycles: i64 = @intCast(rdtsc());

        if (global_back_buffer.width != context.width or global_back_buffer.height != context.height) {
            global_back_buffer.buffer.?.destroy();
            std.posix.munmap(global_back_buffer.memory);
            try wlCreateBuffer(&global_back_buffer, shm, context.width, context.height);
        }

        if (!context.waiting_for_frame) {
            const old_keyboard_controller: *handmade.GameControllerInput = handmade.getController(old_input, 0);
            const new_keyboard_controller: *handmade.GameControllerInput = handmade.getController(new_input, 0);
            new_keyboard_controller.is_connected = true;

            for (0..new_keyboard_controller.button.buttons.len) |button_index| {
                new_keyboard_controller.button.buttons[button_index].ended_down = old_keyboard_controller.button.buttons[button_index].ended_down;
            }

            keyboard_context.keyboard_controller = new_keyboard_controller;

            gamepad_manager.checkHotplug() catch |err| {
                std.debug.print("Hotplug check error: {}\n", .{err});
            };

            if (!global_pause) {
                const max_controller_count: u32 = 4;

                for (0..max_controller_count) |controller_index| {
                    const our_controller_index = controller_index + 1;

                    const old_controller: *handmade.GameControllerInput = handmade.getController(old_input, our_controller_index);
                    const new_controller: *handmade.GameControllerInput = handmade.getController(new_input, our_controller_index);

                    const slot = &gamepad_manager.slots[controller_index];
                    if (slot.is_valid) {
                        if (slot.fd) |fd| {
                            new_controller.is_connected = true;
                            new_controller.is_analog = old_controller.is_analog;

                            for (0..new_controller.button.buttons.len) |button_index| {
                                new_controller.button.buttons[button_index].ended_down = old_controller.button.buttons[button_index].ended_down;
                            }

                            new_controller.left_stick_average_x = old_controller.left_stick_average_x;
                            new_controller.left_stick_average_y = old_controller.left_stick_average_y;
                            new_controller.right_stick_average_x = old_controller.right_stick_average_x;
                            new_controller.right_stick_average_y = old_controller.right_stick_average_y;

                            // Process Gamepads
                            const success = linuxProcessGamepads(fd, &events, new_controller);
                            if (!success) {
                                std.posix.close(fd);
                                slot.fd = null;
                                slot.is_valid = false;
                                new_controller.is_connected = false;
                            } else if (new_controller.left_stick_average_x != 0.0 or
                                new_controller.left_stick_average_y != 0.0 or
                                new_controller.right_stick_average_x == 0.0 or
                                new_controller.right_stick_average_y == 0.0)
                            {
                                new_controller.is_analog = true;
                            } else {
                                new_controller.is_analog = false;
                            }
                        }
                    } else {
                        new_controller.is_connected = false;
                        new_controller.is_analog = false;
                    }
                }

                var thread = std.mem.zeroInit(handmade.ThreadContext, .{});

                var buffer = handmade.GameOffScreenBuffer{
                    .memory = global_back_buffer.memory,
                    .width = global_back_buffer.width,
                    .height = global_back_buffer.height,
                    .pitch = global_back_buffer.pitch,
                    .bytes_per_pixel = 4,
                };

                handmade.gameUpdateAndRender(&thread, &game_memory, new_input, &buffer);

                const audio_wall_clock = try linuxGetWallClock();
                const from_begin_to_audio_seconds: f32 = linuxGetSecondsElapsed(flip_wall_clock, audio_wall_clock);
                _ = from_begin_to_audio_seconds;

                const write_cursor = audio_state.write_cursor.load(.acquire);
                const read_cursor = audio_state.read_cursor.load(.acquire);

                const buffered_samples = if (write_cursor >= read_cursor)
                    write_cursor - read_cursor
                else
                    (audio_state.ring_buffer_size - read_cursor) + write_cursor;

                const target_frames_ahead: u32 = 4;
                const samples_per_frame: u32 = @intFromFloat((samples_per_second_float / game_update_hz) * channels_float);
                const target_buffered_samples = samples_per_frame * target_frames_ahead;

                if (buffered_samples < target_buffered_samples) {
                    const free_samples = if (read_cursor > write_cursor)
                        read_cursor - write_cursor - 1
                    else
                        (audio_state.ring_buffer_size - write_cursor) + read_cursor - 1;

                    if (free_samples >= total_samples) {
                        var sound_buffer = handmade.GameSoundOutputBuffer{
                            .samples_per_second = @intCast(audio_state.samples_per_second),
                            .sample_count = @intCast(expected_frames_per_update),
                            .samples = temp_buffer.ptr,
                        };

                        handmade.getSoundSamples(&thread, &game_memory, &sound_buffer);

                        for (0..total_samples) |i| {
                            const buffer_index = (write_cursor + @as(u32, @intCast(i))) % audio_state.ring_buffer_size;
                            audio_state.ring_buffer[buffer_index] = temp_buffer[i];
                        }

                        const new_write_cursor = (write_cursor + total_samples) % audio_state.ring_buffer_size;
                        audio_state.write_cursor.store(new_write_cursor, .release);
                    } else {
                        std.debug.print("Ring buffer full! Skipping audio frame.\n", .{});
                    }
                }

                if (!audio_state.sound_is_valid.load(.acquire)) {
                    const current_write = audio_state.write_cursor.load(.acquire);
                    const current_read = audio_state.read_cursor.load(.acquire);
                    const current_buffered = if (current_write >= current_read)
                        current_write - current_read
                    else
                        (audio_state.ring_buffer_size - current_read) + current_write;

                    if (current_buffered >= target_buffered_samples) {
                        audio_state.sound_is_valid.store(true, .release);
                        mini_result = mini.ma_device_start(&device);
                        if (mini_result != mini.MA_SUCCESS) {
                            std.debug.print("Failed to start device: {}\n", .{mini_result});
                            return error.MiniDeviceStartFailed;
                        }
                    }
                }

                if (context.frame_callback) |cb| {
                    cb.destroy();
                }

                context.frame_callback = try surface.frame();
                context.frame_callback.?.setListener(*WlContext, wlFrameListener, &context);
                context.waiting_for_frame = true;

                flip_wall_clock = try linuxGetWallClock();

                surface.attach(global_back_buffer.buffer, 0, 0);
                surface.damage(0, 0, context.width, context.height);
                surface.commit();

                const temp: *handmade.GameInput = new_input;
                new_input = old_input;
                old_input = temp;
            }

            if (global_pause) {
                if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
            } else {
                while (context.waiting_for_frame and context.running) {
                    if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
                }
            }

            const frame_end = try linuxGetWallClock();
            const frame_end_cycles: i64 = @intCast(rdtsc());

            const ms_per_frame: f32 = 1000.0 * linuxGetSecondsElapsed(frame_start, frame_end);
            const cycles_elapsed: i64 = frame_end_cycles - frame_start_cycles;

            const frames_per_second: f32 = 1000.0 / ms_per_frame;
            const mega_cycles_per_frame: f32 = @as(f32, @floatFromInt(cycles_elapsed)) / (1000.0 * 1000.0);
            _ = frames_per_second;
            _ = mega_cycles_per_frame;

            // std.debug.print("ms/f: {d:.2}, f/s: {d:.2}, mega_cycles/f {d:.2}\n", .{ ms_per_frame, frames_per_second, mega_cycles_per_frame });
        }
    }
    if (context.frame_callback) |cb| {
        cb.destroy();
    }
}
