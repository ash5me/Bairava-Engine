//! A* search over a `Grid`: the cheapest route of cells from one cell to another. A cell is entered from any of its
//! eight neighbors. A diagonal step is allowed only when both cells beside it are walkable, so a route never slips
//! between two wall corners that touch. Costs are integers (10 for a straight step, 14 for a diagonal one), and the
//! heuristic is the matching octile distance, which never overestimates. So the first route that reaches the goal
//! is a cheapest one.
//!
//! A `Pathfinder` keeps its arrays between searches. A search does not clear them. It stamps each cell it touches
//! with the number of the current search, and a cell with another stamp counts as untouched.
//!
//! Pure code with no SDL or logging, so `zig build test` covers it without a window.

const std = @import("std");
const tilemap = @import("../scene/tilemap.zig");
const grid_mod = @import("grid.zig");

const Grid = grid_mod.Grid;
const Cell = grid_mod.Cell;

/// The cost of one step to an orthogonal neighbor, and of one step to a diagonal neighbor.
pub const straight_cost: u32 = 10;
pub const diagonal_cost: u32 = 14;

pub const FindError = error{
    /// The start or the goal lies outside the map.
    OutOfBounds,
    /// The goal is a solid cell, so no route can end there.
    GoalBlocked,
    /// No walkable route joins the two cells.
    NoPath,
    /// The route has more cells than the caller's buffer holds.
    PathTooLong,
};

/// Offsets to the eight neighbors: east, west, south, north, and then the four diagonals.
const offsets = [8][2]i32{
    .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 },
    .{ 1, 1 }, .{ -1, 1 }, .{ 1, -1 }, .{ -1, -1 },
};

/// The parent of the start cell. No real cell has this index.
const no_parent: u32 = std.math.maxInt(u32);

/// One entry of the open list. `g` is the cost when the entry was made. When a cell is reached again more cheaply,
/// the older entry is still in the heap. It is stale, and the search skips it.
const Node = struct {
    f: u32,
    g: u32,
    cell: u32,
};

fn lessThan(a: Node, b: Node) bool {
    return a.f < b.f or (a.f == b.f and a.g > b.g);
}

/// The octile distance from `from` to `goal`: the cheapest cost to get there with no walls in the way.
fn heuristic(from: Cell, goal: Cell) u32 {
    const dx: u32 = @abs(from.col - goal.col);
    const dy: u32 = @abs(from.row - goal.row);
    const diagonal_steps = @min(dx, dy);
    return straight_cost * (dx + dy) - (2 * straight_cost - diagonal_cost) * diagonal_steps;
}

