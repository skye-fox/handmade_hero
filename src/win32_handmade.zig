const std = @import("std");
const win = @import("std").os.windows;

const zig32 = @import("zigwin32");
const controller = @import("zigwin32").ui.input.xbox_controller;
const kbam = @import("zigwin32").ui.input.keyboard_and_mouse;
const foundation = @import("zigwin32").foundation;
const gdi = @import("zigwin32").graphics.gdi;
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

var instance: foundation.HINSTANCE = undefined;

var global_running = false;

var global_back_buffer = std.mem.zeroInit(Win32OffscreenBuffer, .{});

fn win32GetWindowDimension(window: foundation.HWND) Win32WindowDimension {
    var client_rect: foundation.RECT = undefined;
    _ = wam.GetClientRect(window, &client_rect);

    const result = Win32WindowDimension{
        .width = client_rect.right - client_rect.left,
        .height = client_rect.bottom - client_rect.top,
    };
    return result;
}

fn win32RenderWierdGradient(buffer: *Win32OffscreenBuffer, blue_offset: i32, green_offset: i32) void {
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
    buffer.memory = zig32_mem.VirtualAlloc(null, @as(usize, @intCast(bitmap_memory_size)), zig32_mem.MEM_COMMIT, zig32_mem.PAGE_READWRITE);

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

            var x_offset: i32 = 0;
            var y_offset: i32 = 0;

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

                        const pad_up: bool = if (pad.wButtons == controller.XINPUT_GAMEPAD_DPAD_UP) true else false;
                        const pad_down: bool = if (pad.wButtons == controller.XINPUT_GAMEPAD_DPAD_DOWN) true else false;
                        const pad_left: bool = if (pad.wButtons == controller.XINPUT_GAMEPAD_DPAD_LEFT) true else false;
                        const pad_right: bool = if (pad.wButtons == controller.XINPUT_GAMEPAD_DPAD_RIGHT) true else false;

                        const pad_start: bool = if (pad.wButtons == controller.XINPUT_GAMEPAD_START) true else false;
                        const pad_back: bool = if (pad.wButtons == controller.XINPUT_GAMEPAD_BACK) true else false;

                        const pad_left_shoulder: bool = if (pad.wButtons == controller.XINPUT_GAMEPAD_LEFT_SHOULDER) true else false;
                        const pad_right_shoulder: bool = if (pad.wButtons == controller.XINPUT_GAMEPAD_RIGHT_SHOULDER) true else false;

                        const pad_A: bool = if (pad.wButtons == controller.XINPUT_GAMEPAD_A) true else false;
                        const pad_B: bool = if (pad.wButtons == controller.XINPUT_GAMEPAD_B) true else false;
                        const pad_X: bool = if (pad.wButtons == controller.XINPUT_GAMEPAD_X) true else false;
                        const pad_Y: bool = if (pad.wButtons == controller.XINPUT_GAMEPAD_Y) true else false;

                        const left_stick_x = pad.sThumbLX;
                        const left_stick_y = pad.sThumbLY;

                        x_offset += left_stick_x >> 12;
                        y_offset += left_stick_y >> 12;

                        const right_stick_x = pad.sThumbRX;
                        const right_stick_y = pad.sThumbRY;

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
                        _ = right_stick_y;
                    } else {
                        // Controller not available
                    }
                }

                // NOTE: Example of how to do XInput vibration

                // var vibration = std.mem.zeroInit(controller.XINPUT_VIBRATION, .{});
                // vibration.wLeftMotorSpeed = 60000;
                // vibration.wRightMotorSpeed = 60000;
                // _ = controller.XInputSetState(0, &vibration);

                win32RenderWierdGradient(&global_back_buffer, x_offset, y_offset);

                const dimension = win32GetWindowDimension(window);
                win32DisplayBufferInWindow(&global_back_buffer, device_context.?, dimension.width, dimension.height);
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
