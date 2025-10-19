const std = @import("std");

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;

const WlContext = struct {
    shm: ?*wl.Shm,
    compositor: ?*wl.Compositor,
    wm_base: ?*xdg.WmBase,
    width: i32 = 256,
    height: i32 = 256,
    configured: bool = false,
    running: bool = true,
};

const WlColor = packed struct(u32) {
    blue: u8,
    green: u8,
    red: u8,
    alpha: u8 = 255,
};

const WlOffscreenBuffer = struct {
    buffer: ?*wl.Buffer,
    memory: []align(4096) u8,
    width: i32,
    height: i32,
    pitch: i32,
};

var global_back_buffer = std.mem.zeroInit(WlOffscreenBuffer, .{});

fn wlRenderWeirdGradient(buffer: *WlOffscreenBuffer, blue_offset: u32, green_offset: u32) void {
    var row: [*]u8 = @ptrCast(buffer.memory);

    var y: u32 = 0;
    while (y < buffer.height) : (y += 1) {
        var pixel: [*]WlColor = @ptrCast(@alignCast(row));
        var x: u32 = 0;
        while (x < buffer.width) : (x += 1) {
            pixel[0] = .{ .blue = @truncate(x +% blue_offset), .green = @truncate(y +% green_offset), .red = @truncate(0) };
            pixel += 1;
        }
        row += @intCast(buffer.pitch);
    }

    // const data_u32: [*]u32 = @ptrCast(@alignCast(data));
    // for (0..width * height) |i| {
    //     data_u32[i] = 0xFF8B5CF6;
    // }

}

fn WlCreateBuffer(buffer: *WlOffscreenBuffer, shm: *wl.Shm, width: i32, height: i32) !void {
    buffer.width = width;
    buffer.height = height;
    buffer.pitch = width * 4;
    const size: u64 = @intCast(buffer.pitch * height);
    const fd = try std.posix.memfd_create("handmade_hero", 0);
    try std.posix.ftruncate(fd, size);

    buffer.memory = try std.posix.mmap(null, size, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .SHARED }, fd, 0);

    const pool = try shm.createPool(fd, @intCast(size));
    defer pool.destroy();

    buffer.buffer = try pool.createBuffer(0, @intCast(width), @intCast(height), @intCast(buffer.pitch), wl.Shm.Format.argb8888);
}

fn wlRegistryListener(registry: *wl.Registry, event: wl.Registry.Event, context: *WlContext) void {
    switch (event) {
        .global => |global| {
            if (std.mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                context.compositor = registry.bind(global.name, wl.Compositor, 1) catch |err| {
                    std.debug.print("Failed to bind to compositor interface: {}.\n", .{err});
                    return;
                };
            } else if (std.mem.orderZ(u8, global.interface, wl.Shm.interface.name) == .eq) {
                context.shm = registry.bind(global.name, wl.Shm, 1) catch |err| {
                    std.debug.print("Failed bind to shm interface: {}", .{err});
                    return;
                };
            } else if (std.mem.orderZ(u8, global.interface, xdg.WmBase.interface.name) == .eq) {
                context.wm_base = registry.bind(global.name, xdg.WmBase, 1) catch |err| {
                    std.debug.print("Failed bind to wm_base interface: {}", .{err});
                    return;
                };
            }
        },
        .global_remove => {},
    }
}

fn wlXDGSurfaceListener(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, context: *WlContext) void {
    switch (event) {
        .configure => |configure| {
            xdg_surface.ackConfigure(configure.serial);
            context.configured = true;
        },
    }
}

fn wlXDGToplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, context: *WlContext) void {
    switch (event) {
        .configure => |configure| {
            if (configure.width > 0 and configure.height > 0) {
                const new_width: i32 = @intCast(configure.width);
                const new_height: i32 = @intCast(configure.height);
                if (new_width != context.width or new_height != context.height) {
                    context.width = new_width;
                    context.height = new_height;
                    context.configured = false;
                }
            }
        },
        .close => context.running = false,
    }
}

fn wlWMBaseListener(_: *xdg.WmBase, event: xdg.WmBase.Event, wm_base: *xdg.WmBase) void {
    switch (event) {
        .ping => |ping| {
            wm_base.pong(ping.serial);
        },
    }
}

pub fn run() !void {
    const display = try wl.Display.connect(null);
    defer display.disconnect();

    const registry = try wl.Display.getRegistry(display);
    defer registry.destroy();

    var context = WlContext{
        .shm = null,
        .compositor = null,
        .wm_base = null,
    };

    registry.setListener(*WlContext, wlRegistryListener, &context);
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    std.debug.print("Connection established!\n", .{});

    const shm = context.shm orelse return error.NoWlShm;
    const compositor = context.compositor orelse return error.NoWlCompositor;
    const wm_base = context.wm_base orelse return error.NoXdgWmBase;

    const surface = try compositor.createSurface();
    defer surface.destroy();
    const xdg_surface = try wm_base.getXdgSurface(surface);
    defer xdg_surface.destroy();
    const xdg_toplevel = try xdg_surface.getToplevel();
    defer xdg_toplevel.destroy();

    xdg_surface.setListener(*WlContext, wlXDGSurfaceListener, &context);
    xdg_toplevel.setListener(*WlContext, wlXDGToplevelListener, &context);
    wm_base.setListener(*xdg.WmBase, wlWMBaseListener, wm_base);

    surface.commit();
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    while (!context.configured and context.running) {
        if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
    }

    if (!context.running) return;

    try WlCreateBuffer(&global_back_buffer, shm, context.width, context.height);
    defer global_back_buffer.buffer.?.destroy();

    var blue_offset: u32 = 0;
    var green_offset: u32 = 0;
    while (context.running) {
        if (global_back_buffer.width != context.width or global_back_buffer.height != context.height) {
            global_back_buffer.buffer.?.destroy();
            std.posix.munmap(global_back_buffer.memory);
            try WlCreateBuffer(&global_back_buffer, shm, context.width, context.height);
        }
        wlRenderWeirdGradient(&global_back_buffer, blue_offset, green_offset);
        surface.attach(global_back_buffer.buffer, 0, 0);
        surface.commit();
        if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
        blue_offset += 1;
        green_offset += 1;
    }
}
