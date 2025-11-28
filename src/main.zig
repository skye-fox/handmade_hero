const std = @import("std");
const builtin = @import("builtin");

pub const platform =
    // Linux
    if (builtin.os.tag == .linux) @import("linux_handmade.zig")
    // Windows
    else if (builtin.os.tag == .windows) @import("win32_handmade.zig")
    // Unsupported
    else @compileError("Unsupported OS: " ++ @tagName(builtin.os.tag));

pub fn main() !void {
    try platform.run();
}
