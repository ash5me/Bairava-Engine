//! Queries and movement against a list of static colliders. Slice-based queries are linear; use
//! broad_phase.zig when a static scene needs a spatial index.
//!
//! Detection and response are separate. `firstOverlap` and `anyOverlap` only report. `moveBox` reports
//! where a box ends up, and it never changes a collider.
//!
//! Layers: a query's `mask` is a set of bits. A collider is hit when its layer and the mask share a
//! bit. A collider with layer 0 is hit by no mask.
//!
//! Movement resolves one axis at a time, the way `TileMap.moveBox` does: X first, then Y from the X
//! position the box ended at. Only colliders ahead of the box on the axis of motion can stop it, and
//! the nearest one stops it flush, so the box slides along walls. A box that already overlaps a
//! collider can move out of it. A non-finite delta leaves that axis where it is, and an empty box
//! moves freely. There is no swept test, so a step longer than a collider can pass through it: keep
//! steps shorter than the thinnest collider.

const std = @import("std");
const shapes = @import("shapes.zig");
const collision = @import("collision.zig");

const Point = shapes.Point;
const Box = shapes.Box;
const OrientedBox = shapes.OrientedBox;
pub const Collider = collision.Collider;

pub const OverlapPhase = enum { enter, stay, exit };

/// A discrete overlap transition between collider indices in the source slice.
pub const OverlapEvent = struct {
    phase: OverlapPhase,
    a: usize,
    b: usize,
};

/// A normalized pair of collider indices. `a` is always less than `b`.
pub const OverlapPair = struct {
    a: usize,
    b: usize,
};

/// Counts from one trigger-overlap collection pass. Pair and event counts are totals; dropped
/// fields report how many did not fit in the caller's respective output buffers.
pub const OverlapResult = struct {
    pair_count: usize = 0,
    event_count: usize = 0,
    dropped_pairs: usize = 0,
    dropped_events: usize = 0,
};

/// Collects discrete enter, stay, and exit events for overlapping pairs where at least one
/// collider is a trigger. The caller owns all buffers and should use the current-pair buffer as
/// the previous-pair buffer on the next update. Pair indices refer to this collider slice, so its
/// ordering must remain stable between calls. Pairwise collider layer and mask rules apply.
pub fn collectTriggerEvents(
    colliders: []const Collider,
    previous_pairs: []const OverlapPair,
    current_pairs: []OverlapPair,
    out_events: []OverlapEvent,
) OverlapResult {
    var result = OverlapResult{};
    for (colliders, 0..) |a, a_index| {
        if (!a.enabled) continue;
        for (colliders[a_index + 1 ..], a_index + 1..) |b, b_index| {
            if (!b.enabled or (!a.is_trigger and !b.is_trigger)) continue;
            if (!collision.colliderOverlaps(a, b)) continue;

            const pair = OverlapPair{ .a = a_index, .b = b_index };
            if (result.pair_count < current_pairs.len) {
                current_pairs[result.pair_count] = pair;
            } else {
                result.dropped_pairs += 1;
            }
            result.pair_count += 1;

            const phase: OverlapPhase = if (containsPair(previous_pairs, pair)) .stay else .enter;
            appendOverlapEvent(&result, out_events, .{ .phase = phase, .a = a_index, .b = b_index });
        }
    }

    for (previous_pairs) |pair| {
        if (pair.a >= colliders.len or pair.b >= colliders.len or pair.a >= pair.b) continue;
        if (isCurrentTriggerOverlap(colliders, pair)) continue;
        appendOverlapEvent(&result, out_events, .{ .phase = .exit, .a = pair.a, .b = pair.b });
    }
    return result;
}

fn isCurrentTriggerOverlap(colliders: []const Collider, pair: OverlapPair) bool {
    const a = colliders[pair.a];
    const b = colliders[pair.b];
    return a.enabled and b.enabled and (a.is_trigger or b.is_trigger) and collision.colliderOverlaps(a, b);
}

fn containsPair(pairs: []const OverlapPair, pair: OverlapPair) bool {
    for (pairs) |candidate| {
        if (candidate.a == pair.a and candidate.b == pair.b) return true;
    }
    return false;
}

