const std = @import("std");
const linux = @import("std").os.linux;
const debug_mode = @import("builtin").mode == @import("std").builtin.OptimizeMode.Debug;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;

const xkb = @cImport({
    @cInclude("xkbcommon/xkbcommon.h");
});

const handmade = @import("handmade.zig");

pub const DEBUGReadFileResult = struct {
    content_size: u32,
    content: ?*anyopaque,
};

const WlKeyboardContext = struct {
    context: *WlContext,
    keyboard_controller: ?*handmade.GameControllerInput,
};

const WlReplayBuffer = struct {
    file_handle: ?*anyopaque,
    memory_map: ?*anyopaque,
    file_name: [260:0]u8,
    memory_block: ?*anyopaque,
};

const WlState = struct {
    game_memory_block: ?*anyopaque,
    total_size: usize,
    replay_buffers: [4]WlReplayBuffer,

    recording_handle: ?*anyopaque,
    input_recording_index: u32,

    playback_handle: ?*anyopaque,
    input_playing_index: u32,

    exe_file_path: [260:0]u8,
    one_past_last_exe_file_name_slash: ?[*:0]u8,
};

const WlRecordedInput = struct {
    input_count: i32,
    input_stream: *handmade.GameInput,
};

const WlGameCode = struct {
    game_code_dll: ?*anyopaque,
    dll_last_write_time: bool,

    updateAndRender: ?handmade.UpdateAndRenderFnPtr,
    getSoundSamples: ?handmade.GetSoundSamplesFnPtr,

    is_valid: bool,
};

const wlDebugTimeMarker = struct {
    output_play_cursor: u32,
    output_write_cursor: u32,
    output_location: u32,
    output_byte_count: u32,

    expected_flip_play_cursor: u32,
    flip_play_cursor: u32,
    flip_write_cursor: u32,
};

const WlOffscreenBuffer = struct {
    buffer: ?*wl.Buffer,
    memory: []align(4096) u8,
    width: i32,
    height: i32,
    pitch: usize,
};

const WlWindowDimension = struct {
    width: i32,
    height: i32,
};

const WlSoundOutput = struct {
    samples_per_second: u32,
    bytes_per_sample: u32,
    running_sample_index: u32,
    secondary_buffer_size: u32,
    safety_bytes: u32,
};

const WlContext = struct {
    shm: ?*wl.Shm,
    compositor: ?*wl.Compositor,
    wm_base: ?*xdg.WmBase,
    seat: ?*wl.Seat,
    keyboard: ?*wl.Keyboard,
    mouse: ?*wl.Pointer,

    xkb_context: ?*xkb.struct_xkb_context,
    xkb_keymap: ?*xkb.struct_xkb_keymap,
    xkb_state: ?*xkb.struct_xkb_state,

    width: i32 = 1280,
    height: i32 = 720,
    configured: bool = false,
    running: bool = true,
};

var global_back_buffer = std.mem.zeroInit(WlOffscreenBuffer, .{});

inline fn rdtsc() usize {
    var a: u32 = undefined;
    var b: u32 = undefined;
    asm volatile ("rdtsc"
        : [a] "={edx}" (a),
          [b] "={eax}" (b),
    );
    return (@as(u64, a) << 32) | b;
}

// NOTE: (CASEY) Start-->
// These are NOT for doing anything in the shipping game - they are
// blocking and the write doesn't protect against lost data!

pub fn debugPlatformReadEntireFile(thread: *handmade.ThreadContext, file_path: [*:0]const u8) DEBUGReadFileResult {
    const result = DEBUGReadFileResult{
        .content_size = 0,
        .content = null,
    };
    _ = thread;
    _ = file_path;

    // const file_handle: foundation.HANDLE = fs.CreateFileA(file_path, fs.FILE_GENERIC_READ, fs.FILE_SHARE_READ, null, fs.OPEN_EXISTING, fs.FILE_ATTRIBUTE_NORMAL, null);
    // if (file_handle != foundation.INVALID_HANDLE_VALUE) {
    //     var file_size: foundation.LARGE_INTEGER = undefined;
    //     if (zig32.zig.SUCCEEDED(fs.GetFileSizeEx(file_handle, &file_size))) {
    //         std.debug.assert(file_size.QuadPart <= 0xFFFFFFFF);
    //         const file_size32: u32 = @intCast(file_size.QuadPart);
    //         result.content = zig32_mem.VirtualAlloc(null, file_size32, reserve_and_commit, zig32_mem.PAGE_READWRITE);
    //         if (result.content) |content| {
    //             var bytes_read: win.DWORD = 0;
    //             if (zig32.zig.SUCCEEDED(fs.ReadFile(file_handle, content, file_size32, &bytes_read, null)) and file_size32 == bytes_read) {
    //                 std.debug.print("File read successfully.\n", .{});
    //                 result.content_size = file_size32;
    //             } else {
    //                 std.debug.print("Failed to read.\n", .{});
    //                 debugPlatformFreeFileMemory(thread, content);
    //                 result.content = null;
    //             }
    //         } else {
    //             // TODO: Logging
    //         }
    //     } else {
    //         // TODO: Logging
    //     }
    //     zig32.zig.closeHandle(file_handle);
    // } else {
    //     // TODO: Logging
    // }
    return result;
}

