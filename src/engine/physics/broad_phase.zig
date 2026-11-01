//! Uniform-grid broad phase for static collider slices. Geometry and layers must stay unchanged
//! while the index is in use; rebuild after editing the collider slice.

const std = @import("std");
const shapes = @import("shapes.zig");
const collision = @import("collision.zig");

const Point = shapes.Point;
const Box = shapes.Box;
pub const Collider = collision.Collider;
const all_layers: u32 = std.math.maxInt(u32);

const max_entries = 1_000_000;
const max_query_cells = 65_536;

const Entry = struct {
    x: i32,
    y: i32,
    collider: usize,
};

const Range = struct {
    min_x: i32,
    max_x: i32,
    min_y: i32,
    max_y: i32,
};

pub const Index = struct {
    allocator: std.mem.Allocator,
    colliders: []const Collider,
    entries: []Entry,
    stamps: []u32,
    candidates: []usize,
    cell_size: f32,
    generation: u32 = 0,
    candidate_count: usize = 0,

    pub const InitError = std.mem.Allocator.Error || error{
        InvalidCellSize,
        InvalidColliderBounds,
        TooManyCells,
    };

    /// Builds a spatial grid. Each nonempty collider is inserted into every cell its half-open
    /// bounds touch. The entry limit prevents unexpectedly large colliders from exhausting memory.
    pub fn init(allocator: std.mem.Allocator, colliders: []const Collider, cell_size: f32) InitError!Index {
        if (!std.math.isFinite(cell_size) or cell_size <= 0) return error.InvalidCellSize;
        var entry_count: usize = 0;
        for (colliders) |collider| {
            if (collision.isEmptyBox(collider.box)) continue;
            const range = cellRange(collider.box, cell_size) orelse return error.InvalidColliderBounds;
            entry_count = try addCellCount(entry_count, range);
        }

        const entries = try allocator.alloc(Entry, entry_count);
        errdefer allocator.free(entries);
        const stamps = try allocator.alloc(u32, colliders.len);
        errdefer allocator.free(stamps);
        @memset(stamps, 0);
        const candidates = try allocator.alloc(usize, colliders.len);
        errdefer allocator.free(candidates);

        var cursor: usize = 0;
        for (colliders, 0..) |collider, collider_index| {
            if (collision.isEmptyBox(collider.box)) continue;
            const range = cellRange(collider.box, cell_size).?;
            var y = range.min_y;
            while (y <= range.max_y) : (y += 1) {
                var x = range.min_x;
                while (x <= range.max_x) : (x += 1) {
                    entries[cursor] = .{ .x = x, .y = y, .collider = collider_index };
                    cursor += 1;
                }
            }
        }
        std.mem.sort(Entry, entries, {}, lessEntry);
        return .{
            .allocator = allocator,
            .colliders = colliders,
            .entries = entries,
            .stamps = stamps,
            .candidates = candidates,
            .cell_size = cell_size,
        };
    }

    pub fn deinit(self: *Index) void {
        self.allocator.free(self.entries);
        self.allocator.free(self.stamps);
        self.allocator.free(self.candidates);
        self.* = undefined;
    }

    /// First overlapping collider in original slice order, after layer filtering.
    pub fn firstOverlap(self: *Index, box: Box, mask: u32) ?usize {
        const count = self.collectBox(box);
        var first: ?usize = null;
        for (self.candidates[0..count]) |index| {
            const collider = self.colliders[index];
            if (hits(collider, mask) and collision.boxesOverlap(collider.box, box))
                first = if (first) |found| @min(found, index) else index;
        }
        return first;
    }

    pub fn anyOverlap(self: *Index, box: Box, mask: u32) bool {
        return self.firstOverlap(box, mask) != null;
    }

    /// First collider containing `point`, in original slice order.
    pub fn firstAtPoint(self: *Index, point: Point, mask: u32) ?usize {
        if (!std.math.isFinite(point.x) or !std.math.isFinite(point.y)) return null;
        const x = cellCoordinate(point.x, self.cell_size) orelse return linearPoint(self.colliders, point, mask);
        const y = cellCoordinate(point.y, self.cell_size) orelse return linearPoint(self.colliders, point, mask);
        self.beginQuery();
        self.appendCell(x, y);
        var first: ?usize = null;
        for (self.candidates[0..self.candidate_count]) |index| {
            const collider = self.colliders[index];
            if (hits(collider, mask) and collision.pointInBox(point, collider.box))
                first = if (first) |found| @min(found, index) else index;
        }
        return first;
    }

    /// Writes region-overlapping collider indices in original slice order. Returns the number
    /// written; additional hits are omitted if `out` is too small.
    pub fn queryRegion(self: *Index, region: Box, mask: u32, out: []usize) usize {
        const count = self.collectBox(region);
        std.mem.sort(usize, self.candidates[0..count], {}, std.sort.asc(usize));
        var written: usize = 0;
        for (self.candidates[0..count]) |index| {
            const collider = self.colliders[index];
            if (!hits(collider, mask) or !collision.boxesOverlap(region, collider.box)) continue;
            if (written == out.len) break;
            out[written] = index;
            written += 1;
        }
        return written;
    }

    /// Moves `box` by (dx, dy), resolving X before Y like the slice-based query. Only colliders
    /// intersecting the swept bounds enter the narrow phase.
    pub fn moveBox(self: *Index, box: Box, dx: f32, dy: f32, mask: u32) Point {
        const safe_dx = if (std.math.isFinite(dx)) dx else 0;
        const safe_dy = if (std.math.isFinite(dy)) dy else 0;
        const swept = Box{
            .x = @min(box.x, box.x + safe_dx),
            .y = @min(box.y, box.y + safe_dy),
            .w = box.w + @abs(safe_dx),
            .h = box.h + @abs(safe_dy),
        };
        const count = self.collectBox(swept);
        const candidates = self.candidates[0..count];
        const x = slideX(self.colliders, candidates, box, dx, mask);
        const y = slideY(self.colliders, candidates, .{ .x = x, .y = box.y, .w = box.w, .h = box.h }, dy, mask);
        return .{ .x = x, .y = y };
    }

    fn collectBox(self: *Index, box: Box) usize {
        const range = cellRange(box, self.cell_size) orelse return self.collectAll();
        const width: u64 = @intCast(@as(i64, range.max_x) - range.min_x + 1);
        const height: u64 = @intCast(@as(i64, range.max_y) - range.min_y + 1);
        if (width > max_query_cells or height > max_query_cells or width * height > max_query_cells)
            return self.collectAll();
        self.beginQuery();
        var y = range.min_y;
        while (y <= range.max_y) : (y += 1) {
            var x = range.min_x;
            while (x <= range.max_x) : (x += 1) self.appendCell(x, y);
        }
        return self.candidate_count;
    }

    fn collectAll(self: *Index) usize {
        self.beginQuery();
        for (self.colliders, 0..) |_, index| self.mark(index);
        return self.candidate_count;
    }

    fn beginQuery(self: *Index) void {
        self.generation +%= 1;
        if (self.generation == 0) {
            @memset(self.stamps, 0);
            self.generation = 1;
        }
        self.candidate_count = 0;
    }

    fn mark(self: *Index, collider_index: usize) void {
        if (self.stamps[collider_index] == self.generation) return;
        self.stamps[collider_index] = self.generation;
        self.candidates[self.candidate_count] = collider_index;
        self.candidate_count += 1;
    }

    fn appendCell(self: *Index, x: i32, y: i32) void {
        var cursor = lowerBound(self.entries, x, y);
        while (cursor < self.entries.len and self.entries[cursor].y == y and self.entries[cursor].x == x) : (cursor += 1) {
            self.mark(self.entries[cursor].collider);
        }
    }
};

