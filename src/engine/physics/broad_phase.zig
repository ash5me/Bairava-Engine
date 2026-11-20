//! Uniform-grid broad phase for static collider slices. Geometry and layers must stay unchanged
//! while the index is in use; rebuild after editing the collider slice.

const std = @import("std");
const shapes = @import("shapes.zig");
const collision = @import("collision.zig");

const Point = shapes.Point;
const Box = shapes.Box;
const OrientedBox = shapes.OrientedBox;
pub const Collider = collision.Collider;
pub const Hit = collision.Hit;
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
            if (collider.circle) |circle| {
                if (collision.isEmptyCircle(circle)) continue;
            } else if (collision.isEmptyBox(collider.box)) continue;
            const bounds = collision.colliderBounds(collider) orelse return error.InvalidColliderBounds;
            const range = cellRange(bounds, cell_size) orelse return error.InvalidColliderBounds;
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
            if (collider.circle) |circle| {
                if (collision.isEmptyCircle(circle)) continue;
            } else if (collision.isEmptyBox(collider.box)) continue;
            const bounds = collision.colliderBounds(collider).?;
            const range = cellRange(bounds, cell_size).?;
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
            if (!collider.enabled or !hits(collider, mask)) continue;
            if (collision.overlapsProbe(collider, box))
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
            if (!collider.enabled or !hits(collider, mask)) continue;
            if (collision.containsPoint(collider, point))
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
            if (!collider.enabled or !hits(collider, mask)) continue;
            if (!collision.overlapsProbe(collider, region)) continue;
            if (written == out.len) break;
            out[written] = index;
            written += 1;
        }
        return written;
    }

    /// First ray hit along the segment from `origin` through `origin + delta`.
    pub fn raycast(self: *Index, origin: Point, delta: Point, mask: u32) ?Hit {
        const count = self.collectRay(origin, delta);
        var closest: ?Hit = null;
        for (self.candidates[0..count]) |index| {
            const collider = self.colliders[index];
            if (!collider.enabled or !hits(collider, mask)) continue;
            const hit = collision.rayVsCollider(index, origin, delta, collider) orelse continue;
            closest = if (closest) |current|
                if (hit.fraction < current.fraction or
                    (hit.fraction == current.fraction and hit.index < current.index)) hit else current
            else
                hit;
        }
        return closest;
    }

    /// Writes ray hits in fraction order, breaking ties by collider index. If `out` is too small,
    /// keeps the nearest hits. Returns the number of hits written.
    pub fn raycastAll(self: *Index, origin: Point, delta: Point, mask: u32, out: []Hit) usize {
        const count = self.collectRay(origin, delta);
        var written: usize = 0;
        for (self.candidates[0..count]) |index| {
            const collider = self.colliders[index];
            if (!collider.enabled or !hits(collider, mask)) continue;
            const hit = collision.rayVsCollider(index, origin, delta, collider) orelse continue;
            var insertion: usize = 0;
            while (insertion < written and hitBeforeOrEqual(out[insertion], hit)) : (insertion += 1) {}
            if (insertion >= out.len) continue;
            const new_written = @min(written + 1, out.len);
            var move = new_written;
            while (move > insertion + 1) : (move -= 1) out[move - 1] = out[move - 2];
            out[insertion] = hit;
            written = new_written;
        }
        return written;
    }

    /// Sweeps an axis-aligned box from its current pose by `delta`.
    pub fn castBox(self: *Index, box: Box, delta: Point, mask: u32) ?Hit {
        const count = self.collectShapeSweep(.{
            .x = @min(box.x, box.x + delta.x),
            .y = @min(box.y, box.y + delta.y),
            .w = box.w + @abs(delta.x),
            .h = box.h + @abs(delta.y),
        });
        var closest: ?Hit = null;
        for (self.candidates[0..count]) |index| {
            const collider = self.colliders[index];
            if (!collider.enabled or !hits(collider, mask)) continue;
            const hit = collision.castBoxVsCollider(index, box, delta, collider) orelse continue;
            closest = if (closest) |current|
                if (hit.fraction < current.fraction or
                    (hit.fraction == current.fraction and hit.index < current.index)) hit else current
            else
                hit;
        }
        return closest;
    }

    /// Sweeps a circle from its current center by `delta`.
    pub fn castCircle(self: *Index, circle: shapes.Circle, delta: Point, mask: u32) ?Hit {
        const count = self.collectShapeSweep(.{
            .x = @min(circle.x, circle.x + delta.x) - circle.r,
            .y = @min(circle.y, circle.y + delta.y) - circle.r,
            .w = 2 * circle.r + @abs(delta.x),
            .h = 2 * circle.r + @abs(delta.y),
        });
        var closest: ?Hit = null;
        for (self.candidates[0..count]) |index| {
            const collider = self.colliders[index];
            if (!collider.enabled or !hits(collider, mask)) continue;
            const hit = collision.castCircleVsCollider(index, circle, delta, collider) orelse continue;
            closest = if (closest) |current|
                if (hit.fraction < current.fraction or
                    (hit.fraction == current.fraction and hit.index < current.index)) hit else current
            else
                hit;
        }
        return closest;
    }

    /// Moves `box` by (dx, dy), resolving X before Y like the slice-based query. Only colliders
    /// intersecting the swept bounds enter the narrow phase.
    pub fn moveBox(self: *Index, box: Box, dx: f32, dy: f32, mask: u32) Point {
        return self.moveBoxWithOneWay(box, dx, dy, mask, false);
    }

    /// Moves like `moveBox`, but ignores axis-aligned one-way tops for this slide only.
    pub fn moveBoxIgnoringOneWay(self: *Index, box: Box, dx: f32, dy: f32, mask: u32) Point {
        return self.moveBoxWithOneWay(box, dx, dy, mask, true);
    }

    fn moveBoxWithOneWay(self: *Index, box: Box, dx: f32, dy: f32, mask: u32, ignore_one_way: bool) Point {
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
        const y = slideY(self.colliders, candidates, .{ .x = x, .y = box.y, .w = box.w, .h = box.h }, dy, mask, ignore_one_way);
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

    fn collectRay(self: *Index, origin: Point, delta: Point) usize {
        if (!std.math.isFinite(origin.x) or !std.math.isFinite(origin.y) or
            !std.math.isFinite(delta.x) or !std.math.isFinite(delta.y)) return self.collectAll();
        const end_x = origin.x + delta.x;
        const end_y = origin.y + delta.y;
        if (!std.math.isFinite(end_x) or !std.math.isFinite(end_y)) return self.collectAll();
        var cell_x = cellCoordinate(origin.x, self.cell_size) orelse return self.collectAll();
        var cell_y = cellCoordinate(origin.y, self.cell_size) orelse return self.collectAll();
        const end_cell_x = cellCoordinate(end_x, self.cell_size) orelse return self.collectAll();
        const end_cell_y = cellCoordinate(end_y, self.cell_size) orelse return self.collectAll();
        const step_x: i32 = if (delta.x > 0) 1 else if (delta.x < 0) -1 else 0;
        const step_y: i32 = if (delta.y > 0) 1 else if (delta.y < 0) -1 else 0;
        const delta_t_x = if (step_x == 0) std.math.inf(f32) else self.cell_size / @abs(delta.x);
        const delta_t_y = if (step_y == 0) std.math.inf(f32) else self.cell_size / @abs(delta.y);
        var max_t_x = if (step_x > 0)
            (@as(f32, @floatFromInt(cell_x + 1)) * self.cell_size - origin.x) / delta.x
        else if (step_x < 0)
            (@as(f32, @floatFromInt(cell_x)) * self.cell_size - origin.x) / delta.x
        else
            std.math.inf(f32);
        var max_t_y = if (step_y > 0)
            (@as(f32, @floatFromInt(cell_y + 1)) * self.cell_size - origin.y) / delta.y
        else if (step_y < 0)
            (@as(f32, @floatFromInt(cell_y)) * self.cell_size - origin.y) / delta.y
        else
            std.math.inf(f32);

        self.beginQuery();
        var visited: usize = 0;
        while (true) {
            visited += 1;
            if (visited > max_query_cells) return self.collectAll();
            self.appendRayNeighborhood(cell_x, cell_y);
            if (cell_x == end_cell_x and cell_y == end_cell_y) break;
            if (max_t_x < max_t_y) {
                cell_x += step_x;
                max_t_x += delta_t_x;
            } else if (max_t_y < max_t_x) {
                cell_y += step_y;
                max_t_y += delta_t_y;
            } else {
                cell_x += step_x;
                cell_y += step_y;
                max_t_x += delta_t_x;
                max_t_y += delta_t_y;
            }
        }
        return self.candidate_count;
    }

    fn appendRayNeighborhood(self: *Index, cell_x: i32, cell_y: i32) void {
        var y_offset: i32 = -1;
        while (y_offset <= 1) : (y_offset += 1) {
            var x_offset: i32 = -1;
            while (x_offset <= 1) : (x_offset += 1) {
                const x = @as(i64, cell_x) + x_offset;
                const y = @as(i64, cell_y) + y_offset;
                if (x < -1_000_000_000 or x > 1_000_000_000 or
                    y < -1_000_000_000 or y > 1_000_000_000) continue;
                self.appendCell(@intCast(x), @intCast(y));
            }
        }
    }

    fn collectShapeSweep(self: *Index, bounds: Box) usize {
        return self.collectBox(.{
            .x = bounds.x - self.cell_size,
            .y = bounds.y - self.cell_size,
            .w = bounds.w + 2 * self.cell_size,
            .h = bounds.h + 2 * self.cell_size,
        });
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

fn hitBeforeOrEqual(a: Hit, b: Hit) bool {
    return a.fraction < b.fraction or (a.fraction == b.fraction and a.index < b.index);
}

fn hits(collider: Collider, mask: u32) bool {
    return collider.layer & mask != 0;
}

fn linearPoint(colliders: []const Collider, point: Point, mask: u32) ?usize {
    for (colliders, 0..) |collider, index| {
        if (!collider.enabled or !hits(collider, mask)) continue;
        if (collision.containsPoint(collider, point)) return index;
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
        if (!collider.enabled or collider.is_trigger or !hits(collider, mask)) continue;
        if (collider.circle) |circle| {
            if (collision.circleStopX(box, dx, circle)) |stop| {
                if (dx > 0 and stop >= box.x and stop < target) {
                    result = @min(result, stop);
                } else if (dx < 0 and stop <= box.x and stop > target) {
                    result = @max(result, stop);
                }
            }
            continue;
        }
        if (collision.isEmptyBox(collider.box)) continue;
        if (collider.one_way and collider.rotation == 0) continue;
        if (collider.rotation != 0) {
            const c_box = OrientedBox{ .x = collider.box.x, .y = collider.box.y, .w = collider.box.w, .h = collider.box.h, .rotation = collider.rotation };
            const start_box = OrientedBox{ .x = box.x, .y = box.y, .w = box.w, .h = box.h, .rotation = 0 };
            if (collision.orientedBoxesOverlap(c_box, start_box)) continue;
            var i: usize = 0;
            var previous: f32 = box.x;
            var first_contact: ?f32 = null;
            while (i <= 128) : (i += 1) {
                const sample = box.x + (target - box.x) * (@as(f32, @floatFromInt(i)) / 128);
                const sample_box = OrientedBox{ .x = sample, .y = box.y, .w = box.w, .h = box.h, .rotation = 0 };
                if (collision.orientedBoxesOverlap(c_box, sample_box)) {
                    first_contact = sample;
                    break;
                }
                previous = sample;
            }
            if (first_contact) |contact| {
                if (dx > 0) {
                    var low = previous;
                    var high = contact;
                    var j: usize = 0;
                    while (j < 32) : (j += 1) {
                        const middle = low + (high - low) / 2;
                        const middle_box = OrientedBox{ .x = middle, .y = box.y, .w = box.w, .h = box.h, .rotation = 0 };
                        if (collision.orientedBoxesOverlap(c_box, middle_box)) high = middle else low = middle;
                    }
                    result = @min(result, low);
                } else {
                    var low = contact;
                    var high = previous;
                    var j: usize = 0;
                    while (j < 32) : (j += 1) {
                        const middle = low + (high - low) / 2;
                        const middle_box = OrientedBox{ .x = middle, .y = box.y, .w = box.w, .h = box.h, .rotation = 0 };
                        if (collision.orientedBoxesOverlap(c_box, middle_box)) low = middle else high = middle;
                    }
                    result = @max(result, high);
                }
            }
            continue;
        }
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

fn slideY(colliders: []const Collider, candidates: []const usize, box: Box, dy: f32, mask: u32, ignore_one_way: bool) f32 {
    if (!std.math.isFinite(dy) or dy == 0) return box.y;
    const target = box.y + dy;
    if (collision.isEmptyBox(box)) return target;
    var result = target;
    for (candidates) |index| {
        const collider = colliders[index];
        if (!collider.enabled or collider.is_trigger or !hits(collider, mask)) continue;
        if (collider.circle) |circle| {
            if (collision.circleStopY(box, dy, circle)) |stop| {
                if (dy > 0 and stop >= box.y and stop < target) {
                    result = @min(result, stop);
                } else if (dy < 0 and stop <= box.y and stop > target) {
                    result = @max(result, stop);
                }
            }
            continue;
        }
        if (collision.isEmptyBox(collider.box)) continue;
        if (collider.one_way and collider.rotation == 0 and (dy < 0 or ignore_one_way)) continue;
        if (collider.rotation != 0) {
            const c_box = OrientedBox{ .x = collider.box.x, .y = collider.box.y, .w = collider.box.w, .h = collider.box.h, .rotation = collider.rotation };
            const start_box = OrientedBox{ .x = box.x, .y = box.y, .w = box.w, .h = box.h, .rotation = 0 };
            if (collision.orientedBoxesOverlap(c_box, start_box)) continue;
            var i: usize = 0;
            var previous: f32 = box.y;
            var first_contact: ?f32 = null;
            while (i <= 128) : (i += 1) {
                const sample = box.y + (target - box.y) * (@as(f32, @floatFromInt(i)) / 128);
                const sample_box = OrientedBox{ .x = box.x, .y = sample, .w = box.w, .h = box.h, .rotation = 0 };
                if (collision.orientedBoxesOverlap(c_box, sample_box)) {
                    first_contact = sample;
                    break;
                }
                previous = sample;
            }
            if (first_contact) |contact| {
                if (dy > 0) {
                    var low = previous;
                    var high = contact;
                    var j: usize = 0;
                    while (j < 32) : (j += 1) {
                        const middle = low + (high - low) / 2;
                        const middle_box = OrientedBox{ .x = box.x, .y = middle, .w = box.w, .h = box.h, .rotation = 0 };
                        if (collision.orientedBoxesOverlap(c_box, middle_box)) high = middle else low = middle;
                    }
                    result = @min(result, low);
                } else {
                    var low = contact;
                    var high = previous;
                    var j: usize = 0;
                    while (j < 32) : (j += 1) {
                        const middle = low + (high - low) / 2;
                        const middle_box = OrientedBox{ .x = box.x, .y = middle, .w = box.w, .h = box.h, .rotation = 0 };
                        if (collision.orientedBoxesOverlap(c_box, middle_box)) low = middle else high = middle;
                    }
                    result = @max(result, high);
                }
            }
            continue;
        }
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

test "indexed movement matches linear one-way collider behavior" {
    const linear = @import("queries.zig");
    const colliders = [_]Collider{
        .{ .box = .{ .x = 20, .y = 50, .w = 20, .h = 10 }, .layer = 1, .one_way = true },
        .{ .box = .{ .x = 20, .y = 80, .w = 20, .h = 10 }, .layer = 1 },
    };
    var index = try Index.init(std.testing.allocator, &colliders, 8);
    defer index.deinit();
    const box = Box{ .x = 25, .y = 30, .w = 10, .h = 20 };
    const expected = linear.moveBox(&colliders, box, 0, 80, 1);
    const actual = index.moveBox(box, 0, 80, 1);
    try std.testing.expectEqual(expected.x, actual.x);
    try std.testing.expectEqual(expected.y, actual.y);
    const drop_expected = linear.moveBoxIgnoringOneWay(&colliders, box, 0, 80, 1);
    const drop_actual = index.moveBoxIgnoringOneWay(box, 0, 80, 1);
    try std.testing.expectEqual(drop_expected.x, drop_actual.x);
    try std.testing.expectEqual(drop_expected.y, drop_actual.y);
}

test "indexed movement ignores trigger colliders but overlap queries include them" {
    const linear = @import("queries.zig");
    const colliders = [_]Collider{
        .{
            .box = .{ .x = 40, .y = 0, .w = 10, .h = 30 },
            .layer = 1,
            .is_trigger = true,
        },
        .{ .box = .{ .x = 70, .y = 0, .w = 10, .h = 30 }, .layer = 1 },
    };
    var index = try Index.init(std.testing.allocator, &colliders, 8);
    defer index.deinit();

    const probe = Box{ .x = 42, .y = 2, .w = 2, .h = 2 };
    try std.testing.expectEqual(@as(?usize, 0), index.firstOverlap(probe, 1));
    const mover = Box{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const expected = linear.moveBox(&colliders, mover, 100, 0, 1);
    const actual = index.moveBox(mover, 100, 0, 1);
    try std.testing.expectEqual(@as(f32, 60), expected.x);
    try std.testing.expectEqual(expected.x, actual.x);
    try std.testing.expectEqual(expected.y, actual.y);
}

test "indexed ray and shape casts match linear queries" {
    const linear = @import("queries.zig");
    const colliders = [_]Collider{
        .{ .box = .{ .x = 40, .y = -5, .w = 10, .h = 10 }, .layer = 1 },
        .{
            .box = .{ .x = 10, .y = -5, .w = 10, .h = 10 },
            .layer = 2,
            .circle = .{ .x = 25, .y = 0, .r = 5 },
        },
        .{ .box = .{ .x = 20, .y = -5, .w = 10, .h = 10 }, .layer = 1 },
        .{ .box = .{ .x = 90, .y = -5, .w = 10, .h = 10 }, .layer = 1 },
    };
    var index = try Index.init(std.testing.allocator, &colliders, 8);
    defer index.deinit();

    const origin = Point{ .x = 0, .y = 0 };
    const delta = Point{ .x = 60, .y = 0 };
    try std.testing.expectEqual(
        linear.raycast(&colliders, origin, delta, all_layers),
        index.raycast(origin, delta, all_layers),
    );
    var linear_hits: [4]Hit = undefined;
    var indexed_hits: [4]Hit = undefined;
    const linear_count = linear.raycastAll(&colliders, origin, delta, all_layers, &linear_hits);
    const indexed_count = index.raycastAll(origin, delta, all_layers, &indexed_hits);
    try std.testing.expectEqual(linear_count, indexed_count);
    for (linear_hits[0..linear_count], indexed_hits[0..indexed_count]) |expected, actual| {
        try std.testing.expectEqual(expected.index, actual.index);
        try std.testing.expectEqual(expected.fraction, actual.fraction);
    }

    const box = Box{ .x = 0, .y = -2, .w = 5, .h = 4 };
    try std.testing.expectEqual(
        linear.castBox(&colliders, box, delta, all_layers),
        index.castBox(box, delta, all_layers),
    );
    const circle = shapes.Circle{ .x = 0, .y = 0, .r = 2 };
    try std.testing.expectEqual(
        linear.castCircle(&colliders, circle, delta, all_layers),
        index.castCircle(circle, delta, all_layers),
    );
}

test "indexed circle queries and movement match the linear collider pipeline" {
    const linear = @import("queries.zig");
    const colliders = [_]Collider{
        .{
            .box = .{ .x = -100, .y = -100, .w = 1, .h = 1 },
            .layer = 1,
            .circle = .{ .x = 50, .y = 13, .r = 5 },
            .one_way = true,
        },
        .{ .box = .{ .x = 70, .y = 0, .w = 10, .h = 40 }, .layer = 1, .one_way = true },
        .{
            .box = .{ .x = 0, .y = 0, .w = 10, .h = 10 },
            .layer = 1,
            .circle = .{ .x = 100, .y = 100, .r = 0 },
        },
    };
    var index = try Index.init(std.testing.allocator, &colliders, 8);
    defer index.deinit();
    const probe = Box{ .x = 45, .y = 8, .w = 2, .h = 2 };
    try std.testing.expectEqual(linear.firstOverlap(&colliders, probe, 1), index.firstOverlap(probe, 1));
    try std.testing.expectEqual(linear.firstAtPoint(&colliders, .{ .x = 50, .y = 13 }, 1), index.firstAtPoint(.{ .x = 50, .y = 13 }, 1));
    try std.testing.expectEqual(@as(?usize, null), index.firstAtPoint(.{ .x = 55, .y = 13 }, 1));
    var linear_indices: [3]usize = undefined;
    var indexed_indices: [3]usize = undefined;
    const linear_count = linear.queryRegion(&colliders, probe, 1, &linear_indices);
    const indexed_count = index.queryRegion(probe, 1, &indexed_indices);
    try std.testing.expectEqual(linear_count, indexed_count);
    try std.testing.expectEqualSlices(usize, linear_indices[0..linear_count], indexed_indices[0..indexed_count]);

    const mover = Box{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const expected = linear.moveBox(&colliders, mover, 100, 0, 1);
    const actual = index.moveBox(mover, 100, 0, 1);
    try std.testing.expectEqual(expected.x, actual.x);
    try std.testing.expectEqual(expected.y, actual.y);
    try std.testing.expectEqual(@as(f32, 36), actual.x);
}

test "indexed diagonal rays collect cells across exact grid corners" {
    const linear = @import("queries.zig");
    const colliders = [_]Collider{
        .{ .box = .{ .x = 20, .y = 20, .w = 8, .h = 8 }, .layer = 1 },
        .{ .box = .{ .x = 40, .y = 40, .w = 8, .h = 8 }, .layer = 1 },
        .{ .box = .{ .x = 5, .y = 25, .w = 8, .h = 8 }, .layer = 1 },
    };
    var index = try Index.init(std.testing.allocator, &colliders, 8);
    defer index.deinit();

    const origin = Point{ .x = 0, .y = 0 };
    const delta = Point{ .x = 56, .y = 56 };
    try std.testing.expectEqual(
        linear.raycast(&colliders, origin, delta, all_layers),
        index.raycast(origin, delta, all_layers),
    );
    const hit = index.raycast(origin, delta, all_layers).?;
    try std.testing.expectEqual(@as(usize, 0), hit.index);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0 / 56.0), hit.fraction, 1e-6);
}

test "indexed circles skip empty shapes and enforce the cell-entry cap" {
    const empty = [_]Collider{.{
        .box = .{ .x = 0, .y = 0, .w = 10, .h = 10 },
        .layer = 1,
        .circle = .{ .x = 0, .y = 0, .r = 0 },
    }};
    var empty_index = try Index.init(std.testing.allocator, &empty, 8);
    defer empty_index.deinit();
    try std.testing.expectEqual(@as(?usize, null), empty_index.firstOverlap(.{ .x = 0, .y = 0, .w = 1, .h = 1 }, all_layers));

    const huge = [_]Collider{.{
        .box = .{ .x = 0, .y = 0, .w = 10, .h = 10 },
        .layer = 1,
        .circle = .{ .x = 0, .y = 0, .r = 10_000 },
    }};
    try std.testing.expectError(error.TooManyCells, Index.init(std.testing.allocator, &huge, 1));
}