pub const Pathfinder = struct {
    allocator: std.mem.Allocator,
    /// The cheapest known cost to each cell, and the cell it was reached from. An entry counts only for a cell whose
    /// `seen` stamp is the current search's.
    g: []u32,
    parent: []u32,
    /// The search that last reached, or closed, each cell.
    seen: []u32,
    closed: []u32,
    /// A binary min-heap of open entries, ordered by `f` and then by the larger `g`. It grows as needed.
    heap: []Node,
    heap_len: usize,
    /// The number of the current search. Zero means no search has run since the arrays were made.
    stamp: u32,

    pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!Pathfinder {
        return .{
            .allocator = allocator,
            .g = try allocator.alloc(u32, 0),
            .parent = try allocator.alloc(u32, 0),
            .seen = try allocator.alloc(u32, 0),
            .closed = try allocator.alloc(u32, 0),
            .heap = try allocator.alloc(Node, 0),
            .heap_len = 0,
            .stamp = 0,
        };
    }

    pub fn deinit(self: *Pathfinder) void {
        self.allocator.free(self.g);
        self.allocator.free(self.parent);
        self.allocator.free(self.seen);
        self.allocator.free(self.closed);
        self.allocator.free(self.heap);
    }

    /// Finds the cheapest route from `start` to `goal`, and writes its cells into `out`, from start to goal, with both
    /// ends included. Returns how many cells were written. `start` may be inside a wall, since a unit can be pushed
    /// there. `goal` must be walkable. `out` is only written when a route is found, so a failed search leaves the
    /// caller's previous route in place.
    pub fn find(self: *Pathfinder, grid: Grid, start: Cell, goal: Cell, out: []Cell) (FindError || std.mem.Allocator.Error)!usize {
        if (!grid.inBounds(start) or !grid.inBounds(goal)) return error.OutOfBounds;
        if (!grid.walkable(goal)) return error.GoalBlocked;
        try self.reserveCells(grid.count());
        self.nextStamp();
        const current = self.stamp;
        const start_index = grid.index(start);
        const goal_index = grid.index(goal);

        self.g[start_index] = 0;
        self.parent[start_index] = no_parent;
        self.seen[start_index] = current;
        self.heap_len = 0;
        try self.push(.{ .f = heuristic(start, goal), .g = 0, .cell = @intCast(start_index) });

        var found = false;
        while (self.heap_len > 0) {
            const node = self.pop();
            const index: usize = node.cell;
            if (self.closed[index] == current or node.g > self.g[index]) continue;
            if (index == goal_index) {
                found = true;
                break;
            }
            self.closed[index] = current;

            const from = grid.cellAt(index);
            for (offsets) |offset| {
                const next = Cell{ .col = from.col + offset[0], .row = from.row + offset[1] };
                if (!grid.walkable(next)) continue;
                const diagonal = offset[0] != 0 and offset[1] != 0;
                if (diagonal) {
                    // No cutting corners: both cells beside the diagonal must be open as well.
                    if (!grid.walkable(.{ .col = next.col, .row = from.row }) or
                        !grid.walkable(.{ .col = from.col, .row = next.row })) continue;
                }
                const next_index = grid.index(next);
                if (self.closed[next_index] == current) continue;
                const step = if (diagonal) diagonal_cost else straight_cost;
                const cost = node.g + step;
                if (self.seen[next_index] == current and cost >= self.g[next_index]) continue;
                self.seen[next_index] = current;
                self.g[next_index] = cost;
                self.parent[next_index] = @intCast(index);
                try self.push(.{ .f = cost + heuristic(next, goal), .g = cost, .cell = @intCast(next_index) });
            }
        }
        if (!found) return error.NoPath;
        return self.writePath(grid, start_index, goal_index, out);
    }

    /// Makes the arrays hold at least `count` cells. They are made once, and again only when a bigger map shows up.
    /// Making new ones clears every stamp, so no stale entry can match.
    fn reserveCells(self: *Pathfinder, count: usize) std.mem.Allocator.Error!void {
        if (self.g.len >= count) return;
        const g = try self.allocator.alloc(u32, count);
        errdefer self.allocator.free(g);
        const parent = try self.allocator.alloc(u32, count);
        errdefer self.allocator.free(parent);
        const seen = try self.allocator.alloc(u32, count);
        errdefer self.allocator.free(seen);
        const closed = try self.allocator.alloc(u32, count);
        self.allocator.free(self.g);
        self.allocator.free(self.parent);
        self.allocator.free(self.seen);
        self.allocator.free(self.closed);
        self.g = g;
        self.parent = parent;
        self.seen = seen;
        self.closed = closed;
        @memset(self.seen, 0);
        @memset(self.closed, 0);
        self.stamp = 0;
    }

    /// Starts a new search. When the counter wraps around, old stamps could match again, so they are cleared once.
    fn nextStamp(self: *Pathfinder) void {
        self.stamp +%= 1;
        if (self.stamp == 0) {
            @memset(self.seen, 0);
            @memset(self.closed, 0);
            self.stamp = 1;
        }
    }

    /// Adds an entry to the open list, growing the heap when it is full.
    fn push(self: *Pathfinder, node: Node) std.mem.Allocator.Error!void {
        if (self.heap_len == self.heap.len) {
            self.heap = try self.allocator.realloc(self.heap, @max(64, self.heap.len * 2));
        }
        var child = self.heap_len;
        self.heap[child] = node;
        self.heap_len += 1;
        while (child > 0) {
            const parent_index = (child - 1) / 2;
            if (!lessThan(self.heap[child], self.heap[parent_index])) break;
            std.mem.swap(Node, &self.heap[child], &self.heap[parent_index]);
            child = parent_index;
        }
    }

    /// Removes and returns the entry that comes first. The heap must not be empty.
    fn pop(self: *Pathfinder) Node {
        const top = self.heap[0];
        self.heap_len -= 1;
        if (self.heap_len == 0) return top;
        self.heap[0] = self.heap[self.heap_len];
        var parent_index: usize = 0;
        while (true) {
            const left = 2 * parent_index + 1;
            if (left >= self.heap_len) break;
            var smallest = left;
            const right = left + 1;
            if (right < self.heap_len and lessThan(self.heap[right], self.heap[left])) smallest = right;
            if (!lessThan(self.heap[smallest], self.heap[parent_index])) break;
            std.mem.swap(Node, &self.heap[parent_index], &self.heap[smallest]);
            parent_index = smallest;
        }
        return top;
    }

    /// Walks the parents back from the goal, and writes the route into `out` from start to goal.
    fn writePath(self: *const Pathfinder, grid: Grid, start_index: usize, goal_index: usize, out: []Cell) FindError!usize {
        var length: usize = 1;
        var index = goal_index;
        while (index != start_index) : (index = self.parent[index]) length += 1;
        if (length > out.len) return error.PathTooLong;

        index = goal_index;
        var slot = length;
        while (true) {
            slot -= 1;
            out[slot] = grid.cellAt(index);
            if (index == start_index) break;
            index = self.parent[index];
        }
        return length;
    }
};

