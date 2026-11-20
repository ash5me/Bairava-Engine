//! The walkable cells of a tile map, for paths and sight lines. A cell is walkable when the map does not block
//! it, so the edge of the map counts as a wall. The grid only reads the map, so it is cheap to make one wherever
//! it is needed. It keeps a pointer to the map, so it must not outlive the map, and it should not be stored in a
//! struct that is later moved. Make it where it is used.
//!
//! Pure code with no SDL or logging, so `zig build test` covers it without a window.

const std = @import("std");
const tilemap = @import("../scene/tilemap.zig");

/// Range and facing constraints used before the grid blocker walk.
pub const Sight = struct {
    /// Pixels. A target at exactly this distance is in range. Non-finite means unlimited.
    range: f32 = std.math.inf(f32),
    /// Facing direction in world pixels, with y down. Its length is ignored.
    facing_x: f32 = 0,
    facing_y: f32 = 0,
    /// Half-angle in radians on either side of facing. Pi or more means a full circle.
    half_angle: f32 = std.math.pi,
};

/// True when two finite points are within range. A non-finite range is unlimited.
pub fn inRange(from: tilemap.Point, to: tilemap.Point, range: f32) bool {
    if (!finitePoint(from) or !finitePoint(to)) return false;
    if (!std.math.isFinite(range)) return true;
    if (range < 0) return false;
    const dx = to.x - from.x;
    const dy = to.y - from.y;
    const distance_squared = dx * dx + dy * dy;
    if (!std.math.isFinite(distance_squared)) return false;
    return distance_squared <= range * range;
}

/// True when `to` lies inside the supplied forward cone. Facing length is ignored.
pub fn inCone(from: tilemap.Point, to: tilemap.Point, facing_x: f32, facing_y: f32, half_angle: f32) bool {
    if (!finitePoint(from) or !finitePoint(to) or !std.math.isFinite(half_angle) or half_angle < 0) return false;
    if (half_angle >= std.math.pi) return true;
    const dx = to.x - from.x;
    const dy = to.y - from.y;
    const dist2 = dx * dx + dy * dy;
    if (dist2 == 0) return true;
    if (!std.math.isFinite(facing_x) or !std.math.isFinite(facing_y)) return false;
    const face2 = facing_x * facing_x + facing_y * facing_y;
    if (face2 == 0) return false;
    const dot = facing_x * dx + facing_y * dy;
    const cos_half = @cos(half_angle);
    const threshold = dist2 * face2 * cos_half * cos_half;
    if (cos_half >= 0) {
        return dot >= 0 and dot * dot >= threshold;
    }
    return dot >= 0 or dot * dot <= threshold;
}

fn finitePoint(point: tilemap.Point) bool {
    return std.math.isFinite(point.x) and std.math.isFinite(point.y);
}

/// A cell of the grid, counted from the top-left corner of the map. The fields are signed, so a neighbor past
/// the edge is easy to name. Such a cell is never walkable.
pub const Cell = struct {
    col: i32,
    row: i32,

    pub fn eql(self: Cell, other: Cell) bool {
        return self.col == other.col and self.row == other.row;
    }
};

/// The cell that holds a point, in pixels. A point on a cell's left or top edge belongs to that cell.
pub fn cellOf(point: tilemap.Point) Cell {
    return .{
        .col = @intFromFloat(@floor(point.x / tilemap.tile_px)),
        .row = @intFromFloat(@floor(point.y / tilemap.tile_px)),
    };
}

/// The center of a cell, in pixels.
pub fn cellCenter(cell: Cell) tilemap.Point {
    return .{
        .x = (@as(f32, @floatFromInt(cell.col)) + 0.5) * tilemap.tile_px,
        .y = (@as(f32, @floatFromInt(cell.row)) + 0.5) * tilemap.tile_px,
    };
}

