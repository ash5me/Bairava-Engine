//! Walks a box along a path of cells, one waypoint at a time, through the tile map's collision. It keeps the path
//! and its place on it. It drops the path when the box makes no progress for a while, so a unit that is held
//! against something replans instead of pushing forever.
//!
//! When the box reaches an open waypoint, it snaps onto that cell's center. Steering diagonally can leave the box a
//! fraction of a pixel off the grid, and that fraction can put its edge over a wall row, which blocks the next
//! straight move. Snapping keeps the box on the grid, and a box centered on an open cell never overlaps a wall.
//!
//! Pure code with no SDL or logging, so `zig build test` covers it without a window.

const std = @import("std");
const tilemap = @import("../scene/tilemap.zig");
const grid_mod = @import("grid.zig");

pub const Cell = grid_mod.Cell;

/// The most cells a path may hold. A longer route is refused by the pathfinder, which reports PathTooLong.
pub const max_path = 128;
/// A waypoint counts as reached when the box's center is this close to the waypoint's center, in pixels.
pub const arrive_px: f32 = 2.0;
/// Seconds without progress before the follower drops its path.
pub const stuck_seconds: f32 = 0.35;
/// A move shorter than this, in pixels, counts as no movement, so rounding noise is not progress.
const move_eps: f32 = 1e-4;

pub const Follower = struct {
    /// The path, from its first cell to its last.
    cells: [max_path]Cell = undefined,
    /// How many cells of `cells` are in use.
    len: usize = 0,
    /// The next waypoint, as an index into `cells`. It equals `len` when the path is done.
    index: usize = 0,
    /// Seconds spent without progress while the path was still open.
    stuck_time: f32 = 0,
    /// Whether the last `step` moved the box.
    moved: bool = false,

    /// The array a new path is written into. A search may write into it while the old path is still in use, and a
    /// failed search writes nothing, so the old path survives. `commit` then makes the new one current.
    pub fn buffer(self: *Follower) []Cell {
        return &self.cells;
    }

    /// Makes the first `len` cells of the buffer the current path, and starts it from its first cell.
    pub fn commit(self: *Follower, len: usize) void {
        self.len = len;
        self.index = 0;
        self.stuck_time = 0;
    }

    /// Drops the path. The follower stands still and reports that it is done.
    pub fn clear(self: *Follower) void {
        self.len = 0;
        self.index = 0;
        self.stuck_time = 0;
        self.moved = false;
    }

    /// True while a waypoint is still ahead.
    pub fn hasPath(self: *const Follower) bool {
        return self.index < self.len;
    }

    /// True when there is no path, or the path's last cell has been reached.
    pub fn atGoal(self: *const Follower) bool {
        return !self.hasPath();
    }

    /// Moves the box toward the next waypoint, by `speed * dt` pixels at most, and returns the new top-left corner.
    /// Collision is the same as for the player: the box slides along walls and stops where a solid tile blocks it.
    /// `moved` tells the caller whether the box went anywhere this step.
    pub fn step(self: *Follower, map: *const tilemap.TileMap, box: tilemap.Box, speed: f32, dt: f32) tilemap.Point {
        var position = tilemap.Point{ .x = box.x, .y = box.y };

        // Waypoints the box has already reached are passed. An open one is also snapped to, so the box lines up with
        // the grid again. A solid start cell is passed without snapping, since the box must not be placed inside it.
        while (self.hasPath()) {
            const cell = self.cells[self.index];
            const waypoint = grid_mod.cellCenter(cell);
            if (distance(waypoint, centerAt(position, box.w, box.h)) > arrive_px) break;
            if (!map.isSolid(cell.col, cell.row)) {
                position = .{ .x = waypoint.x - box.w / 2.0, .y = waypoint.y - box.h / 2.0 };
            }
            self.index += 1;
        }
        if (!self.hasPath()) {
            self.stuck_time = 0;
            self.moved = @abs(position.x - box.x) > move_eps or @abs(position.y - box.y) > move_eps;
            return position;
        }

        // The waypoint is farther than arrive_px, so the distance is not zero, and a step of at most that distance
        // never passes the waypoint.
        const here = centerAt(position, box.w, box.h);
        const target = grid_mod.cellCenter(self.cells[self.index]);
        const dx = target.x - here.x;
        const dy = target.y - here.y;
        const dist = @sqrt(dx * dx + dy * dy);
        const travel = @min(speed * dt, dist);
        const moved_to = map.moveBox(.{ .x = position.x, .y = position.y, .w = box.w, .h = box.h }, dx / dist * travel, dy / dist * travel);

        self.moved = @abs(moved_to.x - box.x) > move_eps or @abs(moved_to.y - box.y) > move_eps;
        if (self.moved) {
            self.stuck_time = 0;
        } else {
            self.stuck_time += dt;
            if (self.stuck_time >= stuck_seconds) self.clear();
        }
        return moved_to;
    }
};

