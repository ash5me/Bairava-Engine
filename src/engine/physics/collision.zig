//! Overlap tests for points, boxes, and circles. This is detection only: these functions say whether
//! shapes overlap and never move anything. Pure code with no SDL, no rendering, no tile map, and no
//! ECS, so it runs in tests without a window.
//!
//! Edges follow shapes.zig: a box's right and bottom edges are outside it, so touching edges do not
//! overlap. Empty shapes overlap nothing.

const std = @import("std");
const shapes = @import("shapes.zig");

const Point = shapes.Point;
const Box = shapes.Box;
const Circle = shapes.Circle;
const OrientedBox = shapes.OrientedBox;

/// A static collider: a box that queries and movement can hit. `layer` is a set of bits, and one
/// collider can belong to several layers. See queries.zig for how masks select layers.
pub const Collider = struct {
    box: Box,
    layer: u32,
    mask: u32 = std.math.maxInt(u32),
    rotation: f32 = 0,
    enabled: bool = true,
};

/// A collision shape attached to an ECS row.
/// `layer` identifies which collision groups this component belongs to.
/// `mask` identifies which layers this component may overlap or be queried against.
pub const Component = struct {
    box: Box,
    layer: u32 = 0,
    mask: u32 = std.math.maxInt(u32),
    rotation: f32 = 0,
    enabled: bool = true,

    pub fn collider(self: Component) Collider {
        return .{
            .box = self.box,
            .layer = self.layer,
            .mask = self.mask,
            .rotation = self.rotation,
            .enabled = self.enabled,
        };
    }
};

/// Copies enabled collision components from an ECS world into a caller-owned collider slice.
/// Rows may use AoS or SoA storage. The world is traversed by dense row index, so stale handles
/// and row moves cannot expose removed components. The row must contain a field named `collision`
/// whose type is Component, or exactly one field of type Component.
pub fn collidersFromWorld(world: anytype, out: []Collider) usize {
    var written: usize = 0;
    var index: usize = 0;
    while (index < world.count() and written < out.len) : (index += 1) {
        const row = world.rows.get(index);
        const Row = @TypeOf(row);
        inline for (std.meta.fields(Row)) |field| {
            if (written >= out.len) break;
            if (field.type != Component and !std.mem.eql(u8, field.name, "collision")) continue;
            if (field.type == Component) {
                const component = @field(row, field.name);
                if (component.enabled) out[written] = component.collider();
                written += if (component.enabled) @as(usize, 1) else 0;
            }
        }
    }
    return written;
}

/// True when the box has no area, or one of its values is not finite.
pub fn isEmptyBox(box: Box) bool {
    return !finite4(box.x, box.y, box.w, box.h) or box.w <= 0 or box.h <= 0;
}

/// True when the circle has no area, or its radius is not finite or not positive.
pub fn isEmptyCircle(c: Circle) bool {
    return !(std.math.isFinite(c.x) and std.math.isFinite(c.y) and std.math.isFinite(c.r)) or c.r <= 0;
}

/// True when the point lies inside the box. The left and top edges are inside, and the right and
/// bottom edges are not.
pub fn pointInBox(p: Point, box: Box) bool {
    if (isEmptyBox(box) or !(std.math.isFinite(p.x) and std.math.isFinite(p.y))) return false;
    return p.x >= box.x and p.x < box.x + box.w and p.y >= box.y and p.y < box.y + box.h;
}

/// True when a point lies inside an oriented rectangle. Edge rules match pointInBox: left and
/// top are inclusive, right and bottom are exclusive in the box's local coordinate space.
pub fn pointInOrientedBox(p: Point, box: OrientedBox) bool {
    if (!std.math.isFinite(box.rotation) or !(std.math.isFinite(p.x) and std.math.isFinite(p.y)) or
        box.w <= 0 or box.h <= 0 or
        !(std.math.isFinite(box.x) and std.math.isFinite(box.y) and
            std.math.isFinite(box.w) and std.math.isFinite(box.h))) return false;

    const center = Point{ .x = box.x + box.w / 2, .y = box.y + box.h / 2 };
    const cosine = @cos(box.rotation);
    const sine = @sin(box.rotation);
    const dx = p.x - center.x;
    const dy = p.y - center.y;
    // Unrotate clockwise screen-space coordinates around the center.
    const local_x = dx * cosine + dy * sine;
    const local_y = -dx * sine + dy * cosine;
    return local_x >= -box.w / 2 and local_x < box.w / 2 and
        local_y >= -box.h / 2 and local_y < box.h / 2;
}

