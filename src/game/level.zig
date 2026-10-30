//! The level: the tile map the game loads, and its size. Drawing the tiles is the engine's job
//! (engine/tilemap_draw.zig), and game.zig decides which layer is drawn when.

const std = @import("std");
const engine = @import("../engine/engine.zig");

/// Side length of one tile, in native pixels.
pub const tile_px = engine.tilemap.tile_px;

/// The level's tile map, loaded from a text file at startup.
pub const Level = struct {
    map: engine.tilemap.TileMap,

    /// Reads and parses the map file at `path`, relative to the executable's folder. A missing or
    /// malformed map is a bug in the game's data, so this panics and says why.
    pub fn load(ctx: *const engine.Context, path: []const u8) Level {
        const text = ctx.readFile(path) catch |err| {
            std.debug.panic("map '{s}' could not be read: {s}", .{ path, @errorName(err) });
        };
        defer std.heap.page_allocator.free(text);
        const map = engine.tilemap.TileMap.parse(std.heap.page_allocator, text) catch |err| {
            std.debug.panic("map '{s}' is invalid: {s}", .{ path, @errorName(err) });
        };
        return .{ .map = map };
    }

    pub fn deinit(self: *const Level) void {
        self.map.deinit(std.heap.page_allocator);
    }

    pub fn widthPx(self: *const Level) f32 {
        return @as(f32, @floatFromInt(self.map.cols)) * tile_px;
    }

    pub fn heightPx(self: *const Level) f32 {
        return @as(f32, @floatFromInt(self.map.rows)) * tile_px;
    }
};
