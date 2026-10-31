//! The level: the tile map the game loads, and its size. Drawing the tiles is the engine's job
//! (engine/renderer/tilemap_draw.zig), and game.zig decides which layer is drawn when.

const std = @import("std");
<<<<<<< HEAD
const engine = @import("bairava");
=======
const engine = @import("../engine/core/engine.zig");
>>>>>>> main

/// Side length of one tile, in native pixels.
pub const tile_px = engine.tilemap.tile_px;

/// The level's tile map, loaded from a text file at startup.
pub const Level = struct {
    map: engine.tilemap.TileMap,
    allocator: std.mem.Allocator,

    /// Reads and parses the map file. Missing or malformed game assets return an error to the
    /// game's initializer, which lets the runtime unwind engine-owned state cleanly.
    pub fn load(ctx: *const engine.Context, path: []const u8) engine.AssetError!Level {
        const text = ctx.readFile(ctx.allocators.asset, path) catch |err| {
            return switch (err) {
                error.FileNotFound => error.FileNotFound,
                error.PathTooLong => error.PathTooLong,
                error.OutOfMemory => error.OutOfMemory,
                else => error.ReadFailed,
            };
        };
        defer ctx.allocators.asset.free(text);
        const allocator = ctx.allocators.asset;
        const map = engine.tilemap.TileMap.parse(allocator, text) catch {
            return error.InvalidLevel;
        };
        return .{ .map = map, .allocator = allocator };
    }

    pub fn deinit(self: *const Level) void {
        self.map.deinit(self.allocator);
    }

    pub fn widthPx(self: *const Level) f32 {
        return @as(f32, @floatFromInt(self.map.cols)) * tile_px;
    }

    pub fn heightPx(self: *const Level) f32 {
        return @as(f32, @floatFromInt(self.map.rows)) * tile_px;
    }
};
