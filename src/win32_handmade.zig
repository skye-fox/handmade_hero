const std = @import("std");
const win = @import("std").os.windows;
const debug = @import("builtin").mode == @import("std").builtin.OptimizeMode.Debug;

const game = @import("handmade.zig");

const zig32 = @import("zigwin32");
const audio = @import("zigwin32").media.audio;
const controller = @import("zigwin32").ui.input.xbox_controller;
const d_sound = @import("zigwin32").media.audio.direct_sound;
const foundation = @import("zigwin32").foundation;
const gdi = @import("zigwin32").graphics.gdi;
const kbam = @import("zigwin32").ui.input.keyboard_and_mouse;
const fs = @import("zigwin32").storage.file_system;
const perf = @import("zigwin32").system.performance;
const wam = @import("zigwin32").ui.windows_and_messaging;
const zig32_mem = @import("zigwin32").system.memory;

pub const DEBUGReadFileResult = struct {
    content_size: u32,
    content: ?*anyopaque,
};

const Win32OffscreenBuffer = struct {
    info: gdi.BITMAPINFO,
    memory: ?*anyopaque,
    width: i32,
    height: i32,
    pitch: i32,
    bytes_per_pixel: i32,
};

const Win32WindowDimension = struct {
    width: i32,
    height: i32,
};

const Win32SoundOutput = struct {
    samples_per_second: u32,
    bytes_per_sample: u32,
    running_sample_index: u32,
    secondary_buffer_size: u32,
    tsine: f32,
    latency_sample_count: u32,
};

const reserve_and_commit = zig32_mem.VIRTUAL_ALLOCATION_TYPE{ .RESERVE = 1, .COMMIT = 1 };

var instance: foundation.HINSTANCE = undefined;

var global_running = false;
var global_back_buffer = std.mem.zeroInit(Win32OffscreenBuffer, .{});
var global_secondary_buffer: ?*d_sound.IDirectSoundBuffer8 = undefined;
var global_perf_count_frequency: i64 = 0;

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

pub fn DEBUG_readEntireFile(file_path: [*:0]const u8) DEBUGReadFileResult {
    var result = DEBUGReadFileResult{
        .content_size = 0,
        .content = null,
    };

    const file_handle: foundation.HANDLE = fs.CreateFileA(file_path, fs.FILE_GENERIC_READ, fs.FILE_SHARE_READ, null, fs.OPEN_EXISTING, fs.FILE_ATTRIBUTE_NORMAL, null);
    if (file_handle != foundation.INVALID_HANDLE_VALUE) {
        var file_size: foundation.LARGE_INTEGER = undefined;
        if (zig32.zig.SUCCEEDED(fs.GetFileSizeEx(file_handle, &file_size))) {
            std.debug.assert(file_size.QuadPart <= 0xFFFFFFFF);
            const file_size32: u32 = @intCast(file_size.QuadPart);
            result.content = zig32_mem.VirtualAlloc(null, file_size32, reserve_and_commit, zig32_mem.PAGE_READWRITE);
            if (result.content) |content| {
                var bytes_read: win.DWORD = 0;
                if (zig32.zig.SUCCEEDED(fs.ReadFile(file_handle, content, file_size32, &bytes_read, null)) and file_size32 == bytes_read) {
                    std.debug.print("File read successfully.\n", .{});
                    result.content_size = file_size32;
                } else {
                    std.debug.print("Failed to read.\n", .{});
                    DEBUG_freeFileMemory(content);
                    result.content = null;
                }
            } else {
                // TODO: Logging
            }
        } else {
            // TODO: Logging
        }
        zig32.zig.closeHandle(file_handle);
    } else {
        // TODO: Logging
    }
    return result;
}

pub fn DEBUG_freeFileMemory(memory: ?*anyopaque) void {
    if (memory) |_| {
        _ = zig32_mem.VirtualFree(memory, 0, zig32_mem.MEM_RELEASE);
    }
}

pub fn DEBUG_writeEntireFile(file_name: [*:0]const u8, memory_size: u32, memory: ?*anyopaque) bool {
    var result = false;

    const file_handle = fs.CreateFileA(file_name, fs.FILE_GENERIC_WRITE, fs.FILE_SHARE_NONE, null, fs.CREATE_ALWAYS, fs.FILE_ATTRIBUTE_NORMAL, null);
    defer zig32.zig.closeHandle(file_handle);
    if (file_handle != foundation.INVALID_HANDLE_VALUE) {
        var bytes_written: win.DWORD = 0;
        if (zig32.zig.SUCCEEDED(fs.WriteFile(file_handle, memory, memory_size, &bytes_written, null))) {
            std.debug.print("File written successfully\n", .{});
            result = bytes_written == memory_size;
        } else {
            // TODO: Logging
        }
    } else {
        // TODO: Logging
    }
    return result;
}

