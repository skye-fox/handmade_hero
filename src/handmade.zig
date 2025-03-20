const std = struct {
    usingnamespace @import("std");
    usingnamespace @import("std").math;
    usingnamespace @import("std").debug;
};

const dbg = @import("builtin").mode == @import("std").builtin.Mode.Debug;

const DEBUGPlatformReadEntireFile = @import("win32_handmade.zig").DEBUGPlatformReadEntireFile;
const DEBUGPlatformFreeFileMemory = @import("win32_handmade.zig").DEBUGPlatformFreeFileMemory;
const DEBUGPlatformWriteEntireFile = @import("win32_handmade.zig").DEBUGPlatformWriteEntireFile;
const DEBUGPlatformReadFileResult = @import("win32_handmade.zig").DEBUGPlatformReadFileResult;

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
    is_connected: bool,

    stick_average_x: f32,
    stick_average_y: f32,

    button_union: extern union {
        buttons: [12]GameButtonState,
        button_input: extern struct {
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

pub const GameMemory = struct {
    is_initialized: bool,
    permanent_storage_size: u64,
    permanent_storage: ?*anyopaque,
    transient_storage_size: u64,
    transient_storage: ?*anyopaque,
};

const GameState = struct {
    tone_hz: i32,
    blue_offset: i32,
    green_offset: i32,
};

pub const GameInput = struct { controllers: [5]GameControllerInput };

const pi: f32 = 3.14159265359;
var t_sine: f32 = 0.0;

pub fn kilobytes(value: u64) u64 {
    return value * 1024;
}

pub fn megabytes(value: u64) u64 {
    return value * std.pow(u64, 1024, 2);
}

pub fn gigabytes(value: u64) u64 {
    return value * std.pow(u64, 1024, 3);
}

pub fn terabytes(value: u64) u64 {
    return value * std.pow(u64, 1024, 4);
}

pub inline fn getController(input: *GameInput, controller_index: u32) *GameControllerInput {
    std.assert(controller_index < input.controllers.len);

    const result: *GameControllerInput = &input.controllers[controller_index];
    return result;
}

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

pub fn gameUpdateAndRender(memory: *GameMemory, input: *GameInput, buffer: *GameOffscreenBuffer, sound_buffer: *GameOutputSoundBuffer) void {
    std.assert((&input.controllers[0].button_union.button_input.terminator - &input.controllers[0].button_union.buttons[0]) == input.controllers[0].button_union.buttons.len);
    std.assert(@sizeOf(GameState) <= memory.permanent_storage_size);

    var game_state: *GameState = @alignCast(@ptrCast(memory.permanent_storage));

    if (!memory.is_initialized) {
        const file_name: ?[*:0]const u8 = "C:/Users/SkyeFox/code/learning/handmade_hero/assets/test.txt";

        const file: DEBUGPlatformReadFileResult = if (dbg) DEBUGPlatformReadEntireFile(file_name) else null;

        if (file.contents) |_| {
            _ = DEBUGPlatformWriteEntireFile("C:/Users/SkyeFox/code/learning/handmade_hero/assets/test2.txt", file.contents_size, file.contents);
            DEBUGPlatformFreeFileMemory(file.contents);
        }

        game_state.tone_hz = 256;
        game_state.blue_offset = 0;
        game_state.green_offset = 0;

        memory.is_initialized = true;
    }

    var controller_index: u32 = 0;
    while (controller_index < input.controllers.len) : (controller_index += 1) {
        const controller: *GameControllerInput = getController(input, controller_index);

        if (controller.is_analog) {
            // analog movement
            game_state.blue_offset += @intFromFloat(4.0 * controller.stick_average_x);
            game_state.tone_hz = 256 + @as(i32, @intFromFloat(128.0 * controller.stick_average_y));
        } else {
            // digital movement
            if (controller.button_union.button_input.move_left.ended_down) {
                game_state.blue_offset -= 1;
            }

            if (controller.button_union.button_input.move_right.ended_down) {
                game_state.blue_offset += 1;
            }
        }

        if (controller.button_union.button_input.action_down.ended_down) {
            game_state.green_offset += 1;
        }
    }

    gameOutputSound(sound_buffer, game_state.tone_hz);
    renderWeirdGradient(buffer, game_state.blue_offset, game_state.green_offset);
}