/// Which cells of one tile map a unit can stand on.
pub const Grid = struct {
    map: *const tilemap.TileMap,

    pub fn init(map: *const tilemap.TileMap) Grid {
        return .{ .map = map };
    }

    /// The number of cells: columns times rows.
    pub fn count(self: Grid) usize {
        return @as(usize, self.map.cols) * @as(usize, self.map.rows);
    }

    /// True when the cell lies inside the map.
    pub fn inBounds(self: Grid, cell: Cell) bool {
        return cell.col >= 0 and cell.row >= 0 and
            cell.col < @as(i32, @intCast(self.map.cols)) and
            cell.row < @as(i32, @intCast(self.map.rows));
    }

    /// True when a unit can stand on the cell: it is inside the map, and no solid tile blocks it. Cells outside
    /// the map are solid, so this is false for them.
    pub fn walkable(self: Grid, cell: Cell) bool {
        return !self.map.isSolid(cell.col, cell.row);
    }

    /// The position of a cell in a flat array with one entry per cell, row by row. The cell must be inside the map.
    pub fn index(self: Grid, cell: Cell) usize {
        return @as(usize, @intCast(cell.row)) * @as(usize, self.map.cols) + @as(usize, @intCast(cell.col));
    }

    /// The cell at a position from `index`.
    pub fn cellAt(self: Grid, position: usize) Cell {
        const cols: usize = self.map.cols;
        return .{
            .col = @intCast(position % cols),
            .row = @intCast(position / cols),
        };
    }

    /// True when no solid cell lies on the straight line from `from` to `to`, both in pixels. Every cell the line
    /// crosses is checked in order, so a thin wall can't be stepped past at a corner. The walk is Amanatides and
    /// Woo's grid traversal: it moves from one cell edge along the line to the next.
    pub fn lineOfSight(self: Grid, from: tilemap.Point, to: tilemap.Point) bool {
        const size = tilemap.tile_px;
        const dx = to.x - from.x;
        const dy = to.y - from.y;
        var cell = cellOf(from);
        const end = cellOf(to);

        // Cells still to enter along each axis. An axis with none left is never stepped again, so the walk
        // ends exactly on the end cell even when rounding would put an edge crossing on the wrong side.
        var left_x: u32 = @abs(end.col - cell.col);
        var left_y: u32 = @abs(end.row - cell.row);
        const step_x: i32 = if (dx > 0) 1 else if (dx < 0) -1 else 0;
        const step_y: i32 = if (dy > 0) 1 else if (dy < 0) -1 else 0;

        // Along the line, `next_*` is the fraction of the way from `from` (0) to `to` (1) where the walk next
        // crosses a cell edge on that axis, and `delta_*` is the fraction between two such crossings. An axis
        // that does not move never crosses, so its values stay infinite.
        var next_x: f32 = std.math.inf(f32);
        var delta_x: f32 = std.math.inf(f32);
        if (step_x != 0) {
            const edge = if (step_x > 0) cell.col + 1 else cell.col;
            next_x = (@as(f32, @floatFromInt(edge)) * size - from.x) / dx;
            delta_x = size / @abs(dx);
        }
        var next_y: f32 = std.math.inf(f32);
        var delta_y: f32 = std.math.inf(f32);
        if (step_y != 0) {
            const edge = if (step_y > 0) cell.row + 1 else cell.row;
            next_y = (@as(f32, @floatFromInt(edge)) * size - from.y) / dy;
            delta_y = size / @abs(dy);
        }

        while (true) {
            if (!self.walkable(cell)) return false;
            if (left_x == 0 and left_y == 0) return true;
            // Cross whichever edge the line reaches first, unless that axis has no cells left to enter.
            if (left_y == 0 or (left_x != 0 and next_x < next_y)) {
                cell.col += step_x;
                left_x -= 1;
                next_x += delta_x;
            } else {
                cell.row += step_y;
                left_y -= 1;
                next_y += delta_y;
            }
        }
    }

    /// Applies finite-point, range, and cone filters before the unchanged walkability test.
    pub fn perceive(self: Grid, from: tilemap.Point, to: tilemap.Point, sight: Sight) bool {
        if (!finitePoint(from) or !finitePoint(to)) return false;
        if (!inRange(from, to, sight.range)) return false;
        if (!inCone(from, to, sight.facing_x, sight.facing_y, sight.half_angle)) return false;
        return self.lineOfSight(from, to);
    }
};

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