// NOTE: END-->

inline fn win32GetWallClock() foundation.LARGE_INTEGER {
    var result: foundation.LARGE_INTEGER = undefined;
    _ = perf.QueryPerformanceCounter(&result);
    return result;
}

inline fn win32GetSecondsElapsed(start: foundation.LARGE_INTEGER, end: foundation.LARGE_INTEGER) f32 {
    const result: f32 = @as(f32, @floatFromInt(end.QuadPart - start.QuadPart)) / @as(f32, @floatFromInt(global_perf_count_frequency));
    return result;
}

fn win32DebugDrawVertical(buffer: *Win32OffscreenBuffer, x: u32, top: u32, bottom: u32, color: u32) void {
    var pixel: [*]u8 = @as([*]u8, @ptrCast(buffer.memory)) + x * @as(u32, @intCast(buffer.bytes_per_pixel)) + top * @as(u32, @intCast(buffer.pitch));
    for (top..bottom) |_| {
        @as([*]u32, @ptrCast(@alignCast(pixel)))[0] = color;
        pixel += @as(u32, @intCast(global_back_buffer.pitch));
    }
}

fn win32DebugSyncDisplay(back_buffer: *Win32OffscreenBuffer, sound_output: *Win32SoundOutput, last_play_cursor: []win.DWORD, last_play_cursor_count: u32) void {
    const pad_x: u32 = 16;
    const pad_y: u32 = 16;
    const top = pad_y;
    const bottom: u32 = @as(u32, @intCast(back_buffer.height)) - pad_y;

    const c: f32 = @as(f32, @floatFromInt(back_buffer.width - 2 * pad_x)) / @as(f32, @floatFromInt(sound_output.secondary_buffer_size));
    for (0..last_play_cursor_count) |index| {
        const this_play_cursor: win.DWORD = last_play_cursor[index];
        std.debug.assert(this_play_cursor < sound_output.secondary_buffer_size);
        const x_f32: f32 = c * @as(f32, @floatFromInt(this_play_cursor));
        const x: u32 = pad_x + @as(u32, @intFromFloat(x_f32));
        win32DebugDrawVertical(back_buffer, x, top, bottom, 0xFFFFFFFF);
    }
}

fn win32ProcessPendingMessages(keyboard_controller: *game.GameControllerInput) void {
    var message: wam.MSG = undefined;
    while (wam.PeekMessageA(&message, null, 0, 0, wam.PM_REMOVE) != 0) {
        switch (message.message) {
            wam.WM_QUIT => global_running = false,
            wam.WM_SYSKEYDOWN, wam.WM_SYSKEYUP, wam.WM_KEYDOWN, wam.WM_KEYUP => {
                // const vk_int = message.wParam;
                const was_down: bool = ((message.lParam & (1 << 30)) != 0);
                const is_down: bool = ((message.lParam & (1 << 31)) == 0);

                if (was_down != is_down) {
                    const vk_code = std.meta.intToEnum(kbam.VIRTUAL_KEY, message.wParam) catch {
                        continue;
                    };
                    switch (vk_code) {
                        .W => win32ProcessKeyboardMessage(&keyboard_controller.button.input.move_up, is_down),
                        .A => win32ProcessKeyboardMessage(&keyboard_controller.button.input.move_left, is_down),
                        .S => win32ProcessKeyboardMessage(&keyboard_controller.button.input.move_down, is_down),
                        .D => win32ProcessKeyboardMessage(&keyboard_controller.button.input.move_right, is_down),
                        .Q => win32ProcessKeyboardMessage(&keyboard_controller.button.input.left_shoulder, is_down),
                        .E => win32ProcessKeyboardMessage(&keyboard_controller.button.input.right_shoulder, is_down),
                        .UP => win32ProcessKeyboardMessage(&keyboard_controller.button.input.action_up, is_down),
                        .LEFT => win32ProcessKeyboardMessage(&keyboard_controller.button.input.action_left, is_down),
                        .DOWN => win32ProcessKeyboardMessage(&keyboard_controller.button.input.action_down, is_down),
                        .RIGHT => win32ProcessKeyboardMessage(&keyboard_controller.button.input.action_right, is_down),
                        .SPACE => {},
                        .F4 => {
                            const alt_down: bool = ((message.lParam & (1 << 29)) != 0);
                            if (alt_down) {
                                global_running = false;
                            }
                        },
                        .ESCAPE => win32ProcessKeyboardMessage(&keyboard_controller.button.input.start, is_down),
                        else => {},
                    }
                }
            },
            else => {
                _ = wam.TranslateMessage(&message);
                _ = wam.DispatchMessageA(&message);
            },
        }
    }
}

