const std = @import("std");

const builtin = @import("builtin");
const debug = builtin.mode == @import("std").builtin.OptimizeMode.Debug;

const platform = @import("main.zig").platform;

const TileChunkPosition = struct {
    tile_chunk_x: u32,
    tile_chunk_y: u32,

    rel_tile_x: u32,
    rel_tile_y: u32,
};

const WorldPosition = struct {
    // NOTE:(Casey): These are fixed point tile locations. The high bits are the tile chunk index,
    // and the low bits are the tile index in the chunk.
    abs_tile_x: u32,
    abs_tile_y: u32,

    tile_rel_x: f32,
    tile_rel_y: f32,
};

const World = struct {
    chunk_shift: u32,
    chunk_mask: u32,
    chunk_dim: u32,

    tile_side_in_meters: f32,
    tile_side_in_pixels: u32,
    meters_to_pixels: f32,

    tile_chunk_count_x: i32,
    tile_chunk_count_y: i32,

    tile_chunks: [*]TileChunk,
};

const TileChunk = struct {
    tiles: [*]u32,
};

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
    player_pos: WorldPosition,
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

inline fn getTileChunk(world: *World, tile_chunk_x: u32, tile_chunk_y: u32) *TileChunk {
    var tile_chunk: *TileChunk = undefined;
    if (tile_chunk_x >= 0 and tile_chunk_x < world.tile_chunk_count_x and tile_chunk_y >= 0 and tile_chunk_y < world.tile_chunk_count_y) {
        tile_chunk = &world.tile_chunks[@intCast(tile_chunk_y * @as(u32, @intCast(world.tile_chunk_count_x)) + tile_chunk_x)];
    }
    return tile_chunk;
}

inline fn getTileValueUnchecked(world: *World, tile_chunk: *TileChunk, tile_x: u32, tile_y: u32) u32 {
    std.debug.assert(tile_x < world.chunk_dim and tile_y < world.chunk_dim);

    const tile_chunk_value = tile_chunk.tiles[@intCast(tile_y * world.chunk_dim + tile_x)];
    return tile_chunk_value;
}

inline fn recanonicalizeCoord(world: *World, tile: *u32, tile_rel: *f32) void {
    const offset: i32 = @intFromFloat(@floor(tile_rel.* / world.tile_side_in_meters));

    if (offset >= 0) {
        tile.* += @intCast(offset);
    } else {
        tile.* -= @abs(offset);
    }
    tile_rel.* -= @as(f32, @floatFromInt(offset)) * world.tile_side_in_meters;

    std.debug.assert(tile_rel.* >= 0);
    std.debug.assert(tile_rel.* < world.tile_side_in_meters);
}

inline fn recanonicalizePosition(world: *World, pos: WorldPosition) WorldPosition {
    var result: WorldPosition = pos;

    recanonicalizeCoord(world, &result.abs_tile_x, &result.tile_rel_x);
    recanonicalizeCoord(world, &result.abs_tile_y, &result.tile_rel_y);

    return result;
}

inline fn getChunkPositionFor(world: *World, abs_tile_x: u32, abs_tile_y: u32) TileChunkPosition {
    var result: TileChunkPosition = undefined;

    result.tile_chunk_x = abs_tile_x >> @intCast(world.chunk_shift);
    result.tile_chunk_y = abs_tile_y >> @intCast(world.chunk_shift);
    result.rel_tile_x = abs_tile_x & world.chunk_mask;
    result.rel_tile_y = abs_tile_y & world.chunk_mask;

    return result;
}

fn getTileValueAbs(world: *World, abs_tile_x: u32, abs_tile_y: u32) u32 {
    const chunk_pos = getChunkPositionFor(world, abs_tile_x, abs_tile_y);
    const tile_chunk = getTileChunk(world, chunk_pos.tile_chunk_x, chunk_pos.tile_chunk_y);

    const tile_chunk_value = getTileValue(world, tile_chunk, chunk_pos.rel_tile_x, chunk_pos.rel_tile_y);

    return tile_chunk_value;
}

