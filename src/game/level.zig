//! The level: the tile map and how it is drawn. This is game content, so it lives outside the
//! engine. The engine supplies the tile map format, the sprite batch, and the camera.

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

    /// How many tiles a tileset texture holds. The tiles form a grid, read left to right, then down.
    pub fn tileCount(tileset: *const engine.Texture) u32 {
        return tilesAcross(tileset) * (tileset.height / engine.tilemap.tile_size);
    }

    fn tilesAcross(tileset: *const engine.Texture) u32 {
        return tileset.width / engine.tilemap.tile_size;
    }

    /// Queues the tiles of one layer that overlap the camera's view. Each cell draws the tile its
    /// ID names. Empty cells draw nothing.
    pub fn drawLayer(
        self: *const Level,
        batch: *engine.SpriteBatch,
        tileset: *const engine.Texture,
        cam: *const engine.Camera,
        layer: engine.tilemap.Layer,
    ) void {
        const across = tilesAcross(tileset);
        // One extra tile on each side, so edge tiles never pop in while scrolling.
        const first_col = clampIndex(@floor(cam.x / tile_px) - 1, self.map.cols);
        const last_col = clampIndex(@ceil((cam.x + cam.view_w) / tile_px) + 1, self.map.cols);
        const first_row = clampIndex(@floor(cam.y / tile_px) - 1, self.map.rows);
        const last_row = clampIndex(@ceil((cam.y + cam.view_h) / tile_px) + 1, self.map.rows);

        var row = first_row;
        while (row < last_row) : (row += 1) {
            var col = first_col;
            while (col < last_col) : (col += 1) {
                const id: u32 = self.map.idAt(layer, @intCast(col), @intCast(row)) orelse continue;
                const src = engine.Rect{
                    .x = @as(f32, @floatFromInt(id % across)) * tile_px,
                    .y = @as(f32, @floatFromInt(id / across)) * tile_px,
                    .w = tile_px,
                    .h = tile_px,
                };
                // The same rounding as the player's sprite, so tiles and sprites stay on one pixel grid.
                const dst = engine.Rect{
                    .x = cam.screenX(@as(f32, @floatFromInt(col)) * tile_px),
                    .y = cam.screenY(@as(f32, @floatFromInt(row)) * tile_px),
                    .w = tile_px,
                    .h = tile_px,
                };
                batch.drawSprite(tileset, src, dst, .{ 1.0, 1.0, 1.0 });
            }
        }
    }
};

/// Clamps a float tile index to [0, count] and converts it to an integer.
fn clampIndex(index: f32, count: u32) u32 {
    const limit: f32 = @floatFromInt(count);
    return @intFromFloat(std.math.clamp(index, 0.0, limit));
}