/// True when two boxes share some area. Boxes that only touch along an edge or a corner do not.
pub fn boxesOverlap(a: Box, b: Box) bool {
    if (isEmptyBox(a) or isEmptyBox(b)) return false;
    return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h;
}

/// True when two rectangles overlap, treating either rectangle's rotation in radians as a
/// clockwise rotation around its center. This uses the separating-axis theorem and is exact
/// for rectangular boxes; it does not use an oversized axis-aligned approximation.
pub fn orientedBoxesOverlap(a: OrientedBox, b: OrientedBox) bool {
    if (!std.math.isFinite(a.rotation) or !std.math.isFinite(b.rotation) or
        a.w <= 0 or a.h <= 0 or b.w <= 0 or b.h <= 0 or
        !(std.math.isFinite(a.x) and std.math.isFinite(a.y) and std.math.isFinite(a.w) and std.math.isFinite(a.h) and
            std.math.isFinite(b.x) and std.math.isFinite(b.y) and std.math.isFinite(b.w) and std.math.isFinite(b.h)))
        return false;

    const a_axes = boxAxes(a);
    const b_axes = boxAxes(b);
    const a_center = Point{ .x = a.x + a.w / 2, .y = a.y + a.h / 2 };
    const b_center = Point{ .x = b.x + b.w / 2, .y = b.y + b.h / 2 };

    const axes = [4][2]f32{ a_axes[0], a_axes[1], b_axes[0], b_axes[1] };
    for (axes) |axis| {
        const length_squared = axis[0] * axis[0] + axis[1] * axis[1];
        if (length_squared <= 0) continue;
        const a_radius = absProjection(a, axis) / std.math.sqrt(length_squared);
        const b_radius = absProjection(b, axis) / std.math.sqrt(length_squared);
        const center_delta = .{
            b_center.x - a_center.x,
            b_center.y - a_center.y,
        };
        const center_distance = @abs(dot(center_delta, axis)) / std.math.sqrt(length_squared);
        if (center_distance >= a_radius + b_radius) return false;
    }
    return true;
}

/// Overlap test for two collider components. Disabled colliders and empty boxes overlap nothing;
/// membership and mask bits must both match on the pair.
pub fn colliderOverlaps(a: Collider, b: Collider) bool {
    if (!a.enabled or !b.enabled) return false;
    const layers_match =
        (a.layer & b.mask != 0) and (b.layer & a.mask != 0);
    if (!layers_match) return false;
    const a_box = OrientedBox{ .x = a.box.x, .y = a.box.y, .w = a.box.w, .h = a.box.h, .rotation = a.rotation };
    const b_box = OrientedBox{ .x = b.box.x, .y = b.box.y, .w = b.box.w, .h = b.box.h, .rotation = b.rotation };
    return orientedBoxesOverlap(a_box, b_box);
}

