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
    usingnamespace @import("win32").ui.windows_and_messaging;
    usingnamespace @import("win32").zig;
};

fn win32MainWindowCallBack(window: zig32.HWND, message: u32, w_param: zig32.WPARAM, l_param: zig32.LPARAM) callconv(.c) zig32.LRESULT {
    var result: zig32.LRESULT = 0;
    switch (message) {
        zig32.WM_CLOSE, zig32.WM_DESTROY => {
            std.print("window message: {}\n", .{message});
        },
        zig32.WM_ACTIVATEAPP => {
            std.print("window message: {}\n", .{message});
        },
        zig32.WM_PAINT => {
            var paint: zig32.PAINTSTRUCT = std.zeroInit(zig32.PAINTSTRUCT, .{});
            const device_context: ?zig32.HDC = zig32.BeginPaint(window, &paint);
            const x = paint.rcPaint.left;
            const y = paint.rcPaint.top;
            const width = paint.rcPaint.left - paint.rcPaint.right;
            const height = paint.rcPaint.bottom - paint.rcPaint.top;
            _ = zig32.PatBlt(device_context, x, y, width, height, zig32.BLACKNESS);
            _ = zig32.EndPaint(window, &paint);
        },
        zig32.WM_SIZE => {
            std.print("window message: {}\n", .{message});
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
            while (true) {
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
