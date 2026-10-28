//! The player: position, facing, walk animation, and drawing. This is gameplay code. The engine
//! sees only the sprites it queues, and the tile map that the player collides with.

const std = @import("std");
const engine = @import("../engine/engine.zig");

/// The sprite is 16x32 pixels. The sheet is laid out in rows by facing.
const width: f32 = 16.0;
const height: f32 = 32.0;
/// Collision uses the bottom half of the sprite, the feet. The top half may overlap walls, as it
/// would in a top-down view.
const collide_top: f32 = 16.0;
const collide_h: f32 = 16.0;
/// Player speed, in native pixels per second.
const speed: f32 = 80.0;
/// Time each walk frame is shown, in seconds.
const walk_frame_seconds: f32 = 0.12;

// Sheet rows, by facing.
const row_down: u32 = 0;
const row_right: u32 = 1;
const row_up: u32 = 2;
const row_left: u32 = 3;

const white = [3]f32{ 1.0, 1.0, 1.0 };

/// A point in native pixels.
pub const Point = struct {
    x: f32,
    y: f32,
};

pub const Player = struct {
    /// Top-left corner, in native pixels, as of the latest update.
    x: f32,
    y: f32,
    /// Top-left corner as of the update before that. Drawing blends between the two.
    prev_x: f32,
    prev_y: f32,
    /// Sheet row for the current facing.
    row: u32 = row_down,
    /// Sheet column to draw this frame.
    frame: u32 = 0,
    walk_timer: f32 = 0,
    walk_frame: u32 = 0,

    /// A player whose feet fill the given tile. The game starts the player on the map's spawn cell.
    pub fn standingOn(col: u32, row: u32) Player {
        const x = @as(f32, @floatFromInt(col)) * engine.tilemap.tile_px;
        const y = @as(f32, @floatFromInt(row)) * engine.tilemap.tile_px - collide_top;
        return .{ .x = x, .y = y, .prev_x = x, .prev_y = y };
    }

    /// Top-left corner to draw at, blended between the last two updates. `alpha` is 0 at the
    /// previous update and 1 at the latest.
    pub fn drawPosition(self: *const Player, alpha: f32) Point {
        return .{
            .x = self.prev_x + (self.x - self.prev_x) * alpha,
            .y = self.prev_y + (self.y - self.prev_y) * alpha,
        };
    }

    /// Center of the sprite to draw at, blended between the last two updates.
    pub fn drawCenter(self: *const Player, alpha: f32) Point {
        const top_left = self.drawPosition(alpha);
        return .{ .x = top_left.x + width / 2.0, .y = top_left.y + height / 2.0 };
    }

    /// Moves the player. `move_x` and `move_y` are input directions, each -1, 0, or 1. Solid tiles
    /// in `map` stop the player on each axis, so the player slides along walls.
    pub fn update(self: *Player, move_x: f32, move_y: f32, dt: f32, map: *const engine.tilemap.TileMap) void {
        // Remember where we were, so drawing can blend from here to the new position.
        self.prev_x = self.x;
        self.prev_y = self.y;

        var dx = move_x;
        var dy = move_y;

        // Facing comes from the raw input, before normalization. Horizontal wins on diagonals.
        if (dx < 0) {
            self.row = row_left;
        } else if (dx > 0) {
            self.row = row_right;
        } else if (dy < 0) {
            self.row = row_up;
        } else if (dy > 0) {
            self.row = row_down;
        }

        const moving = dx != 0 or dy != 0;
        // The back-facing row has four frames; the other rows have five.
        const frame_count: u32 = if (self.row == row_up) 4 else 5;
        if (moving) {
            self.walk_timer += dt;
            while (self.walk_timer >= walk_frame_seconds) {
                self.walk_timer -= walk_frame_seconds;
                self.walk_frame = (self.walk_frame + 1) % frame_count;
            }
        } else {
            self.walk_timer = 0;
            self.walk_frame = 0;
        }
        // After a turn, the walk index can sit past the end of a shorter row, so wrap it.
        self.frame = if (moving) self.walk_frame % frame_count else 0;

        // Diagonal input is normalized so it isn't faster. Cardinal input already has length 1,
        // and zero input stays zero.
        const direction = engine.math.normalizeOrZero(.{ dx, dy });
        dx = direction[0];
        dy = direction[1];

        // Move the feet against the map, one axis at a time. Then place the sprite above them.
        const feet = map.moveBox(
            .{ .x = self.x, .y = self.y + collide_top, .w = width, .h = collide_h },
            dx * speed * dt,
            dy * speed * dt,
        );
        self.x = feet.x;
        self.y = feet.y - collide_top;

        // Invariants: the walk index stays inside its row, and the position stays a real number.
        engine.log.assert(self.frame < frame_count, @src(), "frame {d} is outside its row of {d} frames", .{ self.frame, frame_count });
        engine.log.assert(std.math.isFinite(self.x) and std.math.isFinite(self.y), @src(), "player position is not finite: ({d}, {d})", .{ self.x, self.y });
    }

    /// Queues the current frame at the blended position, relative to the camera.
    pub fn draw(self: *const Player, batch: *engine.SpriteBatch, sheet: *const engine.Texture, cam: *const engine.Camera, alpha: f32) void {
        const pos = self.drawPosition(alpha);
        const src = engine.Rect{
            .x = @as(f32, @floatFromInt(self.frame)) * width,
            .y = @as(f32, @floatFromInt(self.row)) * height,
            .w = width,
            .h = height,
        };
        // Whole native pixels keep the edges of the sprite sharp.
        const dst = engine.Rect{
            .x = @round(pos.x) - cam.x,
            .y = @round(pos.y) - cam.y,
            .w = width,
            .h = height,
        };
        batch.drawSprite(sheet, src, dst, white);
    }
};
