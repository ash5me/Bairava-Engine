//! A grid of tile IDs with collision. This is pure code with no SDL or logging, so `zig build test`
//! covers it without a window.
//!
//! A map has up to three layers: ground, decoration, and foreground. The game draws them in that
//! order, and it draws the player between decoration and foreground, so foreground tiles can cover
//! the player. A cell can hold a tile on each layer. Whether a tile blocks movement depends only on
//! its ID, and a cell blocks movement when any of its layers holds a blocking ID.
//!
//! Map file format, read by `TileMap.parse`:
//!
//!     # Comments start with '#'. Blank lines are ignored.
//!     size <cols> <rows>          required, both at least 1
//!     solid <id> [<id> ...]       optional, any number of lines; these IDs block movement
//!     spawn <col> <row>           required, the cell where the player starts
//!     layer <name>                ground, decoration, or foreground; each name at most once
//!     <entry> <entry> ...         one line per row, each with exactly <cols> entries
//!
//! The header lines (`size`, `solid`, `spawn`) come before the first `layer` line. Every row line
//! belongs to the `layer` line above it. Layers may appear in any order. A layer the file leaves
//! out is empty, but the file needs at least one layer. An entry is a tile ID from 0 to 254, which
//! picks a tile from the tile texture, or `.` for a cell with no tile on that layer.

const std = @import("std");
const shapes = @import("../physics/shapes.zig");

/// Side of one tile, in pixels. Collision and drawing both use it.
pub const tile_size: u32 = 16;
pub const tile_px: f32 = @floatFromInt(tile_size);

/// The entry for a cell with no tile on a layer. Files write it as `.`, so no tile ID equals it.
pub const empty: u8 = 255;

/// The layers of a map, in the order the game draws them.
pub const Layer = enum(u8) {
    ground,
    decoration,
    foreground,
};

/// Every layer, in draw order.
pub const all_layers = [_]Layer{ .ground, .decoration, .foreground };

/// How many layers a map has.
pub const layer_count: usize = all_layers.len;