fn appendOverlapEvent(result: *OverlapResult, out: []OverlapEvent, event: OverlapEvent) void {
    if (result.event_count < out.len) {
        out[result.event_count] = event;
    } else {
        result.dropped_events += 1;
    }
    result.event_count += 1;
}

/// A mask with every bit set, so it hits any collider with a nonzero layer.
pub const all_layers: u32 = std.math.maxInt(u32);

fn hits(c: Collider, mask: u32) bool {
    return c.layer & mask != 0;
}

/// True when the ranges [a, a + a_len) and [b, b + b_len) share some length.
fn rangesOverlap(a: f32, a_len: f32, b: f32, b_len: f32) bool {
    return a < b + b_len and b < a + a_len;
}

/// True when some collider that the mask hits overlaps `box`.
pub fn anyOverlap(colliders: []const Collider, box: Box, mask: u32) bool {
    return firstOverlap(colliders, box, mask) != null;
}

/// The index of the first collider, in slice order, that the mask hits and that overlaps `box`.
pub fn firstOverlap(colliders: []const Collider, box: Box, mask: u32) ?usize {
    for (colliders, 0..) |c, i| {
        if (!c.enabled or !hits(c, mask)) continue;
        if (collision.overlapsProbe(c, box)) return i;
    }
    return null;
}

/// The index of the first collider, in slice order, containing `point` and selected by `mask`.
pub fn firstAtPoint(colliders: []const Collider, point: Point, mask: u32) ?usize {
    for (colliders, 0..) |collider, index| {
        if (!collider.enabled or !hits(collider, mask)) continue;
        if (collision.containsPoint(collider, point)) return index;
    }
    return null;
}

/// Writes region-overlapping collider indices in slice order. Returns the number written;
/// additional hits are omitted when `out` is too small.
pub fn queryRegion(colliders: []const Collider, region: Box, mask: u32, out: []usize) usize {
    var written: usize = 0;
    for (colliders, 0..) |collider, index| {
        if (!collider.enabled or !hits(collider, mask)) continue;
        if (!collision.overlapsProbe(collider, region)) continue;
        if (written == out.len) break;
        out[written] = index;
        written += 1;
    }
    return written;
}

/// Moves `box` by (dx, dy) and returns its new top-left corner. Only colliders the mask hits can stop it.
pub fn moveBox(colliders: []const Collider, box: Box, dx: f32, dy: f32, mask: u32) Point {
    return moveBoxWithOneWay(colliders, box, dx, dy, mask, false);
}

/// Moves like `moveBox`, but ignores axis-aligned one-way tops for this slide only.
pub fn moveBoxIgnoringOneWay(colliders: []const Collider, box: Box, dx: f32, dy: f32, mask: u32) Point {
    return moveBoxWithOneWay(colliders, box, dx, dy, mask, true);
}

fn moveBoxWithOneWay(colliders: []const Collider, box: Box, dx: f32, dy: f32, mask: u32, ignore_one_way: bool) Point {
    const x = slideX(colliders, box, dx, mask);
    const y = slideY(colliders, .{ .x = x, .y = box.y, .w = box.w, .h = box.h }, dy, mask, ignore_one_way);
    return .{ .x = x, .y = y };
}

