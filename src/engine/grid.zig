//! The walkable cells of a tile map, for paths and sight lines. A cell is walkable when the map does not block
//! it, so the edge of the map counts as a wall. The grid only reads the map, so it is cheap to make one wherever
//! it is needed. It keeps a pointer to the map, so it must not outlive the map, and it should not be stored in a
//! struct that is later moved. Make it where it is used.
//!
//! Pure code with no SDL or logging, so `zig build test` covers it without a window.

const std = @import("std");
const tilemap = @import("../scene/tilemap.zig");

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
