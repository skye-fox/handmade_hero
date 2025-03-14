const std = struct {
    usingnamespace @import("std");
    usingnamespace @import("std").debug;
    usingnamespace @import("std").mem;
};

const win = std.os.windows;

const zig32 = struct {
    usingnamespace @import("win32");
    usingnamespace @import("win32").foundation;
    usingnamespace @import("win32").graphics.gdi;
    usingnamespace @import("win32").system.memory;
    usingnamespace @import("win32").ui.input.keyboard_and_mouse;
    usingnamespace @import("win32").ui.input.xbox_controller;
    usingnamespace @import("win32").ui.windows_and_messaging;
    usingnamespace @import("win32").zig;
};

const Color = packed struct(u32) {
    blue: u8,
    green: u8,
    red: u8,
    _: u8 = 0,
};

const Win32OffscreenBuffer = struct {
    // NOTE: Pixels are always 32-bits wide, memory order BB GG RR XX
    info: zig32.BITMAPINFO,
    memory: ?*anyopaque,
    width: i32,
    height: i32,
    pitch: u32,
};

const win32WindowDimension = struct {
    width: i32,
    height: i32,
};

var global_running = false;
var global_back_buffer: Win32OffscreenBuffer = std.zeroInit(Win32OffscreenBuffer, .{});

fn win32GetWindowDimension(window: zig32.HWND) win32WindowDimension {
    var result: win32WindowDimension = std.zeroInit(win32WindowDimension, .{});

    var client_rect: zig32.RECT = std.zeroInit(zig32.RECT, .{});
    _ = zig32.GetClientRect(window, &client_rect);
    result.width = client_rect.right - client_rect.left;
    result.height = client_rect.bottom - client_rect.top;

    return result;
}

fn win32RenderWeirdGradient(buffer: *Win32OffscreenBuffer, blue_offset: i32, green_offset: i32) void {
    var row: [*]u8 = @ptrCast(buffer.memory);
    var y: i32 = 0;
    while (y < buffer.height) : (y += 1) {
        var x: i32 = 0;

        // NOTE: pixel in memory: BB GG RR xx
        var pixel: [*]Color = @alignCast(@ptrCast(row));
        while (x < buffer.width) : (x += 1) {
            const blue: u8 = @truncate(@abs(x + blue_offset));
            const green: u8 = @truncate(@abs(y + green_offset));
            // NOTE: bitwise method (This is how Casey Muratori did it)
            // pixel[0] = ((@as(u32, green) << 8) | blue);
            // pixel += 1;

            // NOTE: packed struct method (not possible in C, but perhaps the preferred method in zig?)
            pixel[0] = .{ .blue = blue, .green = green, .red = 0 };
            pixel += 1;
        }
        row += buffer.pitch;
    }
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
    buffer.memory = zig32.VirtualAlloc(null, bitmap_memory_size, zig32.MEM_COMMIT, zig32.PAGE_READWRITE);

    buffer.pitch = @intCast(width * bytes_per_pixel);
}

fn win32DisplayBufferInWindow(buffer: *Win32OffscreenBuffer, device_context: ?zig32.HDC, width: i32, height: i32) void {
    _ = zig32.StretchDIBits(device_context, 0, 0, width, height, 0, 0, buffer.width, buffer.height, buffer.memory, &buffer.info, zig32.DIB_RGB_COLORS, zig32.SRCCOPY);
}

