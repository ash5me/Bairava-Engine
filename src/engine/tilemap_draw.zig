//! Queues a tile map's layers as sprites, one per visible tile. It lives apart from tilemap.zig so
//! the map stays free of SDL: the map is pure data and collision, and this file is the drawing.

const std = @import("std");

const atlas = @import("atlas.zig");
const profile = @import("profile.zig");
const sprite = @import("sprite.zig");
const tilemap = @import("tilemap.zig");
const Camera = @import("camera.zig").Camera;
const Texture = @import("texture.zig").Texture;

/// Queues the tiles of one layer that overlap the camera's view. `tileset` is the region of the
/// atlas that holds the tiles, read left to right, then down. Each cell draws the tile its ID names,
/// and empty cells draw nothing.
pub fn drawLayer(
    map: *const tilemap.TileMap,
    batch: *sprite.SpriteBatch,
    texture: *const Texture,
    tileset: atlas.Region,
    cam: *const Camera,
    layer: tilemap.Layer,
) void {
    const zone = profile.zoneNamed(@src(), "draw layer");
    defer zone.End();
    const tile_px = tilemap.tile_px;
    const tile_size = tilemap.tile_size;
    const across = tileset.cellsAcross(tile_size);
    // One extra tile on each side, so edge tiles never pop in while scrolling.
    const first_col = clampIndex(@floor(cam.x / tile_px) - 1, map.cols);
    const last_col = clampIndex(@ceil((cam.x + cam.view_w) / tile_px) + 1, map.cols);
    const first_row = clampIndex(@floor(cam.y / tile_px) - 1, map.rows);
    const last_row = clampIndex(@ceil((cam.y + cam.view_h) / tile_px) + 1, map.rows);

    var row = first_row;
    while (row < last_row) : (row += 1) {
        var col = first_col;
        while (col < last_col) : (col += 1) {
            const id: u32 = map.idAt(layer, @intCast(col), @intCast(row)) orelse continue;
            // The region's corner offsets the tile's grid cell inside the atlas.
            const src = sprite.Rect{
                .x = @as(f32, @floatFromInt(tileset.x + (id % across) * tile_size)),
                .y = @as(f32, @floatFromInt(tileset.y + (id / across) * tile_size)),
                .w = tile_px,
                .h = tile_px,
            };
            // The same rounding as the player's sprite, so tiles and sprites stay on one pixel grid.
            const dst = sprite.Rect{
                .x = cam.screenX(@as(f32, @floatFromInt(col)) * tile_px),
                .y = cam.screenY(@as(f32, @floatFromInt(row)) * tile_px),
                .w = tile_px,
                .h = tile_px,
            };
            batch.drawSprite(texture, src, dst, .{});
        }
    }
}

/// Clamps a float tile index to [0, count] and converts it to an integer.
fn clampIndex(index: f32, count: u32) u32 {
    const limit: f32 = @floatFromInt(count);
    return @intFromFloat(std.math.clamp(index, 0.0, limit));
}
