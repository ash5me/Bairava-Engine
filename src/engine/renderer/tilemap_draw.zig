//! Queues a tile map's layers as sprites, one per visible tile. It lives apart from tilemap.zig so
//! the map stays free of SDL: the map is pure data and collision, and this file is the drawing.

const std = @import("std");

const atlas = @import("../assets/loaders/atlas.zig");
const profile = @import("../profiling/profile.zig");
const sprite = @import("sprite.zig");
const tilemap = @import("../scene/tilemap.zig");
const Camera = @import("camera.zig").Camera;
const Texture = @import("texture.zig").Texture;

/// Queues the tiles of one layer that overlap the camera's view. `tileset` is the region of the
/// atlas that holds the tiles, read left to right, then down. Each cell draws the tile its ID names,
/// and empty cells draw nothing. Every tile is drawn with `options`, so `.lit = true` lights the layer.
pub fn drawLayer(
    map: *const tilemap.TileMap,
    batch: *sprite.SpriteBatch,
    texture: *const Texture,
    tileset: atlas.Region,
    cam: *const Camera,
    layer: tilemap.Layer,
    options: sprite.Options,
) void {
    const zone = profile.zoneNamed(@src(), "draw layer");
    defer zone.End();
    const tile_px = tilemap.tile_px;
    const tile_size = tilemap.tile_size;
    const across = tileset.cellsAcross(tile_size);
    const view = cam.viewRect();
    // One extra tile on each side, so edge tiles never pop in while scrolling.
    const first_col = clampIndex(@floor(view.x / tile_px) - 1, map.cols);
    const last_col = clampIndex(@ceil((view.x + view.w) / tile_px) + 1, map.cols);
    const first_row = clampIndex(@floor(view.y / tile_px) - 1, map.rows);
    const last_row = clampIndex(@ceil((view.y + view.h) / tile_px) + 1, map.rows);

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
            batch.drawSprite(texture, src, dst, options);
        }
    }
}

/// Clamps a float tile index to [0, count] and converts it to an integer.
fn clampIndex(index: f32, count: u32) u32 {
    const limit: f32 = @floatFromInt(count);
    return @intFromFloat(std.math.clamp(index, 0.0, limit));
}

test "tile draw window includes the one-tile pad but not tiles two cells beyond it" {
    const fixtures = @import("../test_fixtures.zig");
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, "size 6 1\nlayer ground\n0 0 0 0 0 0\n");
    defer map.deinit(allocator);
    var no_vertices: [0]sprite.Vertex = .{};
    var no_batches: [0]sprite.Batch = .{};
    var batch = fixtures.batch(&no_vertices, &no_batches);
    defer fixtures.freeBatch(&batch);
    const tex = fixtures.texture(16, 16);
    const cam = Camera{
        .x = 32,
        .y = 0,
        .view_w = 16,
        .view_h = 16,
        .world_w = 96,
        .world_h = 16,
    };

    batch.begin(cam.view_w, cam.view_h);
    drawLayer(&map, &batch, &tex, .{ .x = 0, .y = 0, .w = 16, .h = 16 }, &cam, .ground, .{});
    try std.testing.expectEqual(@as(u32, 3), batch.sprite_count);
}