/// The center of a box with its top-left corner at `top_left`.
fn centerAt(top_left: tilemap.Point, w: f32, h: f32) tilemap.Point {
    return .{ .x = top_left.x + w / 2.0, .y = top_left.y + h / 2.0 };
}

fn distance(a: tilemap.Point, b: tilemap.Point) f32 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return @sqrt(dx * dx + dy * dy);
}

const open_text =
    \\size 6 6
    \\solid 1
    \\layer ground
    \\1 1 1 1 1 1
    \\1 0 0 0 0 1
    \\1 0 0 0 0 1
    \\1 0 0 0 0 1
    \\1 0 0 0 0 1
    \\1 1 1 1 1 1
;

const room_text =
    \\size 6 6
    \\solid 1
    \\layer ground
    \\1 1 1 1 1 1
    \\1 0 0 0 0 1
    \\1 0 0 1 0 1
    \\1 0 0 0 0 1
    \\1 0 0 0 0 1
    \\1 1 1 1 1 1
;

test "a follower walks its path to the last cell, then reports that it is done" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, open_text);
    defer map.deinit(allocator);

    var follower = Follower{};
    const route = [_]Cell{ .{ .col = 1, .row = 1 }, .{ .col = 2, .row = 1 }, .{ .col = 3, .row = 1 } };
    @memcpy(follower.buffer()[0..route.len], &route);
    follower.commit(route.len);

    var box = tilemap.Box{ .x = 16, .y = 16, .w = 16, .h = 16 };
    var steps: usize = 0;
    while (!follower.atGoal() and steps < 600) : (steps += 1) {
        const next = follower.step(&map, box, 60, 1.0 / 60.0);
        box.x = next.x;
        box.y = next.y;
    }
    try std.testing.expect(follower.atGoal());
    // The box ends centered on the last cell, (3, 1), which is at x 48 and y 16 as a top-left corner.
    try std.testing.expectApproxEqAbs(@as(f32, 48), box.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 16), box.y, 0.01);
}

test "a box moves no farther in one step than its speed allows" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, open_text);
    defer map.deinit(allocator);

    var follower = Follower{};
    follower.buffer()[0] = .{ .col = 1, .row = 1 };
    follower.buffer()[1] = .{ .col = 4, .row = 1 };
    follower.commit(2);

    const box = tilemap.Box{ .x = 16, .y = 16, .w = 16, .h = 16 };
    const next = follower.step(&map, box, 60, 1.0 / 60.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1), next.x - box.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0), next.y - box.y, 1e-4);
    try std.testing.expect(follower.moved);
}

test "a follower pushed against a wall gives up its path after standing still" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, room_text);
    defer map.deinit(allocator);

    // The second waypoint is the wall at (3, 2), so the box can never reach it.
    var follower = Follower{};
    follower.buffer()[0] = .{ .col = 1, .row = 1 };
    follower.buffer()[1] = .{ .col = 3, .row = 2 };
    follower.commit(2);

    var box = tilemap.Box{ .x = 16, .y = 16, .w = 16, .h = 16 };
    var steps: usize = 0;
    while (follower.hasPath() and steps < 600) : (steps += 1) {
        const next = follower.step(&map, box, 60, 1.0 / 60.0);
        box.x = next.x;
        box.y = next.y;
    }
    try std.testing.expect(!follower.hasPath());
    try std.testing.expect(steps < 600);
    // Collision held: the box never overlaps a solid cell, even though it pressed against the wall.
    try std.testing.expect(!map.boxOverlapsSolid(box));
}

test "a follower with no path stands still and reports that it is done" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, open_text);
    defer map.deinit(allocator);

    var follower = Follower{};
    try std.testing.expect(follower.atGoal());
    const box = tilemap.Box{ .x = 16, .y = 16, .w = 16, .h = 16 };
    const next = follower.step(&map, box, 60, 1.0 / 60.0);
    try std.testing.expectEqual(box.x, next.x);
    try std.testing.expectEqual(box.y, next.y);
    try std.testing.expect(!follower.moved);
}

test "a box that starts off-center on an open waypoint snaps onto its center" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, open_text);
    defer map.deinit(allocator);

    var follower = Follower{};
    follower.buffer()[0] = .{ .col = 2, .row = 2 };
    follower.commit(1);
    // A box 1 pixel off the grid is within arrival range of the cell's center, so it snaps there.
    const box = tilemap.Box{ .x = 33, .y = 32.5, .w = 16, .h = 16 };
    const next = follower.step(&map, box, 60, 1.0 / 60.0);
    try std.testing.expectApproxEqAbs(@as(f32, 32), next.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 32), next.y, 1e-4);
    try std.testing.expect(follower.atGoal());
}
