const std = @import("std");
const builtin = @import("builtin");

const platform_os =
    // Linux
    if (builtin.os.tag == .linux) @import("wayland_handmade.zig")
    // Windows
    else if (builtin.os.tag == .windows) @import("win32_handmade.zig")
    // Unsupported
    else @compileError("Unsupported OS");

pub fn main() !void {
    try platform_os.run();
}
