const std = @import("std");

pub const GameButtonState = extern struct {
    half_transition_count: i32,
    ended_down: bool,
};

pub const GameControllerInput = extern struct {
    is_analog: bool,
    is_connected: bool,

    stick_average_x: f32,
    stick_average_y: f32,

    button: extern union {
        buttons: [12]GameButtonState,
        input: extern struct {
            action_up: GameButtonState,
            action_down: GameButtonState,
            action_left: GameButtonState,
            action_right: GameButtonState,

            move_up: GameButtonState,
            move_down: GameButtonState,
            move_left: GameButtonState,
            move_right: GameButtonState,

            left_shoulder: GameButtonState,
            right_shoulder: GameButtonState,

            back: GameButtonState,
            start: GameButtonState,

            // NOTE: All buttons must be added above this line
            terminator: GameButtonState,
        },
    },
};

pub const GameInput = struct { controllers: [5]GameControllerInput };

pub const GameSoundOutputBuffer = struct {
    samples_per_second: i32,
    sample_count: i32,
    samples: [*]i16,
};

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

const pi: f32 = 3.14159265359;

var tsine: f32 = 0.0;

fn gameOutputSound(sound_buffer: *GameSoundOutputBuffer, tone_hz: i32) void {
    const tone_volume: i32 = 3000;
    const wave_period: i32 = @divTrunc(sound_buffer.samples_per_second, tone_hz);
    var sample_out: [*]i16 = @ptrCast(@alignCast(sound_buffer.samples));

    var sample_index: u32 = 0;
    while (sample_index < sound_buffer.sample_count) : (sample_index += 1) {
        const sin_value = @sin(tsine);
        const sample_value: i16 = @intFromFloat(sin_value * @as(f32, @floatFromInt(tone_volume)));

        sample_out[0] = sample_value;
        sample_out += 1;
        sample_out[0] = sample_value;
        sample_out += 1;

        tsine += 2.0 * pi / @as(f32, @floatFromInt(wave_period));
    }
}

fn gameRender(buffer: *GameOffScreenBuffer, blue_offset: i32, green_offset: i32, alpha: i32) void {
    var row = @as([*]u8, @ptrCast(buffer.memory));

    var y: i32 = 0;
    while (y < buffer.height) : (y += 1) {
        var pixel: [*]Color = @ptrCast(@alignCast(row));
        var x: i32 = 0;
        while (x < buffer.width) : (x += 1) {
            const blue: u8 = @truncate(@abs(x +% blue_offset));
            const green: u8 = @truncate(@abs(y +% green_offset));
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

var x_offset: i32 = 0;
var y_offset: i32 = 0;

pub fn gameUpdateAndRender(input: *GameInput, buffer: *GameOffScreenBuffer, sound_buffer: *GameSoundOutputBuffer, alpha: i32) void {
    var tone_hz: i32 = 256;
    const input0: *GameControllerInput = &input.controllers[0];
    if (input0.is_analog) {
        // NOTE: Analog
        tone_hz = 256 + @as(i32, @intFromFloat(128.0 * input0.stick_average_x));
        x_offset += @as(i32, @intFromFloat(4.0 * input0.stick_average_y));
    } else {
        // NOTE: Digital
    }

    if (input0.button.input.action_down.ended_down) {
        y_offset += 1;
    }

    gameOutputSound(sound_buffer, tone_hz);
    gameRender(buffer, x_offset, y_offset, alpha);
}
