//! A grid of tile IDs with collision. This is pure code with no SDL or logging, so `zig build test`
//! covers it without a window.
//!
//! Map file format, read by `TileMap.parse`:
//!
//!     # Comments start with '#'. Blank lines are ignored.
//!     size <cols> <rows>          required, both at least 1
//!     solid <id> [<id> ...]       optional, any number of lines; these IDs block movement
//!     spawn <col> <row>           required, the cell where the player starts
//!     tiles                       required, after the header
//!     <id> <id> ...               one line per row, each with exactly <cols> IDs
//!
//! An ID is a number from 0 to 255. It picks a tile from the tile texture.

const std = @import("std");

/// Side of one tile, in pixels. Collision and drawing both use it.
pub const tile_size: u32 = 16;
pub const tile_px: f32 = @floatFromInt(tile_size);

pub const ParseError = error{
    /// A line has an unknown keyword, the wrong number of values, or an empty `solid` list.
    BadHeader,
    /// A value is not a number, or an ID is above 255.
    BadNumber,
    /// `size` is missing, or `tiles` comes before it.
    MissingSize,
    /// `spawn` is missing, or `tiles` comes before it.
    MissingSpawn,
    /// There is no `tiles` line.
    MissingTiles,
    /// A row has the wrong number of IDs, or the map has the wrong number of rows.
    BadRow,
    /// The spawn cell is outside the map.
    SpawnOutside,
} || std.mem.Allocator.Error;

/// A cell in the grid.
pub const Cell = struct {
    col: u32,
    row: u32,
};

/// A point in pixels.
pub const Point = struct {
    x: f32,
    y: f32,
};

