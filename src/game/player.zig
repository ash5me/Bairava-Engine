//! The player: position, facing, walk animation, and drawing. This is gameplay code. The engine
//! sees only the sprites it queues, the tile map that the player collides with, and the animation
//! clips the player plays.

const std = @import("std");
const engine = @import("bairava");

/// The sprite frames are 16x32 pixels. The validated animation file defines their rectangles.
const width: f32 = 16.0;
const height: f32 = 32.0;
/// Collision uses the bottom half of the sprite, the feet. The top half may overlap walls, as it
/// would in a top-down view.
const collide_top: f32 = 16.0;
const collide_h: f32 = 16.0;
/// Player speed, in native pixels per second.
const speed: f32 = 80.0;
/// Which way the player faces.
pub const Facing = enum(u32) {
    down,
    right,
    up,
    left,
};

/// Gameplay selects named clips; frame timing and rectangles come from the engine's animation data.
fn clipFor(library: *const engine.animation.Library, facing: Facing, moving: bool) *const engine.animation.DataClip {
    const prefix: []const u8 = if (moving) "walk_" else "idle_";
    const direction = switch (facing) {
        .down => "down",
        .up => "up",
        .left => "left",
        .right => "right",
    };
    var name: [16]u8 = undefined;
    const clip_name = std.fmt.bufPrint(&name, "{s}{s}", .{ prefix, direction }) catch unreachable;
    return library.find(clip_name) orelse unreachable;
}

/// A point in native pixels.
pub const Point = struct {
    x: f32,
    y: f32,
};

pub const Player = struct {
    /// Local transform; gameplay uses its position as the sprite's top-left corner.
    transform: engine.transform.Transform = .{},
    /// Top-left corner as of the update before that. Drawing blends between the two.
    prev_x: f32,
    prev_y: f32,
    /// Direction the player last moved in. It stays put when the player stops.
    facing: Facing = .down,
    /// Plays the walk and idle clips.
    anim: engine.animation.Timeline,

    /// Sprite size in native pixels, so game code can check a position against the level.
    pub const sprite_w: f32 = width;
    pub const sprite_h: f32 = height;

    /// The feet: the collision box of a player whose top-left corner is at (x, y).
    pub fn feetAt(x: f32, y: f32) engine.tilemap.Box {
        return .{ .x = x, .y = y + collide_top, .w = width, .h = collide_h };
    }

    /// A player whose feet fill the given tile. The game starts the player on the map's spawn cell.
    pub fn standingOn(col: u32, row: u32, animations: *const engine.animation.Library) Player {
        const x = @as(f32, @floatFromInt(col)) * engine.tilemap.tile_px;
        const y = @as(f32, @floatFromInt(row)) * engine.tilemap.tile_px - collide_top;
        return .{
            .transform = .{ .position = .{ x, y, 0.0 } },
            .prev_x = x,
            .prev_y = y,
            .anim = engine.animation.Timeline.init(clipFor(animations, .down, false)),
        };
    }

    /// Restores persisted movement state without interpolating from an unrelated previous frame.
    pub fn restore(self: *Player, transform: engine.transform.Transform, facing: Facing, moving: bool, elapsed: f32, animations: *const engine.animation.Library) void {
        self.transform = transform;
        const x = transform.position[0];
        const y = transform.position[1];
        self.prev_x = x;
        self.prev_y = y;
        self.facing = facing;
        self.anim.play(clipFor(animations, facing, moving));
        self.anim.time = @mod(@max(elapsed, 0), self.anim.clip.duration());
    }

    /// Top-left corner to draw at, blended between the last two updates. `alpha` is 0 at the
    /// previous update and 1 at the latest.
    pub fn drawPosition(self: *const Player, alpha: f32) Point {
        return .{
            .x = self.prev_x + (self.transform.position[0] - self.prev_x) * alpha,
            .y = self.prev_y + (self.transform.position[1] - self.prev_y) * alpha,
        };
    }

    /// Center of the sprite to draw at, blended between the last two updates.
    pub fn drawCenter(self: *const Player, alpha: f32) Point {
        const top_left = self.drawPosition(alpha);
        return .{ .x = top_left.x + width / 2.0, .y = top_left.y + height / 2.0 };
    }

    /// Moves the player. `move_x` and `move_y` are input directions, each -1, 0, or 1. Solid tiles
    /// in `map` stop the player on each axis, so the player slides along walls.
    pub fn update(self: *Player, move_x: f32, move_y: f32, dt: f32, map: *const engine.tilemap.TileMap, animations: *const engine.animation.Library) void {
        // Remember where we were, so drawing can blend from here to the new position.
        self.prev_x = self.transform.position[0];
        self.prev_y = self.transform.position[1];

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
        self.anim.play(clipFor(animations, self.facing, moving));
        self.anim.update(dt);

        // Diagonal input is normalized so it isn't faster. Cardinal input already has length 1,
        // and zero input stays zero.
        const direction = engine.math.normalizeOrZero(.{ dx, dy });
        dx = direction[0];
        dy = direction[1];

        // Move the feet against the map, one axis at a time. Then place the sprite above them.
        const feet = map.moveBox(Player.feetAt(self.transform.position[0], self.transform.position[1]), dx * speed * dt, dy * speed * dt);
        self.transform.position[0] = feet.x;
        self.transform.position[1] = feet.y - collide_top;

        engine.log.assert(std.math.isFinite(self.transform.position[0]) and std.math.isFinite(self.transform.position[1]), @src(), "player position is not finite: ({d}, {d})", .{ self.transform.position[0], self.transform.position[1] });
    }

    /// The collision box (the feet) at the blended position, in world pixels. Debug geometry draws it.
    pub fn collisionBox(self: *const Player, alpha: f32) engine.tilemap.Box {
        const pos = self.drawPosition(alpha);
        return feetAt(pos.x, pos.y);
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
        const frame = self.anim.frame();
        const src = engine.Rect{
            .x = @floatFromInt(sheet.x + frame.x),
            .y = @floatFromInt(sheet.y + frame.y),
            .w = @floatFromInt(frame.w),
            .h = @floatFromInt(frame.h),
        };
        // Whole native pixels keep the edges of the sprite sharp. The camera rounds once per sprite.
        const dst = engine.Rect{
            .x = cam.screenX(pos.x),
            .y = cam.screenY(pos.y),
            .w = @floatFromInt(frame.w),
            .h = @floatFromInt(frame.h),
        };
        batch.drawSprite(atlas, src, dst, .{});
    }
};
