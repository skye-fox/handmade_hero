const std = @import("std");

const game = @import("handmade.zig");

pub const TileMapPosition = struct {
    // NOTE:(Casey): These are fixed point tile locations. The high bits are the tile chunk index,
    // and the low bits are the tile index in the chunk.
    abs_tile_x: u32,
    abs_tile_y: u32,
    abs_tile_z: u32,

    //NOTE: (Casey): These are the offsets from the tiles center.
    offset_x: f32,
    offset_y: f32,
};

const TileChunkPosition = struct {
    tile_chunk_x: u32,
    tile_chunk_y: u32,
    tile_chunk_z: u32,

    rel_tile_x: u32,
    rel_tile_y: u32,
};

pub const TileChunk = struct {
    tiles: ?[*]u32,
};

pub const TileMap = struct {
    chunk_shift: u32,
    chunk_mask: u32,
    chunk_dim: u32,

    tile_side_in_meters: f32,

    tile_chunk_count_x: u32,
    tile_chunk_count_y: u32,
    tile_chunk_count_z: u32,

    tile_chunks: [*]TileChunk,
};

inline fn getTileChunk(tile_map: *TileMap, tile_chunk_x: u32, tile_chunk_y: u32, tile_chunk_z: u32) ?*TileChunk {
    var tile_chunk: ?*TileChunk = null;
    if ((tile_chunk_x >= 0) and (tile_chunk_x < tile_map.tile_chunk_count_x) and
        (tile_chunk_y >= 0) and (tile_chunk_y < tile_map.tile_chunk_count_y) and
        (tile_chunk_z >= 0) and (tile_chunk_z < tile_map.tile_chunk_count_z))
    {
        tile_chunk = &tile_map.tile_chunks[
            tile_chunk_z * tile_map.tile_chunk_count_y * tile_map.tile_chunk_count_x +
                tile_chunk_y * tile_map.tile_chunk_count_x + tile_chunk_x
        ];
    }
    return tile_chunk;
}

inline fn getTileValueUnchecked(tile_map: *TileMap, tile_chunk: *TileChunk, tile_x: u32, tile_y: u32) u32 {
    std.debug.assert(tile_x < tile_map.chunk_dim and tile_y < tile_map.chunk_dim);

    var tile_chunk_value: u32 = 0;

    if (tile_chunk.tiles) |tiles| {
        tile_chunk_value = tiles[@intCast(tile_y * tile_map.chunk_dim + tile_x)];
    }
    return tile_chunk_value;
}

inline fn setTileValueUnchecked(tile_map: *TileMap, tile_chunk: *TileChunk, tile_x: u32, tile_y: u32, tile_value: u32) void {
    std.debug.assert(tile_x < tile_map.chunk_dim and tile_y < tile_map.chunk_dim);

    tile_chunk.tiles.?[@intCast(tile_y * tile_map.chunk_dim + tile_x)] = tile_value;
}

inline fn getTileValue(tile_map: *TileMap, tile_chunk: ?*TileChunk, test_tile_x: u32, test_tile_y: u32) u32 {
    var tile_chunk_value: u32 = 0;
    if (tile_chunk) |chunk| {
        if (chunk.tiles != null) {
            tile_chunk_value = getTileValueUnchecked(tile_map, chunk, test_tile_x, test_tile_y);
        }
    }

    return tile_chunk_value;
}

inline fn setTileValue(tile_map: *TileMap, tile_chunk: *TileChunk, test_tile_x: u32, test_tile_y: u32, tile_value: u32) void {
    if (tile_chunk.tiles) |_| {
        setTileValueUnchecked(tile_map, tile_chunk, test_tile_x, test_tile_y, tile_value);
    }
}

inline fn getChunkPositionFor(tile_map: *TileMap, abs_tile_x: u32, abs_tile_y: u32, abs_tile_z: u32) TileChunkPosition {
    var result: TileChunkPosition = undefined;

    result.tile_chunk_x = abs_tile_x >> @intCast(tile_map.chunk_shift);
    result.tile_chunk_y = abs_tile_y >> @intCast(tile_map.chunk_shift);
    result.tile_chunk_z = abs_tile_z;
    result.rel_tile_x = abs_tile_x & tile_map.chunk_mask;
    result.rel_tile_y = abs_tile_y & tile_map.chunk_mask;

    return result;
}