/// The axis-aligned bounds that contain a box at its current rotation. Suitable for spatial-grid
/// insertion and broad-phase culling.
pub fn boundingBox(box: Box, rotation: f32) ?Box {
    if (isEmptyBox(box) or !std.math.isFinite(rotation)) return null;
    const center = Point{ .x = box.x + box.w / 2, .y = box.y + box.h / 2 };
    const cosine = @cos(rotation);
    const sine = @sin(rotation);
    var min_x: f32 = std.math.inf(f32);
    var max_x: f32 = -std.math.inf(f32);
    var min_y: f32 = std.math.inf(f32);
    var max_y: f32 = -std.math.inf(f32);
    const sx = [_]f32{ -box.w / 2, box.w / 2 };
    const sy = [_]f32{ -box.h / 2, box.h / 2 };
    for (sx) |x| {
        for (sy) |y| {
            // Clockwise screen-space rotation maps local +y down, matching the renderer.
            const world_x = center.x + x * cosine - y * sine;
            const world_y = center.y + x * sine + y * cosine;
            min_x = @min(min_x, world_x);
            max_x = @max(max_x, world_x);
            min_y = @min(min_y, world_y);
            max_y = @max(max_y, world_y);
        }
    }
    if (!(std.math.isFinite(min_x) and std.math.isFinite(max_x) and std.math.isFinite(min_y) and std.math.isFinite(max_y))) return null;
    return .{ .x = min_x, .y = min_y, .w = max_x - min_x, .h = max_y - min_y };
}

fn boxAxes(box: OrientedBox) [2][2]f32 {
    const cosine = @cos(box.rotation);
    const sine = @sin(box.rotation);
    return .{
        .{ cosine, sine },
        .{ -sine, cosine },
    };
}

fn absProjection(box: OrientedBox, axis: [2]f32) f32 {
    const center = Point{ .x = box.x + box.w / 2, .y = box.y + box.h / 2 };
    const center_value = dot(.{ center.x, center.y }, axis);
    _ = center_value;
    const half_w = box.w / 2;
    const half_h = box.h / 2;
    return @abs(axis[0] * half_w * @cos(box.rotation) + axis[1] * half_w * @sin(box.rotation)) +
        @abs(axis[0] * -half_h * @sin(box.rotation) + axis[1] * half_h * @cos(box.rotation));
}

fn dot(a: [2]f32, b: [2]f32) f32 {
    return a[0] * b[0] + a[1] * b[1];
}

/// True when two circles overlap. Circles that only touch do not.
pub fn circlesOverlap(a: Circle, b: Circle) bool {
    if (isEmptyCircle(a) or isEmptyCircle(b)) return false;
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    const reach = a.r + b.r;
    return dx * dx + dy * dy < reach * reach;
}

/// True when a circle and a box overlap. The box point nearest the circle's center decides it, so a
/// circle that only touches the box's edge or corner does not overlap.
pub fn circleOverlapsBox(c: Circle, box: Box) bool {
    if (isEmptyCircle(c) or isEmptyBox(box)) return false;
    const nearest_x = std.math.clamp(c.x, box.x, box.x + box.w);
    const nearest_y = std.math.clamp(c.y, box.y, box.y + box.h);
    const dx = c.x - nearest_x;
    const dy = c.y - nearest_y;
    return dx * dx + dy * dy < c.r * c.r;
}

fn finite4(a: f32, b: f32, c: f32, d: f32) bool {
    return std.math.isFinite(a) and std.math.isFinite(b) and std.math.isFinite(c) and std.math.isFinite(d);
}

const expect = std.testing.expect;

test "boxes that only touch along an edge or corner do not overlap" {
    const a = Box{ .x = 0, .y = 0, .w = 16, .h = 16 };
    try expect(!boxesOverlap(a, .{ .x = 16, .y = 0, .w = 16, .h = 16 }));
    try expect(!boxesOverlap(a, .{ .x = 0, .y = 16, .w = 16, .h = 16 }));
    try expect(!boxesOverlap(a, .{ .x = 16, .y = 16, .w = 16, .h = 16 }));
    try expect(boxesOverlap(a, .{ .x = 15.5, .y = 0, .w = 16, .h = 16 }));
}

test "boxes overlap when they share area, including one inside another" {
    const big = Box{ .x = 0, .y = 0, .w = 100, .h = 100 };
    try expect(boxesOverlap(big, .{ .x = 40, .y = 40, .w = 5, .h = 5 }));
    try expect(!boxesOverlap(big, .{ .x = 100, .y = 0, .w = 5, .h = 5 }));
    try expect(!boxesOverlap(big, .{ .x = 200, .y = 200, .w = 5, .h = 5 }));
}

