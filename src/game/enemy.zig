//! Enemies: AI monsters. Each one keeps near its home cell. It notices the player when it can see the player, chases
//! along a route, and walks home after losing sight. Decisions are in enemy_ai.zig. This file carries them out with
//! the engine's navigation: sight lines, routes, and collision with the tile map. Enemies do not fight yet, so they
//! cannot hurt the player.

const std = @import("std");
const engine = @import("bairava");
const enemy_ai = @import("enemy_ai.zig");
const Facing = @import("player.zig").Facing;

const nav = engine.navigation;
const tile_px = engine.tilemap.tile_px;

/// The feet are a square the size of one tile. Walls block the feet, the same as for the player.
const feet_px: f32 = tile_px;
/// The sprite is 16 by 32 pixels, and its feet are the bottom half. This is the height of the top half.
const collide_top: f32 = 16.0;
/// Speed while chasing, and while wandering or walking home, in pixels per second. The player moves at 80, so a
/// chasing enemy can always be outrun.
const chase_speed: f32 = 44.0;
const patrol_speed: f32 = 20.0;
/// How far an enemy can see, in pixels from its feet to the target's feet, with a clear line between them.
const sight_range: f32 = 88.0;
/// Wander targets lie within this many cells of home, on each axis.
const wander_radius: i32 = 4;
/// Seconds between route updates while chasing. Between them the route stays fixed, so a moving target does not
/// cost a search every step. A chase also replans as soon as the target moves into another cell.
const repath_seconds: f32 = 0.4;
/// The warrior's sprites, tinted so the enemies read as different from the player.
const tint = [3]f32{ 1.0, 0.5, 0.5 };
/// Debug colors: the enemy's feet, and the cells left on its route.
const body_color = engine.diagnostics.Color{ .r = 1.0, .g = 0.3, .b = 0.3, .a = 0.9 };
const path_color = engine.diagnostics.Color{ .r = 0.4, .g = 0.8, .b = 1.0, .a = 0.9 };

/// Where the player is, as the enemies see it: the center of its feet, and the cell that holds that point.
pub const Target = struct {
    center: engine.tilemap.Point,
    cell: nav.Cell,
};

/// Everything an enemy needs for one update step. The game builds it once per step, and gives it to every enemy.
pub const Stage = struct {
    map: *const engine.tilemap.TileMap,
    finder: *nav.Pathfinder,
    target: Target,
    clips: *const Clips,
    dt: f32,
};

/// The warrior's animation clips for each facing, indexed by `Facing`: down, right, up, left. They are found once,
/// at startup. They point into the animation library, so the library must outlive the enemies.
pub const Clips = struct {
    idle: [4]*const engine.animation.DataClip,
    walk: [4]*const engine.animation.DataClip,

    /// Finds the eight warrior clips, or returns null when one of them is missing.
    pub fn resolve(library: *const engine.animation.Library) ?Clips {
        const idle_names = [4][]const u8{ "idle_down", "idle_right", "idle_up", "idle_left" };
        const walk_names = [4][]const u8{ "walk_down", "walk_right", "walk_up", "walk_left" };
        var clips: Clips = undefined;
        for (idle_names, 0..) |name, index| clips.idle[index] = library.find(name) orelse return null;
        for (walk_names, 0..) |name, index| clips.walk[index] = library.find(name) orelse return null;
        return clips;
    }
};

