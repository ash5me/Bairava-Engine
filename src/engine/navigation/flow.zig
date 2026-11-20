//! Shared-goal Dijkstra flow fields over a navigation grid. The field stores cost-to-goal and one legal downhill
//! neighbor per reachable cell, so many units can steer toward the same goal without running a search each.

const std = @import("std");
const grid_mod = @import("grid.zig");
const pathfind = @import("pathfind.zig");

const Grid = grid_mod.Grid;
const Cell = grid_mod.Cell;

const no_direction: u8 = 8;
const unreachable_cost = std.math.maxInt(u32);

pub const FlowError = pathfind.FindError || error{NoGoals};

pub const FlowField = struct {
    allocator: std.mem.Allocator,
    /// Cost-to-goal for each cell. Unreachable cells have `maxInt(u32)`.
    cost: []u32,
    /// Neighbor offset index, matching `pathfind.offsets`; 8 means no direction.
    dir: []u8,
    goal: ?Cell = null,
    cols: u32 = 0,
    rows: u32 = 0,
    heap: []pathfind.HeapNode,
    heap_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!FlowField {
        const cost = try allocator.alloc(u32, 0);
        errdefer allocator.free(cost);
        const dir = try allocator.alloc(u8, 0);
        errdefer allocator.free(dir);
        return .{
            .allocator = allocator,
            .cost = cost,
            .dir = dir,
            .heap = try allocator.alloc(pathfind.HeapNode, 0),
        };
    }

    pub fn deinit(self: *FlowField) void {
        self.allocator.free(self.cost);
        self.allocator.free(self.dir);
        self.allocator.free(self.heap);
    }

    /// Builds a field for one walkable goal. Invalid goals leave the current field unchanged.
    pub fn build(self: *FlowField, grid: Grid, goal: Cell) (FlowError || std.mem.Allocator.Error)!void {
        try self.buildGoals(grid, &.{goal});
    }

    /// Builds a field whose sources are all the supplied walkable goals. Invalid goals leave the current field
    /// unchanged. An empty goal list returns `NoGoals`.
    pub fn buildGoals(self: *FlowField, grid: Grid, goals: []const Cell) (FlowError || std.mem.Allocator.Error)!void {
        if (goals.len == 0) return error.NoGoals;
        for (goals) |goal| {
            if (!grid.inBounds(goal)) return error.OutOfBounds;
            if (!grid.walkable(goal)) return error.GoalBlocked;
        }

        try self.reserve(grid);
        @memset(self.cost, unreachable_cost);
        @memset(self.dir, no_direction);
        self.heap_len = 0;

        for (goals) |goal| {
            const index = grid.index(goal);
            if (self.cost[index] == 0) continue;
            self.cost[index] = 0;
            try pathfind.heapPush(self.allocator, &self.heap, &self.heap_len, .{
                .f = 0,
                .g = 0,
                .cell = @intCast(index),
            });
        }

        while (self.heap_len > 0) {
            const node = pathfind.heapPop(self.heap, &self.heap_len);
            const at_index: usize = node.cell;
            if (node.g != self.cost[at_index]) continue;
            const at = grid.cellAt(at_index);

            for (pathfind.offsets) |offset| {
                const from = Cell{ .col = at.col + offset[0], .row = at.row + offset[1] };
                if (!grid.walkable(from) or !pathfind.legalStep(grid, from, at)) continue;
                const from_index = grid.index(from);
                const candidate = node.g + pathfind.stepCost(from, at);
                if (candidate >= self.cost[from_index]) continue;
                self.cost[from_index] = candidate;
                try pathfind.heapPush(self.allocator, &self.heap, &self.heap_len, .{
                    .f = candidate,
                    .g = candidate,
                    .cell = @intCast(from_index),
                });
            }
        }

        for (0..grid.count()) |index| {
            if (self.cost[index] == unreachable_cost or self.cost[index] == 0) continue;
            const from = grid.cellAt(index);
            var best_neighbor_cost: u32 = unreachable_cost;
            for (pathfind.offsets, 0..) |offset, direction| {
                const to = Cell{ .col = from.col + offset[0], .row = from.row + offset[1] };
                if (!grid.walkable(from) or !grid.walkable(to) or !pathfind.legalStep(grid, from, to)) continue;
                const to_index = grid.index(to);
                const neighbor_cost = self.cost[to_index];
                if (neighbor_cost == unreachable_cost or neighbor_cost + pathfind.stepCost(from, to) != self.cost[index]) continue;
                if (neighbor_cost < best_neighbor_cost) {
                    best_neighbor_cost = neighbor_cost;
                    self.dir[index] = @intCast(direction);
                }
            }
        }

        self.goal = if (goals.len == 1) goals[0] else null;
        self.cols = grid.map.cols;
        self.rows = grid.map.rows;
    }

    /// Returns the next legal, lower-cost cell, or null at a source, in a solid cell, or when unreachable.
    pub fn nextCell(self: *const FlowField, grid: Grid, cell: Cell) ?Cell {
        if (self.cols != grid.map.cols or self.rows != grid.map.rows or !grid.inBounds(cell)) return null;
        const index = grid.index(cell);
        if (index >= self.cost.len or self.cost[index] == unreachable_cost) return null;
        const direction = self.dir[index];
        if (@as(usize, direction) >= pathfind.offsets.len) return null;
        const offset = pathfind.offsets[@as(usize, direction)];
        const next = Cell{ .col = cell.col + offset[0], .row = cell.row + offset[1] };
        if (!pathfind.legalStep(grid, cell, next)) return null;
        return next;
    }

    fn reserve(self: *FlowField, grid: Grid) std.mem.Allocator.Error!void {
        const count = grid.count();
        if (self.cost.len >= count) return;
        const cost = try self.allocator.alloc(u32, count);
        errdefer self.allocator.free(cost);
        const dir = try self.allocator.alloc(u8, count);
        self.allocator.free(self.cost);
        self.allocator.free(self.dir);
        self.cost = cost;
        self.dir = dir;
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

test "flow costs descend by legal A* step costs and reach the goal" {
    const tilemap = @import("../scene/tilemap.zig");
    const pathfind_mod = @import("pathfind.zig");
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, open_text);
    defer map.deinit(allocator);
    const grid = Grid.init(&map);
    var field = try FlowField.init(allocator);
    defer field.deinit();
    const goal = Cell{ .col = 4, .row = 4 };
    try field.build(grid, goal);
    try std.testing.expectEqual(@as(u32, 0), field.cost[grid.index(goal)]);

    var finder = try pathfind_mod.Pathfinder.init(allocator);
    defer finder.deinit();
    var route: [36]Cell = undefined;
    for (0..grid.count()) |index| {
        const start = grid.cellAt(index);
        if (!grid.walkable(start)) continue;
        var cell = start;
        var steps: usize = 0;
        while (!cell.eql(goal) and steps < grid.count()) : (steps += 1) {
            const next = field.nextCell(grid, cell) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(field.cost[grid.index(cell)] - pathfind_mod.stepCost(cell, next), field.cost[grid.index(next)]);
            try std.testing.expect(grid.walkable(next));
            cell = next;
        }
        try std.testing.expect(cell.eql(goal));

        const route_len = try finder.find(grid, start, goal, &route);
        var route_cost: u32 = 0;
        for (route[1..route_len], 0..) |next, route_index| {
            route_cost += pathfind_mod.stepCost(route[route_index], next);
        }
        try std.testing.expectEqual(route_cost, field.cost[index]);
    }
}

test "flow respects walls, corner rules, and southward one-way entry" {
    const tilemap = @import("../scene/tilemap.zig");
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, "size 3 2\nsolid 1\noneway 2\nlayer ground\n0 0 0\n1 2 1\n");
    defer map.deinit(allocator);
    const grid = Grid.init(&map);
    var field = try FlowField.init(allocator);
    defer field.deinit();
    try field.build(grid, .{ .col = 1, .row = 1 });

    try std.testing.expectEqual(unreachable_cost, field.cost[grid.index(.{ .col = 1, .row = 0 })]);

    const corner_map = try tilemap.TileMap.parse(allocator, "size 2 2\nsolid 1\nlayer ground\n0 1\n1 0\n");
    defer corner_map.deinit(allocator);
    const corner_grid = Grid.init(&corner_map);
    try field.build(corner_grid, .{ .col = 1, .row = 1 });
    try std.testing.expect(field.nextCell(corner_grid, .{ .col = 0, .row = 0 }) == null);
}

