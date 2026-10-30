//! The player: position, facing, walk animation, and drawing. This is gameplay code. The engine
//! sees only the sprites it queues, the tile map that the player collides with, and the animation
//! clips the player plays.

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

/// Which way the player faces.
pub const Facing = enum(u32) {
    down,
    right,
    up,
    left,
};

/// The sheet row for each facing. The warrior sheet has four rows, in this order: front, back,
/// left, right. Each row has five frames.
fn sheetRow(facing: Facing) u32 {
    return switch (facing) {
        .down => 0,
        .up => 1,
        .left => 2,
        .right => 3,
    };
}

/// The clip for a facing. Walking plays the facing's row through its five frames. Standing still
/// holds the row's first frame.
fn clipFor(facing: Facing, moving: bool) engine.animation.Clip {
    const row = sheetRow(facing);
    if (!moving) {
        return .{ .row = row, .frame_count = 1, .frame_time = walk_frame_seconds, .looping = true };
    }
    return .{
        .row = row,
        .frame_count = 5,
        .frame_time = walk_frame_seconds,
        .looping = true,
    };
}

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
    /// Direction the player last moved in. It stays put when the player stops.
    facing: Facing = .down,
    /// Plays the walk and idle clips.
    anim: engine.animation.Animator,

    /// Sprite size in native pixels, so game code can check a position against the level.
    pub const sprite_w: f32 = width;
    pub const sprite_h: f32 = height;

    /// The feet: the collision box of a player whose top-left corner is at (x, y).
    pub fn feetAt(x: f32, y: f32) engine.tilemap.Box {
        return .{ .x = x, .y = y + collide_top, .w = width, .h = collide_h };
    }

    /// A player whose feet fill the given tile. The game starts the player on the map's spawn cell.
    pub fn standingOn(col: u32, row: u32) Player {
        const x = @as(f32, @floatFromInt(col)) * engine.tilemap.tile_px;
        const y = @as(f32, @floatFromInt(row)) * engine.tilemap.tile_px - collide_top;
        return .{
            .x = x,
            .y = y,
            .prev_x = x,
            .prev_y = y,
            .anim = engine.animation.Animator.init(clipFor(.down, false)),
        };
    }

    /// Restores persisted movement state without interpolating from an unrelated previous frame.
    pub fn restore(self: *Player, x: f32, y: f32, facing: Facing, moving: bool, elapsed: f32) void {
        self.x = x;
        self.y = y;
        self.prev_x = x;
        self.prev_y = y;
        self.facing = facing;
        self.anim.play(clipFor(facing, moving));
        self.anim.time = @mod(@max(elapsed, 0), self.anim.clip.duration());
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
            self.facing = .left;
        } else if (dx > 0) {
            self.facing = .right;
        } else if (dy < 0) {
            self.facing = .up;
        } else if (dy > 0) {
            self.facing = .down;
        }

        // Switching clips restarts them, so a new walk begins at its first frame. Holding the same
        // clip keeps its place.
        const moving = dx != 0 or dy != 0;
        self.anim.play(clipFor(self.facing, moving));
        self.anim.update(dt);

        // Diagonal input is normalized so it isn't faster. Cardinal input already has length 1,
        // and zero input stays zero.
        const direction = engine.math.normalizeOrZero(.{ dx, dy });
        dx = direction[0];
        dy = direction[1];

        // Move the feet against the map, one axis at a time. Then place the sprite above them.
        const feet = map.moveBox(Player.feetAt(self.x, self.y), dx * speed * dt, dy * speed * dt);
        self.x = feet.x;
        self.y = feet.y - collide_top;

        engine.log.assert(std.math.isFinite(self.x) and std.math.isFinite(self.y), @src(), "player position is not finite: ({d}, {d})", .{ self.x, self.y });
    }

    /// Queues the current frame at the blended position, relative to the camera. `atlas` is the
    /// texture that holds every sprite, and `sheet` is the warrior's region of it.
    pub fn draw(
        self: *const Player,
        batch: *engine.SpriteBatch,
        atlas: *const engine.Texture,
        sheet: engine.atlas.Region,
        cam: *const engine.Camera,
        alpha: f32,
    ) void {
        const pos = self.drawPosition(alpha);
        const src = engine.Rect{
            .x = @as(f32, @floatFromInt(sheet.x)) + @as(f32, @floatFromInt(self.anim.frame())) * width,
            .y = @as(f32, @floatFromInt(sheet.y)) + @as(f32, @floatFromInt(self.anim.clip.row)) * height,
            .w = width,
            .h = height,
        };
        // Whole native pixels keep the edges of the sprite sharp. The camera rounds once per sprite.
        const dst = engine.Rect{
            .x = cam.screenX(pos.x),
            .y = cam.screenY(pos.y),
            .w = width,
            .h = height,
        };
        batch.drawSprite(atlas, src, dst, .{});
    }
};