test "a cell is walkable when open floor lies inside the map, and the map's edge is a wall" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, room_text);
    defer map.deinit(allocator);
    const grid = Grid.init(&map);
    try std.testing.expect(grid.walkable(.{ .col = 1, .row = 1 }));
    try std.testing.expect(!grid.walkable(.{ .col = 3, .row = 2 }));
    try std.testing.expect(!grid.walkable(.{ .col = 0, .row = 1 }));
    try std.testing.expect(!grid.walkable(.{ .col = -1, .row = 1 }));
    try std.testing.expect(!grid.walkable(.{ .col = 6, .row = 1 }));
    try std.testing.expect(grid.inBounds(.{ .col = 5, .row = 5 }));
    try std.testing.expect(!grid.inBounds(.{ .col = 6, .row = 5 }));
}

test "cell indices run row by row, and cellAt inverts index" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, room_text);
    defer map.deinit(allocator);
    const grid = Grid.init(&map);
    try std.testing.expectEqual(@as(usize, 36), grid.count());
    try std.testing.expectEqual(@as(usize, 8), grid.index(.{ .col = 2, .row = 1 }));
    try std.testing.expect(grid.cellAt(8).eql(.{ .col = 2, .row = 1 }));
    try std.testing.expect(grid.cellAt(grid.index(.{ .col = 5, .row = 4 })).eql(.{ .col = 5, .row = 4 }));
}

test "points belong to the cell that holds them, and cell centers map back to their cell" {
    try std.testing.expect(cellOf(.{ .x = 0, .y = 0 }).eql(.{ .col = 0, .row = 0 }));
    try std.testing.expect(cellOf(.{ .x = 15.9, .y = 16 }).eql(.{ .col = 0, .row = 1 }));
    try std.testing.expect(cellOf(.{ .x = -0.5, .y = 0 }).eql(.{ .col = -1, .row = 0 }));
    const center = cellCenter(.{ .col = 3, .row = 2 });
    try std.testing.expectApproxEqAbs(@as(f32, 56), center.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 40), center.y, 1e-4);
    try std.testing.expect(cellOf(center).eql(.{ .col = 3, .row = 2 }));
}

test "line of sight is clear along open floor and blocked by a wall in the way" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, room_text);
    defer map.deinit(allocator);
    const grid = Grid.init(&map);
    // Along row 1, which is open from column 1 to column 4.
    try std.testing.expect(grid.lineOfSight(.{ .x = 24, .y = 24 }, .{ .x = 72, .y = 24 }));
    // Down column 1, which is open from row 1 to row 4.
    try std.testing.expect(grid.lineOfSight(.{ .x = 24, .y = 24 }, .{ .x = 24, .y = 72 }));
    // Along row 2, the wall at column 3 stands between the two points.
    try std.testing.expect(!grid.lineOfSight(.{ .x = 24, .y = 40 }, .{ .x = 72, .y = 40 }));
    // Looking out past the edge of the map is blocked by the border.
    try std.testing.expect(!grid.lineOfSight(.{ .x = 24, .y = 24 }, .{ .x = -24, .y = 24 }));
    // Two points in one open cell always see each other.
    try std.testing.expect(grid.lineOfSight(.{ .x = 20, .y = 20 }, .{ .x = 28, .y = 28 }));
}

test "a diagonal line of sight is blocked by a wall it crosses, and not by open cells beside it" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, room_text);
    defer map.deinit(allocator);
    const grid = Grid.init(&map);
    // From cell (1, 1) to cell (4, 3). The line passes through cells (2, 1), (2, 2), and then the wall at (3, 2).
    try std.testing.expect(!grid.lineOfSight(.{ .x = 24, .y = 24 }, .{ .x = 72, .y = 56 }));
    // From cell (1, 1) to cell (4, 4). The line passes (2, 2) and (3, 3), which are open, and never touches (3, 2).
    try std.testing.expect(grid.lineOfSight(.{ .x = 24, .y = 24 }, .{ .x = 72, .y = 72 }));
}

test "default perception preserves LOS cell traversal and corner tie-breaking" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, room_text);
    defer map.deinit(allocator);
    const grid = Grid.init(&map);
    const cases = [_]struct { from: tilemap.Point, to: tilemap.Point }{
        .{ .from = .{ .x = 24, .y = 24 }, .to = .{ .x = 72, .y = 24 } },
        .{ .from = .{ .x = 24, .y = 24 }, .to = .{ .x = 24, .y = 72 } },
        .{ .from = .{ .x = 24, .y = 40 }, .to = .{ .x = 72, .y = 40 } },
        .{ .from = .{ .x = 24, .y = 24 }, .to = .{ .x = -24, .y = 24 } },
        .{ .from = .{ .x = 20, .y = 20 }, .to = .{ .x = 28, .y = 28 } },
        .{ .from = .{ .x = 24, .y = 24 }, .to = .{ .x = 72, .y = 56 } },
        .{ .from = .{ .x = 24, .y = 24 }, .to = .{ .x = 72, .y = 72 } },
    };
    for (cases) |case| try std.testing.expectEqual(
        grid.lineOfSight(case.from, case.to),
        grid.perceive(case.from, case.to, .{}),
    );
}

