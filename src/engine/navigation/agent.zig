//! A reusable navigation agent that owns its pathfinder, current goal, and route follower.
//! The map and grid remain caller-owned; the agent does not outlive either while stepping.

const std = @import("std");
const tilemap = @import("../scene/tilemap.zig");
const grid_mod = @import("grid.zig");
const pathfind = @import("pathfind.zig");
const follow = @import("follow.zig");

pub const Cell = grid_mod.Cell;
pub const Follower = follow.Follower;
pub const max_path = follow.max_path;
pub const PlanError = pathfind.FindError || std.mem.Allocator.Error;

pub const Agent = struct {
    finder: pathfind.Pathfinder,
    follower: Follower = .{},
    goal: ?Cell = null,

    pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!Agent {
        return .{
            .finder = try pathfind.Pathfinder.init(allocator),
        };
    }

    pub fn deinit(self: *Agent) void {
        self.finder.deinit();
        self.* = undefined;
    }

    /// Plans a route to `goal`, keeping the current route if the search fails.
    pub fn plan(self: *Agent, grid: grid_mod.Grid, start: Cell, goal: Cell) PlanError!void {
        var buffer: [max_path]Cell = undefined;
        const count = try self.finder.find(grid, start, goal, &buffer);
        @memcpy(self.follower.cells[0..count], buffer[0..count]);
        self.follower.commit(count);
        self.goal = goal;
    }

    /// Moves a box along the current route using the tile map's collision. Planning and movement are explicit,
    /// so callers can decide when a moving target or changed world requires a new route.
    pub fn step(self: *Agent, map: *const tilemap.TileMap, box: tilemap.Box, speed: f32, dt: f32) tilemap.Point {
        return self.follower.step(map, box, speed, dt);
    }

    pub fn clear(self: *Agent) void {
        self.goal = null;
        self.follower.clear();
    }

    pub fn atGoal(self: *const Agent) bool {
        return self.follower.atGoal();
    }

    pub fn hasPath(self: *const Agent) bool {
        return self.follower.hasPath();
    }

    pub fn nextWaypoint(self: *const Agent) ?Cell {
        if (!self.follower.hasPath()) return null;
        return self.follower.cells[self.follower.index];
    }
};

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

test "an agent plans and follows a collision-aware route to its goal" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, open_text);
    defer map.deinit(allocator);
    var agent = try Agent.init(allocator);
    defer agent.deinit();
    const goal = Cell{ .col = 4, .row = 1 };
    try agent.plan(grid_mod.Grid.init(&map), .{ .col = 1, .row = 1 }, goal);
    try std.testing.expect(agent.goal.?.eql(goal));
    try std.testing.expect(agent.nextWaypoint().?.eql(.{ .col = 1, .row = 1 }));

    var box = tilemap.Box{ .x = 16, .y = 16, .w = 16, .h = 16 };
    var steps: usize = 0;
    while (!agent.atGoal() and steps < 600) : (steps += 1) {
        const position = agent.step(&map, box, 60, 1.0 / 60.0);
        box.x = position.x;
        box.y = position.y;
    }
    try std.testing.expect(agent.atGoal());
    try std.testing.expectApproxEqAbs(@as(f32, 64), box.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 16), box.y, 0.01);
    try std.testing.expect(agent.nextWaypoint() == null);
}

test "a failed plan leaves the last valid route and goal intact" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, room_text);
    defer map.deinit(allocator);
    var agent = try Agent.init(allocator);
    defer agent.deinit();
    const grid = grid_mod.Grid.init(&map);
    const original_goal = Cell{ .col = 1, .row = 1 };
    try agent.plan(grid, original_goal, .{ .col = 2, .row = 1 });
    const original_waypoint = agent.nextWaypoint().?;

    try std.testing.expectError(error.GoalBlocked, agent.plan(grid, original_goal, .{ .col = 3, .row = 2 }));
    try std.testing.expect(agent.goal.?.eql(.{ .col = 2, .row = 1 }));
    try std.testing.expect(agent.nextWaypoint().?.eql(original_waypoint));
}

test "clearing an agent drops both its route and its remembered goal" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, open_text);
    defer map.deinit(allocator);
    var agent = try Agent.init(allocator);
    defer agent.deinit();
    try agent.plan(grid_mod.Grid.init(&map), .{ .col = 1, .row = 1 }, .{ .col = 4, .row = 1 });
    agent.clear();
    try std.testing.expect(agent.atGoal());
    try std.testing.expect(agent.goal == null);
    try std.testing.expect(agent.nextWaypoint() == null);
}
