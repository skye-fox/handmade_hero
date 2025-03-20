const std = struct {
    usingnamespace @import("std");
    usingnamespace @import("std").debug;
    usingnamespace @import("std").mem;
};

const win = std.os.windows;

const dbg = @import("builtin").mode == @import("std").builtin.Mode.Debug;

const zig32 = struct {
    usingnamespace @import("win32");
    usingnamespace @import("win32").storage.file_system;
    usingnamespace @import("win32").foundation;
    usingnamespace @import("win32").graphics.gdi;
    usingnamespace @import("win32").media.audio;
    usingnamespace @import("win32").media.audio.direct_sound;
    usingnamespace @import("win32").system.performance;
    usingnamespace @import("win32").system.memory;
    usingnamespace @import("win32").system.system_services;
    usingnamespace @import("win32").ui.input.keyboard_and_mouse;
    usingnamespace @import("win32").ui.input.xbox_controller;
    usingnamespace @import("win32").ui.windows_and_messaging;
    usingnamespace @import("win32").zig;
};

const hm = @import("handmade.zig");

const Win32OffscreenBuffer = struct {
    info: zig32.BITMAPINFO,
    memory: ?*anyopaque,
    width: i32,
    height: i32,
    pitch: u32,
};

const Win32WindowDimension = struct {
    width: i32,
    height: i32,
};

const Win32SoundOutput = struct {
    samples_per_second: u32,
    running_sample_index: u32,
    bytes_per_sample: u32,
    secondary_buffer_size: u32,
    latency_sample_count: u32,
};

pub const DEBUGPlatformReadFileResult = struct {
    contents_size: u32,
    contents: ?*anyopaque,
};

const pi: f32 = 3.14159265359;

var global_running = false;
var global_back_buffer: Win32OffscreenBuffer = std.zeroInit(Win32OffscreenBuffer, .{});
var global_secondary_buffer: ?*zig32.IDirectSoundBuffer8 = std.zeroes(?*zig32.IDirectSoundBuffer8);

inline fn rdtsc() usize {
    var a: u32 = undefined;
    var b: u32 = undefined;
    asm volatile ("rdtsc"
        : [a] "={edx}" (a),
          [b] "={eax}" (b),
    );
    return (@as(u64, a) << 32) | b;
}