test "range and cone filters include their boundaries and reject invalid inputs" {
    const origin = tilemap.Point{ .x = 24, .y = 24 };
    try std.testing.expect(inRange(origin, .{ .x = 72, .y = 24 }, 88));
    try std.testing.expect(inRange(origin, .{ .x = 112, .y = 24 }, 88));
    try std.testing.expect(!inRange(origin, .{ .x = 72, .y = 24 }, 40));
    try std.testing.expect(inRange(origin, origin, 0));
    try std.testing.expect(!inRange(origin, .{ .x = 25, .y = 24 }, -1));
    try std.testing.expect(!inRange(origin, .{ .x = std.math.nan(f32), .y = 24 }, std.math.inf(f32)));

    const right = tilemap.Point{ .x = 72, .y = 24 };
    const up = tilemap.Point{ .x = 24, .y = 0 };
    const left = tilemap.Point{ .x = -24, .y = 24 };
    const half = std.math.pi / 2.0;
    try std.testing.expect(inCone(origin, right, 1, 0, half));
    try std.testing.expect(inCone(origin, up, 1, 0, half));
    try std.testing.expect(!inCone(origin, left, 1, 0, half));
    try std.testing.expect(inCone(origin, left, 0, 0, std.math.pi));
    try std.testing.expect(!inCone(origin, right, 0, 0, 0));
    try std.testing.expect(inCone(origin, origin, 0, 0, 0));
    try std.testing.expect(!inCone(origin, right, 1, 0, std.math.nan(f32)));
    try std.testing.expect(!inCone(origin, right, 1, 0, -0.1));
}

test "perception rejects invalid points and filters distance before LOS" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, room_text);
    defer map.deinit(allocator);
    const grid = Grid.init(&map);
    const from = tilemap.Point{ .x = 24, .y = 24 };
    try std.testing.expect(!grid.perceive(from, .{ .x = 72, .y = 24 }, .{ .range = 40 }));
    try std.testing.expect(!grid.perceive(from, .{ .x = std.math.nan(f32), .y = 24 }, .{}));
    try std.testing.expect(!grid.perceive(.{ .x = 56, .y = 40 }, .{ .x = 56, .y = 40 }, .{ .range = 0 }));
    try std.testing.expect(grid.perceive(.{ .x = 24, .y = 24 }, .{ .x = 24, .y = 24 }, .{ .range = 0, .half_angle = 0 }));
    try std.testing.expect(!grid.perceive(from, .{ .x = 72, .y = 24 }, .{ .range = -1 }));
    try std.testing.expect(!grid.perceive(from, .{ .x = 72, .y = 24 }, .{ .half_angle = -1 }));

    const wide_map = try tilemap.TileMap.parse(
        allocator,
        "size 10 3\nsolid 1\nlayer ground\n1 1 1 1 1 1 1 1 1 1\n1 0 0 0 0 0 0 0 0 1\n1 1 1 1 1 1 1 1 1 1\n",
    );
    defer wide_map.deinit(allocator);
    const wide_grid = Grid.init(&wide_map);
    try std.testing.expect(wide_grid.perceive(from, .{ .x = 112, .y = 24 }, .{ .range = 88 }));
    try std.testing.expect(!wide_grid.perceive(from, .{ .x = 112.01, .y = 24 }, .{ .range = 88 }));
}

test "one-way tiles do not block perception" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(
        allocator,
        "size 6 2\nsolid 1\noneway 2\nlayer ground\n1 1 1 1 1 1\n1 0 2 0 0 1\n",
    );
    defer map.deinit(allocator);
    const grid = Grid.init(&map);
    try std.testing.expect(grid.perceive(.{ .x = 24, .y = 24 }, .{ .x = 72, .y = 24 }, .{}));
}
