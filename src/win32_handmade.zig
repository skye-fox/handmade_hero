const std = @import("std");
const win = @import("std").os.windows;

const zig32 = @import("zigwin32");
const audio = @import("zigwin32").media.audio;
const controller = @import("zigwin32").ui.input.xbox_controller;
const d_sound = @import("zigwin32").media.audio.direct_sound;
const foundation = @import("zigwin32").foundation;
const gdi = @import("zigwin32").graphics.gdi;
const kbam = @import("zigwin32").ui.input.keyboard_and_mouse;
const perf = @import("zigwin32").system.performance;
const wam = @import("zigwin32").ui.windows_and_messaging;
const zig32_mem = @import("zigwin32").system.memory;

const Color = packed struct(u32) {
    // NOTE: Pixels are always 32 bits wide, windows memory order BB GG RR XX
    blue: u8,
    green: u8,
    red: u8,
    pad: u8 = 0,
};

const Win32OffscreenBuffer = struct {
    info: gdi.BITMAPINFO,
    memory: ?*anyopaque,
    width: i32,
    height: i32,
    pitch: i32,
};

const Win32WindowDimension = struct {
    width: i32,
    height: i32,
};

const Win32SoundOutput = struct {
    samples_per_second: u32,
    bytes_per_sample: u32,
    tone_hz: i32,
    tone_volume: i16,
    running_sample_index: u32,
    wave_period: i32,
    secondary_buffer_size: u32,
    tsine: f32,
    latency_sample_count: u32,
};

const pi: f32 = 3.14159265359;

var instance: foundation.HINSTANCE = undefined;

var global_running = false;

var global_back_buffer = std.mem.zeroInit(Win32OffscreenBuffer, .{});
var global_secondary_buffer: ?*d_sound.IDirectSoundBuffer8 = undefined;

inline fn rdtsc() usize {
    var a: u32 = undefined;
    var b: u32 = undefined;
    asm volatile ("rdtsc"
        : [a] "={edx}" (a),
          [b] "={eax}" (b),
    );
    return (@as(u64, a) << 32) | b;
}