/// A rectangle in pixels, with its top-left corner at (x, y).
pub const Box = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const TileMap = struct {
    cols: u32,
    rows: u32,
    /// Tile IDs, row by row, top row first. The map owns them. `deinit` frees them.
    tiles: []u8,
    /// Which IDs block movement, indexed by ID.
    solid: [256]bool,
    /// The cell the player starts in.
    spawn: Cell,

    /// Parses the text of a map file. The returned map owns its tiles and must be freed with `deinit`.
    pub fn parse(allocator: std.mem.Allocator, text: []const u8) ParseError!TileMap {
        var map = TileMap{
            .cols = 0,
            .rows = 0,
            .tiles = undefined,
            .solid = [_]bool{false} ** 256,
            .spawn = .{ .col = 0, .row = 0 },
        };
        var have_size = false;
        var have_spawn = false;
        var in_tiles = false;
        var row: u32 = 0;
        // The tile storage is allocated at the `tiles` line, which comes after `size`, so the size is known.
        var storage: []u8 = undefined;
        var allocated = false;
        errdefer {
            if (allocated) allocator.free(storage);
        }

        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;

            if (in_tiles) {
                // Every line after `tiles` is one row of IDs.
                if (row >= map.rows) return error.BadRow;
                var values = std.mem.tokenizeAny(u8, line, " \t");
                var col: u32 = 0;
                while (values.next()) |word| : (col += 1) {
                    if (col >= map.cols) return error.BadRow;
                    const index = @as(usize, row) * @as(usize, map.cols) + @as(usize, col);
                    storage[index] = try parseId(word);
                }
                if (col != map.cols) return error.BadRow;
                row += 1;
                continue;
            }

            var words = std.mem.tokenizeAny(u8, line, " \t");
            const keyword = words.next() orelse continue;
            if (std.mem.eql(u8, keyword, "size")) {
                const cols = try parseCount(words.next());
                const rows = try parseCount(words.next());
                if (words.next() != null or cols == 0 or rows == 0) return error.BadHeader;
                map.cols = cols;
                map.rows = rows;
                have_size = true;
            } else if (std.mem.eql(u8, keyword, "solid")) {
                var any = false;
                while (words.next()) |word| {
                    map.solid[try parseId(word)] = true;
                    any = true;
                }
                if (!any) return error.BadHeader;
            } else if (std.mem.eql(u8, keyword, "spawn")) {
                const col = try parseCount(words.next());
                const spawn_row = try parseCount(words.next());
                if (words.next() != null) return error.BadHeader;
                map.spawn = .{ .col = col, .row = spawn_row };
                have_spawn = true;
            } else if (std.mem.eql(u8, keyword, "tiles")) {
                if (words.next() != null) return error.BadHeader;
                if (!have_size) return error.MissingSize;
                if (!have_spawn) return error.MissingSpawn;
                storage = try allocator.alloc(u8, @as(usize, map.cols) * @as(usize, map.rows));
                allocated = true;
                in_tiles = true;
            } else {
                return error.BadHeader;
            }
        }

        if (!in_tiles) return error.MissingTiles;
        if (row != map.rows) return error.BadRow;
        if (map.spawn.col >= map.cols or map.spawn.row >= map.rows) return error.SpawnOutside;
        map.tiles = storage;
        return map;
    }

    /// Frees the tiles. The map must not be used afterwards.
    pub fn deinit(self: *const TileMap, allocator: std.mem.Allocator) void {
        allocator.free(self.tiles);
    }

    /// The ID at a cell, or null when the cell is outside the map.
    pub fn idAt(self: *const TileMap, col: i32, row: i32) ?u8 {
        if (col < 0 or row < 0) return null;
        const c: u32 = @intCast(col);
        const r: u32 = @intCast(row);
        if (c >= self.cols or r >= self.rows) return null;
        return self.tiles[@as(usize, r) * @as(usize, self.cols) + @as(usize, c)];
    }

    /// True when a cell blocks movement. Cells outside the map are solid, so the map's edge is a wall.
    pub fn isSolid(self: *const TileMap, col: i32, row: i32) bool {
        const id = self.idAt(col, row) orelse return true;
        return self.solid[id];
    }

    /// The largest ID in the map. The game compares it with its tileset, to catch IDs that name no tile.
    pub fn largestId(self: *const TileMap) u8 {
        var largest: u8 = 0;
        for (self.tiles) |id| largest = @max(largest, id);
        return largest;
    }

    /// Moves `box` by (dx, dy), one axis at a time, and returns its new top-left corner. The X move
    /// is resolved first. The Y move starts from the X position the box ended at. A solid cell stops
    /// the box on the axis it blocks, so the box slides along a wall. A box that already overlaps a
    /// solid cell can still move out of it.
    pub fn moveBox(self: *const TileMap, box: Box, dx: f32, dy: f32) Point {
        const x = self.slideX(box, dx);
        const y = self.slideY(.{ .x = x, .y = box.y, .w = box.w, .h = box.h }, dy);
        return .{ .x = x, .y = y };
    }

    /// The X position after moving `box` by `dx`, stopped before the first solid cell in its way.
    fn slideX(self: *const TileMap, box: Box, dx: f32) f32 {
        const target = box.x + dx;
        const top = floorIndex(box.y);
        const bottom = ceilIndex(box.y + box.h) - 1;
        if (dx > 0) {
            // Columns that start at or after the box's right edge, and before the new right edge.
            // Walking right finds the nearest blocker first.
            const first = ceilIndex(box.x + box.w);
            const last = ceilIndex(target + box.w) - 1;
            var col = first;
            while (col <= last) : (col += 1) {
                if (self.anySolidInColumn(col, top, bottom)) return tileEdge(col) - box.w;
            }
        } else if (dx < 0) {
            // Columns that end at or before the box's left edge, and after the new left edge.
            // Walking left finds the nearest blocker first.
            const first = floorIndex(target);
            var col = floorIndex(box.x) - 1;
            while (col >= first) : (col -= 1) {
                if (self.anySolidInColumn(col, top, bottom)) return tileEdge(col + 1);
            }
        }
        return target;
    }

    /// The Y position after moving `box` by `dy`, stopped before the first solid cell in its way.
    fn slideY(self: *const TileMap, box: Box, dy: f32) f32 {
        const target = box.y + dy;
        const left = floorIndex(box.x);
        const right = ceilIndex(box.x + box.w) - 1;
        if (dy > 0) {
            const first = ceilIndex(box.y + box.h);
            const last = ceilIndex(target + box.h) - 1;
            var row = first;
            while (row <= last) : (row += 1) {
                if (self.anySolidInRow(row, left, right)) return tileEdge(row) - box.h;
            }
        } else if (dy < 0) {
            const first = floorIndex(target);
            var row = floorIndex(box.y) - 1;
            while (row >= first) : (row -= 1) {
                if (self.anySolidInRow(row, left, right)) return tileEdge(row + 1);
            }
        }
        return target;
    }

    fn anySolidInColumn(self: *const TileMap, col: i32, top: i32, bottom: i32) bool {
        var row = top;
        while (row <= bottom) : (row += 1) {
            if (self.isSolid(col, row)) return true;
        }
        return false;
    }

    fn anySolidInRow(self: *const TileMap, row: i32, left: i32, right: i32) bool {
        var col = left;
        while (col <= right) : (col += 1) {
            if (self.isSolid(col, row)) return true;
        }
        return false;
    }
};

/// The pixel position of the edge at the start of cell `index`.
fn tileEdge(index: i32) f32 {
    return @as(f32, @floatFromInt(index)) * tile_px;
}

/// The index of the cell that contains `v`.
fn floorIndex(v: f32) i32 {
    return @intFromFloat(@floor(v / tile_px));
}

/// The smallest index `k` with `k * tile_px >= v`. Subtract 1 for the last cell that starts before `v`.
fn ceilIndex(v: f32) i32 {
    return @intFromFloat(@ceil(v / tile_px));
}

fn parseCount(word: ?[]const u8) ParseError!u32 {
    const text = word orelse return error.BadHeader;
    return std.fmt.parseInt(u32, text, 10) catch return error.BadNumber;
}

fn parseId(word: []const u8) ParseError!u8 {
    return std.fmt.parseInt(u8, word, 10) catch return error.BadNumber;
}
