pub const GameOffscreenBuffer = struct {
    memory: ?*anyopaque,
    width: i32,
    height: i32,
    pitch: u32,
};

const Color = packed struct(u32) {
    // NOTE: Pixels are always 32-bits wide, windows memory order BB GG RR XX
    blue: u8,
    green: u8,
    red: u8,
    _: u8 = 0,
};

pub const GameOutputSoundBuffer = struct {
    samples_per_second: u32,
    sample_count: u32,
    samples: *i16,
};

pub const GameButtonState = extern struct {
    half_transition_count: i32,
    ended_down: bool,
};

pub const GameControllerInput = extern struct {
    is_analog: bool,

    start_x: f32,
    start_y: f32,

    min_x: f32,
    min_y: f32,

    max_x: f32,
    max_y: f32,

    end_x: f32,
    end_y: f32,

    button_union: extern union {
        buttons: [6]GameButtonState,
        button_input: extern struct {
            up: GameButtonState,
            down: GameButtonState,
            left: GameButtonState,
            right: GameButtonState,
            left_shoulder: GameButtonState,
            right_shoulder: GameButtonState,
        },
    },
};

pub const GameInput = struct { controllers: [4]GameControllerInput };

const pi: f32 = 3.14159265359;
var t_sine: f32 = 0.0;
var b_offset: i32 = 0;
var g_offset: i32 = 0;

fn gameOutputSound(sound_buffer: *GameOutputSoundBuffer, tone_hz: i32) void {
    const tone_volume: i16 = 2000;
    const wave_period: i32 = @intCast(@divTrunc(@as(i32, @intCast(sound_buffer.samples_per_second)), tone_hz));
    var sample_out: [*]i16 = @ptrCast(sound_buffer.samples);

    var sample_index: u32 = 0;
    while (sample_index < sound_buffer.sample_count) : (sample_index += 1) {
        const sine_value: f32 = @sin(t_sine);
        const sample_value: i16 = @intFromFloat(sine_value * @as(f32, @floatFromInt(tone_volume)));
        sample_out[0] = sample_value;
        sample_out += 1;
        sample_out[0] = sample_value;
        sample_out += 1;

        t_sine += 2.0 * pi * 1.0 / @as(f32, @floatFromInt(wave_period));
    }
}

fn renderWeirdGradient(buffer: *GameOffscreenBuffer, blue_offset: i32, green_offset: i32) void {
    var row: [*]u8 = @ptrCast(buffer.memory);
    var y: i32 = 0;
    while (y < buffer.height) : (y += 1) {
        var x: i32 = 0;

        // NOTE: pixel in windows memory: BB GG RR xx
        var pixel: [*]Color = @alignCast(@ptrCast(row));
        while (x < buffer.width) : (x += 1) {
            const blue: u8 = @truncate(@abs(x + blue_offset));
            const green: u8 = @truncate(@abs(y + green_offset));
            // NOTE: bitwise method (This is how Casey Muratori did it)
            // pixel[0] = ((@as(u32, green) << 8) | blue);
            // pixel += 1;

            // NOTE: packed struct method (not possible in C, but perhaps the preferred method in zig?)
            pixel[0] = .{ .blue = blue, .green = green, .red = 0 };
            pixel += 1;
        }
        row += buffer.pitch;
    }
}

pub fn gameUpdateAndRender(input: *GameInput, buffer: *GameOffscreenBuffer, sound_buffer: *GameOutputSoundBuffer) void {
    var tone_hz: i32 = 256;

    const input0: *GameControllerInput = &input.controllers[0];

    if (input0.is_analog) {
        // analog movement
        b_offset += @intFromFloat(4.0 * input0.end_x);
        tone_hz = 256 + @as(i32, @intFromFloat(128.0 * input0.end_y));
    } else {
        // digital movement
    }

    if (input0.button_union.button_input.down.ended_down) {
        g_offset += 1;
    }

    gameOutputSound(sound_buffer, tone_hz);
    renderWeirdGradient(buffer, b_offset, g_offset);
}