fn hits(collider: Collider, mask: u32) bool {
    return collider.layer & mask != 0;
}

fn linearPoint(colliders: []const Collider, point: Point, mask: u32) ?usize {
    for (colliders, 0..) |collider, index| {
        if (hits(collider, mask) and collision.pointInBox(point, collider.box)) return index;
    }
    return null;
}

fn rangesOverlap(a: f32, a_len: f32, b: f32, b_len: f32) bool {
    return a < b + b_len and b < a + a_len;
}

fn slideX(colliders: []const Collider, candidates: []const usize, box: Box, dx: f32, mask: u32) f32 {
    if (!std.math.isFinite(dx) or dx == 0) return box.x;
    const target = box.x + dx;
    if (collision.isEmptyBox(box)) return target;
    var result = target;
    for (candidates) |index| {
        const collider = colliders[index];
        if (!hits(collider, mask) or collision.isEmptyBox(collider.box)) continue;
        if (!rangesOverlap(collider.box.y, collider.box.h, box.y, box.h)) continue;
        if (dx > 0) {
            if (collider.box.x >= box.x + box.w and collider.box.x < target + box.w)
                result = @min(result, collider.box.x - box.w);
        } else if (collider.box.x + collider.box.w <= box.x and collider.box.x + collider.box.w > target) {
            result = @max(result, collider.box.x + collider.box.w);
        }
    }
    return result;
}