test "unreachable cells, multiple goals, and failed builds preserve valid state" {
    const tilemap = @import("../scene/tilemap.zig");
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, "size 5 1\nsolid 1\nlayer ground\n0 0 1 0 0\n");
    defer map.deinit(allocator);
    const grid = Grid.init(&map);
    var field = try FlowField.init(allocator);
    defer field.deinit();
    try field.buildGoals(grid, &.{ .{ .col = 0, .row = 0 }, .{ .col = 4, .row = 0 } });
    try std.testing.expectEqual(@as(u32, 10), field.cost[grid.index(.{ .col = 1, .row = 0 })]);
    try std.testing.expectEqual(@as(u32, 10), field.cost[grid.index(.{ .col = 3, .row = 0 })]);
    try std.testing.expectEqual(unreachable_cost, field.cost[grid.index(.{ .col = 2, .row = 0 })]);
    try std.testing.expect(field.nextCell(grid, .{ .col = 2, .row = 0 }) == null);
    try std.testing.expectError(error.GoalBlocked, field.build(grid, .{ .col = 2, .row = 0 }));
    try std.testing.expectError(error.OutOfBounds, field.build(grid, .{ .col = 5, .row = 0 }));
    try std.testing.expectError(error.NoGoals, field.buildGoals(grid, &.{}));
    try std.testing.expectEqual(@as(u32, 10), field.cost[grid.index(.{ .col = 1, .row = 0 })]);
}