fn win32MainWindowCallBack(window: zig32.HWND, message: u32, w_param: zig32.WPARAM, l_param: zig32.LPARAM) callconv(.c) zig32.LRESULT {
    var result: zig32.LRESULT = 0;
    switch (message) {
        zig32.WM_CLOSE, zig32.WM_DESTROY => global_running = false,
        zig32.WM_KEYDOWN, zig32.WM_KEYUP, zig32.WM_SYSKEYDOWN, zig32.WM_SYSKEYUP => {
            const vk_code: zig32.VIRTUAL_KEY = @enumFromInt(w_param);
            const was_down: bool = ((l_param & (1 << 30)) != 0);
            const is_down: bool = ((l_param & (1 << 31)) == 0);

            if (was_down != is_down) {
                switch (vk_code) {
                    zig32.VK_W => {},
                    zig32.VK_A => {},
                    zig32.VK_S => {},
                    zig32.VK_D => {},
                    zig32.VK_Q => {},
                    zig32.VK_E => {},
                    zig32.VK_UP => {},
                    zig32.VK_LEFT => {},
                    zig32.VK_DOWN => {},
                    zig32.VK_RIGHT => {},
                    zig32.VK_ESCAPE => {
                        std.print("escape: ", .{});
                        if (is_down) {
                            std.print("is_down ", .{});
                        }
                        if (was_down) {
                            std.print("was_down ", .{});
                        }
                        std.print("\n", .{});
                    },
                    zig32.VK_SPACE => {},
                    else => {},
                }
            }
            const alt_is_down: bool = ((l_param & (1 << 29)) != 0);
            if ((vk_code == zig32.VK_F4) and alt_is_down) {
                global_running = false;
            }
        },
        zig32.WM_ACTIVATEAPP => {},
        zig32.WM_PAINT => {
            var paint: zig32.PAINTSTRUCT = std.zeroInit(zig32.PAINTSTRUCT, .{});
            const device_context: ?zig32.HDC = zig32.BeginPaint(window, &paint);

            const dimension: win32WindowDimension = win32GetWindowDimension(window);

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

            var x_offset: i32 = 0;
            var y_offset: i32 = 0;

            global_running = true;
            while (global_running) {
                var message: zig32.MSG = undefined;
                while (zig32.PeekMessageA(&message, null, 0, 0, zig32.PM_REMOVE) != 0) {
                    if (message.message == zig32.WM_QUIT) global_running = false;
                    _ = zig32.TranslateMessage(&message);
                    _ = zig32.DispatchMessageA(&message);
                }

                var controller_index: win.DWORD = 0;
                while (controller_index < zig32.XUSER_MAX_COUNT) : (controller_index += 1) {
                    var controller_state: zig32.XINPUT_STATE = std.zeroInit(zig32.XINPUT_STATE, .{});
                    if (zig32.XInputGetState(controller_index, &controller_state) == @intFromEnum(zig32.ERROR_SUCCESS)) {
                        const game_pad: *zig32.XINPUT_GAMEPAD = &controller_state.Gamepad;

                        const up: bool = (game_pad.wButtons == zig32.XINPUT_GAMEPAD_DPAD_UP);
                        const down: bool = (game_pad.wButtons == zig32.XINPUT_GAMEPAD_DPAD_DOWN);
                        const left: bool = (game_pad.wButtons == zig32.XINPUT_GAMEPAD_DPAD_LEFT);
                        const right: bool = (game_pad.wButtons == zig32.XINPUT_GAMEPAD_DPAD_RIGHT);

                        const left_shoulder: bool = (game_pad.wButtons == zig32.XINPUT_GAMEPAD_LEFT_SHOULDER);
                        const right_shoulder: bool = (game_pad.wButtons == zig32.XINPUT_GAMEPAD_RIGHT_SHOULDER);

                        const a_button: bool = (game_pad.wButtons == zig32.XINPUT_GAMEPAD_A);
                        const b_button: bool = (game_pad.wButtons == zig32.XINPUT_GAMEPAD_B);
                        const x_button: bool = (game_pad.wButtons == zig32.XINPUT_GAMEPAD_X);
                        const y_button: bool = (game_pad.wButtons == zig32.XINPUT_GAMEPAD_Y);

                        const left_stick_x: i16 = game_pad.sThumbLX;
                        const left_stick_y: i16 = game_pad.sThumbLY;
                        const right_stick_x: i16 = game_pad.sThumbRX;
                        const right_stick_y: i16 = game_pad.sThumbRY;

                        x_offset += @divTrunc(left_stick_x, 8000);
                        y_offset += @divTrunc(left_stick_y, 8000);

                        if (a_button) y_offset += 1;
                        _ = up;
                        _ = down;
                        _ = left;
                        _ = right;

                        _ = left_shoulder;
                        _ = right_shoulder;

                        // _ = a_button;
                        _ = b_button;
                        _ = x_button;
                        _ = y_button;

                        // _ = left_stick_x;
                        // _ = left_stick_y;
                        _ = right_stick_x;
                        _ = right_stick_y;
                    } else {
                        // The controller is unavailable
                    }
                }

                // var vibration: zig32.XINPUT_VIBRATION = std.zeroInit(zig32.XINPUT_VIBRATION, .{});
                // vibration.wLeftMotorSpeed = 60000;
                // vibration.wRightMotorSpeed = 60000;
                // _ = zig32.XInputSetState(0, &vibration);

                win32RenderWeirdGradient(&global_back_buffer, x_offset, y_offset);

                const dimension: win32WindowDimension = win32GetWindowDimension(window.?);
                win32DisplayBufferInWindow(&global_back_buffer, device_context, dimension.width, dimension.height);
            }
        } else {
            // TODO: Logging
        }
    } else {
        // TODO: Logging
    }
    return 0;
}
