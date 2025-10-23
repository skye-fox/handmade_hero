const std = @import("std");
const debug = @import("builtin").mode == @import("std").builtin.OptimizeMode.Debug;

const builtin = @import("builtin");

const platform = if (builtin.os.tag == .windows) @import("win32_handmade.zig");

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

pub const GameButtonState = extern struct {
    half_transition_count: i32,
    ended_down: bool,
};

pub const GameControllerInput = extern struct {
    is_analog: bool,
    is_connected: bool,

    left_stick_average_x: f32,
    left_stick_average_y: f32,

    right_stick_average_x: f32,
    right_stick_average_y: f32,

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
    alpha: u8 = 255,
};

var tsine: f32 = 0.0;

pub fn kiloBytes(value: u32) u64 {
    return value * 1024;
}

pub fn megaBytes(value: u32) u64 {
    return value * std.math.pow(u32, 1024, 2);
}

pub fn gigaBytes(value: u32) u64 {
    return value * std.math.pow(u64, 1024, 3);
}

pub fn teraBytes(value: u32) u64 {
    return value * std.math.pow(u64, 1024, 4);
}

pub inline fn getController(input: *GameInput, controller_index: usize) *GameControllerInput {
    std.debug.assert(controller_index < input.controllers.len);

    const result: *GameControllerInput = &input.controllers[controller_index];
    return result;
}

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

        tsine += 2.0 * std.math.pi / @as(f32, @floatFromInt(wave_period));
    }
}

fn gameRender(buffer: *GameOffScreenBuffer, blue_offset: i32, green_offset: i32) void {
    var row = @as([*]u8, @ptrCast(buffer.memory));

    var y: i32 = 0;
    while (y < buffer.height) : (y += 1) {
        var pixel: [*]Color = @ptrCast(@alignCast(row));
        var x: i32 = 0;
        while (x < buffer.width) : (x += 1) {
            const blue: u8 = @truncate(@abs(x +% blue_offset));
            const green: u8 = @truncate(@abs(y +% green_offset));
            pixel[0] = .{ .blue = blue, .green = green, .red = @truncate(0) };
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

pub fn gameUpdateAndRender(memory: *GameMemory, input: *GameInput, video_buffer: *GameOffScreenBuffer, sound_buffer: *GameSoundOutputBuffer) !void {
    if (debug) {
        std.debug.assert((&input.controllers[0].button.input.terminator - &input.controllers[0].button.buttons[0]) == input.controllers[0].button.buttons.len);
        std.debug.assert(@sizeOf(GameMemory) <= memory.permanent_storage_size);
    }

    const game_state: *GameState = @ptrCast(@alignCast(memory.permanent_storage));
    if (!memory.is_initialized) {
        game_state.tone_hz = 256;
        game_state.blue_offset = 0;
        game_state.green_offset = 0;

        if (debug) {
            const file_path = "src/handmade.zig";
            const file: platform.DEBUGReadFileResult = platform.DEBUG_readEntireFile(file_path);
            if (file.content) |content| {
                _ = platform.DEBUG_writeEntireFile("test.txt", file.content_size, content);
                platform.DEBUG_freeFileMemory(content);
            }
        }
        memory.is_initialized = true;
    }

    for (0..input.controllers.len) |controller_index| {
        const controller: *GameControllerInput = getController(input, controller_index);
        if (controller.is_analog) {
            // NOTE: Analog
            game_state.tone_hz = 256 + @as(i32, @intFromFloat(128.0 * controller.right_stick_average_x));
            // game_state.tone_hz = 256 + @as(i32, @intFromFloat(128.0 * controller.right_stick_average_y));
            game_state.blue_offset += @as(i32, @intFromFloat(4.0 * controller.left_stick_average_x));
            game_state.green_offset += @as(i32, @intFromFloat(4.0 * controller.left_stick_average_y));
        } else {
            // NOTE: Digital
            if (controller.button.input.move_left.ended_down) {
                game_state.blue_offset -= 1;
            }

            if (controller.button.input.move_right.ended_down) {
                game_state.blue_offset += 1;
            }
            if (controller.button.input.move_down.ended_down) {
                game_state.green_offset -= 1;
            }
        }
        if (controller.button.input.action_down.ended_down) {
            game_state.green_offset -= 1;
        }
    }

    gameOutputSound(sound_buffer, game_state.tone_hz);
    gameRender(video_buffer, game_state.blue_offset, game_state.green_offset);
}

pub fn TEMPgameUpdateAndRender(video_buffer: *GameOffScreenBuffer, blue_offset: i32, green_offset: i32) void {
    gameRender(video_buffer, blue_offset, green_offset);
}