fn win32ProcessKeyboardMessage(new_state: *game.GameButtonState, is_down: bool) void {
    std.debug.assert(new_state.ended_down != is_down);
    new_state.ended_down = is_down;
    new_state.half_transition_count += 1;
}

fn win32ProcessXInputStickValue(value: win.SHORT, deadzone_threshold: win.SHORT) f32 {
    var result: f32 = 0.0;

    if (value < -deadzone_threshold) {
        result = @as(f32, @floatFromInt(@as(i32, value) + @as(i32, deadzone_threshold))) / (32768.0 - @as(f32, @floatFromInt(deadzone_threshold)));
    } else if (value > deadzone_threshold) {
        result = @as(f32, @floatFromInt(@as(i32, value) - @as(i32, deadzone_threshold))) / (32767.0 - @as(f32, @floatFromInt(deadzone_threshold)));
    }
    return result;
}

fn win32ProcessXInputDigitalButton(old_state: *game.GameButtonState, new_state: *game.GameButtonState, xinput_button_state: win.DWORD, button_bit: win.DWORD) void {
    new_state.ended_down = if ((xinput_button_state & button_bit) == button_bit) true else false;
    new_state.half_transition_count = if (old_state.ended_down != new_state.ended_down) 1 else 0;
}

fn win32ClearBuffer(sound_output: *Win32SoundOutput) void {
    var region_one: ?*anyopaque = null;
    var region_one_size: win.DWORD = 0;
    var region_two: ?*anyopaque = null;
    var region_two_size: win.DWORD = 0;
    if (zig32.zig.SUCCEEDED(global_secondary_buffer.?.IDirectSoundBuffer.Lock(0, sound_output.secondary_buffer_size, &region_one, &region_one_size, &region_two, &region_two_size, 0))) {
        var dest_sample: [*]u8 = @ptrCast(@alignCast(region_one));
        for (0..region_one_size) |_| {
            dest_sample[0] = 0;
            dest_sample += 1;
        }
        if (region_two) |_| {
            dest_sample = @ptrCast(@alignCast(region_two));
            for (0..region_two_size) |_| {
                dest_sample[0] = 0;
                dest_sample += 1;
            }
        }
        _ = global_secondary_buffer.?.IDirectSoundBuffer.Unlock(region_one, region_one_size, region_two, region_two_size);
    }
}

fn win32FillSoundBuffer(sound_output: *Win32SoundOutput, source_buffer: *game.GameSoundOutputBuffer, byte_to_lock: win.DWORD, bytes_to_write: win.DWORD) void {
    var region_one: ?*anyopaque = null;
    var region_one_size: win.DWORD = 0;
    var region_two: ?*anyopaque = null;
    var region_two_size: win.DWORD = 0;

    if (zig32.zig.SUCCEEDED(global_secondary_buffer.?.IDirectSoundBuffer.Lock(byte_to_lock, bytes_to_write, &region_one, &region_one_size, &region_two, &region_two_size, 0))) {
        const region_one_sample_count = region_one_size / sound_output.bytes_per_sample;

        var dest_sample: [*]i16 = @ptrCast(@alignCast(region_one));
        var source_sample: [*]i16 = source_buffer.samples;
        for (0..region_one_sample_count) |_| {
            dest_sample[0] = source_sample[0];
            dest_sample += 1;
            source_sample += 1;
            dest_sample[0] = source_sample[0];
            dest_sample += 1;
            source_sample += 1;

            sound_output.running_sample_index += 1;
        }

        if (region_two) |_| {
            const region_two_sample_count = region_two_size / sound_output.bytes_per_sample;
            dest_sample = @ptrCast(@alignCast(region_two));
            for (0..region_two_sample_count) |_| {
                dest_sample[0] = source_sample[0];
                dest_sample += 1;
                source_sample += 1;
                dest_sample[0] = source_sample[0];
                dest_sample += 1;
                source_sample += 1;

                sound_output.running_sample_index += 1;
            }
        }
        _ = global_secondary_buffer.?.IDirectSoundBuffer.Unlock(region_one, region_one_size, region_two, region_two_size);
    }
}