fn slideY(colliders: []const Collider, candidates: []const usize, box: Box, dy: f32, mask: u32) f32 {
    if (!std.math.isFinite(dy) or dy == 0) return box.y;
    const target = box.y + dy;
    if (collision.isEmptyBox(box)) return target;
    var result = target;
    for (candidates) |index| {
        const collider = colliders[index];
        if (!hits(collider, mask) or collision.isEmptyBox(collider.box)) continue;
        if (!rangesOverlap(collider.box.x, collider.box.w, box.x, box.w)) continue;
        if (dy > 0) {
            if (collider.box.y >= box.y + box.h and collider.box.y < target + box.h)
                result = @min(result, collider.box.y - box.h);
        } else if (collider.box.y + collider.box.h <= box.y and collider.box.y + collider.box.h > target) {
            result = @max(result, collider.box.y + collider.box.h);
        }
    }
    return result;
}

fn cellCoordinate(value: f32, cell_size: f32) ?i32 {
    const coordinate = @floor(value / cell_size);
    if (!std.math.isFinite(coordinate) or coordinate < -1_000_000_000 or coordinate > 1_000_000_000) return null;
    return @intFromFloat(coordinate);
}

fn maxCell(boundary: f32, cell_size: f32) ?i32 {
    const coordinate = @ceil(@as(f64, boundary) / @as(f64, cell_size)) - 1.0;
    if (!std.math.isFinite(coordinate) or coordinate < -1_000_000_000 or coordinate > 1_000_000_000) return null;
    return @intFromFloat(coordinate);
}

fn cellRange(box: Box, cell_size: f32) ?Range {
    if (collision.isEmptyBox(box)) return null;
    const min_x = cellCoordinate(box.x, cell_size) orelse return null;
    const min_y = cellCoordinate(box.y, cell_size) orelse return null;
    const right = box.x + box.w;
    const bottom = box.y + box.h;
    if (!std.math.isFinite(right) or !std.math.isFinite(bottom)) return null;
    const max_x = maxCell(right, cell_size) orelse return null;
    const max_y = maxCell(bottom, cell_size) orelse return null;
    return .{ .min_x = min_x, .max_x = max_x, .min_y = min_y, .max_y = max_y };
}

fn addCellCount(current: usize, range: Range) Index.InitError!usize {
    const width: usize = @intCast(@as(i64, range.max_x) - range.min_x + 1);
    const height: usize = @intCast(@as(i64, range.max_y) - range.min_y + 1);
    const cells = std.math.mul(usize, width, height) catch return error.TooManyCells;
    const total = std.math.add(usize, current, cells) catch return error.TooManyCells;
    if (cells > max_entries or total > max_entries) return error.TooManyCells;
    return total;
}

fn lessEntry(_: void, a: Entry, b: Entry) bool {
    if (a.y != b.y) return a.y < b.y;
    if (a.x != b.x) return a.x < b.x;
    return a.collider < b.collider;
}

fn lowerBound(entries: []const Entry, x: i32, y: i32) usize {
    var low: usize = 0;
    var high = entries.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const entry = entries[middle];
        if (entry.y < y or (entry.y == y and entry.x < x)) low = middle + 1 else high = middle;
    }
    return low;
}