// A 6 by 6 room with a wall at (3, 2), and an open 6 by 6 room with no inner walls.
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

/// True when every cell is walkable and each cell is a neighbor of the one before it. A diagonal step must not cut a
/// corner, so both cells beside it must be walkable too.
fn expectValidRoute(grid: Grid, route: []const Cell) !void {
    for (route) |cell| try std.testing.expect(grid.walkable(cell));
    for (route[1..], 0..) |next, i| {
        const prev = route[i];
        const dc = next.col - prev.col;
        const dr = next.row - prev.row;
        try std.testing.expect(@abs(dc) <= 1 and @abs(dr) <= 1 and (dc != 0 or dr != 0));
        if (dc != 0 and dr != 0) {
            try std.testing.expect(grid.walkable(.{ .col = next.col, .row = prev.row }));
            try std.testing.expect(grid.walkable(.{ .col = prev.col, .row = next.row }));
        }
    }
}

test "a straight run across open floor is found, with its cells in order from start to goal" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, open_text);
    defer map.deinit(allocator);
    const grid = Grid.init(&map);
    var finder = try Pathfinder.init(allocator);
    defer finder.deinit();

    var route: [16]Cell = undefined;
    const count = try finder.find(grid, .{ .col = 1, .row = 1 }, .{ .col = 4, .row = 1 }, &route);
    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expect(route[0].eql(.{ .col = 1, .row = 1 }));
    try std.testing.expect(route[1].eql(.{ .col = 2, .row = 1 }));
    try std.testing.expect(route[3].eql(.{ .col = 4, .row = 1 }));
}

test "a diagonal step is used on open floor, so the route takes the fewest cells" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, open_text);
    defer map.deinit(allocator);
    const grid = Grid.init(&map);
    var finder = try Pathfinder.init(allocator);
    defer finder.deinit();

    var route: [16]Cell = undefined;
    const count = try finder.find(grid, .{ .col = 1, .row = 1 }, .{ .col = 4, .row = 4 }, &route);
    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expect(route[1].eql(.{ .col = 2, .row = 2 }));
    try std.testing.expect(route[2].eql(.{ .col = 3, .row = 3 }));
    try expectValidRoute(grid, route[0..count]);
}

test "a route goes around a wall rather than through it" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, room_text);
    defer map.deinit(allocator);
    const grid = Grid.init(&map);
    var finder = try Pathfinder.init(allocator);
    defer finder.deinit();

    // The wall at (3, 2) lies between the two cells. Both ways around it take five cells.
    var route: [16]Cell = undefined;
    const count = try finder.find(grid, .{ .col = 1, .row = 2 }, .{ .col = 4, .row = 2 }, &route);
    try std.testing.expectEqual(@as(usize, 5), count);
    for (route[0..count]) |cell| try std.testing.expect(!cell.eql(.{ .col = 3, .row = 2 }));
    try expectValidRoute(grid, route[0..count]);
}

test "a route that does not exist is reported, and so is a goal in a wall or a start off the map" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, room_text);
    defer map.deinit(allocator);
    const grid = Grid.init(&map);
    var finder = try Pathfinder.init(allocator);
    defer finder.deinit();
    var route: [16]Cell = undefined;

    try std.testing.expectError(error.GoalBlocked, finder.find(grid, .{ .col = 1, .row = 1 }, .{ .col = 3, .row = 2 }, &route));
    try std.testing.expectError(error.OutOfBounds, finder.find(grid, .{ .col = -1, .row = 1 }, .{ .col = 2, .row = 1 }, &route));
    try std.testing.expectError(error.OutOfBounds, finder.find(grid, .{ .col = 1, .row = 1 }, .{ .col = 6, .row = 1 }, &route));

    // A wall of solid tiles splits the two cells, so no route joins them.
    const split = try tilemap.TileMap.parse(allocator, "size 3 1\nsolid 1\nlayer ground\n0 1 0\n");
    defer split.deinit(allocator);
    try std.testing.expectError(error.NoPath, finder.find(Grid.init(&split), .{ .col = 0, .row = 0 }, .{ .col = 2, .row = 0 }, &route));
}

