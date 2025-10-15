const std = @import("std");
const win = @import("std").os.windows;

const zig32 = @import("zigwin32");
const foundation = @import("zigwin32").foundation;
const gdi = @import("zigwin32").graphics.gdi;
const zig32_mem = @import("zigwin32").system.memory;
const wam = @import("zigwin32").ui.windows_and_messaging;

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

fn win32RenderWierdGradient(buffer: Win32OffscreenBuffer, blue_offset: u32, green_offset: u32) void {
    var row = @as([*]u8, @ptrCast(buffer.memory));

    var y: u32 = 0;
    while (y < buffer.height) : (y += 1) {
        var pixel: [*]Color = @ptrCast(@alignCast(row));
        var x: u32 = 0;
        while (x < buffer.width) : (x += 1) {
            pixel[0] = .{ .blue = @truncate(x + blue_offset), .green = @truncate(y + green_offset), .red = @truncate(0) };
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

fn win32DisplayBufferInWindow(device_context: gdi.HDC, window_width: i32, window_height: i32, buffer: Win32OffscreenBuffer) void {
    _ = gdi.StretchDIBits(device_context, 0, 0, window_width, window_height, 0, 0, buffer.width, buffer.height, buffer.memory, &buffer.info, gdi.DIB_RGB_COLORS, gdi.SRCCOPY);
}

fn win32MainWindowCallback(window: foundation.HWND, message: win.UINT, wparam: foundation.WPARAM, lparam: foundation.LPARAM) callconv(.c) foundation.LRESULT {
    var result: foundation.LRESULT = 0;
    switch (message) {
        wam.WM_ACTIVATEAPP => {
            std.debug.print("WM_ACTIVATEAPP\n", .{});
        },
        wam.WM_CLOSE, wam.WM_DESTROY => global_running = false,
        wam.WM_PAINT => {
            var paint: gdi.PAINTSTRUCT = undefined;
            const device_context = gdi.BeginPaint(window, &paint);

            const dimension = win32GetWindowDimension(window);

            win32DisplayBufferInWindow(device_context.?, dimension.width, dimension.height, global_back_buffer);
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

            var blue_offset: u32 = 0;
            var green_offset: u32 = 0;

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
                win32RenderWierdGradient(global_back_buffer, blue_offset, green_offset);

                const dimension = win32GetWindowDimension(window);
                win32DisplayBufferInWindow(device_context.?, dimension.width, dimension.height, global_back_buffer);

                blue_offset += 1;
                green_offset += 1;
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
