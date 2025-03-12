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
    usingnamespace @import("win32").ui.windows_and_messaging;
    usingnamespace @import("win32").zig;
};

var bitmap_memory: ?*anyopaque = undefined;
var bitmap_info: zig32.BITMAPINFO = std.zeroInit(zig32.BITMAPINFO, .{});
var bitmap_width: i32 = 0;
var bitmap_height: i32 = 0;

var global_running = false;

fn win32ResizeDIBSection(width: i32, height: i32) void {
    if (bitmap_memory != null) {
        _ = zig32.VirtualFree(bitmap_memory, 0, zig32.MEM_RELEASE);
    }

    bitmap_width = width;
    bitmap_height = height;

    bitmap_info.bmiHeader.biSize = @sizeOf(@TypeOf(bitmap_info.bmiHeader));
    bitmap_info.bmiHeader.biWidth = width;
    bitmap_info.bmiHeader.biHeight = -height;
    bitmap_info.bmiHeader.biPlanes = 1;
    bitmap_info.bmiHeader.biBitCount = 32;
    bitmap_info.bmiHeader.biCompression = zig32.BI_RGB;

    const bytes_per_pixel: u8 = 4;
    const bitmap_memory_size: usize = @intCast((width * height) * bytes_per_pixel);
    bitmap_memory = zig32.VirtualAlloc(null, bitmap_memory_size, zig32.MEM_COMMIT, zig32.PAGE_READWRITE);
}

fn win32UpdateWindow(device_context: ?zig32.HDC, window_rect: *zig32.RECT) void {
    const window_width: i32 = window_rect.right - window_rect.left;
    const window_height: i32 = window_rect.bottom - window_rect.top;
    _ = zig32.StretchDIBits(device_context, 0, 0, bitmap_width, bitmap_height, 0, 0, window_width, window_height, bitmap_memory, &bitmap_info, zig32.DIB_RGB_COLORS, zig32.SRCCOPY);
}

fn win32MainWindowCallBack(window: zig32.HWND, message: u32, w_param: zig32.WPARAM, l_param: zig32.LPARAM) callconv(.c) zig32.LRESULT {
    var result: zig32.LRESULT = 0;
    switch (message) {
        zig32.WM_CLOSE, zig32.WM_DESTROY => {
            global_running = false;
        },
        zig32.WM_ACTIVATEAPP => {},
        zig32.WM_PAINT => {
            var paint: zig32.PAINTSTRUCT = std.zeroInit(zig32.PAINTSTRUCT, .{});
            const device_context: ?zig32.HDC = zig32.BeginPaint(window, &paint);

            var client_rect: zig32.RECT = std.zeroInit(zig32.RECT, .{});
            _ = zig32.GetClientRect(window, &client_rect);

            win32UpdateWindow(device_context, &client_rect);
            _ = zig32.EndPaint(window, &paint);
        },
        zig32.WM_SIZE => {
            var client_rect: zig32.RECT = std.zeroInit(zig32.RECT, .{});
            _ = zig32.GetClientRect(window, &client_rect);
            const width: i32 = client_rect.right - client_rect.left;
            const height: i32 = client_rect.bottom - client_rect.top;
            win32ResizeDIBSection(width, height);
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
            var message: zig32.MSG = undefined;
            global_running = true;
            while (global_running) {
                const message_result = zig32.GetMessageA(&message, null, 0, 0);
                if (message_result > 0) {
                    _ = zig32.TranslateMessage(&message);
                    _ = zig32.DispatchMessageA(&message);
                } else {
                    break;
                }
            }
        } else {
            // TODO: Logging
        }
    } else {
        // TODO: Logging
    }
    return 0;
}