fn win32InitDSound(window: foundation.HWND, samples_per_second: u32, buffer_size: u32) void {
    var direct_sound: ?*d_sound.IDirectSound8 = undefined;
    if (zig32.zig.SUCCEEDED(d_sound.DirectSoundCreate8(null, &direct_sound, null))) {
        var wave_format = std.mem.zeroInit(audio.WAVEFORMATEX, .{});
        wave_format.wFormatTag = audio.WAVE_FORMAT_PCM;
        wave_format.nChannels = 2;
        wave_format.nSamplesPerSec = samples_per_second;
        wave_format.wBitsPerSample = 16;
        wave_format.nBlockAlign = (wave_format.nChannels * wave_format.wBitsPerSample) / 8;
        wave_format.nAvgBytesPerSec = wave_format.nSamplesPerSec * wave_format.nBlockAlign;

        if (zig32.zig.SUCCEEDED(direct_sound.?.IDirectSound.SetCooperativeLevel(window, d_sound.DSSCL_PRIORITY))) {
            var buffer_description = std.mem.zeroInit(d_sound.DSBUFFERDESC, .{});
            buffer_description.dwSize = @sizeOf(@TypeOf(buffer_description));
            buffer_description.dwFlags = d_sound.DSBCAPS_PRIMARYBUFFER;

            var primary_buffer: ?*d_sound.IDirectSoundBuffer8 = undefined;
            if (zig32.zig.SUCCEEDED(direct_sound.?.IDirectSound.CreateSoundBuffer(&buffer_description, &primary_buffer, null))) {
                if (zig32.zig.SUCCEEDED(primary_buffer.?.IDirectSoundBuffer.SetFormat(&wave_format))) {
                    // We have finally set the format
                    std.debug.print("Primary buffer was set.\n", .{});
                } else {
                    // TODO: Logging
                }
            } else {
                // TODO: Logging
            }
        } else {
            // TODO: Logging
        }
        var buffer_description = std.mem.zeroInit(d_sound.DSBUFFERDESC, .{});
        buffer_description.dwSize = @sizeOf(@TypeOf(buffer_description));
        buffer_description.dwBufferBytes = buffer_size;
        buffer_description.lpwfxFormat = &wave_format;

        if (zig32.zig.SUCCEEDED(direct_sound.?.IDirectSound.CreateSoundBuffer(&buffer_description, &global_secondary_buffer, null))) {
            std.debug.print("Secondary buffer created successfully.\n", .{});
            if (zig32.zig.SUCCEEDED(global_secondary_buffer.?.IDirectSoundBuffer.SetFormat(&wave_format))) {
                // We have finally set the format
            } else {
                // TODO: Logging
            }
        } else {
            // TODO: Logging
        }
    } else {
        // TODO: Logging
    }
}

fn win32GetWindowDimension(window: foundation.HWND) Win32WindowDimension {
    var client_rect: foundation.RECT = undefined;
    _ = wam.GetClientRect(window, &client_rect);

    const result = Win32WindowDimension{
        .width = client_rect.right - client_rect.left,
        .height = client_rect.bottom - client_rect.top,
    };
    return result;
}

fn win32ResizeDIBSection(buffer: *Win32OffscreenBuffer, width: i32, height: i32) void {
    if (buffer.memory) |memory| {
        _ = zig32_mem.VirtualFree(memory, 0, zig32_mem.MEM_RELEASE);
    }

    buffer.width = width;
    buffer.height = height;

    buffer.info.bmiHeader.biSize = @sizeOf(@TypeOf(buffer.info.bmiHeader));
    buffer.info.bmiHeader.biWidth = buffer.width;
    buffer.info.bmiHeader.biHeight = -buffer.height;
    buffer.info.bmiHeader.biPlanes = 1;
    buffer.info.bmiHeader.biBitCount = 32;
    buffer.info.bmiHeader.biCompression = gdi.BI_RGB;

    buffer.bytes_per_pixel = 4;

    const bitmap_memory_size = (buffer.width * buffer.height) * buffer.bytes_per_pixel;
    buffer.memory = zig32_mem.VirtualAlloc(null, @as(usize, @intCast(bitmap_memory_size)), reserve_and_commit, zig32_mem.PAGE_READWRITE);

    buffer.pitch = buffer.width * buffer.bytes_per_pixel;
}

fn win32DisplayBufferInWindow(buffer: *Win32OffscreenBuffer, device_context: gdi.HDC, window_width: i32, window_height: i32) void {
    _ = gdi.StretchDIBits(device_context, 0, 0, window_width, window_height, 0, 0, buffer.width, buffer.height, buffer.memory, &buffer.info, gdi.DIB_RGB_COLORS, gdi.SRCCOPY);
}

