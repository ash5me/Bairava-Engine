//! Debug geometry for the world: the tile grid, the solid cells that block movement, and the world's
//! edges. Each function queues view-space shapes into a `debug_draw.Draw`, mapping world positions
//! through the camera exactly as the sprites are mapped. Game code calls these from `draw` when the
//! matching geometry switch is on. Pure code with no SDL, so `zig build test` covers it.

const std = @import("std");
const tilemap = @import("../scene/tilemap.zig");
const debug_draw = @import("../diagnostics/debug_draw.zig");
const Camera = @import("camera.zig").Camera;

const grid_color = debug_draw.Color{ .r = 1, .g = 1, .b = 1, .a = 0.22 };
const solid_color = debug_draw.Color{ .r = 0.95, .g = 0.25, .b = 0.25, .a = 0.35 };
const camera_color = debug_draw.Color{ .r = 0.35, .g = 0.9, .b = 1.0, .a = 0.9 };

/// Cells that can be on screen along one axis, with one cell of margin, clamped to the map.
const Range = struct {
    first: u32,
    end: u32,
};

fn visibleRange(origin: f32, length: f32, count: u32) Range {
    const tile = tilemap.tile_px;
    return .{
        .first = clampIndex(@floor(origin / tile) - 1, count),
        .end = clampIndex(@ceil((origin + length) / tile) + 1, count),
    };
}

fn clampIndex(index: f32, count: u32) u32 {
    const limit: f32 = @floatFromInt(count);
    return @intFromFloat(std.math.clamp(index, 0.0, limit));
}

/// The view x of the left edge of a cell column.
fn cellX(cam: *const Camera, col: u32) f32 {
    return cam.screenX(@as(f32, @floatFromInt(col)) * tilemap.tile_px);
}

/// The view y of the top edge of a cell row.
fn cellY(cam: *const Camera, row: u32) f32 {
    return cam.screenY(@as(f32, @floatFromInt(row)) * tilemap.tile_px);
}

/// Outlines every visible tile, which shows the grid of tile boundaries.
pub fn drawGrid(map: *const tilemap.TileMap, draw: *debug_draw.Draw, cam: *const Camera) void {
    const cols = visibleRange(cam.x, cam.view_w, map.cols);
    const rows = visibleRange(cam.y, cam.view_h, map.rows);
    var row = rows.first;
    while (row < rows.end) : (row += 1) {
        var col = cols.first;
        while (col < cols.end) : (col += 1) {
            draw.outline(cellX(cam, col), cellY(cam, row), tilemap.tile_px, tilemap.tile_px, grid_color);
        }
    }
}

/// Fills every visible cell that blocks movement. A cell blocks when any of its layers holds a solid
/// tile, the same rule the collision code uses.
pub fn drawSolid(map: *const tilemap.TileMap, draw: *debug_draw.Draw, cam: *const Camera) void {
    const cols = visibleRange(cam.x, cam.view_w, map.cols);
    const rows = visibleRange(cam.y, cam.view_h, map.rows);
    var row = rows.first;
    while (row < rows.end) : (row += 1) {
        var col = cols.first;
        while (col < cols.end) : (col += 1) {
            if (!map.isSolid(@intCast(col), @intCast(row))) continue;
            draw.fill(cellX(cam, col), cellY(cam, row), tilemap.tile_px, tilemap.tile_px, solid_color);
        }
    }
}

/// Outlines the world's edges, as they sit in the view.
pub fn cameraBounds(draw: *debug_draw.Draw, cam: *const Camera) void {
    draw.outline(cam.screenX(0), cam.screenY(0), cam.world_w, cam.world_h, camera_color);
}

fn testMap(tiles: []u8, solid: *[256]bool) tilemap.TileMap {
    return .{ .cols = 4, .rows = 3, .tiles = tiles, .solid = solid.* };
}

test "the grid outlines each visible tile once" {
    var tiles = [_]u8{tilemap.empty} ** 36;
    var solid = [_]bool{false} ** 256;
    const map = testMap(&tiles, &solid);
    const cam = Camera{ .view_w = 64, .view_h = 48, .world_w = 64, .world_h = 48 };
    var draw = debug_draw.Draw{};
    drawGrid(&map, &draw, &cam);
    try std.testing.expectEqual(@as(usize, 12), draw.count);
    try std.testing.expectEqual(debug_draw.Kind.outline, draw.slice()[0].kind);
}

test "solid cells are filled where they are, and open cells are not" {
    var tiles = [_]u8{tilemap.empty} ** 36;
    tiles[5] = 1; // ground, column 1, row 1
    var solid = [_]bool{false} ** 256;
    solid[1] = true;
    const map = testMap(&tiles, &solid);
    const cam = Camera{ .view_w = 64, .view_h = 48, .world_w = 64, .world_h = 48 };
    var draw = debug_draw.Draw{};
    drawSolid(&map, &draw, &cam);
    try std.testing.expectEqual(@as(usize, 1), draw.count);
    try std.testing.expectEqual(@as(f32, 16), draw.slice()[0].x);
    try std.testing.expectEqual(@as(f32, 16), draw.slice()[0].y);
}

test "the camera bounds follow the camera, so a scrolled view moves them" {
    const cam = Camera{ .x = 10, .y = 4, .view_w = 64, .view_h = 48, .world_w = 100, .world_h = 80 };
    var draw = debug_draw.Draw{};
    cameraBounds(&draw, &cam);
    try std.testing.expectEqual(@as(f32, -10), draw.slice()[0].x);
    try std.testing.expectEqual(@as(f32, -4), draw.slice()[0].y);
    try std.testing.expectEqual(@as(f32, 100), draw.slice()[0].w);
}