pub fn getTileValuePos(tile_map: *TileMap, pos: TileMapPosition) u32 {
    const tile_chunk_value = getTileValueAbs(tile_map, pos.abs_tile_x, pos.abs_tile_y, pos.abs_tile_z);

    return tile_chunk_value;
}

pub fn getTileValueAbs(tile_map: *TileMap, abs_tile_x: u32, abs_tile_y: u32, abs_tile_z: u32) u32 {
    var tile_chunk_value: u32 = 0;
    const chunk_pos = getChunkPositionFor(tile_map, abs_tile_x, abs_tile_y, abs_tile_z);
    const tile_chunk = getTileChunk(tile_map, chunk_pos.tile_chunk_x, chunk_pos.tile_chunk_y, chunk_pos.tile_chunk_z);

    if (tile_chunk) |chunk| {
        tile_chunk_value = getTileValue(tile_map, chunk, chunk_pos.rel_tile_x, chunk_pos.rel_tile_y);
    }

    return tile_chunk_value;
}

pub fn isTileMapPointEmpty(tile_map: *TileMap, pos: TileMapPosition) bool {
    const tile_chunk_value = getTileValuePos(tile_map, pos);

    const empty = (tile_chunk_value == 1) or (tile_chunk_value == 3) or (tile_chunk_value == 4);

    return empty;
}

pub fn setTileValueAbs(arena: *game.MemoryArena, tile_map: *TileMap, abs_tile_x: u32, abs_tile_y: u32, abs_tile_z: u32, tile_value: u32) void {
    const chunk_pos = getChunkPositionFor(tile_map, abs_tile_x, abs_tile_y, abs_tile_z);
    const tile_chunk = getTileChunk(tile_map, chunk_pos.tile_chunk_x, chunk_pos.tile_chunk_y, chunk_pos.tile_chunk_z);

    std.debug.assert(tile_chunk != null);

    if (tile_chunk) |chunk| {
        const tile_count: u32 = tile_map.chunk_dim * tile_map.chunk_dim;
        if (chunk.tiles == null) {
            chunk.tiles = @ptrCast(@alignCast(game.pushArray(arena, tile_count, @sizeOf(u32))));
            for (0..tile_count) |tile_index| {
                chunk.tiles.?[tile_index] = 1;
            }
        }

        setTileValue(tile_map, chunk, chunk_pos.rel_tile_x, chunk_pos.rel_tile_y, tile_value);
    }
}

inline fn recanonicalizeCoord(tile_map: *TileMap, tile: *u32, tile_rel: *f32) void {
    const offset: i32 = @intFromFloat(@round(tile_rel.* / tile_map.tile_side_in_meters));

    if (offset >= 0) {
        tile.* +%= @intCast(offset);
    } else {
        tile.* -%= @abs(offset);
    }
    tile_rel.* -= @as(f32, @floatFromInt(offset)) * tile_map.tile_side_in_meters;

    std.debug.assert(tile_rel.* >= -0.5 * tile_map.tile_side_in_meters);
    std.debug.assert(tile_rel.* <= 0.5 * tile_map.tile_side_in_meters);
}

pub inline fn recanonicalizePosition(tile_map: *TileMap, pos: TileMapPosition) TileMapPosition {
    var result: TileMapPosition = pos;

    recanonicalizeCoord(tile_map, &result.abs_tile_x, &result.offset_x);
    recanonicalizeCoord(tile_map, &result.abs_tile_y, &result.offset_y);

    return result;
}

pub inline fn areOnSameTile(pos_a: *TileMapPosition, pos_b: *TileMapPosition) bool {
    const result = ((pos_a.abs_tile_x == pos_b.abs_tile_x) and (pos_a.abs_tile_y == pos_b.abs_tile_y) and (pos_a.abs_tile_z == pos_b.abs_tile_z));
    return result;
}