test "corners can't be cut, so two open cells that meet only at a corner are not joined" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, "size 2 2\nsolid 1\nlayer ground\n0 1\n1 0\n");
    defer map.deinit(allocator);
    var finder = try Pathfinder.init(allocator);
    defer finder.deinit();
    var route: [4]Cell = undefined;
    try std.testing.expectError(error.NoPath, finder.find(Grid.init(&map), .{ .col = 0, .row = 0 }, .{ .col = 1, .row = 1 }, &route));
}

test "a start inside a wall can still find its way out" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, room_text);
    defer map.deinit(allocator);
    const grid = Grid.init(&map);
    var finder = try Pathfinder.init(allocator);
    defer finder.deinit();

    var route: [16]Cell = undefined;
    const count = try finder.find(grid, .{ .col = 3, .row = 2 }, .{ .col = 1, .row = 1 }, &route);
    try std.testing.expect(route[0].eql(.{ .col = 3, .row = 2 }));
    try std.testing.expect(route[count - 1].eql(.{ .col = 1, .row = 1 }));
}

test "a route longer than the buffer is refused, and a start that is also the goal is one cell" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, open_text);
    defer map.deinit(allocator);
    const grid = Grid.init(&map);
    var finder = try Pathfinder.init(allocator);
    defer finder.deinit();

    var short: [3]Cell = undefined;
    try std.testing.expectError(error.PathTooLong, finder.find(grid, .{ .col = 1, .row = 1 }, .{ .col = 4, .row = 1 }, &short));

    var route: [16]Cell = undefined;
    const count = try finder.find(grid, .{ .col = 2, .row = 2 }, .{ .col = 2, .row = 2 }, &route);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expect(route[0].eql(.{ .col = 2, .row = 2 }));
}

test "one finder serves searches on maps of different sizes, one after another" {
    const allocator = std.testing.allocator;
    var finder = try Pathfinder.init(allocator);
    defer finder.deinit();
    var route: [16]Cell = undefined;

    const small = try tilemap.TileMap.parse(allocator, "size 2 1\nsolid 1\nlayer ground\n0 0\n");
    defer small.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), try finder.find(Grid.init(&small), .{ .col = 0, .row = 0 }, .{ .col = 1, .row = 0 }, &route));

    const big = try tilemap.TileMap.parse(allocator, open_text);
    defer big.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), try finder.find(Grid.init(&big), .{ .col = 1, .row = 1 }, .{ .col = 4, .row = 1 }, &route));

    // Back to the small map: the older search's stamps must not leak into this one.
    try std.testing.expectEqual(@as(usize, 2), try finder.find(Grid.init(&small), .{ .col = 0, .row = 0 }, .{ .col = 1, .row = 0 }, &route));
}

test "on a larger map with walls, every route found is valid and joins its two ends" {
    const allocator = std.testing.allocator;
    // A 12 by 12 map with a scattered pattern of walls, built directly so the test needs no text.
    const size = 12;
    var tiles = [_]u8{tilemap.empty} ** (size * size);
    var solid = [_]bool{false} ** 256;
    solid[1] = true;
    for (0..size) |row| {
        for (0..size) |col| {
            if ((col * 7 + row * 3) % 5 == 0 and col % 4 != 0) tiles[row * size + col] = 1;
        }
    }
    const map = tilemap.TileMap{ .cols = size, .rows = size, .tiles = &tiles, .solid = solid };
    const grid = Grid.init(&map);
    var finder = try Pathfinder.init(allocator);
    defer finder.deinit();

    var route: [size * size]Cell = undefined;
    var found: usize = 0;
    for (0..size) |a| {
        for (0..size) |b| {
            const start = grid.cellAt(a * size + b);
            if (!grid.walkable(start)) continue;
            const goal = grid.cellAt((size - 1 - a) * size + (size - 1 - b));
            if (!grid.walkable(goal)) continue;
            if (finder.find(grid, start, goal, &route)) |count| {
                found += 1;
                try std.testing.expect(route[0].eql(start));
                try std.testing.expect(route[count - 1].eql(goal));
                try expectValidRoute(grid, route[0..count]);
            } else |err| {
                try std.testing.expect(err == error.NoPath);
            }
        }
    }
    try std.testing.expect(found > 50);
}
