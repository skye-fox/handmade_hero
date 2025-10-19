const std = @import("std");

pub const GameOffScreenBuffer = struct {
    memory: []align(4096) u8,
    width: i32,
    height: i32,
    pitch: i32,
};

const Color = packed struct(u32) {
    // NOTE: Pixels are always 32 bits wide, memory order BB GG RR AA
    blue: u8,
    green: u8,
    red: u8,
    alpha: u8,
};

fn renderGame(buffer: *GameOffScreenBuffer, blue_offset: i32, green_offset: i32, alpha: i32) void {
    var row = @as([*]u8, @ptrCast(buffer.memory));

    var y: i32 = 0;
    while (y < buffer.height) : (y += 1) {
        var pixel: [*]Color = @ptrCast(@alignCast(row));
        var x: i32 = 0;
        while (x < buffer.width) : (x += 1) {
            const blue: u8 = @truncate(@abs(x + blue_offset));
            const green: u8 = @truncate(@abs(y + green_offset));
            pixel[0] = .{ .blue = blue, .green = green, .red = @truncate(0), .alpha = @intCast(alpha) };
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

pub fn gameUpdateAndRender(buffer: *GameOffScreenBuffer, blue_offset: i32, green_offset: i32, alpha: i32) void {
    renderGame(buffer, blue_offset, green_offset, alpha);
}