fn win32MainWindowCallback(window: foundation.HWND, message: win.UINT, wparam: foundation.WPARAM, lparam: foundation.LPARAM) callconv(.c) foundation.LRESULT {
    var result: foundation.LRESULT = 0;
    switch (message) {
        wam.WM_ACTIVATEAPP => {
            std.debug.print("WM_ACTIVATEAPP\n", .{});
        },
        wam.WM_CLOSE, wam.WM_DESTROY => global_running = false,
        wam.WM_KEYDOWN, wam.WM_KEYUP, wam.WM_SYSKEYDOWN, wam.WM_SYSKEYUP => {
            unreachable;
        },
        wam.WM_PAINT => {
            var paint: gdi.PAINTSTRUCT = undefined;
            const device_context = gdi.BeginPaint(window, &paint);

            const dimension = win32GetWindowDimension(window);

            win32DisplayBufferInWindow(&global_back_buffer, device_context.?, dimension.width, dimension.height);
            _ = gdi.EndPaint(window, &paint);
        },
        else => {
            result = wam.DefWindowProcA(window, message, wparam, lparam);
        },
    }
    return result;
}

pub fn run() !void {
    var perf_count_frequency_result: foundation.LARGE_INTEGER = undefined;
    _ = perf.QueryPerformanceFrequency(&perf_count_frequency_result);
    global_perf_count_frequency = perf_count_frequency_result.QuadPart;

    // NOTE:(Casey): Set the windows scheduler granularity to 1ms.
    const desired_scheduler_ms = 1;
    const sleep_is_granular: bool = zig32.media.timeBeginPeriod(desired_scheduler_ms) == zig32.everything.TIMERR_NOERROR;

    win32ResizeDIBSection(&global_back_buffer, 1280, 720);

    var window_class = std.mem.zeroInit(wam.WNDCLASSA, .{});

    window_class.style = .{ .HREDRAW = 1, .VREDRAW = 1, .OWNDC = 1 };
    window_class.lpfnWndProc = win32MainWindowCallback;
    window_class.hInstance = instance;
    window_class.lpszClassName = "Handmade Hero";

    const monitor_refresh_hz: u32 = 60;
    const game_update_hz: u32 = monitor_refresh_hz / 2;
    const target_seconds_per_frame: f32 = 1.0 / @as(f32, @floatFromInt(game_update_hz));

    if (wam.RegisterClassA(&window_class) != 0) {
        const window_handle = wam.CreateWindowExA(
            wam.WINDOW_EX_STYLE{},
            window_class.lpszClassName,
            "Handmade Hero",
            wam.WINDOW_STYLE{ .BORDER = 1, .DLGFRAME = 1, .GROUP = 1, .SYSMENU = 1, .TABSTOP = 1, .THICKFRAME = 1, .VISIBLE = 1 },
            wam.CW_USEDEFAULT,
            wam.CW_USEDEFAULT,
            wam.CW_USEDEFAULT,
            wam.CW_USEDEFAULT,
            null,
            null,
            instance,
            null,
        );

        if (window_handle) |window| {
            const device_context = gdi.GetDC(window);

            var sound_output: Win32SoundOutput = .{
                .samples_per_second = 48000,
                .bytes_per_sample = @sizeOf(i16) * 2,
                .running_sample_index = 0,
                .secondary_buffer_size = 0,
                .tsine = 0,
                .latency_sample_count = 0,
            };
            sound_output.secondary_buffer_size = sound_output.samples_per_second * sound_output.bytes_per_sample;
            sound_output.latency_sample_count = sound_output.samples_per_second / 15;

            win32InitDSound(window, sound_output.samples_per_second, sound_output.secondary_buffer_size);
            win32ClearBuffer(&sound_output);
            _ = global_secondary_buffer.?.IDirectSoundBuffer.Play(0, 0, d_sound.DSBPLAY_LOOPING);

            const samples: ?[*]i16 = @ptrCast(@alignCast(zig32_mem.VirtualAlloc(null, sound_output.secondary_buffer_size, reserve_and_commit, zig32_mem.PAGE_READWRITE)));

            const base_address: ?*anyopaque = if (debug) @ptrFromInt(game.teraBytes(2)) else null;

            var game_memory = game.GameMemory{
                .is_initialized = false,
                .permanent_storage_size = 0,
                .permanent_storage = null,
                .transient_storage_size = 0,
                .transient_storage = null,
            };
            game_memory.permanent_storage_size = game.megaBytes(64);
            game_memory.transient_storage_size = game.gigaBytes(4);

            const total_size: u64 = game_memory.permanent_storage_size + game_memory.transient_storage_size;
            game_memory.permanent_storage = @ptrCast(@alignCast(zig32_mem.VirtualAlloc(base_address, total_size, reserve_and_commit, zig32_mem.PAGE_READWRITE)));
            game_memory.transient_storage = @as([*]u8, @ptrCast(game_memory.permanent_storage)) + game_memory.permanent_storage_size;

            if (samples != null and game_memory.permanent_storage != null and game_memory.transient_storage != null) {
                var input = std.mem.zeroes([2]game.GameInput);
                var new_input: *game.GameInput = &input[0];
                var old_input: *game.GameInput = &input[1];

                var last_counter: foundation.LARGE_INTEGER = win32GetWallClock();

                const debug_last_play_cursor_size: u32 = game_update_hz / 2;
                var debug_last_play_cursor = std.mem.zeroes([debug_last_play_cursor_size]win.DWORD);
                var debug_last_play_cursor_index: u32 = 0;

                var last_cycle_count: i64 = @intCast(rdtsc());

                global_running = true;
                while (global_running) {
                    const old_keyboard_controller: *game.GameControllerInput = game.getController(old_input, 0);
                    const new_keyboard_controller: *game.GameControllerInput = game.getController(new_input, 0);
                    new_keyboard_controller.is_connected = true;

                    for (0..new_keyboard_controller.button.buttons.len) |button_index| {
                        new_keyboard_controller.button.buttons[button_index].ended_down = old_keyboard_controller.button.buttons[button_index].ended_down;
                    }

                    win32ProcessPendingMessages(new_keyboard_controller);

                    var max_controller_count = controller.XUSER_MAX_COUNT;
                    if (max_controller_count > new_input.controllers.len - 1) {
                        max_controller_count = new_input.controllers.len - 1;
                    }

                    for (0..max_controller_count) |controller_index| {
                        const our_controller_index = controller_index + 1;
                        const old_controller: *game.GameControllerInput = game.getController(old_input, our_controller_index);
                        const new_controller: *game.GameControllerInput = game.getController(new_input, our_controller_index);

                        var controller_state = std.mem.zeroInit(controller.XINPUT_STATE, .{});

                        if (controller.XInputGetState(@intCast(controller_index), &controller_state) == @intFromEnum(foundation.ERROR_SUCCESS)) {
                            new_controller.is_connected = true;
                            // Controller available
                            const pad = &controller_state.Gamepad;

                            new_controller.left_stick_average_x = win32ProcessXInputStickValue(pad.sThumbLX, controller.XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE);
                            new_controller.left_stick_average_y = win32ProcessXInputStickValue(pad.sThumbLY, controller.XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE);

                            new_controller.right_stick_average_x = win32ProcessXInputStickValue(pad.sThumbRX, controller.XINPUT_GAMEPAD_RIGHT_THUMB_DEADZONE);
                            new_controller.right_stick_average_y = win32ProcessXInputStickValue(pad.sThumbRY, controller.XINPUT_GAMEPAD_RIGHT_THUMB_DEADZONE);

                            if (new_controller.left_stick_average_x != 0.0 or new_controller.left_stick_average_y != 0.0) {
                                new_controller.is_analog = true;
                            }

                            if ((pad.wButtons & controller.XINPUT_GAMEPAD_DPAD_UP) != 0) {
                                new_controller.left_stick_average_y = 1.0;
                                new_controller.is_analog = false;
                            }

                            if ((pad.wButtons & controller.XINPUT_GAMEPAD_DPAD_DOWN) != 0) {
                                new_controller.left_stick_average_y = -1.0;
                                new_controller.is_analog = false;
                            }

                            if ((pad.wButtons & controller.XINPUT_GAMEPAD_DPAD_LEFT) != 0) {
                                new_controller.left_stick_average_x = -1.0;
                                new_controller.is_analog = false;
                            }

                            if ((pad.wButtons & controller.XINPUT_GAMEPAD_DPAD_RIGHT) != 0) {
                                new_controller.left_stick_average_x = 1.0;
                                new_controller.is_analog = false;
                            }

                            // const threshold: f32 = 0.5;
                            //
                            // win32ProcessXInputDigitalButton(
                            //     &old_controller.button.input.move_up,
                            //     &new_controller.button.input.move_up,
                            //     if (new_controller.left_stick_average_y < threshold) 1 else 0,
                            //     1,
                            // );
                            //
                            // win32ProcessXInputDigitalButton(
                            //     &old_controller.button.input.move_down,
                            //     &new_controller.button.input.move_down,
                            //     if (new_controller.left_stick_average_y < -threshold) 1 else 0,
                            //     1,
                            // );
                            //
                            // win32ProcessXInputDigitalButton(
                            //     &old_controller.button.input.move_left,
                            //     &new_controller.button.input.move_left,
                            //     if (new_controller.left_stick_average_x < -threshold) 1 else 0,
                            //     1,
                            // );
                            //
                            // win32ProcessXInputDigitalButton(
                            //     &old_controller.button.input.move_right,
                            //     &new_controller.button.input.move_right,
                            //     if (new_controller.left_stick_average_x < threshold) 1 else 0,
                            //     1,
                            // );

                            win32ProcessXInputDigitalButton(
                                &old_controller.button.input.move_up,
                                &new_controller.button.input.move_up,
                                pad.wButtons,
                                controller.XINPUT_GAMEPAD_DPAD_UP,
                            );
                            win32ProcessXInputDigitalButton(
                                &old_controller.button.input.move_down,
                                &new_controller.button.input.move_down,
                                pad.wButtons,
                                controller.XINPUT_GAMEPAD_DPAD_DOWN,
                            );
                            win32ProcessXInputDigitalButton(
                                &old_controller.button.input.move_left,
                                &new_controller.button.input.move_left,
                                pad.wButtons,
                                controller.XINPUT_GAMEPAD_DPAD_LEFT,
                            );
                            win32ProcessXInputDigitalButton(
                                &old_controller.button.input.move_right,
                                &new_controller.button.input.move_right,
                                pad.wButtons,
                                controller.XINPUT_GAMEPAD_DPAD_RIGHT,
                            );

                            win32ProcessXInputDigitalButton(
                                &old_controller.button.input.action_down,
                                &new_controller.button.input.action_down,
                                pad.wButtons,
                                controller.XINPUT_GAMEPAD_A,
                            );
                            win32ProcessXInputDigitalButton(
                                &old_controller.button.input.action_right,
                                &new_controller.button.input.action_right,
                                pad.wButtons,
                                controller.XINPUT_GAMEPAD_B,
                            );
                            win32ProcessXInputDigitalButton(
                                &old_controller.button.input.action_left,
                                &new_controller.button.input.action_left,
                                pad.wButtons,
                                controller.XINPUT_GAMEPAD_X,
                            );
                            win32ProcessXInputDigitalButton(
                                &old_controller.button.input.action_up,
                                &new_controller.button.input.action_up,
                                pad.wButtons,
                                controller.XINPUT_GAMEPAD_Y,
                            );

                            win32ProcessXInputDigitalButton(
                                &old_controller.button.input.start,
                                &new_controller.button.input.start,
                                pad.wButtons,
                                controller.XINPUT_GAMEPAD_START,
                            );
                            win32ProcessXInputDigitalButton(
                                &old_controller.button.input.back,
                                &new_controller.button.input.back,
                                pad.wButtons,
                                controller.XINPUT_GAMEPAD_BACK,
                            );

                            win32ProcessXInputDigitalButton(
                                &old_controller.button.input.left_shoulder,
                                &new_controller.button.input.left_shoulder,
                                pad.wButtons,
                                controller.XINPUT_GAMEPAD_LEFT_SHOULDER,
                            );
                            win32ProcessXInputDigitalButton(
                                &old_controller.button.input.right_shoulder,
                                &new_controller.button.input.right_shoulder,
                                pad.wButtons,
                                controller.XINPUT_GAMEPAD_RIGHT_SHOULDER,
                            );
                        } else {
                            // Controller not available
                        }
                    }

                    var byte_to_lock: win.DWORD = 0;
                    var bytes_to_write: win.DWORD = 0;
                    var target_cursor: win.DWORD = 0;
                    var write_cursor: win.DWORD = 0;
                    var play_cursor: win.DWORD = 0;
                    var sound_is_valid = false;

                    if (zig32.zig.SUCCEEDED(global_secondary_buffer.?.IDirectSoundBuffer.GetCurrentPosition(&play_cursor, &write_cursor))) {
                        byte_to_lock = (sound_output.running_sample_index * sound_output.bytes_per_sample) % sound_output.secondary_buffer_size;
                        target_cursor = ((play_cursor + (sound_output.latency_sample_count * sound_output.bytes_per_sample)) % sound_output.secondary_buffer_size);
                        if (byte_to_lock > target_cursor) {
                            bytes_to_write = sound_output.secondary_buffer_size - byte_to_lock;
                            bytes_to_write += target_cursor;
                        } else {
                            bytes_to_write = target_cursor - byte_to_lock;
                        }

                        sound_is_valid = true;
                    }

                    var game_sound_output_buffer = game.GameSoundOutputBuffer{
                        .samples_per_second = @intCast(sound_output.samples_per_second),
                        .sample_count = @intCast(bytes_to_write / sound_output.bytes_per_sample),
                        .samples = @ptrCast(samples),
                    };

                    var buffer = game.GameOffScreenBuffer{
                        .memory = @ptrCast(@alignCast(global_back_buffer.memory)),
                        .width = global_back_buffer.width,
                        .height = global_back_buffer.height,
                        .pitch = global_back_buffer.pitch,
                    };

                    try game.gameUpdateAndRender(&game_memory, new_input, &buffer, &game_sound_output_buffer);

                    if (sound_is_valid) {
                        win32FillSoundBuffer(&sound_output, &game_sound_output_buffer, byte_to_lock, bytes_to_write);
                    }

                    const work_counter: foundation.LARGE_INTEGER = win32GetWallClock();
                    const work_seconds_elapsed: f32 = win32GetSecondsElapsed(last_counter, work_counter);

                    var seconds_elapsed_for_frame: f32 = work_seconds_elapsed;

                    if (seconds_elapsed_for_frame < target_seconds_per_frame) {
                        if (sleep_is_granular) {
                            const sleep_ms: win.DWORD = @intFromFloat(1000.0 * (target_seconds_per_frame - seconds_elapsed_for_frame));
                            if (sleep_ms > 0) {
                                zig32.system.threading.Sleep(sleep_ms - 1);
                            }
                        }

                        // WARN: This assertion is crashing the program for me, but not Casey. I can't figure out why.

                        // const test_seconds_elapsed_for_frame = win32GetSecondsElapsed(last_counter, win32GetWallClock());
                        // std.debug.assert(test_seconds_elapsed_for_frame < target_seconds_per_frame);

                        while (seconds_elapsed_for_frame < target_seconds_per_frame) {
                            seconds_elapsed_for_frame = win32GetSecondsElapsed(last_counter, win32GetWallClock());
                        }
                    } else {
                        // TODO: (CASEY) Missed Frame Rate
                        // TODO: Logging
                    }

                    const end_counter: foundation.LARGE_INTEGER = win32GetWallClock();
                    const ms_per_frame: f32 = 1000.0 * win32GetSecondsElapsed(last_counter, end_counter);
                    const counter_elapsed: i64 = end_counter.QuadPart - last_counter.QuadPart;
                    last_counter = end_counter;

                    const dimension = win32GetWindowDimension(window);

                    if (debug) {
                        win32DebugSyncDisplay(&global_back_buffer, &sound_output, &debug_last_play_cursor, debug_last_play_cursor.len);
                    }
                    win32DisplayBufferInWindow(&global_back_buffer, device_context.?, dimension.width, dimension.height);

                    if (debug) {
                        _ = global_secondary_buffer.?.IDirectSoundBuffer.GetCurrentPosition(&play_cursor, &write_cursor);
                        if (debug_last_play_cursor_index >= debug_last_play_cursor_size) {
                            debug_last_play_cursor_index = 0;
                        }
                        debug_last_play_cursor[debug_last_play_cursor_index] = play_cursor;
                        debug_last_play_cursor_index += 1;
                    }

                    const temp: *game.GameInput = new_input;
                    new_input = old_input;
                    old_input = temp;

                    const end_cycle_count: i64 = @intCast(rdtsc());
                    const cycles_elapsed: i64 = end_cycle_count - last_cycle_count;
                    last_cycle_count = end_cycle_count;

                    const frames_per_second: f32 = @as(f32, @floatFromInt(global_perf_count_frequency)) / @as(f32, @floatFromInt(counter_elapsed));
                    const mega_cycles_per_frame: f32 = (@as(f32, @floatFromInt(cycles_elapsed)) / (1000.0 * 1000.0));

                    _ = ms_per_frame;
                    _ = frames_per_second;
                    _ = mega_cycles_per_frame;
                    // std.debug.print("ms/f: {d:.2}, f/s: {d:.2}, mega_cycles/f {d:.2}\n", .{ ms_per_frame, frames_per_second, mega_cycles_per_frame });
                }
            } else {
                // TODO: Logging
            }
        } else {
            // TODO: Logging
        }
    } else {
        // TODO: Logging
    }
}

pub export fn wWinMain(hInstance: foundation.HINSTANCE, _: foundation.HINSTANCE, _: foundation.PWSTR, _: win.INT) callconv(.c) win.INT {
    instance = hInstance;
    run() catch return 1;
    return 0;
}
