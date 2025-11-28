const std = @import("std");

const builtin = @import("builtin");
const debug = builtin.mode == @import("std").builtin.OptimizeMode.Debug;

const platform = @import("main.zig").platform;

pub const GameMemory = struct {
    is_initialized: bool,
    permanent_storage_size: usize,
    permanent_storage: ?*anyopaque,
    transient_storage_size: usize,
    transient_storage: ?*anyopaque,

    debugPlatformReadEntireFile: *const fn (*ThreadContext, [*:0]const u8) platform.DEBUGReadFileResult,
    debugPlatformFreeFileMemory: *const fn (*ThreadContext, platform.DEBUGReadFileResult) void,
    debugPlatformWriteEntireFile: *const fn (*ThreadContext, [*:0]const u8, u32, ?*anyopaque) bool,
};

pub const ThreadContext = struct {
    placeholder: u32,
};

const GameState = struct {
    player_x: f32,
    player_y: f32,
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

pub const GameInput = struct {
    mouse_buttons: [5]GameButtonState,
    mouse_x: i32,
    mouse_y: i32,
    mouse_z: i32,
    dt_for_frame: f32,
    controllers: [5]GameControllerInput,
};

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

pub export fn getSoundSamples(thread: *ThreadContext, memory: *GameMemory, sound_buffer: *GameSoundOutputBuffer) void {
    _ = thread;
    _ = sound_buffer;
    const game_state: *GameState = @ptrCast(@alignCast(memory.permanent_storage));
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

fn drawRectangle(buffer: *GameOffScreenBuffer, real_min_x: f32, real_min_y: f32, real_max_x: f32, real_max_y: f32, red: f32, green: f32, blue: f32) void {
    var min_x: i32 = @intFromFloat(@round(real_min_x));
    var min_y: i32 = @intFromFloat(@round(real_min_y));
    var max_x: i32 = @intFromFloat(@round(real_max_x));
    var max_y: i32 = @intFromFloat(@round(real_max_y));

    if (min_x < 0) min_x = 0;
    if (min_y < 0) min_y = 0;

    if (max_x > buffer.width) max_x = buffer.width;
    if (max_y > buffer.height) max_y = buffer.height;

    const color = Color{
        .blue = @intFromFloat(@round(blue * 255.0)),
        .green = @intFromFloat(@round(green * 255.0)),
        .red = @intFromFloat(@round(red * 255.0)),
    };

    var row_ptr = @intFromPtr(buffer.memory.ptr) + @as(usize, @intCast(min_x)) * @as(usize, @intCast(buffer.bytes_per_pixel)) + @as(usize, @intCast(min_y)) * buffer.pitch;

    var y = min_y;
    while (y < max_y) : (y += 1) {
        var x: i32 = min_x;
        var pixel: [*]Color = @ptrFromInt(row_ptr);
        while (x < max_x) : (x += 1) {
            pixel[0] = color;
            pixel += 1;
        }
        row_ptr += buffer.pitch;
    }
}

fn gameRender(buffer: *GameOffScreenBuffer, blue_offset: i32, green_offset: i32) void {
    _ = blue_offset;
    _ = green_offset;
    // var row = @as([*]u8, @ptrCast(buffer.memory));
    //
    // var y: i32 = 0;
    // while (y < buffer.height) : (y += 1) {
    //     var pixel: [*]Color = @ptrCast(@alignCast(row));
    //     var x: i32 = 0;
    //     while (x < buffer.width) : (x += 1) {
    //         const blue: u8 = @truncate(@abs(x +% blue_offset));
    //         const green: u8 = @truncate(@abs(y +% green_offset));
    //         // const red: u8 = @truncate(@abs(x +% y));
    //         pixel[0] = .{ .blue = blue, .green = 0, .red = green };
    //         pixel += 1;
    //     }
    //     row += buffer.pitch;
    // }

    //     Make a solid bg color
    //
    const width: u32 = @intCast(buffer.width);
    const height: u32 = @intCast(buffer.height);
    var pixel: [*]Color = @ptrCast(@alignCast(buffer.memory));
    for (0..width * height) |i| {
        pixel[i] = .{ .blue = 0, .green = 0, .red = 0 };
    }
}

pub export fn gameUpdateAndRender(thread: *ThreadContext, memory: *GameMemory, input: *GameInput, buffer: *GameOffScreenBuffer) void {
    _ = thread;
    std.debug.assert((&input.controllers[0].button.input.terminator - &input.controllers[0].button.buttons[0]) == input.controllers[0].button.buttons.len);
    std.debug.assert(@sizeOf(GameState) <= memory.permanent_storage_size);

    const game_state: *GameState = @ptrCast(@alignCast(memory.permanent_storage));
    if (!memory.is_initialized) {
        memory.is_initialized = true;
    }

    for (0..input.controllers.len) |controller_index| {
        const controller: *GameControllerInput = getController(input, controller_index);
        if (controller.is_analog) {
            // NOTE: Analog
        } else {
            // NOTE: Digital
            var delta_player_x: f32 = 0.0;
            var delta_player_y: f32 = 0.0;
            if (controller.button.input.move_up.ended_down) {
                delta_player_y = -1.0;
            }
            if (controller.button.input.move_down.ended_down) {
                delta_player_y = 1.0;
            }
            if (controller.button.input.move_left.ended_down) {
                delta_player_x = -1.0;
            }
            if (controller.button.input.move_right.ended_down) {
                delta_player_x = 1.0;
            }

            delta_player_x *= 128.0;
            delta_player_y *= 128.0;

            game_state.player_x += input.dt_for_frame * delta_player_x;
            game_state.player_y += input.dt_for_frame * delta_player_y;
        }
    }

    const rows: u32 = 9;
    const columns: u32 = 17;
    const tile_map: [rows][columns]u8 = .{
        .{ 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1 },
        .{ 1, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1 },
        .{ 1, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 1 },
        .{ 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 1 },
        .{ 0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 1, 1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 1 },
        .{ 1, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 },
        .{ 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1 },
        .{ 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1 },
    };

    const upper_left_x: f32 = 0.0;
    const upper_left_y: f32 = 0.0;
    const tile_width: f32 = 60.0;
    const tile_height: f32 = 60.0;

    drawRectangle(buffer, 0.0, 0.0, @floatFromInt(buffer.width), @floatFromInt(buffer.height), 1.0, 0.0, 1.0);

    for (0..rows) |row| {
        for (0..columns) |column| {
            const tile_id = tile_map[row][column];
            var gray: f32 = 0.5;
            if (tile_id == 1) {
                gray = 1.0;
            }

            const min_x = upper_left_x + @as(f32, @floatFromInt(column)) * tile_width;
            const min_y = upper_left_y + @as(f32, @floatFromInt(row)) * tile_height;
            const max_x = min_x + tile_width;
            const max_y = min_y + tile_height;
            drawRectangle(buffer, min_x, min_y, max_x, max_y, gray, gray, gray);
        }
    }

    const player_r: f32 = 1.0;
    const player_g: f32 = 1.0;
    const player_b: f32 = 0.0;
    const player_width = 0.75 * tile_width;
    const player_height = tile_height;
    const player_left = game_state.player_x - 0.5 * player_width;
    const player_top = game_state.player_y - player_height;
    drawRectangle(buffer, player_left, player_top, player_left + player_width, player_top + player_height, player_r, player_g, player_b);
}

pub const UpdateAndRenderFnPtr = *const fn (*ThreadContext, *GameMemory, *GameInput, *GameOffScreenBuffer) callconv(.c) void;
pub const GetSoundSamplesFnPtr = *const fn (*ThreadContext, *GameMemory, *GameSoundOutputBuffer) callconv(.c) void;