pub const ParseError = error{
    /// A line has an unknown keyword, the wrong number of values, an empty `solid` list, or a
    /// layer name that is unknown or repeated.
    BadHeader,
    /// A value is not a number, an ID is above 255, or an ID is 255, which means an empty cell.
    BadNumber,
    /// `size` is missing, or a `layer` line comes before it.
    MissingSize,
    /// `spawn` is missing, or a `layer` line comes before it.
    MissingSpawn,
    /// There is no `layer` line.
    MissingLayer,
    /// A row has the wrong number of entries, or a layer has the wrong number of rows.
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
pub const Point = shapes.Point;

/// A rectangle in pixels, with its top-left corner at (x, y).
pub const Box = shapes.Box;

pub const TileMap = struct {
    cols: u32,
    rows: u32,
    /// Entries for every layer, one layer after another in `Layer` order, each row by row, top row
    /// first. An entry is `empty` when its layer has no tile in that cell. The map owns them, and
    /// `deinit` frees them.
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
        // Allocated at the first `layer` line, when the size is known, and freed on any later error.
        var storage: []u8 = undefined;
        var allocated = false;
        errdefer {
            if (allocated) allocator.free(storage);
        }
        var current: ?Layer = null;
        var seen = [_]bool{false} ** layer_count;
        // Rows read so far in the current layer.
        var row: u32 = 0;

        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;

            var words = std.mem.tokenizeAny(u8, line, " \t");
            const keyword = words.next() orelse continue;

            // Inside a layer, every line up to the next `layer` line is one row of entries.
            if (current) |layer| {
                if (!std.mem.eql(u8, keyword, "layer")) {
                    if (row >= map.rows) return error.BadRow;
                    var col: u32 = 0;
                    var entries = std.mem.tokenizeAny(u8, line, " \t");
                    while (entries.next()) |word| : (col += 1) {
                        if (col >= map.cols) return error.BadRow;
                        storage[storageIndex(layer, map.cols, map.rows, col, row)] = try parseEntry(word);
                    }
                    if (col != map.cols) return error.BadRow;
                    row += 1;
                    continue;
                }
            }

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
            } else if (std.mem.eql(u8, keyword, "layer")) {
                // The layer above must have all its rows before the next one starts.
                if (current != null and row != map.rows) return error.BadRow;
                if (!have_size) return error.MissingSize;
                if (!have_spawn) return error.MissingSpawn;
                const layer = try parseLayer(words.next());
                if (words.next() != null) return error.BadHeader;
                if (seen[@intFromEnum(layer)]) return error.BadHeader;
                seen[@intFromEnum(layer)] = true;
                if (!allocated) {
                    const cells = @as(usize, map.cols) * @as(usize, map.rows) * layer_count;
                    storage = try allocator.alloc(u8, cells);
                    allocated = true;
                    @memset(storage, empty);
                }
                current = layer;
                row = 0;
            } else {
                return error.BadHeader;
            }
        }

        if (!allocated) return error.MissingLayer;
        if (current != null and row != map.rows) return error.BadRow;
        if (map.spawn.col >= map.cols or map.spawn.row >= map.rows) return error.SpawnOutside;
        map.tiles = storage;
        return map;
    }

    /// Frees the tiles. The map must not be used afterwards.
    pub fn deinit(self: *const TileMap, allocator: std.mem.Allocator) void {
        allocator.free(self.tiles);
    }

    /// The tile ID on one layer at a cell. Null when the cell is outside the map, or when that
    /// layer has no tile there.
    pub fn idAt(self: *const TileMap, layer: Layer, col: i32, row: i32) ?u8 {
        if (col < 0 or row < 0) return null;
        const c: u32 = @intCast(col);
        const r: u32 = @intCast(row);
        if (c >= self.cols or r >= self.rows) return null;
        const id = self.tiles[storageIndex(layer, self.cols, self.rows, c, r)];
        if (id == empty) return null;
        return id;
    }

    /// True when a cell blocks movement, which happens when any layer in it holds a solid tile.
    /// Cells outside the map are solid, so the map's edge is a wall.
    pub fn isSolid(self: *const TileMap, col: i32, row: i32) bool {
        if (col < 0 or row < 0) return true;
        const c: u32 = @intCast(col);
        const r: u32 = @intCast(row);
        if (c >= self.cols or r >= self.rows) return true;
        for (all_layers) |layer| {
            const id = self.tiles[storageIndex(layer, self.cols, self.rows, c, r)];
            if (id != empty and self.solid[id]) return true;
        }
        return false;
    }

    /// The largest tile ID in the map, ignoring empty cells. The game compares it with its tileset,
    /// to catch IDs that name no tile.
    pub fn largestId(self: *const TileMap) u8 {
        var largest: u8 = 0;
        for (self.tiles) |id| {
            if (id != empty) largest = @max(largest, id);
        }
        return largest;
    }

    /// True when `box` covers any cell that holds a solid tile. A cell outside the map counts as
    /// solid, so a box past the edge overlaps. The player's collision check uses this.
    pub fn boxOverlapsSolid(self: *const TileMap, box: Box) bool {
        const left = floorIndex(box.x);
        const right = ceilIndex(box.x + box.w) - 1;
        const bottom = ceilIndex(box.y + box.h) - 1;
        var row = floorIndex(box.y);
        while (row <= bottom) : (row += 1) {
            if (self.anySolidInRow(row, left, right)) return true;
        }
        return false;
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

/// Where a cell's entry sits in `TileMap.tiles`. Layers are stored one after another, and each
/// layer is stored row by row.
fn storageIndex(layer: Layer, cols: u32, rows: u32, col: u32, row: u32) usize {
    const cells = @as(usize, cols) * @as(usize, rows);
    const offset = @as(usize, @intFromEnum(layer)) * cells;
    return offset + @as(usize, row) * @as(usize, cols) + @as(usize, col);
}

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

fn parseLayer(word: ?[]const u8) ParseError!Layer {
    const name = word orelse return error.BadHeader;
    if (std.mem.eql(u8, name, "ground")) return .ground;
    if (std.mem.eql(u8, name, "decoration")) return .decoration;
    if (std.mem.eql(u8, name, "foreground")) return .foreground;
    return error.BadHeader;
}

/// One entry in a row: `.` for an empty cell, or a tile ID.
fn parseEntry(word: []const u8) ParseError!u8 {
    if (std.mem.eql(u8, word, ".")) return empty;
    return parseId(word);
}

fn parseId(word: []const u8) ParseError!u8 {
    const id = std.fmt.parseInt(u8, word, 10) catch return error.BadNumber;
    if (id == empty) return error.BadNumber;
    return id;
}