fn win32FillSoundBuffer(sound_output: *Win32SoundOutput, byte_to_lock: win.DWORD, bytes_to_write: win.DWORD) void {
    var region_one: ?*anyopaque = null;
    var region_one_size: win.DWORD = 0;
    var region_two: ?*anyopaque = null;
    var region_two_size: win.DWORD = 0;

    if (zig32.zig.SUCCEEDED(global_secondary_buffer.?.IDirectSoundBuffer.Lock(byte_to_lock, bytes_to_write, &region_one, &region_one_size, &region_two, &region_two_size, 0))) {
        const region_one_sample_count = region_one_size / sound_output.bytes_per_sample;

        var sample_out: [*]i16 = @ptrCast(@alignCast(region_one));
        var sample_index: win.DWORD = 0;
        while (sample_index < region_one_sample_count) : (sample_index += 1) {
            const sin_value = @sin(sound_output.tsine);
            const sample_value: i16 = @intFromFloat(sin_value * @as(f32, @floatFromInt(sound_output.tone_volume)));

            sample_out[0] = sample_value;
            sample_out += 1;
            sample_out[0] = sample_value;
            sample_out += 1;

            sound_output.tsine += 2.0 * pi / @as(f32, @floatFromInt(sound_output.wave_period));
            sound_output.running_sample_index += 1;
        }

        if (region_two) |_| {
            const region_two_sample_count = region_two_size / sound_output.bytes_per_sample;
            sample_out = @ptrCast(@alignCast(region_two));
            sample_index = 0;
            while (sample_index < region_two_sample_count) : (sample_index += 1) {
                const sin_value = @sin(sound_output.tsine);
                const sample_value: i16 = @intFromFloat(sin_value * @as(f32, @floatFromInt(sound_output.tone_volume)));

                sample_out[0] = sample_value;
                sample_out += 1;
                sample_out[0] = sample_value;
                sample_out += 1;

                sound_output.tsine += 2.0 * pi / @as(f32, @floatFromInt(sound_output.wave_period));
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

fn win32RenderWeirdGradient(buffer: *Win32OffscreenBuffer, blue_offset: i32, green_offset: i32) void {
    var row = @as([*]u8, @ptrCast(buffer.memory));

    var y: i32 = 0;
    while (y < buffer.height) : (y += 1) {
        var pixel: [*]Color = @ptrCast(@alignCast(row));
        var x: i32 = 0;
        while (x < buffer.width) : (x += 1) {
            const blue: u8 = @truncate(@abs(x + blue_offset));
            const green: u8 = @truncate(@abs(y + green_offset));
            pixel[0] = .{ .blue = blue, .green = green, .red = @truncate(0) };
            pixel += 1;
        }
        row += @intCast(buffer.pitch);
    }

    //     Make a solid bg color
    //
    //     var pixel: [*]Color = buffer.memory;
    // const width: u32 = @intCast(buffer.width);
    // const height: u32 = @intCast(buffer.height);
    // var pixel: [*]Color = @ptrCast(@alignCast(buffer.memory));
    // for (0..width * height) |i| {
    //     pixel[i] = .{ .blue = 246, .green = 92, .red = 139 };
    // }
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

    const bytes_per_pixel = 4;

    const bitmap_memory_size = (buffer.width * buffer.height) * bytes_per_pixel;
    const reserve_and_commit = zig32_mem.VIRTUAL_ALLOCATION_TYPE{ .RESERVE = 1, .COMMIT = 1 };
    buffer.memory = zig32_mem.VirtualAlloc(null, @as(usize, @intCast(bitmap_memory_size)), reserve_and_commit, zig32_mem.PAGE_READWRITE);

    buffer.pitch = buffer.width * bytes_per_pixel;
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
            const vk_code: kbam.VIRTUAL_KEY = @enumFromInt(wparam);
            const was_down: bool = ((lparam & (1 << 30)) != 0);
            const is_down: bool = ((lparam & (1 << 31)) == 0);

            if (was_down != is_down) {
                switch (vk_code) {
                    .W => {},
                    .A => {},
                    .S => {},
                    .D => {},
                    .Q => {},
                    .E => {},
                    .UP => {},
                    .LEFT => {},
                    .DOWN => {},
                    .RIGHT => {},
                    .SPACE => {},
                    // .F4 => {},
                    .ESCAPE => {
                        std.debug.print("Escape: ", .{});
                        if (is_down) {
                            std.debug.print("is_down ", .{});
                        }
                        if (was_down) {
                            std.debug.print("was_down ", .{});
                        }
                        std.debug.print("\n", .{});
                    },
                    else => {},
                }
            }
            const alt_down: bool = ((lparam & (1 << 29)) != 0);
            if ((vk_code == kbam.VK_F4) and alt_down) {
                global_running = false;
            }
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
    const perf_count_frequency: i64 = perf_count_frequency_result.QuadPart;

    win32ResizeDIBSection(&global_back_buffer, 1280, 720);

    var window_class = std.mem.zeroInit(wam.WNDCLASSA, .{});

    window_class.style = .{ .HREDRAW = 1, .VREDRAW = 1, .OWNDC = 1 };
    window_class.lpfnWndProc = win32MainWindowCallback;
    window_class.hInstance = instance;
    window_class.lpszClassName = "Handmade Hero";

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

            // graphics test
            var x_offset: i32 = 0;
            var y_offset: i32 = 0;

            //sound test
            var sound_output: Win32SoundOutput = .{
                .samples_per_second = 48000,
                .bytes_per_sample = @sizeOf(i16) * 2,
                .tone_hz = 256,
                .tone_volume = 3000,
                .running_sample_index = 0,
                .wave_period = 0,
                .secondary_buffer_size = 0,
                .tsine = 0,
                .latency_sample_count = 0,
            };
            sound_output.wave_period = @divTrunc(@as(i32, @intCast(sound_output.samples_per_second)), sound_output.tone_hz);
            sound_output.secondary_buffer_size = sound_output.samples_per_second * sound_output.bytes_per_sample;
            sound_output.latency_sample_count = sound_output.samples_per_second / 15;

            win32InitDSound(window, sound_output.samples_per_second, sound_output.secondary_buffer_size);
            win32FillSoundBuffer(&sound_output, 0, sound_output.latency_sample_count * sound_output.bytes_per_sample);
            _ = global_secondary_buffer.?.IDirectSoundBuffer.Play(0, 0, d_sound.DSBPLAY_LOOPING);

            var last_counter: foundation.LARGE_INTEGER = undefined;
            _ = perf.QueryPerformanceCounter(&last_counter);
            var last_cycle_count: i64 = @intCast(rdtsc());

            global_running = true;
            while (global_running) {
                var message: wam.MSG = undefined;
                while (wam.PeekMessageA(&message, null, 0, 0, wam.PM_REMOVE) != 0) {
                    if (message.message == wam.WM_QUIT) {
                        global_running = false;
                    }
                    _ = wam.TranslateMessage(&message);
                    _ = wam.DispatchMessageA(&message);
                }

                var controller_index: win.DWORD = 0;
                while (controller_index < controller.XUSER_MAX_COUNT) : (controller_index += 1) {
                    var controller_state = std.mem.zeroInit(controller.XINPUT_STATE, .{});

                    if (controller.XInputGetState(controller_index, &controller_state) == @intFromEnum(foundation.ERROR_SUCCESS)) {
                        // Controller available
                        const pad = &controller_state.Gamepad;

                        const pad_up: bool = (pad.wButtons & controller.XINPUT_GAMEPAD_DPAD_UP) != 0;
                        const pad_down: bool = (pad.wButtons & controller.XINPUT_GAMEPAD_DPAD_DOWN) != 0;
                        const pad_left: bool = (pad.wButtons & controller.XINPUT_GAMEPAD_DPAD_LEFT) != 0;
                        const pad_right: bool = (pad.wButtons & controller.XINPUT_GAMEPAD_DPAD_RIGHT) != 0;

                        const pad_start: bool = (pad.wButtons & controller.XINPUT_GAMEPAD_START) != 0;
                        const pad_back: bool = (pad.wButtons & controller.XINPUT_GAMEPAD_BACK) != 0;

                        const pad_left_shoulder: bool = (pad.wButtons & controller.XINPUT_GAMEPAD_LEFT_SHOULDER) != 0;
                        const pad_right_shoulder: bool = (pad.wButtons & controller.XINPUT_GAMEPAD_RIGHT_SHOULDER) != 0;

                        const pad_A: bool = (pad.wButtons & controller.XINPUT_GAMEPAD_A) != 0;
                        const pad_B: bool = (pad.wButtons & controller.XINPUT_GAMEPAD_B) != 0;
                        const pad_X: bool = (pad.wButtons & controller.XINPUT_GAMEPAD_X) != 0;
                        const pad_Y: bool = (pad.wButtons & controller.XINPUT_GAMEPAD_Y) != 0;

                        const left_stick_x = pad.sThumbLX;
                        const left_stick_y = pad.sThumbLY;

                        x_offset += @divTrunc(left_stick_x, 4096);
                        y_offset += @divTrunc(left_stick_y, 4096);

                        const right_stick_x = pad.sThumbRX;
                        const right_stick_y = pad.sThumbRY;

                        sound_output.tone_hz = 512 + @as(i32, @intFromFloat(@trunc(256.0 * (@as(f32, @floatFromInt(right_stick_y)) / 3000.0))));
                        sound_output.wave_period = @divTrunc(@as(i32, @intCast(sound_output.samples_per_second)), sound_output.tone_hz);

                        _ = pad_up;
                        _ = pad_down;
                        _ = pad_left;
                        _ = pad_right;

                        _ = pad_start;
                        _ = pad_back;

                        _ = pad_right_shoulder;
                        _ = pad_left_shoulder;

                        if (pad_A) {
                            y_offset += 1;
                        }
                        _ = pad_B;
                        _ = pad_X;
                        _ = pad_Y;

                        // _ = left_stick_x;
                        // _ = left_stick_y;
                        _ = right_stick_x;
                        // _ = right_stick_y;
                    } else {
                        // Controller not available
                    }
                }

                // NOTE: Example of how to do XInput vibration

                // var vibration = std.mem.zeroInit(controller.XINPUT_VIBRATION, .{});
                // vibration.wLeftMotorSpeed = 60000;
                // vibration.wRightMotorSpeed = 60000;
                // _ = controller.XInputSetState(0, &vibration);

                win32RenderWeirdGradient(&global_back_buffer, x_offset, y_offset);

                var write_cursor: win.DWORD = 0;
                var play_cursor: win.DWORD = 0;

                if (zig32.zig.SUCCEEDED(global_secondary_buffer.?.IDirectSoundBuffer.GetCurrentPosition(&play_cursor, &write_cursor))) {
                    const byte_to_lock = (sound_output.running_sample_index * sound_output.bytes_per_sample) % sound_output.secondary_buffer_size;
                    const target_cursor: win.DWORD = ((play_cursor + (sound_output.latency_sample_count * sound_output.bytes_per_sample)) % sound_output.secondary_buffer_size);
                    var bytes_to_write: win.DWORD = 0;
                    if (byte_to_lock > target_cursor) {
                        bytes_to_write = sound_output.secondary_buffer_size - byte_to_lock;
                        bytes_to_write += target_cursor;
                    } else {
                        bytes_to_write = target_cursor - byte_to_lock;
                    }
                    win32FillSoundBuffer(&sound_output, byte_to_lock, bytes_to_write);
                }

                const dimension = win32GetWindowDimension(window);
                win32DisplayBufferInWindow(&global_back_buffer, device_context.?, dimension.width, dimension.height);

                const end_cycle_count: i64 = @intCast(rdtsc());

                var end_counter: foundation.LARGE_INTEGER = undefined;
                _ = perf.QueryPerformanceCounter(&end_counter);

                const cycles_elapsed: i64 = end_cycle_count - last_cycle_count;
                const counter_elapsed: i64 = end_counter.QuadPart - last_counter.QuadPart;
                const ms_per_frame: f32 = (1000.0 * @as(f32, @floatFromInt(counter_elapsed))) / @as(f32, @floatFromInt(perf_count_frequency));
                const frames_per_seconds: f32 = @as(f32, @floatFromInt(perf_count_frequency)) / @as(f32, @floatFromInt(counter_elapsed));
                const mega_cycles_per_frame: f32 = (@as(f32, @floatFromInt(cycles_elapsed)) / (1000.0 * 1000.0));

                std.debug.print("ms/f: {any}, f/s: {any}, mega_cycles/f {}\n", .{ ms_per_frame, frames_per_seconds, mega_cycles_per_frame });

                last_counter = end_counter;
                last_cycle_count = end_cycle_count;
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
