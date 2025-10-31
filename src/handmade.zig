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

    debugPlatformReadEntireFile: *const fn ([*:0]const u8) platform.DEBUGReadFileResult,
    debugPlatformFreeFilMemory: *const fn (?*anyopaque) void,
    debugPlatformWriteEntireFile: *const fn ([*:0]const u8, u32, ?*anyopaque) bool,
};

const GameState = struct {
    tone_hz: i32,
    blue_offset: i32,
    green_offset: i32,
    t_sine: f32,

    player_x: i32,
    player_y: i32,
    t_jump: f32,
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
    pitch: usize,
    bytes_per_pixel: i32,
};

const Color = packed struct(u32) {
    // NOTE: Pixels are always 32 bits wide, memory order BB GG RR AA
    blue: u8,
    green: u8,
    red: u8,
    alpha: u8 = 255,
};

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

pub export fn getSoundSamples(memory: *GameMemory, sound_buffer: *GameSoundOutputBuffer) void {
    const game_state: *GameState = @ptrCast(@alignCast(memory.permanent_storage));
    _ = sound_buffer;
    _ = game_state;
    // gameOutputSound(sound_buffer, game_state);
}

fn gameOutputSound(sound_buffer: *GameSoundOutputBuffer, game_state: *GameState) void {
    const tone_volume: i32 = 3000;
    const wave_period: i32 = @divTrunc(sound_buffer.samples_per_second, game_state.tone_hz);
    var sample_out: [*]i16 = @ptrCast(@alignCast(sound_buffer.samples));

    var sample_index: u32 = 0;
    while (sample_index < sound_buffer.sample_count) : (sample_index += 1) {
        const sin_value = @sin(game_state.t_sine);
        const sample_value: i16 = @intFromFloat(sin_value * @as(f32, @floatFromInt(tone_volume)));

        sample_out[0] = sample_value;
        sample_out += 1;
        sample_out[0] = sample_value;
        sample_out += 1;

        game_state.t_sine += 2.0 * std.math.pi / @as(f32, @floatFromInt(wave_period));
        if (game_state.t_sine > 2.0 * std.math.pi) {
            game_state.t_sine -= 2.0 * std.math.pi;
        }
    }
}

fn renderPlayer(buffer: *GameOffScreenBuffer, player_x: i32, player_y: i32) void {
    const end_of_buffer = @intFromPtr(buffer.memory.ptr) + buffer.pitch * @as(usize, @intCast(buffer.height));
    const color: u32 = 0xFFFFFFFF;

    const left = @max(player_x, 0);
    const right = @min(player_x + 20, buffer.width);
    const top = @max(player_y, 0);
    const bottom = @min(player_y + 20, buffer.height);

    var x = left;
    while (x < right) : (x += 1) {
        var pixel_ptr = @intFromPtr(buffer.memory.ptr) + @as(usize, @intCast(x)) * @as(usize, @intCast(buffer.bytes_per_pixel)) + @as(usize, @intCast(top)) * buffer.pitch;

        var y: i32 = top;
        while (y < bottom) : (y += 1) {
            const pixel_addr = @intFromPtr(buffer.memory.ptr);

            if (pixel_ptr >= pixel_addr and (pixel_ptr + 4) < end_of_buffer) {
                const pixel: *u32 = @ptrFromInt(pixel_ptr);
                pixel.* = color;
            }

            pixel_ptr += buffer.pitch;
        }
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
            // const red: u8 = @truncate(@abs(x +% y));
            pixel[0] = .{ .blue = blue, .green = green, .red = 0 };
            pixel += 1;
        }
        row += buffer.pitch;
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

pub export fn gameUpdateAndRender(memory: *GameMemory, input: *GameInput, video_buffer: *GameOffScreenBuffer) void {
    std.debug.assert((&input.controllers[0].button.input.terminator - &input.controllers[0].button.buttons[0]) == input.controllers[0].button.buttons.len);
    std.debug.assert(@sizeOf(GameState) <= memory.permanent_storage_size);

    const game_state: *GameState = @ptrCast(@alignCast(memory.permanent_storage));
    if (!memory.is_initialized) {
        game_state.tone_hz = 256;
        game_state.blue_offset = 0;
        game_state.green_offset = 0;
        game_state.t_sine = 0.0;
        game_state.player_x = 100;
        game_state.player_y = 100;

        if (debug) {
            const file_path = "src/handmade.zig";
            const file: platform.DEBUGReadFileResult = memory.debugPlatformReadEntireFile(file_path);
            if (file.content) |content| {
                _ = memory.debugPlatformWriteEntireFile("test.txt", file.content_size, content);
                memory.debugPlatformFreeFilMemory(content);
            }
        }
        memory.is_initialized = true;
    }

    for (0..input.controllers.len) |controller_index| {
        const controller: *GameControllerInput = getController(input, controller_index);
        if (controller.is_analog) {
            // NOTE: Analog
            game_state.tone_hz = 256 + @as(i32, @intFromFloat(128.0 * controller.right_stick_average_x));
            // game_state.blue_offset += @as(i32, @intFromFloat(4.0 * controller.left_stick_average_x));
            // game_state.green_offset += @as(i32, @intFromFloat(4.0 * controller.left_stick_average_y));
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
        game_state.player_x += @as(i32, @intFromFloat(12.0 * controller.left_stick_average_x));
        game_state.player_y -= @as(i32, @intFromFloat(12.0 * controller.left_stick_average_y));
        if (game_state.t_jump > 0) {
            game_state.player_y += @as(i32, @intFromFloat(10.0 * @sin(std.math.pi * game_state.t_jump)));
        }
        if (controller.button.input.action_down.ended_down) {
            game_state.t_jump = 2.0;
        }
        game_state.t_jump -= 0.029;
    }

    gameRender(video_buffer, game_state.blue_offset, game_state.green_offset);
    renderPlayer(video_buffer, game_state.player_x, game_state.player_y);
}

pub fn TEMPgameUpdateAndRender(video_buffer: *GameOffScreenBuffer, blue_offset: i32, green_offset: i32) !void {
    gameRender(video_buffer, blue_offset, green_offset);
}

pub const UpdateAndRenderFnPtr = *const fn (*GameMemory, *GameInput, *GameOffScreenBuffer) callconv(.c) void;
pub const GetSoundSamplesFnPtr = *const fn (*GameMemory, *GameSoundOutputBuffer) callconv(.c) void;
