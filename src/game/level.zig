//! The level: a grid of tiles and how it is drawn. This is game content, so it lives outside
//! the engine. The engine supplies only the sprite batch and the camera.

const std = @import("std");
const engine = @import("../engine/engine.zig");

/// Side length of one tile, in native pixels.
pub const tile_px: f32 = 16.0;

/// A rectangular grid of tiles that all share one texture.
pub const Level = struct {
    cols: u32,
    rows: u32,

    pub fn widthPx(self: *const Level) f32 {
        return @as(f32, @floatFromInt(self.cols)) * tile_px;
    }

    pub fn heightPx(self: *const Level) f32 {
        return @as(f32, @floatFromInt(self.rows)) * tile_px;
    }

    /// Queues the tiles that overlap the camera's view. Tiles outside it are skipped.
    pub fn draw(self: *const Level, batch: *engine.SpriteBatch, tile: *const engine.Texture, cam: *const engine.Camera) void {
        // One extra tile on each side, so edge tiles never pop in while scrolling.
        const first_col = clampIndex(@floor(cam.x / tile_px) - 1, self.cols);
        const last_col = clampIndex(@ceil((cam.x + cam.view_w) / tile_px) + 1, self.cols);
        const first_row = clampIndex(@floor(cam.y / tile_px) - 1, self.rows);
        const last_row = clampIndex(@ceil((cam.y + cam.view_h) / tile_px) + 1, self.rows);

        const src = engine.Rect{ .x = 0, .y = 0, .w = tile_px, .h = tile_px };

        var row = first_row;
        while (row < last_row) : (row += 1) {
            var col = first_col;
            while (col < last_col) : (col += 1) {
                const dst = engine.Rect{
                    .x = @as(f32, @floatFromInt(col)) * tile_px - cam.x,
                    .y = @as(f32, @floatFromInt(row)) * tile_px - cam.y,
                    .w = tile_px,
                    .h = tile_px,
                };
                // Alternate two tints so the camera's movement is easy to see.
                const tint: [3]f32 = if ((col + row) % 2 == 0)
                    .{ 1.0, 1.0, 1.0 }
                else
                    .{ 0.85, 0.85, 0.85 };
                batch.drawSprite(tile, src, dst, tint);
            }
        }
    }
};

/// Clamps a float tile index to [0, count] and converts it to an integer.
fn clampIndex(index: f32, count: u32) u32 {
    const limit: f32 = @floatFromInt(count);
    return @intFromFloat(std.math.clamp(index, 0.0, limit));
}