test "negative coordinates overlap the same way as positive ones" {
    try expect(boxesOverlap(.{ .x = -20, .y = -20, .w = 10, .h = 10 }, .{ .x = -15, .y = -15, .w = 10, .h = 10 }));
    try expect(!boxesOverlap(.{ .x = -20, .y = -20, .w = 10, .h = 10 }, .{ .x = -10, .y = -20, .w = 10, .h = 10 }));
}

test "empty and non-finite boxes overlap nothing" {
    const solid = Box{ .x = 0, .y = 0, .w = 10, .h = 10 };
    try expect(!boxesOverlap(solid, .{ .x = 0, .y = 0, .w = 0, .h = 10 }));
    try expect(!boxesOverlap(solid, .{ .x = 0, .y = 0, .w = -5, .h = 10 }));
    try expect(!boxesOverlap(solid, .{ .x = std.math.nan(f32), .y = 0, .w = 10, .h = 10 }));
    try expect(!boxesOverlap(solid, .{ .x = 0, .y = 0, .w = std.math.inf(f32), .h = 10 }));
    try expect(!pointInBox(.{ .x = 0, .y = 0 }, .{ .x = 0, .y = 0, .w = -1, .h = 1 }));
}

test "a point is inside a box on its left and top edges, not on its right and bottom edges" {
    const box = Box{ .x = 0, .y = 0, .w = 16, .h = 16 };
    try expect(pointInBox(.{ .x = 0, .y = 0 }, box));
    try expect(pointInBox(.{ .x = 15.9, .y = 15.9 }, box));
    try expect(!pointInBox(.{ .x = 16, .y = 8 }, box));
    try expect(!pointInBox(.{ .x = 8, .y = 16 }, box));
    try expect(!pointInBox(.{ .x = -0.1, .y = 8 }, box));
}

test "circles overlap only when their centers are closer than the sum of their radii" {
    const a = Circle{ .x = 0, .y = 0, .r = 5 };
    try expect(circlesOverlap(a, .{ .x = 9, .y = 0, .r = 5 }));
    try expect(!circlesOverlap(a, .{ .x = 10, .y = 0, .r = 5 }));
    try expect(!circlesOverlap(a, .{ .x = 0, .y = 0, .r = 0 }));
}

test "a circle overlaps a box when the box point nearest its center is inside the circle" {
    const box = Box{ .x = 0, .y = 0, .w = 10, .h = 10 };
    try expect(circleOverlapsBox(.{ .x = 5, .y = 5, .r = 1 }, box));
    try expect(circleOverlapsBox(.{ .x = -4, .y = 5, .r = 5.5 }, box));
    try expect(!circleOverlapsBox(.{ .x = -5, .y = 5, .r = 5 }, box));
    // Near the top-left corner the nearest point is (0, 0), and its distance from (-3, -4) is exactly 5.
    try expect(!circleOverlapsBox(.{ .x = -3, .y = -4, .r = 5 }, box));
    try expect(circleOverlapsBox(.{ .x = -3, .y = -4, .r = 5.01 }, box));
}

test "oriented boxes use separating axes and exclude edge-only contact" {
    const horizontal = OrientedBox{ .x = 0, .y = 0, .w = 20, .h = 10, .rotation = 0 };
    try expect(orientedBoxesOverlap(horizontal, .{ .x = 10, .y = -3, .w = 20, .h = 10, .rotation = 0.78539816 }));
    try expect(!orientedBoxesOverlap(horizontal, .{ .x = 20, .y = 0, .w = 10, .h = 10, .rotation = 0 }));
    try expect(!orientedBoxesOverlap(horizontal, .{ .x = 0, .y = 0, .w = 0, .h = 10, .rotation = 0 }));
}

test "rotated bounds contain the complete oriented rectangle" {
    const bounds = boundingBox(.{ .x = 0, .y = 0, .w = 20, .h = 10 }, 1.5707963).?;
    try std.testing.expectApproxEqAbs(@as(f32, 5), bounds.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -5), bounds.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 10), bounds.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 20), bounds.h, 0.01);
}
