const std = @import("std");
const win = @import("std").os.windows;

const zig32 = @import("zigwin32");
const foundation = @import("zigwin32").foundation;
const gdi = @import("zigwin32").graphics.gdi;
const zig32_mem = @import("zigwin32").system.memory;
const wam = @import("zigwin32").ui.windows_and_messaging;

var instance: foundation.HINSTANCE = undefined;

var bitmap_info = std.mem.zeroInit(gdi.BITMAPINFO, .{});
var bitmap_memory: ?*anyopaque = undefined;
var bitmap_width: i32 = 0;
var bitmap_height: i32 = 0;

var running = false;

const Color = packed struct(u32) {
    blue: u8,
    green: u8,
    red: u8,
    pad: u8,
};

fn win32ResizeDIBSection(width: i32, height: i32) void {
    if (bitmap_memory) |memory| {
        _ = zig32_mem.VirtualFree(memory, 0, zig32_mem.MEM_RELEASE);
    }

    bitmap_width = width;
    bitmap_height = height;

    bitmap_info.bmiHeader.biSize = @sizeOf(@TypeOf(bitmap_info.bmiHeader));
    bitmap_info.bmiHeader.biWidth = bitmap_width;
    bitmap_info.bmiHeader.biHeight = bitmap_height;
    bitmap_info.bmiHeader.biPlanes = 1;
    bitmap_info.bmiHeader.biBitCount = 32;
    bitmap_info.bmiHeader.biCompression = gdi.BI_RGB;

    const bytes_per_pixel: i32 = 4;
    const bitmap_memory_size = (bitmap_width * bitmap_height) * bytes_per_pixel;
    bitmap_memory = zig32_mem.VirtualAlloc(null, @as(usize, @intCast(bitmap_memory_size)), zig32_mem.MEM_COMMIT, zig32_mem.PAGE_READWRITE);

    const pitch = width * bytes_per_pixel;
    var row = @as([*]u8, @ptrCast(bitmap_memory));

    var y: i32 = 0;
    while (y < bitmap_height) : (y += 1) {
        var pixel: [*]Color = @ptrCast(@alignCast(row));
        var x: i32 = 0;
        while (x < bitmap_width) : (x += 1) {
            pixel[0] = .{ .red = 0, .green = @as(u8, @intCast(y)), .blue = @as(u8, @intCast(x)), .pad = 0 };
            pixel += 1;
        }
        row += @intCast(pitch);
    }
}

fn win32UpdateWindow(device_context: gdi.HDC, window_rect: foundation.RECT) void {
    const window_width = window_rect.right - window_rect.left;
    const window_height = window_rect.bottom - window_rect.top;
    _ = gdi.StretchDIBits(device_context, 0, 0, bitmap_width, bitmap_height, 0, 0, window_width, window_height, bitmap_memory, &bitmap_info, gdi.DIB_RGB_COLORS, gdi.SRCCOPY);
}

fn win32MainWindowCallback(window: foundation.HWND, message: win.UINT, wparam: foundation.WPARAM, lparam: foundation.LPARAM) callconv(.c) foundation.LRESULT {
    var result: foundation.LRESULT = 0;
    switch (message) {
        wam.WM_ACTIVATEAPP => {
            std.debug.print("WM_ACTIVATEAPP\n", .{});
        },
        wam.WM_CLOSE, wam.WM_DESTROY => running = false,
        wam.WM_PAINT => {
            var paint: gdi.PAINTSTRUCT = undefined;
            const device_context = gdi.BeginPaint(window, &paint);

            var client_rect: foundation.RECT = undefined;
            _ = wam.GetClientRect(window, &client_rect);

            win32UpdateWindow(device_context.?, client_rect);
            _ = gdi.EndPaint(window, &paint);
        },
        wam.WM_SIZE => {
            var client_rect: foundation.RECT = undefined;
            _ = wam.GetClientRect(window, &client_rect);
            const width = client_rect.right - client_rect.left;
            const height = client_rect.bottom - client_rect.top;
            win32ResizeDIBSection(width, height);
        },
        else => {
            result = wam.DefWindowProcA(window, message, wparam, lparam);
        },
    }
    return result;
}

pub fn run() !void {
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

        if (window_handle) |_| {
            running = true;
            while (running) {
                var message: wam.MSG = undefined;
                const message_result = wam.GetMessageA(&message, null, 0, 0);
                if (message_result > 0) {
                    _ = wam.TranslateMessage(&message);
                    _ = wam.DispatchMessageA(&message);
                }
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