/// The X position after moving `box` by `dx`, stopped flush against the nearest blocker ahead.
fn slideX(colliders: []const Collider, box: Box, dx: f32, mask: u32) f32 {
    if (!std.math.isFinite(dx) or dx == 0) return box.x;
    const target = box.x + dx;
    if (collision.isEmptyBox(box)) return target;
    var result = target;
    for (colliders) |c| {
        if (!c.enabled or c.is_trigger or !hits(c, mask)) continue;
        if (c.circle) |circle| {
            if (collision.circleStopX(box, dx, circle)) |stop| {
                if (dx > 0 and stop >= box.x and stop < target) {
                    result = @min(result, stop);
                } else if (dx < 0 and stop <= box.x and stop > target) {
                    result = @max(result, stop);
                }
            }
            continue;
        }
        if (collision.isEmptyBox(c.box)) continue;
        if (c.one_way and c.rotation == 0) continue;
        if (c.rotation != 0) {
            const c_box = OrientedBox{ .x = c.box.x, .y = c.box.y, .w = c.box.w, .h = c.box.h, .rotation = c.rotation };
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
                var j: usize = 0;
                if (dx > 0) {
                    var low = previous;
                    var high = contact;
                    while (j < 32) : (j += 1) {
                        const middle = low + (high - low) / 2;
                        const middle_box = OrientedBox{ .x = middle, .y = box.y, .w = box.w, .h = box.h, .rotation = 0 };
                        if (collision.orientedBoxesOverlap(c_box, middle_box)) high = middle else low = middle;
                    }
                    result = @min(result, low);
                } else {
                    var low = contact;
                    var high = previous;
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
        if (!rangesOverlap(c.box.y, c.box.h, box.y, box.h)) continue;
        if (dx > 0) {
            // Ahead of the box, and starting before the box's new right edge. Touching counts as ahead.
            if (c.box.x >= box.x + box.w and c.box.x < target + box.w) {
                result = @min(result, c.box.x - box.w);
            }
        } else {
            // Behind the box, and ending after the box's new left edge.
            if (c.box.x + c.box.w <= box.x and c.box.x + c.box.w > target) {
                result = @max(result, c.box.x + c.box.w);
            }
        }
    }
    return result;
}

/// The Y position after moving `box` by `dy`, stopped flush against the nearest blocker ahead.
fn slideY(colliders: []const Collider, box: Box, dy: f32, mask: u32, ignore_one_way: bool) f32 {
    if (!std.math.isFinite(dy) or dy == 0) return box.y;
    const target = box.y + dy;
    if (collision.isEmptyBox(box)) return target;
    var result = target;
    for (colliders) |c| {
        if (!c.enabled or c.is_trigger or !hits(c, mask)) continue;
        if (c.circle) |circle| {
            if (collision.circleStopY(box, dy, circle)) |stop| {
                if (dy > 0 and stop >= box.y and stop < target) {
                    result = @min(result, stop);
                } else if (dy < 0 and stop <= box.y and stop > target) {
                    result = @max(result, stop);
                }
            }
            continue;
        }
        if (collision.isEmptyBox(c.box)) continue;
        if (c.one_way and c.rotation == 0 and (dy < 0 or ignore_one_way)) continue;
        if (c.rotation != 0) {
            const c_box = OrientedBox{ .x = c.box.x, .y = c.box.y, .w = c.box.w, .h = c.box.h, .rotation = c.rotation };
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
        if (!rangesOverlap(c.box.x, c.box.w, box.x, box.w)) continue;
        if (dy > 0) {
            if (c.box.y >= box.y + box.h and c.box.y < target + box.h) {
                result = @min(result, c.box.y - box.h);
            }
        } else {
            if (c.box.y + c.box.h <= box.y and c.box.y + c.box.h > target) {
                result = @max(result, c.box.y + c.box.h);
            }
        }
    }
    return result;
}

const expectEqual = std.testing.expectEqual;

test "a query hits only colliders whose layer shares a bit with the mask" {
    const walls = [_]Collider{
        .{ .box = .{ .x = 0, .y = 0, .w = 10, .h = 10 }, .layer = 0b01 },
        .{ .box = .{ .x = 20, .y = 0, .w = 10, .h = 10 }, .layer = 0b10 },
    };
    const probe = Box{ .x = 0, .y = 0, .w = 30, .h = 10 };
    try expectEqual(@as(?usize, 0), firstOverlap(&walls, probe, 0b01));
    try expectEqual(@as(?usize, 1), firstOverlap(&walls, probe, 0b10));
    try expectEqual(@as(?usize, 0), firstOverlap(&walls, probe, 0b11));
    try expectEqual(@as(?usize, null), firstOverlap(&walls, probe, 0b100));
}

test "firstOverlap reports the first hit in slice order, and nothing for an empty list" {
    const walls = [_]Collider{
        .{ .box = .{ .x = 0, .y = 0, .w = 10, .h = 10 }, .layer = 1 },
        .{ .box = .{ .x = 5, .y = 0, .w = 10, .h = 10 }, .layer = 1 },
    };
    const probe = Box{ .x = 6, .y = 0, .w = 2, .h = 2 };
    try expectEqual(@as(?usize, 0), firstOverlap(&walls, probe, all_layers));
    const none = [_]Collider{};
    try expectEqual(@as(?usize, null), firstOverlap(&none, probe, all_layers));
    try expectEqual(false, anyOverlap(&none, probe, all_layers));
}

test "point and region list queries honor masks, half-open edges, and output capacity" {
    const colliders = [_]Collider{
        .{ .box = .{ .x = 0, .y = 0, .w = 10, .h = 10 }, .layer = 1 },
        .{ .box = .{ .x = 5, .y = 5, .w = 10, .h = 10 }, .layer = 2 },
        .{ .box = .{ .x = 20, .y = 20, .w = 0, .h = 10 }, .layer = 1 },
    };
    try expectEqual(@as(?usize, 0), firstAtPoint(&colliders, .{ .x = 5, .y = 5 }, 1));
    try expectEqual(@as(?usize, 1), firstAtPoint(&colliders, .{ .x = 10, .y = 10 }, 2));
    try expectEqual(@as(?usize, null), firstAtPoint(&colliders, .{ .x = 10, .y = 5 }, 1));

    var indices: [1]usize = undefined;
    const written = queryRegion(&colliders, .{ .x = 4, .y = 4, .w = 8, .h = 8 }, 0b11, &indices);
    try expectEqual(@as(usize, 1), written);
    try expectEqual(@as(usize, 0), indices[0]);
    try expectEqual(@as(usize, 0), queryRegion(&colliders, .{ .x = 100, .y = 100, .w = 1, .h = 1 }, all_layers, &indices));
}

test "circle colliders use exact narrow-phase queries and ignore their box fields" {
    const colliders = [_]Collider{
        .{
            .box = .{ .x = 0, .y = 0, .w = 10, .h = 10 },
            .layer = 1,
            .mask = 0,
            .circle = .{ .x = 50, .y = 10, .r = 5 },
        },
        .{ .box = .{ .x = 40, .y = 0, .w = 10, .h = 10 }, .layer = 1 },
        .{
            .box = .{ .x = 0, .y = 0, .w = 10, .h = 10 },
            .layer = 1,
            .circle = .{ .x = 100, .y = 100, .r = 0 },
        },
        .{
            .box = .{ .x = 0, .y = 0, .w = 10, .h = 10 },
            .layer = 1,
            .circle = .{ .x = 50, .y = 10, .r = 5 },
            .enabled = false,
        },
    };
    try expectEqual(@as(?usize, 0), firstOverlap(&colliders, .{ .x = 45, .y = 8, .w = 2, .h = 2 }, all_layers));
    try expectEqual(@as(?usize, 1), firstOverlap(&colliders, .{ .x = 41, .y = 1, .w = 2, .h = 2 }, all_layers));
    try expectEqual(@as(?usize, null), firstOverlap(&colliders, .{ .x = 0, .y = 0, .w = 10, .h = 10 }, all_layers));
    try expectEqual(@as(?usize, 0), firstAtPoint(&colliders, .{ .x = 50, .y = 10 }, all_layers));
    try expectEqual(@as(?usize, null), firstAtPoint(&colliders, .{ .x = 55, .y = 10 }, all_layers));
    var indices: [3]usize = undefined;
    try expectEqual(@as(usize, 2), queryRegion(&colliders, .{ .x = 45, .y = 8, .w = 2, .h = 2 }, all_layers, &indices));
    try expectEqual(@as(usize, 0), indices[0]);
    try expectEqual(@as(usize, 1), indices[1]);

    const corner_only = [_]Collider{.{
        .box = .{ .x = 0, .y = 0, .w = 10, .h = 10 },
        .layer = 1,
        .circle = .{ .x = -3, .y = -4, .r = 5 },
    }};
    try expectEqual(@as(?usize, null), firstOverlap(&corner_only, .{ .x = 0, .y = 0, .w = 10, .h = 10 }, all_layers));
}

test "trigger overlaps emit enter stay and exit once per tracked pair" {
    var colliders = [_]Collider{
        .{
            .box = .{ .x = 0, .y = 0, .w = 10, .h = 10 },
            .layer = 1,
            .is_trigger = true,
        },
        .{ .box = .{ .x = 5, .y = 0, .w = 10, .h = 10 }, .layer = 1 },
        .{ .box = .{ .x = 6, .y = 1, .w = 2, .h = 2 }, .layer = 1 },
    };
    var previous: [2]OverlapPair = undefined;
    var current: [2]OverlapPair = undefined;
    var events: [4]OverlapEvent = undefined;

    var result = collectTriggerEvents(&colliders, &.{}, &current, &events);
    try expectEqual(@as(usize, 2), result.pair_count);
    try expectEqual(@as(usize, 2), result.event_count);
    try expectEqual(OverlapEvent{ .phase = .enter, .a = 0, .b = 1 }, events[0]);
    try expectEqual(OverlapEvent{ .phase = .enter, .a = 0, .b = 2 }, events[1]);
    @memcpy(previous[0..result.pair_count], current[0..result.pair_count]);

    result = collectTriggerEvents(&colliders, previous[0..2], &current, &events);
    try expectEqual(@as(usize, 2), result.pair_count);
    try expectEqual(@as(usize, 2), result.event_count);
    try expectEqual(OverlapPhase.stay, events[0].phase);
    try expectEqual(OverlapPhase.stay, events[1].phase);
    @memcpy(previous[0..result.pair_count], current[0..result.pair_count]);

    colliders[1].box.x = 30;
    colliders[2].box.x = 40;
    result = collectTriggerEvents(&colliders, previous[0..2], &current, &events);
    try expectEqual(@as(usize, 0), result.pair_count);
    try expectEqual(@as(usize, 2), result.event_count);
    try expectEqual(OverlapEvent{ .phase = .exit, .a = 0, .b = 1 }, events[0]);
    try expectEqual(OverlapEvent{ .phase = .exit, .a = 0, .b = 2 }, events[1]);
}

test "trigger overlaps require a trigger, enabled colliders, and mutual masks" {
    const colliders = [_]Collider{
        .{ .box = .{ .x = 0, .y = 0, .w = 10, .h = 10 }, .layer = 1, .is_trigger = true },
        .{ .box = .{ .x = 1, .y = 1, .w = 2, .h = 2 }, .layer = 1, .mask = 2 },
        .{ .box = .{ .x = 1, .y = 1, .w = 2, .h = 2 }, .layer = 2, .enabled = false },
        .{ .box = .{ .x = 20, .y = 20, .w = 2, .h = 2 }, .layer = 1 },
        .{ .box = .{ .x = 21, .y = 21, .w = 2, .h = 2 }, .layer = 1 },
    };
    var pairs: [6]OverlapPair = undefined;
    var events: [6]OverlapEvent = undefined;
    const result = collectTriggerEvents(&colliders, &.{}, &pairs, &events);
    try expectEqual(@as(usize, 0), result.pair_count);
    try expectEqual(@as(usize, 0), result.event_count);
}

test "trigger event collection reports undersized output buffers" {
    const colliders = [_]Collider{
        .{ .box = .{ .x = 0, .y = 0, .w = 10, .h = 10 }, .layer = 1, .is_trigger = true },
        .{ .box = .{ .x = 1, .y = 1, .w = 2, .h = 2 }, .layer = 1 },
        .{ .box = .{ .x = 2, .y = 2, .w = 2, .h = 2 }, .layer = 1 },
    };
    var pairs: [1]OverlapPair = undefined;
    var events: [1]OverlapEvent = undefined;
    const result = collectTriggerEvents(&colliders, &.{}, &pairs, &events);
    try expectEqual(@as(usize, 2), result.pair_count);
    try expectEqual(@as(usize, 1), result.dropped_pairs);
    try expectEqual(@as(usize, 2), result.event_count);
    try expectEqual(@as(usize, 1), result.dropped_events);
}

test "trigger colliders remain queryable but never block linear movement" {
    const triggers = [_]Collider{.{
        .box = .{ .x = 40, .y = 0, .w = 10, .h = 30 },
        .layer = 1,
        .is_trigger = true,
    }};
    const probe = Box{ .x = 42, .y = 2, .w = 2, .h = 2 };
    try std.testing.expectEqual(@as(?usize, 0), firstOverlap(&triggers, probe, all_layers));
    try expectEqual(@as(f32, 100), moveBox(&triggers, .{ .x = 0, .y = 0, .w = 10, .h = 10 }, 100, 0, all_layers).x);

    const mixed = [_]Collider{
        triggers[0],
        .{ .box = .{ .x = 70, .y = 0, .w = 10, .h = 30 }, .layer = 1 },
    };
    try expectEqual(@as(f32, 60), moveBox(&mixed, .{ .x = 0, .y = 0, .w = 10, .h = 10 }, 100, 0, all_layers).x);
}

test "moveBox stops flush against the nearest wall on each side" {
    const walls = [_]Collider{
        .{ .box = .{ .x = 100, .y = 0, .w = 10, .h = 100 }, .layer = 1 },
        .{ .box = .{ .x = -10, .y = 0, .w = 10, .h = 100 }, .layer = 1 },
        .{ .box = .{ .x = 0, .y = 100, .w = 100, .h = 10 }, .layer = 1 },
        .{ .box = .{ .x = 0, .y = -10, .w = 100, .h = 10 }, .layer = 1 },
    };
    const b = Box{ .x = 40, .y = 40, .w = 20, .h = 20 };
    const right = moveBox(&walls, b, 200, 0, all_layers);
    try std.testing.expectApproxEqAbs(@as(f32, 80), right.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 40), right.y, 1e-4);
    const left = moveBox(&walls, b, -200, 0, all_layers);
    try std.testing.expectApproxEqAbs(@as(f32, 0), left.x, 1e-4);
    const down = moveBox(&walls, b, 0, 200, all_layers);
    try std.testing.expectApproxEqAbs(@as(f32, 80), down.y, 1e-4);
    const up = moveBox(&walls, b, 0, -200, all_layers);
    try std.testing.expectApproxEqAbs(@as(f32, 0), up.y, 1e-4);
}

test "circle movement stops at exact side and corner tangencies" {
    const side = [_]Collider{.{
        .box = .{ .x = 200, .y = 200, .w = 1, .h = 1 },
        .layer = 1,
        .circle = .{ .x = 50, .y = 10, .r = 5 },
    }};
    const mover = Box{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const side_hit = moveBox(&side, mover, 100, 0, all_layers);
    try expectEqual(@as(f32, 35), side_hit.x);
    try std.testing.expect(!collision.circleOverlapsBox(side[0].circle.?, .{ .x = side_hit.x, .y = mover.y, .w = mover.w, .h = mover.h }));

    const corner = [_]Collider{.{
        .box = .{ .x = 200, .y = 200, .w = 1, .h = 1 },
        .layer = 1,
        .circle = .{ .x = 50, .y = 13, .r = 5 },
    }};
    const corner_hit = moveBox(&corner, mover, 100, 0, all_layers);
    try expectEqual(@as(f32, 36), corner_hit.x);
    try std.testing.expect(!collision.circleOverlapsBox(corner[0].circle.?, .{ .x = corner_hit.x, .y = mover.y, .w = mover.w, .h = mover.h }));

    const vertical_corner = [_]Collider{.{
        .box = .{ .x = 200, .y = 200, .w = 1, .h = 1 },
        .layer = 1,
        .circle = .{ .x = 13, .y = 50, .r = 5 },
    }};
    const vertical_hit = moveBox(&vertical_corner, mover, 0, 100, all_layers);
    try expectEqual(@as(f32, 36), vertical_hit.y);
}

test "circle movement skips distant axes and ignores one-way while preserving start-overlap escape" {
    const distant = [_]Collider{.{
        .box = .{ .x = 500, .y = 500, .w = 1, .h = 1 },
        .layer = 1,
        .circle = .{ .x = 50, .y = 20, .r = 5 },
    }};
    const mover = Box{ .x = 0, .y = 0, .w = 10, .h = 10 };
    try expectEqual(@as(f32, 100), moveBox(&distant, mover, 100, 0, all_layers).x);
    const vertical = [_]Collider{.{
        .box = .{ .x = 500, .y = 500, .w = 1, .h = 1 },
        .layer = 1,
        .circle = .{ .x = 5, .y = 50, .r = 5 },
    }};
    try expectEqual(@as(f32, 35), moveBox(&vertical, mover, 0, 100, all_layers).y);

    const platform = [_]Collider{.{
        .box = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        .layer = 1,
        .circle = .{ .x = 50, .y = 50, .r = 5 },
        .one_way = true,
    }};
    try expectEqual(@as(f32, 35), moveBox(&platform, .{ .x = 45, .y = 20, .w = 10, .h = 10 }, 0, 40, all_layers).y);
    try expectEqual(@as(f32, 35), moveBox(&platform, .{ .x = 0, .y = 45, .w = 10, .h = 10 }, 100, 0, all_layers).x);
    try expectEqual(@as(f32, 35), moveBoxIgnoringOneWay(&platform, .{ .x = 45, .y = 20, .w = 10, .h = 10 }, 0, 40, all_layers).y);

    const empty = [_]Collider{.{
        .box = .{ .x = 50, .y = 0, .w = 10, .h = 10 },
        .layer = 1,
        .circle = .{ .x = 50, .y = 0, .r = std.math.nan(f32) },
    }};
    try expectEqual(@as(f32, 100), moveBox(&empty, mover, 100, 0, all_layers).x);

    const overlap = [_]Collider{.{
        .box = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        .layer = 1,
        .circle = .{ .x = 5, .y = 5, .r = 5 },
    }};
    try expectEqual(@as(f32, 26), moveBox(&overlap, .{ .x = 6, .y = 4, .w = 2, .h = 2 }, 20, 0, all_layers).x);
    try expectEqual(@as(f32, 21), moveBox(&overlap, .{ .x = 1, .y = 4, .w = 2, .h = 2 }, 20, 0, all_layers).x);
}

test "one-way colliders block only downward top-edge motion" {
    const platforms = [_]Collider{
        .{ .box = .{ .x = 20, .y = 50, .w = 20, .h = 10 }, .layer = 1, .one_way = true },
    };
    const above = Box{ .x = 25, .y = 30, .w = 10, .h = 20 };
    try expectEqual(@as(f32, 30), moveBox(&platforms, above, 0, 40, all_layers).y);
    try expectEqual(@as(f32, 20), moveBox(&platforms, .{ .x = 25, .y = 60, .w = 10, .h = 10 }, 0, -40, all_layers).y);
    try expectEqual(@as(f32, 30), moveBox(&platforms, .{ .x = 0, .y = 52, .w = 10, .h = 5 }, 30, 0, all_layers).x);
    try expectEqual(@as(f32, -10), moveBox(&platforms, .{ .x = 40, .y = 52, .w = 10, .h = 5 }, -50, 0, all_layers).x);
    try expectEqual(@as(f32, 40), moveBox(&platforms, .{ .x = 25, .y = 40, .w = 10, .h = 10 }, 0, 1, all_layers).y);
    try expectEqual(@as(f32, 55), moveBox(&platforms, .{ .x = 25, .y = 45, .w = 10, .h = 10 }, 0, 10, all_layers).y);
    try expectEqual(@as(?usize, 0), firstOverlap(&platforms, .{ .x = 25, .y = 52, .w = 2, .h = 2 }, all_layers));
}

test "drop-through ignores one-way tops but not solid colliders" {
    const platforms = [_]Collider{
        .{ .box = .{ .x = 20, .y = 50, .w = 20, .h = 10 }, .layer = 1, .one_way = true },
        .{ .box = .{ .x = 20, .y = 80, .w = 20, .h = 10 }, .layer = 1 },
    };
    const box = Box{ .x = 25, .y = 30, .w = 10, .h = 20 };
    try expectEqual(@as(f32, 60), moveBoxIgnoringOneWay(&platforms, box, 0, 80, all_layers).y);
}

test "a rotated one-way collider remains a full block" {
    const platforms = [_]Collider{
        .{
            .box = .{ .x = 40, .y = 40, .w = 20, .h = 20 },
            .layer = 1,
            .rotation = std.math.pi / 4.0,
            .one_way = true,
        },
    };
    const mover = Box{ .x = 45, .y = 0, .w = 10, .h = 10 };
    const moved = moveBox(&platforms, mover, 0, 100, all_layers);
    try std.testing.expect(moved.y < 100);
    try std.testing.expect(!collision.orientedBoxesOverlap(
        .{ .x = platforms[0].box.x, .y = platforms[0].box.y, .w = platforms[0].box.w, .h = platforms[0].box.h, .rotation = platforms[0].rotation },
        .{ .x = mover.x, .y = moved.y, .w = mover.w, .h = mover.h, .rotation = 0 },
    ));
}

test "the nearest collider stops a move no matter what order the list is in" {
    const near = Collider{ .box = .{ .x = 50, .y = 0, .w = 10, .h = 10 }, .layer = 1 };
    const far = Collider{ .box = .{ .x = 80, .y = 0, .w = 10, .h = 10 }, .layer = 1 };
    const forward = [_]Collider{ far, near };
    const backward = [_]Collider{ near, far };
    const b = Box{ .x = 0, .y = 0, .w = 10, .h = 10 };
    try expectEqual(@as(f32, 40), moveBox(&forward, b, 100, 0, all_layers).x);
    try expectEqual(@as(f32, 40), moveBox(&backward, b, 100, 0, all_layers).x);
}

test "a box already overlapping a collider can move out of it" {
    const wall = [_]Collider{
        .{ .box = .{ .x = 0, .y = 0, .w = 20, .h = 20 }, .layer = 1 },
    };
    const inside = Box{ .x = 5, .y = 5, .w = 10, .h = 10 };
    try std.testing.expectApproxEqAbs(@as(f32, -5), moveBox(&wall, inside, -10, 0, all_layers).x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 15), moveBox(&wall, inside, 10, 0, all_layers).x, 1e-4);
}

test "a collider only stops a box when the mask hits its layer" {
    const wall = [_]Collider{
        .{ .box = .{ .x = 50, .y = 0, .w = 10, .h = 10 }, .layer = 0b10 },
    };
    const b = Box{ .x = 0, .y = 0, .w = 10, .h = 10 };
    try expectEqual(@as(f32, 100), moveBox(&wall, b, 100, 0, 0b01).x);
    try expectEqual(@as(f32, 40), moveBox(&wall, b, 100, 0, 0b10).x);
}

test "a non-finite move leaves its axis alone, and an empty box moves freely" {
    const wall = [_]Collider{
        .{ .box = .{ .x = 50, .y = 0, .w = 10, .h = 10 }, .layer = 1 },
    };
    const b = Box{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const stuck = moveBox(&wall, b, std.math.nan(f32), 0, all_layers);
    try expectEqual(@as(f32, 0), stuck.x);
    try expectEqual(@as(f32, 0), stuck.y);
    const empty = Box{ .x = 0, .y = 0, .w = 0, .h = 10 };
    try expectEqual(@as(f32, 100), moveBox(&wall, empty, 100, 0, all_layers).x);
}

test "identical inputs give identical results" {
    const walls = [_]Collider{
        .{ .box = .{ .x = 30, .y = 30, .w = 10, .h = 10 }, .layer = 1 },
    };
    const b = Box{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const first = moveBox(&walls, b, 13.25, -4.5, all_layers);
    const second = moveBox(&walls, b, 13.25, -4.5, all_layers);
    try expectEqual(first.x, second.x);
    try expectEqual(first.y, second.y);
}

test "rotated point containment is exact and movement uses rotated overlap" {
    const walls = [_]Collider{
        .{ .box = .{ .x = 20, .y = 20, .w = 20, .h = 20 }, .rotation = std.math.pi / 4.0, .layer = 1 },
    };
    try expectEqual(@as(?usize, 0), firstAtPoint(&walls, .{ .x = 30, .y = 30 }, all_layers));
    try expectEqual(@as(?usize, null), firstAtPoint(&walls, .{ .x = 20, .y = 20 }, all_layers));

    const mover = Box{ .x = 0, .y = 20, .w = 10, .h = 10 };
    const moved = moveBox(&walls, mover, 100, 0, all_layers);
    try std.testing.expect(moved.x < 50);
    try std.testing.expect(!collision.orientedBoxesOverlap(
        .{ .x = walls[0].box.x, .y = walls[0].box.y, .w = walls[0].box.w, .h = walls[0].box.h, .rotation = walls[0].rotation },
        .{ .x = moved.x, .y = moved.y, .w = mover.w, .h = mover.h, .rotation = 0 },
    ));
}