pub const Enemy = struct {
    /// The cell the enemy guards. It wanders near here, and walks back here after losing the target.
    home: nav.Cell,
    /// The top-left corner of the feet box, in pixels. The sprite is drawn `collide_top` above it.
    x: f32,
    y: f32,
    /// The corner as of the update before, so drawing can blend between the two.
    prev_x: f32,
    prev_y: f32,
    facing: Facing = .down,
    moving: bool = false,
    brain: enemy_ai.Brain,
    route: nav.Follower = .{},
    /// Seconds until the next route update while chasing.
    repath_timer: f32 = 0,
    /// The cell the current chase route leads to, so a change of target cell can replan it.
    chase_goal: ?nav.Cell = null,
    timeline: engine.animation.Timeline,

    /// An enemy standing on `home`. Its brain is seeded with `seed`, so each enemy wanders on its own course.
    pub fn spawn(home: nav.Cell, seed: u32, clips: *const Clips) Enemy {
        const x = @as(f32, @floatFromInt(home.col)) * tile_px;
        const y = @as(f32, @floatFromInt(home.row)) * tile_px;
        return .{
            .home = home,
            .x = x,
            .y = y,
            .prev_x = x,
            .prev_y = y,
            .brain = enemy_ai.Brain.init(seed),
            .timeline = engine.animation.Timeline.init(clips.idle[@intFromEnum(Facing.down)]),
        };
    }

    /// True while the enemy is chasing the target. The debug overlay counts these.
    pub fn isChasing(self: *const Enemy) bool {
        return self.brain.state == .chase;
    }

    /// Runs one update step: decides, plans when the decision or the target changes, then walks and animates.
    pub fn update(self: *Enemy, stage: Stage) void {
        const grid = nav.Grid.init(stage.map);
        const eye = self.feetCenter();
        const sees = seesTarget(grid, eye, stage.target.center);
        const order = self.brain.update(.{ .sees_target = sees, .path_done = self.route.atGoal() }, stage.dt);
        switch (order) {
            .none => {},
            .wander => self.wander(grid, stage.finder),
            .chase => self.chase(grid, stage.finder, stage.target.cell),
            .return_home => self.plan(grid, stage.finder, self.home),
        }
        if (self.brain.state == .chase and sees) {
            self.repath_timer -= stage.dt;
            if (self.repath_timer <= 0 or !sameCell(self.chase_goal, stage.target.cell)) {
                self.chase(grid, stage.finder, stage.target.cell);
            }
        }
        self.walk(stage);
        self.animate(stage);
    }

    /// Queues the enemy's current frame at its blended position, relative to the camera. The sprite is the warrior's,
    /// tinted, so it reads as an enemy.
    pub fn draw(self: *const Enemy, batch: *engine.SpriteBatch, atlas: *const engine.Texture, sheet: engine.atlas.Region, cam: *const engine.Camera, alpha: f32) void {
        const x = self.prev_x + (self.x - self.prev_x) * alpha;
        const y = self.prev_y + (self.y - self.prev_y) * alpha;
        const frame = self.timeline.frame();
        const src = engine.Rect{
            .x = @floatFromInt(sheet.x + frame.x),
            .y = @floatFromInt(sheet.y + frame.y),
            .w = @floatFromInt(frame.w),
            .h = @floatFromInt(frame.h),
        };
        const dst = engine.Rect{
            .x = cam.screenX(x),
            .y = cam.screenY(y - collide_top),
            .w = @floatFromInt(frame.w),
            .h = @floatFromInt(frame.h),
        };
        batch.drawSprite(atlas, src, dst, .{ .tint = tint });
    }

    /// Queues the debug view: the feet, and the cells left on the route, from the next waypoint to the goal.
    pub fn drawDebug(self: *const Enemy, debug: *engine.diagnostics.DebugDraw, cam: *const engine.Camera) void {
        debug.outline(cam.screenX(self.x), cam.screenY(self.y), feet_px, feet_px, body_color);
        var index = self.route.index;
        while (index < self.route.len) : (index += 1) {
            const center = nav.cellCenter(self.route.cells[index]);
            debug.point(cam.screenX(center.x), cam.screenY(center.y), path_color);
        }
    }

    /// The center of the feet box, which is where sight starts and where routes start.
    fn feetCenter(self: *const Enemy) engine.tilemap.Point {
        return .{ .x = self.x + feet_px / 2.0, .y = self.y + feet_px / 2.0 };
    }

    /// Starts chasing: routes to `goal`, and sets the route timer so the next update waits for it to run out.
    fn chase(self: *Enemy, grid: nav.Grid, finder: *nav.Pathfinder, goal: nav.Cell) void {
        self.chase_goal = goal;
        self.repath_timer = repath_seconds;
        self.plan(grid, finder, goal);
    }

    /// Picks a random open cell near home and routes to it. When none of a few tries is open, the enemy keeps its
    /// route empty, so the brain sees the route as done and rests.
    fn wander(self: *Enemy, grid: nav.Grid, finder: *nav.Pathfinder) void {
        var attempt: usize = 0;
        while (attempt < 8) : (attempt += 1) {
            const dc = self.randomOffset();
            const dr = self.randomOffset();
            const goal = nav.Cell{ .col = self.home.col + dc, .row = self.home.row + dr };
            if (!grid.walkable(goal)) continue;
            self.plan(grid, finder, goal);
            if (self.route.hasPath()) return;
        }
        self.route.clear();
    }

    /// Routes from the enemy's cell to `goal`. When no route exists, the enemy's route is dropped.
    fn plan(self: *Enemy, grid: nav.Grid, finder: *nav.Pathfinder, goal: nav.Cell) void {
        const start = nav.cellOf(self.feetCenter());
        const count = finder.find(grid, start, goal, self.route.buffer()) catch {
            self.route.clear();
            return;
        };
        self.route.commit(count);
    }

    /// A random offset along one axis, from -wander_radius to wander_radius.
    fn randomOffset(self: *Enemy) i32 {
        const span: u32 = @intCast(2 * wander_radius + 1);
        const value: i32 = @intCast(self.brain.random() % span);
        return value - wander_radius;
    }

    /// Moves along the route at the speed of the enemy's state, and records whether it moved, and which way it faced.
    fn walk(self: *Enemy, stage: Stage) void {
        const speed: f32 = if (self.brain.state == .chase) chase_speed else patrol_speed;
        self.prev_x = self.x;
        self.prev_y = self.y;
        const box = engine.tilemap.Box{ .x = self.x, .y = self.y, .w = feet_px, .h = feet_px };
        const next = self.route.step(stage.map, box, speed, stage.dt);
        self.x = next.x;
        self.y = next.y;
        self.moving = self.route.moved;
        if (self.moving) self.facing = facingOf(self.x - self.prev_x, self.y - self.prev_y);
    }

    /// Plays the walk clip while moving and the idle clip while standing, both for the way the enemy faces.
    fn animate(self: *Enemy, stage: Stage) void {
        const index = @intFromEnum(self.facing);
        const clip = if (self.moving) stage.clips.walk[index] else stage.clips.idle[index];
        self.timeline.play(clip);
        self.timeline.update(stage.dt);
    }
};

/// True when the target is close enough, and a clear line joins the two points.
fn seesTarget(grid: nav.Grid, from: engine.tilemap.Point, to: engine.tilemap.Point) bool {
    const dx = to.x - from.x;
    const dy = to.y - from.y;
    if (dx * dx + dy * dy > sight_range * sight_range) return false;
    return grid.lineOfSight(from, to);
}

/// The direction of a step, as the sprite's facing. The larger axis wins, and a tie goes to horizontal.
fn facingOf(dx: f32, dy: f32) Facing {
    if (@abs(dx) >= @abs(dy)) return if (dx < 0) .left else .right;
    return if (dy < 0) .up else .down;
}

fn sameCell(a: ?nav.Cell, b: nav.Cell) bool {
    const value = a orelse return false;
    return value.eql(b);
}