fn isWorldPointEmpty(world: *World, world_pos: WorldPosition) bool {
    const tile_chunk_value = getTileValueAbs(world, world_pos.abs_tile_x, world_pos.abs_tile_y);

    const empty = (tile_chunk_value == 0);

    return empty;
}

inline fn getTileValue(world: *World, tile_chunk: *TileChunk, test_tile_x: u32, test_tile_y: u32) u32 {
    var tile_chunk_value: u32 = 0;

    tile_chunk_value = getTileValueUnchecked(world, tile_chunk, test_tile_x, test_tile_y);

    return tile_chunk_value;
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

    if (min_y > max_y) {
        const temp = min_y;
        min_y = max_y;
        max_y = temp;
    }

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

    const rows: u32 = 256;
    const columns: u32 = 256;
    var temp_tiles: [rows][columns]u32 = .{
        .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 } ++ .{0} ** (columns - 34),
        .{ 1, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 } ++ .{0} ** (columns - 34),
        .{ 1, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 1 } ++ .{0} ** (columns - 34),
        .{ 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1 } ++ .{0} ** (columns - 34),
        .{ 1, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1 } ++ .{0} ** (columns - 34),
        .{ 1, 1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1 } ++ .{0} ** (columns - 34),
        .{ 1, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 1 } ++ .{0} ** (columns - 34),
        .{ 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 } ++ .{0} ** (columns - 34),
        .{ 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1 } ++ .{0} ** (columns - 34),
        .{ 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1 } ++ .{0} ** (columns - 34),
        .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 } ++ .{0} ** (columns - 34),
        .{ 1, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 1 } ++ .{0} ** (columns - 34),
        .{ 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1 } ++ .{0} ** (columns - 34),
        .{ 1, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1 } ++ .{0} ** (columns - 34),
        .{ 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1 } ++ .{0} ** (columns - 34),
        .{ 1, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 1 } ++ .{0} ** (columns - 34),
        .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 } ++ .{0} ** (columns - 34),
        .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 } ++ .{0} ** (columns - 34),
    } ++ .{.{0} ** columns} ** (rows - 18);

    var world: World = undefined;
    // NOTE:(Casey): This is set to using 256x256 tile chunks.
    world.chunk_shift = 8;
    world.chunk_mask = 0xFF;
    world.chunk_dim = 256;

    world.tile_chunk_count_x = 1;
    world.tile_chunk_count_y = 1;

    var tile_chunk = TileChunk{
        .tiles = @ptrCast(&temp_tiles),
    };
    world.tile_chunks = @ptrCast(&tile_chunk);

    world.tile_side_in_meters = 1.4;
    world.tile_side_in_pixels = 60;
    world.meters_to_pixels = @as(f32, @floatFromInt(world.tile_side_in_pixels)) / world.tile_side_in_meters;

    const player_height = 1.4;
    const player_width = 0.75 * player_height;

    // lower_left_x = -@as(f32, @floatFromInt(world.tile_side_in_pixels / 2));
    // const lower_left_y: f32 = @as(f32, @floatFromInt(buffer.height)) - 190.0;
    // const lower_left_x: f32 = 10.0;
    // lower_left_y = 10.0;

    const game_state: *GameState = @ptrCast(@alignCast(memory.permanent_storage));
    if (!memory.is_initialized) {
        game_state.player_pos.abs_tile_x = 3;
        game_state.player_pos.abs_tile_y = 3;
        game_state.player_pos.tile_rel_x = 5.0;
        game_state.player_pos.tile_rel_y = 5.0;

        memory.is_initialized = true;
    }

    // const tile_map = getTileChunk(&world, game_state.player_pos.abs_tile_x, game_state.player_pos.abs_tile_y);

    for (0..input.controllers.len) |controller_index| {
        const controller: *GameControllerInput = getController(input, controller_index);
        if (controller.is_analog) {
            // NOTE: Analog
        } else {
            // NOTE: Digital
            var delta_player_x: f32 = 0.0;
            var delta_player_y: f32 = 0.0;
            if (controller.button.input.move_up.ended_down) {
                delta_player_y = 1.0;
            }
            if (controller.button.input.move_down.ended_down) {
                delta_player_y = -1.0;
            }
            if (controller.button.input.move_left.ended_down) {
                delta_player_x = -1.0;
            }
            if (controller.button.input.move_right.ended_down) {
                delta_player_x = 1.0;
            }

            delta_player_x *= 10.0;
            delta_player_y *= 10.0;

            var new_player_pos = game_state.player_pos;
            new_player_pos.tile_rel_x += input.dt_for_frame * delta_player_x;
            new_player_pos.tile_rel_y += input.dt_for_frame * delta_player_y;
            new_player_pos = recanonicalizePosition(&world, new_player_pos);

            var player_left = new_player_pos;
            player_left.tile_rel_x -= 0.5 * player_width;
            player_left = recanonicalizePosition(&world, player_left);

            var player_right = new_player_pos;
            player_right.tile_rel_x += 0.5 * player_width;
            player_right = recanonicalizePosition(&world, player_right);

            const point_is_valid = (isWorldPointEmpty(&world, new_player_pos) and
                isWorldPointEmpty(&world, player_left) and
                isWorldPointEmpty(&world, player_right));

            if (point_is_valid) {
                game_state.player_pos = new_player_pos;
            }
        }
    }

    drawRectangle(buffer, 0.0, 0.0, @floatFromInt(buffer.width), @floatFromInt(buffer.height), 0.0, 0.0, 0.0);

    const center_x = 0.5 * @as(f32, @floatFromInt(buffer.width));
    const center_y = 0.5 * @as(f32, @floatFromInt(buffer.height));

    var rel_row: i32 = -10;
    while (rel_row < 10) : (rel_row += 1) {
        var rel_column: i32 = -20;
        while (rel_column < 20) : (rel_column += 1) {
            const column_signed: i32 = @as(i32, @intCast(game_state.player_pos.abs_tile_x)) + rel_column;
            const row_signed: i32 = @as(i32, @intCast(game_state.player_pos.abs_tile_y)) + rel_row;

            if (column_signed < 0 or row_signed < 0) continue;

            const column: u32 = @intCast(column_signed);
            const row: u32 = @intCast(row_signed);

            const tile_id = getTileValueAbs(&world, column, row);
            var gray: f32 = 0.5;
            if (tile_id == 1) {
                gray = 1.0;
            }

            if (column == game_state.player_pos.abs_tile_x and row == game_state.player_pos.abs_tile_y) {
                gray = 0.0;
            }

            const min_x = center_x - world.meters_to_pixels * game_state.player_pos.tile_rel_x + @as(f32, @floatFromInt(rel_column)) * @as(f32, @floatFromInt(world.tile_side_in_pixels));
            const min_y = center_y + world.meters_to_pixels * game_state.player_pos.tile_rel_y - @as(f32, @floatFromInt(rel_row)) * @as(f32, @floatFromInt(world.tile_side_in_pixels));
            const max_x = min_x + @as(f32, @floatFromInt(world.tile_side_in_pixels));
            const max_y = min_y + @as(f32, @floatFromInt(world.tile_side_in_pixels));
            drawRectangle(buffer, min_x, max_y, max_x, min_y, gray, gray, gray);
        }
    }

    const player_r: f32 = 1.0;
    const player_g: f32 = 1.0;
    const player_b: f32 = 0.0;
    const player_left = center_x - 0.5 * world.meters_to_pixels * player_width;
    const player_top = center_y + @as(f32, @floatFromInt(world.tile_side_in_pixels)) - world.meters_to_pixels * player_height;
    drawRectangle(buffer, player_left, player_top, player_left + world.meters_to_pixels * player_width, player_top + world.meters_to_pixels * player_height, player_r, player_g, player_b);
}

pub const UpdateAndRenderFnPtr = *const fn (*ThreadContext, *GameMemory, *GameInput, *GameOffScreenBuffer) callconv(.c) void;
pub const GetSoundSamplesFnPtr = *const fn (*ThreadContext, *GameMemory, *GameSoundOutputBuffer) callconv(.c) void;