test "grid overlap and point queries preserve slice order and apply layer masks" {
    const colliders = [_]Collider{
        .{ .box = .{ .x = -2, .y = -2, .w = 10, .h = 10 }, .layer = 0b01 },
        .{ .box = .{ .x = 0, .y = 0, .w = 8, .h = 8 }, .layer = 0b10 },
        .{ .box = .{ .x = 30, .y = 30, .w = 1, .h = 1 }, .layer = 0 },
    };
    var index = try Index.init(std.testing.allocator, &colliders, 4);
    defer index.deinit();

    const probe = Box{ .x = 0, .y = 0, .w = 2, .h = 2 };
    try std.testing.expectEqual(@as(?usize, 0), index.firstOverlap(probe, 0b01));
    try std.testing.expectEqual(@as(?usize, 1), index.firstOverlap(probe, 0b10));
    try std.testing.expect(index.anyOverlap(probe, 0b11));
    try std.testing.expectEqual(@as(?usize, 0), index.firstAtPoint(.{ .x = 0, .y = 0 }, 0b01));
    try std.testing.expectEqual(@as(?usize, 1), index.firstAtPoint(.{ .x = 0, .y = 0 }, 0b10));
    try std.testing.expectEqual(@as(?usize, null), index.firstAtPoint(.{ .x = 8, .y = 4 }, all_layers));
}

test "region query deduplicates colliders spanning cells and returns indices in input order" {
    const colliders = [_]Collider{
        .{ .box = .{ .x = -20, .y = -20, .w = 40, .h = 40 }, .layer = 1 },
        .{ .box = .{ .x = 1, .y = 1, .w = 2, .h = 2 }, .layer = 1 },
        .{ .box = .{ .x = 2, .y = 2, .w = 2, .h = 2 }, .layer = 2 },
        .{ .box = .{ .x = 20, .y = 20, .w = 1, .h = 1 }, .layer = 1 },
    };
    var index = try Index.init(std.testing.allocator, &colliders, 4);
    defer index.deinit();
    const region = Box{ .x = 0, .y = 0, .w = 8, .h = 8 };
    var found: [4]usize = undefined;
    const count = index.queryRegion(region, 1, &found);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(usize, 0), found[0]);
    try std.testing.expectEqual(@as(usize, 1), found[1]);
}

test "grid queries handle empty, invalid, and oversized regions without missing hits" {
    const colliders = [_]Collider{
        .{ .box = .{ .x = 100, .y = 100, .w = 1, .h = 1 }, .layer = 1 },
        .{ .box = .{ .x = 0, .y = 0, .w = 0, .h = 1 }, .layer = 1 },
    };
    var index = try Index.init(std.testing.allocator, &colliders, 1);
    defer index.deinit();
    try std.testing.expectEqual(@as(?usize, null), index.firstOverlap(.{ .x = 0, .y = 0, .w = 0, .h = 1 }, all_layers));
    try std.testing.expectEqual(@as(?usize, 0), index.firstOverlap(.{ .x = -1_000_000, .y = 99, .w = 1_000_102, .h = 2 }, all_layers));
    try std.testing.expectEqual(@as(?usize, null), index.firstAtPoint(.{ .x = std.math.nan(f32), .y = 0 }, all_layers));
    try std.testing.expectError(error.InvalidCellSize, Index.init(std.testing.allocator, &colliders, 0));
}

test "indexed movement matches linear movement for diagonal motion and layer masks" {
    const linear = @import("queries.zig");
    const colliders = [_]Collider{
        .{ .box = .{ .x = 50, .y = -20, .w = 10, .h = 60 }, .layer = 1 },
        .{ .box = .{ .x = -20, .y = 50, .w = 100, .h = 10 }, .layer = 1 },
        .{ .box = .{ .x = 80, .y = 80, .w = 10, .h = 10 }, .layer = 2 },
    };
    var index = try Index.init(std.testing.allocator, &colliders, 8);
    defer index.deinit();
    const box = Box{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const expected = linear.moveBox(&colliders, box, 100, 100, 1);
    const actual = index.moveBox(box, 100, 100, 1);
    try std.testing.expectEqual(expected.x, actual.x);
    try std.testing.expectEqual(expected.y, actual.y);
}
