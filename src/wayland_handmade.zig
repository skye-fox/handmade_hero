const std = @import("std");

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;

const Context = struct {
    shm: ?*wl.Shm,
    compositor: ?*wl.Compositor,
    wm_base: ?*xdg.WmBase,
    width: u32 = 256,
    height: u32 = 256,
    configured: bool = false,
    running: bool = true,
};

fn createBuffer(shm: *wl.Shm, width: u32, height: u32) !*wl.Buffer {
    const stride = width * 4;
    const size = stride * height;
    const fd = try std.posix.memfd_create("handmade_hero", 0);
    try std.posix.ftruncate(fd, size);

    const data = try std.posix.mmap(null, size, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .SHARED }, fd, 0);

    const data_u32: [*]u32 = @ptrCast(@alignCast(data));
    for (0..width * height) |i| {
        data_u32[i] = 0xFF8B5CF6;
    }

    const pool = try shm.createPool(fd, @intCast(size));
    defer pool.destroy();

    return try pool.createBuffer(0, @intCast(width), @intCast(height), @intCast(stride), wl.Shm.Format.argb8888);
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, context: *Context) void {
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

fn xdgSurfaceListener(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, context: *Context) void {
    switch (event) {
        .configure => |configure| {
            xdg_surface.ackConfigure(configure.serial);
            context.configured = true;
        },
    }
}

fn xdgToplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, context: *Context) void {
    switch (event) {
        .configure => |configure| {
            if (configure.width > 0 and configure.height > 0) {
                context.width = @intCast(configure.width);
                context.height = @intCast(configure.height);
            }
        },
        .close => context.running = false,
    }
}

fn wmBaseListener(_: *xdg.WmBase, event: xdg.WmBase.Event, wm_base: *xdg.WmBase) void {
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

    var context = Context{
        .shm = null,
        .compositor = null,
        .wm_base = null,
    };

    registry.setListener(*Context, registryListener, &context);
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

    xdg_surface.setListener(*Context, xdgSurfaceListener, &context);
    xdg_toplevel.setListener(*Context, xdgToplevelListener, &context);
    wm_base.setListener(*xdg.WmBase, wmBaseListener, wm_base);

    surface.commit();
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    while (!context.configured and context.running) {
        if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
    }

    if (!context.running) return;

    const buffer = try createBuffer(shm, context.width, context.height);
    defer buffer.destroy();

    surface.attach(buffer, 0, 0);
    surface.commit();

    while (context.running) {
        if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
    }
}
