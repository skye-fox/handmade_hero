const std = @import("std");
const win = @import("std").os.windows;

// const zig32 = @import("zigwin32");
const foundation = @import("zigwin32").foundation;
const gdi = @import("zigwin32").graphics.gdi;
const wam = @import("zigwin32").ui.windows_and_messaging;

var running = true;

fn mainWindowCallback(window: foundation.HWND, message: win.UINT, wparam: foundation.WPARAM, lparam: foundation.LPARAM) foundation.LRESULT {
    var result: foundation.LRESULT = 0;
    switch (message) {
        wam.WM_ACTIVATEAPP => {
            std.debug.print("WM_ACTIVATEAPP\n", .{});
        },
        wam.WM_CLOSE => running = false,
        wam.WM_DESTROY => {
            std.debug.print("WM_DESTROY\n", .{});
        },
        wam.WM_PAINT => {
            const paint: gdi.PAINTSTRUCT = undefined;
            const device_context = gdi.BeginPaint(window, &paint);
            const x = paint.rcPaint.left;
            const y = paint.rcPaint.top;
            const height = paint.rcPaint.bottom - paint.rcPaint.top;
            const width = paint.rcPaint.right - paint.rcPaint.left;
            gdi.PatBlt(device_context, x, y, width, height, gdi.BLACKNESS);
            _ = gdi.EndPaint(window, &paint);
        },
        wam.WM_SIZE => {
            std.debug.print("WM_SIZE\n", .{});
        },
        else => {
            result = wam.DefWindowProcA(window, message, wparam, lparam);
        },
    }
    return result;
}

pub fn wWinMain(instance: foundation.HINSTANCE, _: foundation.HINSTANCE, _: foundation.PWSTR, _: win.INT) !win.INT {
    var window_class = std.mem.zeroInit(wam.WNDCLASSA, .{});

    window_class.style = wam.CS_OWNDC | wam.CS_HREDRAW | wam.CS_VREDRAW;
    window_class.lpfnWndProc = mainWindowCallback;
    window_class.hInstance = instance;
    window_class.lpszClassName = "Handmade Hero";

    if (wam.RegisterClassA(&window_class) != 0) {
        const window_handle = wam.CreateWindowExA(
            0,
            window_class.lpszClassName,
            "Handmade Hero",
            wam.WS_OVERLAPPEDWINDOW | wam.WS_VISIBLE,
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
            while (running) {
                var message: wam.MSG = undefined;
                const message_result = wam.GetMessageA(&message, 0, 0, 0);
                if (message_result > 0) {
                    wam.TranslateMessage(&message);
                    wam.DispatchMessageA(&message);
                }
            }
        } else {
            // TODO: Logging
        }
    } else {
        // TODO: Logging
    }
}
