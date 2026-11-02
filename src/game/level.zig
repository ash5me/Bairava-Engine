//! The level: the tile map the game loads, and its size. Drawing the tiles is the engine's job
//! (engine/renderer/tilemap_draw.zig), and game.zig decides which layer is drawn when.

const std = @import("std");
const engine = @import("bairava");
const level_data = @import("level_data.zig");
const prefab = @import("prefab.zig");

const log = engine.log.scoped("level");

/// Side length of one tile, in native pixels.
pub const tile_px = engine.tilemap.tile_px;

/// The level's tile map, loaded from a text file at startup.
pub const Level = struct {
    map: engine.tilemap.TileMap,
    spawn: level_data.Spawn,
    /// The entities the level metadata places. The game spawns one for each.
    placements: []level_data.Placement,
    allocator: std.mem.Allocator,

    /// Reads and parses the map file. Missing or malformed game assets return an error to the
    /// game's initializer, which lets the runtime unwind engine-owned state cleanly.
    pub fn load(ctx: *const engine.Context, path: []const u8, spawn_path: []const u8, prefabs: *const prefab.Registry) engine.AssetError!Level {
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
        const spawn_text = ctx.readFile(allocator, spawn_path) catch |err| {
            map.deinit(allocator);
            return switch (err) {
                error.FileNotFound => error.FileNotFound,
                error.PathTooLong => error.PathTooLong,
                error.OutOfMemory => error.OutOfMemory,
                else => error.ReadFailed,
            };
        };
        defer allocator.free(spawn_text);
        const data = level_data.parse(allocator, prefabs, map.cols, map.rows, spawn_text) catch |err| {
            map.deinit(allocator);
            log.err("level metadata '{s}' is not valid: {s}", .{ spawn_path, @errorName(err) });
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.InvalidLevel,
            };
        };
        return .{ .map = map, .spawn = data.spawn, .placements = data.placements, .allocator = allocator };
    }

    pub fn deinit(self: *const Level) void {
        self.allocator.free(self.placements);
        self.map.deinit(self.allocator);
    }

    pub fn widthPx(self: *const Level) f32 {
        return @as(f32, @floatFromInt(self.map.cols)) * tile_px;
    }

    pub fn heightPx(self: *const Level) f32 {
        return @as(f32, @floatFromInt(self.map.rows)) * tile_px;
    }
};