pub fn debugPlatformFreeFileMemory(thread: *handmade.ThreadContext, memory: ?*anyopaque) void {
    _ = thread;
    if (memory) |_| {
        // _ = zig32_mem.VirtualFree(memory, 0, zig32_mem.MEM_RELEASE);
    }
}

pub fn debugPlatformWriteEntireFile(thread: *handmade.ThreadContext, file_name: [*:0]const u8, memory_size: u32, memory: ?*anyopaque) bool {
    _ = thread;
    _ = file_name;
    _ = memory_size;
    _ = memory;
    const result = false;

    // const file_handle = fs.CreateFileA(file_name, fs.FILE_GENERIC_WRITE, fs.FILE_SHARE_NONE, null, fs.CREATE_ALWAYS, fs.FILE_ATTRIBUTE_NORMAL, null);
    // defer zig32.zig.closeHandle(file_handle);
    // if (file_handle != foundation.INVALID_HANDLE_VALUE) {
    //     var bytes_written: win.DWORD = 0;
    //     if (zig32.zig.SUCCEEDED(fs.WriteFile(file_handle, memory, memory_size, &bytes_written, null))) {
    //         std.debug.print("File written successfully\n", .{});
    //         result = bytes_written == memory_size;
    //     } else {
    //         // TODO: Logging
    //     }
    // } else {
    //     // TODO: Logging
    // }
    return result;
}

// NOTE: END-->

fn wlProcessKeySym(keyboard_controller: *handmade.GameControllerInput, key_sym: xkb.xkb_keysym_t, is_down: bool, context: *WlContext) void {
    switch (key_sym) {
        xkb.XKB_KEY_w, xkb.XKB_KEY_W => wlProcessKeyboardMessage(&keyboard_controller.button.input.move_up, is_down),
        xkb.XKB_KEY_a, xkb.XKB_KEY_A => wlProcessKeyboardMessage(&keyboard_controller.button.input.move_left, is_down),
        xkb.XKB_KEY_s, xkb.XKB_KEY_S => wlProcessKeyboardMessage(&keyboard_controller.button.input.move_down, is_down),
        xkb.XKB_KEY_d, xkb.XKB_KEY_D => wlProcessKeyboardMessage(&keyboard_controller.button.input.move_right, is_down),

        xkb.XKB_KEY_q, xkb.XKB_KEY_Q => wlProcessKeyboardMessage(&keyboard_controller.button.input.left_shoulder, is_down),
        xkb.XKB_KEY_e, xkb.XKB_KEY_E => wlProcessKeyboardMessage(&keyboard_controller.button.input.right_shoulder, is_down),

        xkb.XKB_KEY_UP => wlProcessKeyboardMessage(&keyboard_controller.button.input.action_up, is_down),
        xkb.XKB_KEY_Left => wlProcessKeyboardMessage(&keyboard_controller.button.input.action_left, is_down),
        xkb.XKB_KEY_DOWN => wlProcessKeyboardMessage(&keyboard_controller.button.input.action_down, is_down),
        xkb.XKB_KEY_Right => wlProcessKeyboardMessage(&keyboard_controller.button.input.action_right, is_down),

        xkb.XKB_KEY_Escape => {
            wlProcessKeyboardMessage(&keyboard_controller.button.input.back, is_down);
            if (is_down) {
                context.running = false;
            }
        },

        else => {},
    }
}

fn wlProcessKeyboardMessage(new_state: *handmade.GameButtonState, is_down: bool) void {
    if (new_state.ended_down != is_down) {
        new_state.ended_down = is_down;
        new_state.half_transition_count += 1;
    }
}