pub fn DEBUGPlatformReadEntireFile(file_name: ?[*:0]const u8) DEBUGPlatformReadFileResult {
    var result: DEBUGPlatformReadFileResult = .{
        .contents_size = 0,
        .contents = null,
    };

    const file_handle: zig32.HANDLE = zig32.CreateFileA(file_name, zig32.FILE_GENERIC_READ, zig32.FILE_SHARE_READ, null, zig32.OPEN_EXISTING, zig32.FILE_ATTRIBUTE_NORMAL, null);
    if (file_handle != zig32.INVALID_HANDLE_VALUE) {
        defer zig32.closeHandle(file_handle);

        var file_size: zig32.LARGE_INTEGER = undefined;
        if (zig32.GetFileSizeEx(file_handle, &file_size) != 0) {
            std.assert(file_size.QuadPart <= 0xFFFFFF);

            const file_size_32: u32 = @intCast(file_size.QuadPart);
            result.contents = zig32.VirtualAlloc(null, file_size_32, zig32.VIRTUAL_ALLOCATION_TYPE{ .RESERVE = 1, .COMMIT = 1 }, zig32.PAGE_READWRITE);
            if (result.contents) |_| {
                var bytes_read: win.DWORD = 0;
                if (zig32.ReadFile(file_handle, result.contents, file_size_32, &bytes_read, null) != 0 and (file_size_32 == bytes_read)) {
                    result.contents_size = file_size_32;
                } else {
                    DEBUGPlatformFreeFileMemory(result.contents);
                    result.contents = null;
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

    return result;
}

pub fn DEBUGPlatformFreeFileMemory(memory: ?*anyopaque) void {
    if (memory) |_| {
        _ = zig32.VirtualFree(memory, 0, zig32.MEM_RELEASE);
    }
}

pub fn DEBUGPlatformWriteEntireFile(file_name: ?[*:0]const u8, memory_size: u32, memory: ?*anyopaque) bool {
    var result: bool = false;

    const file_handle: zig32.HANDLE = zig32.CreateFileA(file_name, zig32.FILE_GENERIC_WRITE, zig32.FILE_SHARE_NONE, null, zig32.CREATE_ALWAYS, zig32.FILE_ATTRIBUTE_NORMAL, null);
    if (file_handle != zig32.INVALID_HANDLE_VALUE) {
        defer zig32.closeHandle(file_handle);

        var bytes_written: win.DWORD = 0;
        if (zig32.WriteFile(file_handle, memory, memory_size, &bytes_written, null) != 0) {
            result = (bytes_written == memory_size);
        } else {
            // TODO: Logging
        }
    } else {
        // TODO: Logging
    }

    return result;
}

fn win32ProcessStickValue(value: win.SHORT, dead_zone_threshold: win.SHORT) f32 {
    var result: f32 = 0.0;

    if (value < -dead_zone_threshold) {
        result = @as(f32, @floatFromInt(value + dead_zone_threshold)) / (32768.0 - @as(f32, @floatFromInt(dead_zone_threshold)));
    } else if (value > dead_zone_threshold) {
        result = @as(f32, @floatFromInt(@as(i32, value) + @as(i32, dead_zone_threshold))) / (32767.0 - @as(f32, @floatFromInt(dead_zone_threshold)));
    }

    return result;
}

fn win32ProcessPendingMessages(keyboard_controller: *hm.GameControllerInput) void {
    var message: zig32.MSG = undefined;

    while (zig32.PeekMessageA(&message, null, 0, 0, zig32.PM_REMOVE) != 0) {
        switch (message.message) {
            zig32.WM_QUIT => global_running = false,
            zig32.WM_KEYDOWN, zig32.WM_KEYUP, zig32.WM_SYSKEYDOWN, zig32.WM_SYSKEYUP => {
                const vk_code: zig32.VIRTUAL_KEY = @enumFromInt(message.wParam);
                const was_down: bool = ((message.lParam & (1 << 30)) != 0);
                const is_down: bool = ((message.lParam & (1 << 31)) == 0);

                if (was_down != is_down) {
                    switch (vk_code) {
                        zig32.VK_W => {
                            win32ProcessKeyboardMessage(&keyboard_controller.button_union.button_input.move_up, is_down);
                        },
                        zig32.VK_A => {
                            win32ProcessKeyboardMessage(&keyboard_controller.button_union.button_input.move_left, is_down);
                        },
                        zig32.VK_S => {
                            win32ProcessKeyboardMessage(&keyboard_controller.button_union.button_input.move_down, is_down);
                        },
                        zig32.VK_D => {
                            win32ProcessKeyboardMessage(&keyboard_controller.button_union.button_input.move_right, is_down);
                        },
                        zig32.VK_Q => {
                            win32ProcessKeyboardMessage(&keyboard_controller.button_union.button_input.left_shoulder, is_down);
                        },
                        zig32.VK_E => {
                            win32ProcessKeyboardMessage(&keyboard_controller.button_union.button_input.right_shoulder, is_down);
                        },
                        zig32.VK_UP => {
                            win32ProcessKeyboardMessage(&keyboard_controller.button_union.button_input.action_up, is_down);
                        },
                        zig32.VK_LEFT => {
                            win32ProcessKeyboardMessage(&keyboard_controller.button_union.button_input.action_left, is_down);
                        },
                        zig32.VK_DOWN => {
                            win32ProcessKeyboardMessage(&keyboard_controller.button_union.button_input.action_down, is_down);
                        },
                        zig32.VK_RIGHT => {
                            win32ProcessKeyboardMessage(&keyboard_controller.button_union.button_input.action_right, is_down);
                        },
                        zig32.VK_ESCAPE => {},
                        zig32.VK_SPACE => {},
                        else => {},
                    }
                }
                const alt_is_down: bool = ((message.lParam & (1 << 29)) != 0);
                if ((vk_code == zig32.VK_F4) and alt_is_down) {
                    global_running = false;
                }
            },
            else => {
                _ = zig32.TranslateMessage(&message);
                _ = zig32.DispatchMessageA(&message);
            },
        }
    }
}

fn win32ProcessKeyboardMessage(new_state: *hm.GameButtonState, is_down: bool) void {
    std.assert(new_state.ended_down != is_down);
    new_state.ended_down = is_down;
    new_state.half_transition_count += 1;
}

fn win32ProcessXInputDigitalButton(xinput_button_state: u16, old_state: *hm.GameButtonState, new_state: *hm.GameButtonState, button_bit: win.DWORD) void {
    new_state.ended_down = ((xinput_button_state & button_bit) == button_bit);
    new_state.half_transition_count = if (old_state.ended_down != new_state.ended_down) 1 else 0;
}

fn win32ClearBuffer(sound_output: *Win32SoundOutput) void {
    var region1: ?*anyopaque = null;
    var region1_size: win.DWORD = 0;
    var region2: ?*anyopaque = null;
    var region2_size: win.DWORD = 0;
    if (zig32.SUCCEEDED(global_secondary_buffer.?.IDirectSoundBuffer.Lock(0, sound_output.secondary_buffer_size, &region1, &region1_size, &region2, &region2_size, 0))) {
        var dest_sample: [*]u8 = @alignCast(@ptrCast(region1));

        var byte_index: win.DWORD = 0;
        while (byte_index < region1_size) : (byte_index += 1) {
            dest_sample[0] = 0;
            dest_sample += 1;
        }

        if (region2) |_| {
            dest_sample = @alignCast(@ptrCast(region2));
            byte_index = 0;
            while (byte_index < region2_size) : (byte_index += 1) {
                dest_sample[0] = 0;
                dest_sample += 1;
            }
        }
    }

    _ = global_secondary_buffer.?.IDirectSoundBuffer.Unlock(region1, region1_size, region2, region2_size);
}

fn win32FillSoundBuffer(sound_output: *Win32SoundOutput, source_buffer: *hm.GameOutputSoundBuffer, byte_to_lock: win.DWORD, bytes_to_write: win.DWORD) void {
    var region1: ?*anyopaque = null;
    var region1_size: win.DWORD = 0;
    var region2: ?*anyopaque = null;
    var region2_size: win.DWORD = 0;

    if (zig32.SUCCEEDED(global_secondary_buffer.?.IDirectSoundBuffer.Lock(byte_to_lock, bytes_to_write, &region1, &region1_size, &region2, &region2_size, 0))) {
        const region1_sample_count: win.DWORD = region1_size / sound_output.bytes_per_sample;
        var dest_sample: [*]i16 = @alignCast(@ptrCast(region1));
        var source_sample: [*]i16 = @ptrCast(source_buffer.samples);

        var sample_index: win.DWORD = 0;
        while (sample_index < region1_sample_count) : (sample_index += 1) {
            dest_sample[0] = source_sample[0];
            dest_sample += 1;
            source_sample += 1;

            dest_sample[0] = source_sample[0];
            dest_sample += 1;
            source_sample += 1;

            sound_output.running_sample_index += 1;
        }

        if (region2) |_| {
            const region2_sample_count: win.DWORD = region2_size / sound_output.bytes_per_sample;
            dest_sample = @alignCast(@ptrCast(region2));

            sample_index = 0;
            while (sample_index < region2_sample_count) : (sample_index += 1) {
                dest_sample[0] = source_sample[0];
                dest_sample += 1;
                source_sample += 1;

                dest_sample[0] = source_sample[0];
                dest_sample += 1;
                source_sample += 1;

                sound_output.running_sample_index += 1;
            }
        }
    }

    _ = global_secondary_buffer.?.IDirectSoundBuffer.Unlock(region1, region1_size, region2, region2_size);
}

fn win32InitDSound(window: zig32.HWND, samples_per_second: u32, buffer_size: u32) void {
    var direct_sound: ?*zig32.IDirectSound8 = std.zeroes(?*zig32.IDirectSound8);
    if (zig32.SUCCEEDED(zig32.DirectSoundCreate8(null, &direct_sound, null))) {
        var wave_format: zig32.WAVEFORMATEX = std.zeroInit(zig32.WAVEFORMATEX, .{});
        wave_format.wFormatTag = zig32.WAVE_FORMAT_PCM;
        wave_format.nChannels = 2;
        wave_format.wBitsPerSample = 16;
        wave_format.nBlockAlign = (wave_format.nChannels * wave_format.wBitsPerSample) / 8;
        wave_format.nSamplesPerSec = samples_per_second;
        wave_format.nAvgBytesPerSec = wave_format.nSamplesPerSec * wave_format.nBlockAlign;

        if (zig32.SUCCEEDED(direct_sound.?.IDirectSound.SetCooperativeLevel(window, zig32.DSSCL_PRIORITY))) {
            var buffer_description: zig32.DSBUFFERDESC = std.zeroInit(zig32.DSBUFFERDESC, .{});
            buffer_description.dwSize = @sizeOf(zig32.DSBUFFERDESC);
            buffer_description.dwFlags = zig32.DSBCAPS_PRIMARYBUFFER;

            var primary_buffer: ?*zig32.IDirectSoundBuffer8 = std.zeroes(?*zig32.IDirectSoundBuffer8);
            if (zig32.SUCCEEDED(direct_sound.?.IDirectSound.CreateSoundBuffer(&buffer_description, &primary_buffer, null))) {
                if (zig32.SUCCEEDED(primary_buffer.?.IDirectSoundBuffer.SetFormat(&wave_format))) {
                    std.print("Primary buffer format was set.\n", .{});
                } else {
                    // TODO: Logging
                }
            } else {
                // TODO: Logging
            }
        } else {
            // TODO: Logging
        }

        var buffer_description: zig32.DSBUFFERDESC = std.zeroInit(zig32.DSBUFFERDESC, .{});
        buffer_description.dwSize = @sizeOf(zig32.DSBUFFERDESC);
        buffer_description.dwBufferBytes = buffer_size;
        buffer_description.lpwfxFormat = &wave_format;

        if (zig32.SUCCEEDED(direct_sound.?.IDirectSound.CreateSoundBuffer(&buffer_description, &global_secondary_buffer, null))) {
            std.print("Secondary buffer created successfully.\n", .{});
        } else {
            // TODO: Logging
        }
    } else {
        // TODO: Logging
    }
}

fn win32GetWindowDimension(window: zig32.HWND) Win32WindowDimension {
    var result: Win32WindowDimension = std.zeroInit(Win32WindowDimension, .{});

    var client_rect: zig32.RECT = std.zeroInit(zig32.RECT, .{});
    _ = zig32.GetClientRect(window, &client_rect);
    result.width = client_rect.right - client_rect.left;
    result.height = client_rect.bottom - client_rect.top;

    return result;
}

fn win32ResizeDIBSection(buffer: *Win32OffscreenBuffer, width: i32, height: i32) void {
    if (buffer.memory != null) {
        _ = zig32.VirtualFree(buffer.memory, 0, zig32.MEM_RELEASE);
    }

    buffer.width = width;
    buffer.height = height;
    const bytes_per_pixel: u8 = 4;

    buffer.info.bmiHeader.biSize = @sizeOf(@TypeOf(buffer.info.bmiHeader));
    buffer.info.bmiHeader.biWidth = width;
    buffer.info.bmiHeader.biHeight = -height;
    buffer.info.bmiHeader.biPlanes = 1;
    buffer.info.bmiHeader.biBitCount = 32;
    buffer.info.bmiHeader.biCompression = zig32.BI_RGB;

    const bitmap_memory_size: usize = @intCast((buffer.width * buffer.height) * bytes_per_pixel);
    buffer.memory = zig32.VirtualAlloc(null, bitmap_memory_size, zig32.VIRTUAL_ALLOCATION_TYPE{ .RESERVE = 1, .COMMIT = 1 }, zig32.PAGE_READWRITE);

    buffer.pitch = @intCast(width * bytes_per_pixel);
}

fn win32DisplayBufferInWindow(buffer: *Win32OffscreenBuffer, device_context: ?zig32.HDC, width: i32, height: i32) void {
    _ = zig32.StretchDIBits(device_context, 0, 0, width, height, 0, 0, buffer.width, buffer.height, buffer.memory, &buffer.info, zig32.DIB_RGB_COLORS, zig32.SRCCOPY);
}

fn win32MainWindowCallBack(window: zig32.HWND, message: u32, w_param: zig32.WPARAM, l_param: zig32.LPARAM) callconv(.c) zig32.LRESULT {
    var result: zig32.LRESULT = 0;
    switch (message) {
        zig32.WM_CLOSE, zig32.WM_DESTROY => global_running = false,
        zig32.WM_ACTIVATEAPP => {},
        zig32.WM_PAINT => {
            var paint: zig32.PAINTSTRUCT = std.zeroInit(zig32.PAINTSTRUCT, .{});
            const device_context: ?zig32.HDC = zig32.BeginPaint(window, &paint);

            const dimension: Win32WindowDimension = win32GetWindowDimension(window);

            win32DisplayBufferInWindow(&global_back_buffer, device_context, dimension.width, dimension.height);
            _ = zig32.EndPaint(window, &paint);
        },
        else => {
            result = zig32.DefWindowProcA(window, message, w_param, l_param);
        },
    }
    return result;
}

pub fn wWinMain(instance: zig32.HINSTANCE, prev_instance: ?zig32.HINSTANCE, cmd_line: zig32.PWSTR, cmd_show: win.INT) win.INT {
    _ = prev_instance;
    _ = cmd_line;
    _ = cmd_show;

    var perf_count_frequency_result: zig32.LARGE_INTEGER = undefined;
    _ = zig32.QueryPerformanceFrequency(&perf_count_frequency_result);
    const perf_count_frequency: i64 = perf_count_frequency_result.QuadPart;

    var window_class = std.zeroInit(zig32.WNDCLASSA, .{});

    win32ResizeDIBSection(&global_back_buffer, 1280, 720);

    window_class.style = .{ .HREDRAW = 1, .VREDRAW = 1, .OWNDC = 1 };
    window_class.lpfnWndProc = win32MainWindowCallBack;
    window_class.hInstance = instance;
    window_class.lpszClassName = "HandmadeHeroWindowClass";

    if (zig32.RegisterClassA(&window_class) != 0) {
        const window: ?zig32.HWND = zig32.CreateWindowExA(
            zig32.WINDOW_EX_STYLE{},
            window_class.lpszClassName,
            "Handmade Hero",
            zig32.WINDOW_STYLE{ .BORDER = 1, .DLGFRAME = 1, .GROUP = 1, .SYSMENU = 1, .TABSTOP = 1, .THICKFRAME = 1, .VISIBLE = 1 },
            zig32.CW_USEDEFAULT,
            zig32.CW_USEDEFAULT,
            zig32.CW_USEDEFAULT,
            zig32.CW_USEDEFAULT,
            null,
            null,
            instance,
            null,
        );
        if (window) |_| {
            const device_context: ?zig32.HDC = zig32.GetDC(window);

            var sound_output: Win32SoundOutput = .{
                .samples_per_second = 48000,
                .running_sample_index = 0,
                .bytes_per_sample = @sizeOf(i16) * 2,
                .secondary_buffer_size = 0,
                .latency_sample_count = 0,
            };
            sound_output.secondary_buffer_size = sound_output.samples_per_second * sound_output.bytes_per_sample;
            sound_output.latency_sample_count = sound_output.samples_per_second / 15;

            win32InitDSound(window.?, sound_output.samples_per_second, sound_output.secondary_buffer_size);
            win32ClearBuffer(&sound_output);
            _ = global_secondary_buffer.?.IDirectSoundBuffer.Play(0, 0, zig32.DSBPLAY_LOOPING);

            global_running = true;

            const samples: ?*i16 = @alignCast(@ptrCast(zig32.VirtualAlloc(null, sound_output.secondary_buffer_size, zig32.VIRTUAL_ALLOCATION_TYPE{ .RESERVE = 1, .COMMIT = 1 }, zig32.PAGE_READWRITE)));

            const base_address: ?win.LPVOID = if (dbg) @ptrFromInt(hm.terabytes(2)) else null;

            var game_memory: hm.GameMemory = .{
                .is_initialized = false,
                .permanent_storage_size = 0,
                .permanent_storage = null,
                .transient_storage_size = 0,
                .transient_storage = null,
            };

            game_memory.permanent_storage_size = hm.megabytes(64);
            game_memory.transient_storage_size = hm.gigabytes(4);

            const total_size: u64 = game_memory.permanent_storage_size + game_memory.transient_storage_size;
            game_memory.permanent_storage = zig32.VirtualAlloc(base_address, total_size, zig32.VIRTUAL_ALLOCATION_TYPE{ .RESERVE = 1, .COMMIT = 1 }, zig32.PAGE_READWRITE);
            game_memory.transient_storage = @as([*]u8, @ptrCast(game_memory.permanent_storage)) + game_memory.permanent_storage_size;

            if (samples != null and game_memory.permanent_storage != null and game_memory.transient_storage != null) {
                var input: [2]hm.GameInput = std.zeroes([2]hm.GameInput);
                var new_input: *hm.GameInput = &input[0];
                var old_input: *hm.GameInput = &input[1];

                var last_counter: zig32.LARGE_INTEGER = undefined;
                _ = zig32.QueryPerformanceCounter(&last_counter);
                var last_cycle_count: usize = rdtsc();

                // NOTE: <-------------------------------------------------MAIN LOOP------------------------------------------------->

                // NOTE: <-------------------------------------------------MAIN LOOP------------------------------------------------->

                while (global_running) {
                    const old_keyboard_controller: *hm.GameControllerInput = hm.getController(old_input, 0);
                    const new_keyboard_controller: *hm.GameControllerInput = hm.getController(new_input, 0);
                    const zero_controller: hm.GameControllerInput = std.zeroInit(hm.GameControllerInput, .{});
                    new_keyboard_controller.* = zero_controller;
                    new_keyboard_controller.is_connected = true;

                    var button_index: u32 = 0;
                    while (button_index < new_keyboard_controller.button_union.buttons.len) : (button_index += 1) {
                        new_keyboard_controller.button_union.buttons[button_index].ended_down = old_keyboard_controller.button_union.buttons[button_index].ended_down;
                    }

                    win32ProcessPendingMessages(new_keyboard_controller);

                    var max_controller_count = zig32.XUSER_MAX_COUNT;
                    if (max_controller_count > new_input.controllers.len - 1) {
                        max_controller_count = new_input.controllers.len - 1;
                    }

                    var controller_index: win.DWORD = 0;
                    while (controller_index < max_controller_count) : (controller_index += 1) {
                        const our_controller_index: win.DWORD = controller_index + 1;
                        const old_controller: *hm.GameControllerInput = hm.getController(old_input, our_controller_index);
                        const new_controller: *hm.GameControllerInput = hm.getController(new_input, our_controller_index);

                        var controller_state: zig32.XINPUT_STATE = std.zeroInit(zig32.XINPUT_STATE, .{});
                        if (zig32.XInputGetState(controller_index, &controller_state) == @intFromEnum(zig32.ERROR_SUCCESS)) {
                            new_controller.is_analog = true;
                            new_controller.is_connected = true;

                            const game_pad: *zig32.XINPUT_GAMEPAD = &controller_state.Gamepad;

                            // NOTE: Thumbstick Deadzone
                            // left = 7849, right = 8689

                            new_controller.stick_average_x = win32ProcessStickValue(game_pad.sThumbLX, zig32.XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE);
                            new_controller.stick_average_y = win32ProcessStickValue(game_pad.sThumbLY, zig32.XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE);

                            // if ((new_controller.stick_average_x != 0.0) or (new_controller.stick_average_y != 0.0)) {
                            //     new_controller.is_analog = true;
                            // }

                            if (game_pad.wButtons == zig32.XINPUT_GAMEPAD_DPAD_UP) {
                                new_controller.stick_average_y = 1.0;
                                // new_controller.is_analog = false;
                            }

                            if (game_pad.wButtons == zig32.XINPUT_GAMEPAD_DPAD_DOWN) {
                                new_controller.stick_average_y = -1.0;
                                // new_controller.is_analog = false;
                            }

                            if (game_pad.wButtons == zig32.XINPUT_GAMEPAD_DPAD_LEFT) {
                                new_controller.stick_average_x = -1.0;
                                // new_controller.is_analog = false;
                            }

                            if (game_pad.wButtons == zig32.XINPUT_GAMEPAD_DPAD_RIGHT) {
                                new_controller.stick_average_x = 1.0;
                                // new_controller.is_analog = false;
                            }

                            const threshold: f32 = 0.5;
                            win32ProcessXInputDigitalButton(
                                if (new_controller.stick_average_x < -threshold) 1 else 0,
                                &old_controller.button_union.button_input.move_left,
                                &new_controller.button_union.button_input.move_left,
                                1,
                            );
                            win32ProcessXInputDigitalButton(
                                if (new_controller.stick_average_x < threshold) 1 else 0,
                                &old_controller.button_union.button_input.move_right,
                                &new_controller.button_union.button_input.move_right,
                                1,
                            );
                            win32ProcessXInputDigitalButton(
                                if (new_controller.stick_average_y < -threshold) 1 else 0,
                                &old_controller.button_union.button_input.move_down,
                                &new_controller.button_union.button_input.move_down,
                                1,
                            );
                            win32ProcessXInputDigitalButton(
                                if (new_controller.stick_average_y < threshold) 1 else 0,
                                &old_controller.button_union.button_input.move_up,
                                &new_controller.button_union.button_input.move_up,
                                1,
                            );

                            win32ProcessXInputDigitalButton(game_pad.wButtons, &old_controller.button_union.button_input.action_down, &new_controller.button_union.button_input.action_down, zig32.XINPUT_GAMEPAD_A);
                            win32ProcessXInputDigitalButton(game_pad.wButtons, &old_controller.button_union.button_input.action_up, &new_controller.button_union.button_input.action_up, zig32.XINPUT_GAMEPAD_Y);
                            win32ProcessXInputDigitalButton(game_pad.wButtons, &old_controller.button_union.button_input.action_left, &new_controller.button_union.button_input.action_left, zig32.XINPUT_GAMEPAD_X);
                            win32ProcessXInputDigitalButton(game_pad.wButtons, &old_controller.button_union.button_input.action_right, &new_controller.button_union.button_input.action_right, zig32.XINPUT_GAMEPAD_B);

                            win32ProcessXInputDigitalButton(
                                game_pad.wButtons,
                                &old_controller.button_union.button_input.left_shoulder,
                                &new_controller.button_union.button_input.left_shoulder,
                                zig32.XINPUT_GAMEPAD_LEFT_SHOULDER,
                            );
                            win32ProcessXInputDigitalButton(
                                game_pad.wButtons,
                                &old_controller.button_union.button_input.right_shoulder,
                                &new_controller.button_union.button_input.right_shoulder,
                                zig32.XINPUT_GAMEPAD_RIGHT_SHOULDER,
                            );

                            const right_stick_x: i16 = game_pad.sThumbRX;
                            const right_stick_y: i16 = game_pad.sThumbRY;

                            _ = right_stick_x;
                            _ = right_stick_y;
                        } else {
                            // The controller is unavailable
                            new_controller.is_connected = false;
                        }
                    }

                    // var vibration: zig32.XINPUT_VIBRATION = std.zeroInit(zig32.XINPUT_VIBRATION, .{});
                    // vibration.wLeftMotorSpeed = 60000;
                    // vibration.wRightMotorSpeed = 60000;
                    // _ = zig32.XInputSetState(0, &vibration);
                    var byte_to_lock: win.DWORD = 0;
                    var bytes_to_write: win.DWORD = 0;
                    var play_cursor: win.DWORD = 0;
                    var write_cursor: win.DWORD = 0;
                    var target_cursor: win.DWORD = 0;
                    var sound_is_valid: bool = false;

                    if (zig32.SUCCEEDED(global_secondary_buffer.?.IDirectSoundBuffer.GetCurrentPosition(&play_cursor, &write_cursor))) {
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

                    var sound_buffer: hm.GameOutputSoundBuffer = .{
                        .samples_per_second = sound_output.samples_per_second,
                        .sample_count = bytes_to_write / sound_output.bytes_per_sample,
                        .samples = samples.?,
                    };

                    var buffer: hm.GameOffscreenBuffer = .{
                        .memory = global_back_buffer.memory,
                        .width = global_back_buffer.width,
                        .height = global_back_buffer.height,
                        .pitch = global_back_buffer.pitch,
                    };
                    hm.gameUpdateAndRender(&game_memory, new_input, &buffer, &sound_buffer);

                    if (sound_is_valid) {
                        win32FillSoundBuffer(&sound_output, &sound_buffer, byte_to_lock, bytes_to_write);
                    }

                    const dimension: Win32WindowDimension = win32GetWindowDimension(window.?);
                    win32DisplayBufferInWindow(&global_back_buffer, device_context, dimension.width, dimension.height);

                    var end_counter: zig32.LARGE_INTEGER = undefined;
                    _ = zig32.QueryPerformanceCounter(&end_counter);
                    const end_cycle_count: usize = rdtsc();

                    const cycles_elapsed: usize = end_cycle_count - last_cycle_count;
                    const counter_elapsed: i64 = end_counter.QuadPart - last_counter.QuadPart;
                    const milliseconds_per_frame: f64 = (1000.0 * @as(f64, @floatFromInt(counter_elapsed))) / @as(f64, @floatFromInt(perf_count_frequency));
                    const fps: f64 = @as(f64, @floatFromInt(perf_count_frequency)) / @as(f64, @floatFromInt(counter_elapsed));
                    const mega_cycles_per_frame: f64 = @as(f64, @floatFromInt(cycles_elapsed)) / (1000.0 * 1000.0);

                    _ = milliseconds_per_frame;
                    _ = fps;
                    _ = mega_cycles_per_frame;
                    // std.print("{d:.4} ms/f, {d:.4} f/s, {d:.4} mc/f\n", .{ milliseconds_per_frame, fps, mega_cycles_per_frame });

                    last_counter = end_counter;
                    last_cycle_count = end_cycle_count;

                    const temp_input: *hm.GameInput = new_input;
                    new_input = old_input;
                    old_input = temp_input;
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
    return 0;
}
