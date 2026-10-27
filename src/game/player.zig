//! The player: position, facing, walk animation, and drawing. This is gameplay code. The engine
//! sees only the sprites it queues.

const std = @import("std");
const engine = @import("../engine/engine.zig");

/// The sprite is 16x32 pixels. The sheet is laid out in rows by facing.
const width: f32 = 16.0;
const height: f32 = 32.0;
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

pub const Player = struct {
    /// World position of the top-left corner, in native pixels.
    x: f32,
    y: f32,
    /// Sheet row for the current facing.
    row: u32 = row_down,
    /// Sheet column to draw this frame.
    frame: u32 = 0,
    walk_timer: f32 = 0,
    walk_frame: u32 = 0,

    /// Starts the player in the middle of a map of the given size.
    pub fn init(map_w: f32, map_h: f32) Player {
        return .{
            .x = (map_w - width) / 2.0,
            .y = (map_h - height) / 2.0,
        };
    }

    pub fn centerX(self: *const Player) f32 {
        return self.x + width / 2.0;
    }

    pub fn centerY(self: *const Player) f32 {
        return self.y + height / 2.0;
    }

    /// Moves the player. `move_x` and `move_y` are input directions, each -1, 0, or 1.
    /// The player stays inside a map of `map_w` by `map_h` pixels.
    pub fn update(self: *Player, move_x: f32, move_y: f32, dt: f32, map_w: f32, map_h: f32) void {
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

        // Diagonal input is normalized so it isn't faster.
        if (dx != 0 and dy != 0) {
            const diagonal = 1.0 / @sqrt(2.0);
            dx *= diagonal;
            dy *= diagonal;
        }

        // Keep the whole sprite inside the map.
        self.x = std.math.clamp(self.x + dx * speed * dt, 0.0, map_w - width);
        self.y = std.math.clamp(self.y + dy * speed * dt, 0.0, map_h - height);
    }

    /// Queues the current frame at the player's position, relative to the camera.
    pub fn draw(self: *const Player, batch: *engine.SpriteBatch, sheet: *const engine.Texture, cam: *const engine.Camera) void {
        const src = engine.Rect{
            .x = @as(f32, @floatFromInt(self.frame)) * width,
            .y = @as(f32, @floatFromInt(self.row)) * height,
            .w = width,
            .h = height,
        };
        // Whole native pixels keep the edges of the sprite sharp.
        const dst = engine.Rect{
            .x = @round(self.x) - cam.x,
            .y = @round(self.y) - cam.y,
            .w = width,
            .h = height,
        };
        batch.drawSprite(sheet, src, dst, white);
    }
};