fn WlCreateBuffer(buffer: *WlOffscreenBuffer, shm: *wl.Shm, width: i32, height: i32) !void {
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
                const xkb_keycode: xkb.xkb_keycode_t = key.key + 8;
                const key_sym = xkb.xkb_state_key_get_one_sym(state, xkb_keycode);

                if (kb_context.keyboard_controller) |controller| {
                    wlProcessKeySym(controller, key_sym, is_down, kb_context.context);
                }
            }
        },
        .keymap => |keymap_info| {
            if (kb_context.context.xkb_state) |state| {
                xkb.xkb_state_unref(state);
                kb_context.context.xkb_state = null;
            }
            if (kb_context.context.xkb_keymap) |km| {
                xkb.xkb_keymap_unref(km);
                kb_context.context.xkb_keymap = null;
            }

            const keymap_size: usize = @intCast(keymap_info.size);
            const keymap_string = std.posix.mmap(null, keymap_size, std.posix.PROT.READ, .{ .TYPE = .PRIVATE }, keymap_info.fd, 0) catch {
                std.debug.print("Failed to map keymap\n", .{});
                return;
            };
            defer std.posix.munmap(keymap_string);

            if (kb_context.context.xkb_context) |xkb_ctx| {
                kb_context.context.xkb_keymap = xkb.xkb_keymap_new_from_string(xkb_ctx, @ptrCast(keymap_string.ptr), xkb.XKB_KEYMAP_FORMAT_TEXT_V1, xkb.XKB_KEYMAP_COMPILE_NO_FLAGS);

                if (kb_context.context.xkb_keymap) |km| {
                    kb_context.context.xkb_state = xkb.xkb_state_new(km);
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
                _ = xkb.xkb_state_update_mask(state, mods.mods_depressed, mods.mods_latched, mods.mods_locked, 0, 0, mods.group);
            }
        },
        .repeat_info => {},
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
    const display = try wl.Display.connect(null);
    defer display.disconnect();

    const registry = try wl.Display.getRegistry(display);
    defer registry.destroy();

    var context = WlContext{
        .shm = null,
        .compositor = null,
        .wm_base = null,
        .seat = null,
        .keyboard = null,
        .mouse = null,
        .xkb_context = null,
        .xkb_keymap = null,
        .xkb_state = null,
    };

    context.xkb_context = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS);
    if (context.xkb_context == null) {
        std.debug.print("Failed to create XKB context.\n", .{});
        return error.XKBContextFailed;
    }

    defer {
        if (context.xkb_state) |state| xkb.xkb_state_unref(state);
        if (context.xkb_keymap) |km| xkb.xkb_keymap_unref(km);
        if (context.xkb_context) |ctx| xkb.xkb_context_unref(ctx);
    }

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

    wm_base.setListener(*xdg.WmBase, wlWMBaseListener, wm_base);
    xdg_surface.setListener(*WlContext, wlXDGSurfaceListener, &context);
    xdg_toplevel.setListener(*WlContext, wlXDGToplevelListener, &context);

    surface.commit();
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    while (!context.configured and context.running) {
        if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
    }

    if (!context.running) return;

    var game_memory = std.mem.zeroInit(handmade.GameMemory, .{
        .permanent_storage_size = handmade.megaBytes(64),
        .transient_storage_size = handmade.gigaBytes(1),

        .debugPlatformReadEntireFile = debugPlatformReadEntireFile,
        .debugPlatformFreeFilMemory = debugPlatformFreeFileMemory,
        .debugPlatformWriteEntireFile = debugPlatformWriteEntireFile,
    });

    var input = [_]handmade.GameInput{std.mem.zeroInit(handmade.GameInput, .{})} ** 2;
    var new_input: *handmade.GameInput = &input[0];
    var old_input: *handmade.GameInput = &input[1];

    try WlCreateBuffer(&global_back_buffer, shm, context.width, context.height);
    defer if (global_back_buffer.buffer) |buf| buf.destroy();

    var keyboard_context = WlKeyboardContext{
        .context = &context,
        .keyboard_controller = null,
    };

    if (context.keyboard) |kbd| {
        kbd.setListener(*WlKeyboardContext, wlKeyboardListener, &keyboard_context);
    }

    while (context.running) {
        if (global_back_buffer.width != context.width or global_back_buffer.height != context.height) {
            global_back_buffer.buffer.?.destroy();
            std.posix.munmap(global_back_buffer.memory);
            try WlCreateBuffer(&global_back_buffer, shm, context.width, context.height);
        }

        const old_keyboard_controller: *handmade.GameControllerInput = handmade.getController(old_input, 0);
        const new_keyboard_controller: *handmade.GameControllerInput = handmade.getController(new_input, 0);
        new_keyboard_controller.is_connected = true;

        for (0..new_keyboard_controller.button.buttons.len) |button_index| {
            new_keyboard_controller.button.buttons[button_index].ended_down = old_keyboard_controller.button.buttons[button_index].ended_down;
        }

        keyboard_context.keyboard_controller = new_keyboard_controller;

        if (display.dispatch() != .SUCCESS) return error.DispatchFailed;

        var thread = std.mem.zeroInit(handmade.ThreadContext, .{});

        var buffer = handmade.GameOffScreenBuffer{
            .memory = global_back_buffer.memory,
            .width = global_back_buffer.width,
            .height = global_back_buffer.height,
            .pitch = global_back_buffer.pitch,
            .bytes_per_pixel = 4,
        };

        handmade.TEMPgameUpdateAndRender(&thread, &game_memory, new_input, &buffer);
        // handmade.gameUpdateAndRender(&thread, &game_memory, &input[0], &buffer);

        surface.attach(global_back_buffer.buffer, 0, 0);
        surface.commit();

        const temp: *handmade.GameInput = new_input;
        new_input = old_input;
        old_input = temp;
    }
}
