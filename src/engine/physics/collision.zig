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

/// A collider hit along a segment. A segment starting inside a shape returns fraction zero.
pub const Hit = struct {
    index: usize,
    fraction: f32,
    point: Point,
    normal: Point,
};

/// A static box or circle that queries can hit. Triggers are queryable but do not block movement.
/// `layer` is a set of bits, and one collider can belong to several layers. See queries.zig for
/// how masks select layers.
pub const Collider = struct {
    box: Box,
    layer: u32,
    mask: u32 = std.math.maxInt(u32),
    rotation: f32 = 0,
    circle: ?Circle = null,
    one_way: bool = false,
    is_trigger: bool = false,
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
    circle: ?Circle = null,
    one_way: bool = false,
    is_trigger: bool = false,
    enabled: bool = true,

    pub fn collider(self: Component) Collider {
        return .{
            .box = self.box,
            .layer = self.layer,
            .mask = self.mask,
            .rotation = self.rotation,
            .circle = self.circle,
            .one_way = self.one_way,
            .is_trigger = self.is_trigger,
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

/// True when a point is strictly inside a circle; the rim is outside.
pub fn pointInCircle(point: Point, circle: Circle) bool {
    if (isEmptyCircle(circle) or !(std.math.isFinite(point.x) and std.math.isFinite(point.y))) return false;
    const dx = point.x - circle.x;
    const dy = point.y - circle.y;
    return dx * dx + dy * dy < circle.r * circle.r;
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
    if (a.circle) |a_circle| {
        if (b.circle) |b_circle| return circlesOverlap(a_circle, b_circle);
        return circleOverlapsRotatedBox(a_circle, b);
    }
    if (b.circle) |b_circle| return circleOverlapsRotatedBox(b_circle, a);
    return orientedBoxesOverlap(
        .{ .x = a.box.x, .y = a.box.y, .w = a.box.w, .h = a.box.h, .rotation = a.rotation },
        .{ .x = b.box.x, .y = b.box.y, .w = b.box.w, .h = b.box.h, .rotation = b.rotation },
    );
}

/// True when a collider's active shape overlaps a box probe.
pub fn overlapsProbe(collider: Collider, box: Box) bool {
    if (collider.circle) |circle| return circleOverlapsBox(circle, box);
    return orientedBoxesOverlap(
        .{ .x = collider.box.x, .y = collider.box.y, .w = collider.box.w, .h = collider.box.h, .rotation = collider.rotation },
        .{ .x = box.x, .y = box.y, .w = box.w, .h = box.h, .rotation = 0 },
    );
}

/// True when a collider's active shape contains a point.
pub fn containsPoint(collider: Collider, point: Point) bool {
    if (collider.circle) |circle| return pointInCircle(point, circle);
    if (collider.rotation == 0) return pointInBox(point, collider.box);
    return pointInOrientedBox(point, .{
        .x = collider.box.x,
        .y = collider.box.y,
        .w = collider.box.w,
        .h = collider.box.h,
        .rotation = collider.rotation,
    });
}

/// Axis-aligned bounds of the collider's active shape. A null result means the shape is empty;
/// a box with a non-finite rotation also returns null.
pub fn colliderBounds(collider: Collider) ?Box {
    if (collider.circle) |circle| {
        if (isEmptyCircle(circle)) return null;
        const bounds = Box{ .x = circle.x - circle.r, .y = circle.y - circle.r, .w = 2 * circle.r, .h = 2 * circle.r };
        if (isEmptyBox(bounds)) return null;
        return bounds;
    }
    return boundingBox(collider.box, collider.rotation);
}

/// Ray/segment against an axis-aligned box. Box faces are inclusive for contact; empty or
/// non-finite inputs miss. A segment starting inside reports fraction zero with the nearest
/// outward face normal.
pub fn rayVsBox(index: usize, origin: Point, delta: Point, box: Box) ?Hit {
    if (isEmptyBox(box) or !finite4(origin.x, origin.y, delta.x, delta.y)) return null;
    const right = box.x + box.w;
    const bottom = box.y + box.h;
    if (!finite4(right, bottom, origin.x + delta.x, origin.y + delta.y)) return null;

    if (origin.x >= box.x and origin.x <= right and origin.y >= box.y and origin.y <= bottom) {
        const distances = [4]f32{ origin.x - box.x, right - origin.x, origin.y - box.y, bottom - origin.y };
        var face: usize = 0;
        for (distances[1..], 1..) |distance, candidate| {
            if (distance < distances[face]) face = candidate;
        }
        const normal = switch (face) {
            0 => Point{ .x = -1, .y = 0 },
            1 => Point{ .x = 1, .y = 0 },
            2 => Point{ .x = 0, .y = -1 },
            else => Point{ .x = 0, .y = 1 },
        };
        return .{ .index = index, .fraction = 0, .point = origin, .normal = normal };
    }

    var entry: f32 = -std.math.inf(f32);
    var exit: f32 = std.math.inf(f32);
    var normal = Point{ .x = 0, .y = 0 };
    if (delta.x == 0) {
        if (origin.x < box.x or origin.x > right) return null;
    } else {
        var near = (box.x - origin.x) / delta.x;
        var far = (right - origin.x) / delta.x;
        var near_normal = Point{ .x = -1, .y = 0 };
        if (near > far) {
            std.mem.swap(f32, &near, &far);
            near_normal.x = 1;
        }
        if (near > entry) {
            entry = near;
            normal = near_normal;
        }
        exit = @min(exit, far);
    }
    if (delta.y == 0) {
        if (origin.y < box.y or origin.y > bottom) return null;
    } else {
        var near = (box.y - origin.y) / delta.y;
        var far = (bottom - origin.y) / delta.y;
        var near_normal = Point{ .x = 0, .y = -1 };
        if (near > far) {
            std.mem.swap(f32, &near, &far);
            near_normal.y = 1;
        }
        if (near > entry) {
            entry = near;
            normal = near_normal;
        }
        exit = @min(exit, far);
    }
    if (entry > exit or exit < 0 or entry < 0 or entry > 1) return null;
    const point = Point{ .x = origin.x + delta.x * entry, .y = origin.y + delta.y * entry };
    return .{ .index = index, .fraction = entry, .point = point, .normal = normal };
}

/// Ray/segment against an open-disk collider, with rim contact counted as a hit. A segment
/// starting inside reports fraction zero and a unit-ish outward normal.
pub fn rayVsCircle(index: usize, origin: Point, delta: Point, circle: Circle) ?Hit {
    if (isEmptyCircle(circle) or !finite4(origin.x, origin.y, delta.x, delta.y) or
        !finite4(origin.x + delta.x, origin.y + delta.y, 0, 0)) return null;
    const mx = origin.x - circle.x;
    const my = origin.y - circle.y;
    const radius_squared = circle.r * circle.r;
    const start_distance_squared = mx * mx + my * my;
    if (start_distance_squared < radius_squared) {
        const normal = if (start_distance_squared > 0)
            unitPoint(mx, my)
        else if (delta.x != 0 or delta.y != 0)
            unitPoint(-delta.x, -delta.y)
        else
            Point{ .x = 1, .y = 0 };
        return .{ .index = index, .fraction = 0, .point = origin, .normal = normal };
    }
    const a = delta.x * delta.x + delta.y * delta.y;
    if (a == 0 or !std.math.isFinite(a)) return null;
    const b = 2 * (mx * delta.x + my * delta.y);
    const c = start_distance_squared - radius_squared;
    const discriminant = b * b - 4 * a * c;
    if (discriminant < 0 or !std.math.isFinite(discriminant)) return null;
    const root = std.math.sqrt(discriminant);
    const denominator = 2 * a;
    var fraction = (-b - root) / denominator;
    if (fraction < 0) fraction = (-b + root) / denominator;
    if (fraction < 0 or fraction > 1 or !std.math.isFinite(fraction)) return null;
    const point = Point{ .x = origin.x + delta.x * fraction, .y = origin.y + delta.y * fraction };
    return .{
        .index = index,
        .fraction = fraction,
        .point = point,
        .normal = unitPoint(point.x - circle.x, point.y - circle.y),
    };
}

/// Ray/segment against a rotated box. The ray is transformed into box-local coordinates and the
/// hit point and normal are transformed back to world coordinates.
pub fn rayVsOrientedBox(index: usize, origin: Point, delta: Point, box: OrientedBox) ?Hit {
    if (!std.math.isFinite(box.rotation) or !finite4(origin.x, origin.y, delta.x, delta.y) or
        !finite4(origin.x + delta.x, origin.y + delta.y, box.x, box.y)) return null;
    const center = Point{ .x = box.x + box.w / 2, .y = box.y + box.h / 2 };
    const cosine = @cos(box.rotation);
    const sine = @sin(box.rotation);
    const ox = origin.x - center.x;
    const oy = origin.y - center.y;
    const local_origin = Point{
        .x = ox * cosine + oy * sine + box.w / 2,
        .y = -ox * sine + oy * cosine + box.h / 2,
    };
    const local_delta = Point{
        .x = delta.x * cosine + delta.y * sine,
        .y = -delta.x * sine + delta.y * cosine,
    };
    var hit = rayVsBox(index, local_origin, local_delta, .{ .x = 0, .y = 0, .w = box.w, .h = box.h }) orelse return null;
    hit.point = .{ .x = origin.x + delta.x * hit.fraction, .y = origin.y + delta.y * hit.fraction };
    const local_normal = hit.normal;
    hit.normal = .{
        .x = local_normal.x * cosine - local_normal.y * sine,
        .y = local_normal.x * sine + local_normal.y * cosine,
    };
    return hit;
}

/// Ray/segment against a collider's active shape. Triggers are queryable like other colliders.
pub fn rayVsCollider(index: usize, origin: Point, delta: Point, collider: Collider) ?Hit {
    if (collider.circle) |circle| return rayVsCircle(index, origin, delta, circle);
    return rayVsOrientedBox(index, origin, delta, .{
        .x = collider.box.x,
        .y = collider.box.y,
        .w = collider.box.w,
        .h = collider.box.h,
        .rotation = collider.rotation,
    });
}

/// Casts an axis-aligned box along a segment against a collider. Rounded-rectangle Minkowski
/// sums make box/circle and box/box contacts exact; box/OBB uses continuous SAT.
pub fn castBoxVsCollider(index: usize, box: Box, delta: Point, collider: Collider) ?Hit {
    if (isEmptyBox(box) or !finite4(delta.x, delta.y, box.x + box.w, box.y + box.h)) return null;
    if (collider.circle) |circle| {
        var hit = rayVsRoundedRect(
            index,
            .{ .x = box.x + box.w / 2, .y = box.y + box.h / 2 },
            delta,
            .{ .x = circle.x, .y = circle.y },
            box.w / 2,
            box.h / 2,
            circle.r,
        ) orelse return null;
        hit.point = .{ .x = box.x + delta.x * hit.fraction, .y = box.y + delta.y * hit.fraction };
        return hit;
    }
    if (isEmptyBox(collider.box)) return null;
    if (collider.rotation == 0) {
        const expanded = Box{
            .x = collider.box.x - box.w,
            .y = collider.box.y - box.h,
            .w = collider.box.w + box.w,
            .h = collider.box.h + box.h,
        };
        var hit = rayVsBox(index, .{ .x = box.x, .y = box.y }, delta, expanded) orelse return null;
        hit.point = .{ .x = box.x + delta.x * hit.fraction, .y = box.y + delta.y * hit.fraction };
        return hit;
    }
    return castBoxVsObb(index, box, delta, .{
        .x = collider.box.x,
        .y = collider.box.y,
        .w = collider.box.w,
        .h = collider.box.h,
        .rotation = collider.rotation,
    });
}

/// Casts a circle along a segment against a collider using rounded-rectangle Minkowski sums.
pub fn castCircleVsCollider(index: usize, circle: Circle, delta: Point, collider: Collider) ?Hit {
    if (isEmptyCircle(circle) or !finite4(delta.x, delta.y, circle.x, circle.y)) return null;
    if (collider.circle) |target| {
        if (isEmptyCircle(target)) return null;
        return rayVsCircle(index, .{ .x = circle.x, .y = circle.y }, delta, .{
            .x = target.x,
            .y = target.y,
            .r = target.r + circle.r,
        });
    }
    if (collider.rotation == 0) {
        if (isEmptyBox(collider.box)) return null;
        return rayVsRoundedRect(index, .{ .x = circle.x, .y = circle.y }, delta, .{
            .x = collider.box.x + collider.box.w / 2,
            .y = collider.box.y + collider.box.h / 2,
        }, collider.box.w / 2, collider.box.h / 2, circle.r);
    }
    const center = Point{ .x = collider.box.x + collider.box.w / 2, .y = collider.box.y + collider.box.h / 2 };
    const cosine = @cos(collider.rotation);
    const sine = @sin(collider.rotation);
    const ox = circle.x - center.x;
    const oy = circle.y - center.y;
    var hit = rayVsRoundedRect(
        index,
        .{ .x = ox * cosine + oy * sine + collider.box.w / 2, .y = -ox * sine + oy * cosine + collider.box.h / 2 },
        .{ .x = delta.x * cosine + delta.y * sine, .y = -delta.x * sine + delta.y * cosine },
        .{ .x = collider.box.w / 2, .y = collider.box.h / 2 },
        collider.box.w / 2,
        collider.box.h / 2,
        circle.r,
    ) orelse return null;
    const local_point = hit.point;
    hit.point = .{
        .x = center.x + (local_point.x - collider.box.w / 2) * cosine - (local_point.y - collider.box.h / 2) * sine,
        .y = center.y + (local_point.x - collider.box.w / 2) * sine + (local_point.y - collider.box.h / 2) * cosine,
    };
    const local_normal = hit.normal;
    hit.normal = .{
        .x = local_normal.x * cosine - local_normal.y * sine,
        .y = local_normal.x * sine + local_normal.y * cosine,
    };
    return hit;
}

fn castBoxVsObb(index: usize, box: Box, delta: Point, target: OrientedBox) ?Hit {
    if (isEmptyBox(box) or target.w <= 0 or target.h <= 0 or !std.math.isFinite(target.rotation) or
        !finite4(target.x, target.y, target.w, target.h) or !finite4(delta.x, delta.y, 0, 0) or
        !finite4(box.x + delta.x, box.y + delta.y, target.x + target.w, target.y + target.h)) return null;
    const mover_center = Point{ .x = box.x + box.w / 2, .y = box.y + box.h / 2 };
    const target_center = Point{ .x = target.x + target.w / 2, .y = target.y + target.h / 2 };
    const axes = [4]Point{
        .{ .x = 1, .y = 0 },
        .{ .x = 0, .y = 1 },
        .{ .x = @cos(target.rotation), .y = @sin(target.rotation) },
        .{ .x = -@sin(target.rotation), .y = @cos(target.rotation) },
    };
    var entry: f32 = 0;
    var exit: f32 = 1;
    var normal = Point{ .x = 0, .y = 0 };
    for (axes) |axis| {
        const center_delta = (target_center.x - mover_center.x) * axis.x + (target_center.y - mover_center.y) * axis.y;
        const speed = delta.x * axis.x + delta.y * axis.y;
        const mover_radius = @abs(axis.x) * box.w / 2 + @abs(axis.y) * box.h / 2;
        const target_radius = @abs(axis.x * @cos(target.rotation) + axis.y * @sin(target.rotation)) * target.w / 2 +
            @abs(-axis.x * @sin(target.rotation) + axis.y * @cos(target.rotation)) * target.h / 2;
        const radius = mover_radius + target_radius;
        if (speed == 0) {
            if (@abs(center_delta) > radius) return null;
            continue;
        }
        var near = (center_delta - radius) / speed;
        var far = (center_delta + radius) / speed;
        var axis_normal = Point{ .x = -axis.x, .y = -axis.y };
        if (near > far) {
            std.mem.swap(f32, &near, &far);
            axis_normal = .{ .x = axis.x, .y = axis.y };
        }
        if (near > entry) {
            entry = near;
            normal = axis_normal;
        }
        exit = @min(exit, far);
        if (entry > exit) return null;
    }
    if (exit < 0 or entry > 1) return null;
    const fraction = @max(entry, 0);
    if (fraction == 0 and normal.x == 0 and normal.y == 0) {
        normal = unitPoint(-delta.x, -delta.y);
    }
    return .{
        .index = index,
        .fraction = fraction,
        .point = .{ .x = box.x + delta.x * fraction, .y = box.y + delta.y * fraction },
        .normal = normal,
    };
}

fn rayVsRoundedRect(index: usize, origin: Point, delta: Point, center: Point, half_w: f32, half_h: f32, radius: f32) ?Hit {
    if (!finite4(origin.x, origin.y, delta.x, delta.y) or
        !finite4(origin.x + delta.x, origin.y + delta.y, 0, 0) or
        !finite4(center.x, center.y, half_w, half_h) or
        !std.math.isFinite(radius) or half_w < 0 or half_h < 0 or radius <= 0) return null;

    const local_x = origin.x - center.x;
    const local_y = origin.y - center.y;
    const outside_x = @max(@abs(local_x) - half_w, 0);
    const outside_y = @max(@abs(local_y) - half_h, 0);
    if (outside_x * outside_x + outside_y * outside_y <= radius * radius) {
        var normal = if (outside_x > 0 or outside_y > 0)
            unitPoint(@as(f32, if (local_x < 0) -1 else 1) * outside_x, @as(f32, if (local_y < 0) -1 else 1) * outside_y)
        else
            nearestRectNormal(local_x, local_y, half_w + radius, half_h + radius);
        if (delta.x == 0 and delta.y == 0 and outside_x == 0 and outside_y == 0) normal = nearestRectNormal(local_x, local_y, half_w + radius, half_h + radius);
        return .{ .index = index, .fraction = 0, .point = origin, .normal = normal };
    }

    var best: ?Hit = null;
    const horizontal = Box{ .x = center.x - half_w, .y = center.y - half_h - radius, .w = 2 * half_w, .h = 2 * radius };
    const vertical = Box{ .x = center.x - half_w - radius, .y = center.y - half_h, .w = 2 * radius, .h = 2 * half_h };
    if (rayVsBox(index, origin, delta, horizontal)) |hit| {
        if (hit.normal.y != 0) best = hit;
    }
    if (rayVsBox(index, origin, delta, vertical)) |hit| {
        if (hit.normal.x != 0) best = earlierHit(best, hit);
    }

    for ([_]f32{ -1, 1 }) |sx| {
        for ([_]f32{ -1, 1 }) |sy| {
            const corner = Circle{
                .x = center.x + sx * half_w,
                .y = center.y + sy * half_h,
                .r = radius,
            };
            if (rayVsCircle(index, origin, delta, corner)) |hit| {
                if ((hit.point.x - corner.x) * sx >= 0 and (hit.point.y - corner.y) * sy >= 0)
                    best = earlierHit(best, hit);
            }
        }
    }
    return best;
}

fn nearestRectNormal(x: f32, y: f32, half_w: f32, half_h: f32) Point {
    const dx = half_w - @abs(x);
    const dy = half_h - @abs(y);
    if (dx <= dy) return .{ .x = if (x < 0) -1 else 1, .y = 0 };
    return .{ .x = 0, .y = if (y < 0) -1 else 1 };
}

fn earlierHit(current: ?Hit, candidate: Hit) ?Hit {
    if (current) |hit| return if (candidate.fraction < hit.fraction) candidate else hit;
    return candidate;
}

fn unitPoint(x: f32, y: f32) Point {
    const length = std.math.sqrt(x * x + y * y);
    if (length == 0 or !std.math.isFinite(length)) return .{ .x = 1, .y = 0 };
    return .{ .x = x / length, .y = y / length };
}

/// Candidate top-left position at first contact while moving a box horizontally into a circle.
pub fn circleStopX(box: Box, dx: f32, circle: Circle) ?f32 {
    if (!std.math.isFinite(dx) or dx == 0 or isEmptyBox(box) or isEmptyCircle(circle)) return null;
    const dy = distanceFromSpan(circle.y, box.y, box.y + box.h);
    if (dy > circle.r) return null;
    const reach = if (dy == 0) circle.r else std.math.sqrt(circle.r * circle.r - dy * dy);
    const candidate = if (dx > 0) circle.x - reach - box.w else circle.x + reach;
    if (dy == 0 or circleOverlapsBox(circle, box) or
        !circleOverlapsBox(circle, .{ .x = candidate, .y = box.y, .w = box.w, .h = box.h })) return candidate;
    if (dx > 0) {
        var free = box.x;
        var hit = candidate;
        var i: usize = 0;
        while (i < 32) : (i += 1) {
            const middle = free + (hit - free) / 2.0;
            if (middle == free or middle == hit) break;
            if (circleOverlapsBox(circle, .{ .x = middle, .y = box.y, .w = box.w, .h = box.h })) {
                hit = middle;
            } else {
                free = middle;
            }
        }
        return free;
    }
    var hit = candidate;
    var free = box.x;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const middle = hit + (free - hit) / 2.0;
        if (middle == hit or middle == free) break;
        if (circleOverlapsBox(circle, .{ .x = middle, .y = box.y, .w = box.w, .h = box.h })) {
            hit = middle;
        } else {
            free = middle;
        }
    }
    return free;
}

/// Candidate top-left position at first contact while moving a box vertically into a circle.
pub fn circleStopY(box: Box, dy: f32, circle: Circle) ?f32 {
    if (!std.math.isFinite(dy) or dy == 0 or isEmptyBox(box) or isEmptyCircle(circle)) return null;
    const dx = distanceFromSpan(circle.x, box.x, box.x + box.w);
    if (dx > circle.r) return null;
    const reach = if (dx == 0) circle.r else std.math.sqrt(circle.r * circle.r - dx * dx);
    const candidate = if (dy > 0) circle.y - reach - box.h else circle.y + reach;
    if (dx == 0 or circleOverlapsBox(circle, box) or
        !circleOverlapsBox(circle, .{ .x = box.x, .y = candidate, .w = box.w, .h = box.h })) return candidate;
    if (dy > 0) {
        var free = box.y;
        var hit = candidate;
        var i: usize = 0;
        while (i < 32) : (i += 1) {
            const middle = free + (hit - free) / 2.0;
            if (middle == free or middle == hit) break;
            if (circleOverlapsBox(circle, .{ .x = box.x, .y = middle, .w = box.w, .h = box.h })) {
                hit = middle;
            } else {
                free = middle;
            }
        }
        return free;
    }
    var hit = candidate;
    var free = box.y;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const middle = hit + (free - hit) / 2.0;
        if (middle == hit or middle == free) break;
        if (circleOverlapsBox(circle, .{ .x = box.x, .y = middle, .w = box.w, .h = box.h })) {
            hit = middle;
        } else {
            free = middle;
        }
    }
    return free;
}

fn distanceFromSpan(value: f32, start: f32, end: f32) f32 {
    if (value < start) return start - value;
    if (value > end) return value - end;
    return 0;
}

fn circleOverlapsRotatedBox(circle: Circle, collider: Collider) bool {
    if (collider.rotation == 0) return circleOverlapsBox(circle, collider.box);
    if (!std.math.isFinite(collider.rotation) or isEmptyCircle(circle) or isEmptyBox(collider.box)) return false;
    const center_x = collider.box.x + collider.box.w / 2.0;
    const center_y = collider.box.y + collider.box.h / 2.0;
    const dx = circle.x - center_x;
    const dy = circle.y - center_y;
    const cosine = @cos(collider.rotation);
    const sine = @sin(collider.rotation);
    const local_circle = Circle{
        .x = dx * cosine + dy * sine + collider.box.w / 2.0,
        .y = -dx * sine + dy * cosine + collider.box.h / 2.0,
        .r = circle.r,
    };
    return circleOverlapsBox(local_circle, .{ .x = 0, .y = 0, .w = collider.box.w, .h = collider.box.h });
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

test "points on a circle rim are outside and the adjacent interior float is inside" {
    const circle = Circle{ .x = 0, .y = 0, .r = 5 };
    const inside_x: f32 = @bitCast(@as(u32, @bitCast(@as(f32, 5))) - 1);
    try expect(!pointInCircle(.{ .x = 5, .y = 0 }, circle));
    try expect(pointInCircle(.{ .x = inside_x, .y = 0 }, circle));
    try expect(!pointInCircle(.{ .x = 0, .y = 0 }, .{ .x = 0, .y = 0, .r = std.math.inf(f32) }));
}

test "circle collider pairs use circle tests, rotated-box local space, and mutual masks" {
    const circle = Collider{
        .box = .{ .x = 100, .y = 100, .w = 1, .h = 1 },
        .layer = 1,
        .circle = .{ .x = 5, .y = 5, .r = 5 },
    };
    const touching_circle = Collider{
        .box = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        .layer = 1,
        .circle = .{ .x = 15, .y = 5, .r = 5 },
    };
    try expect(!colliderOverlaps(circle, touching_circle));
    try expect(colliderOverlaps(
        circle,
        .{
            .box = .{ .x = 5, .y = 5, .w = 10, .h = 10 },
            .layer = 1,
            .rotation = std.math.pi / 4.0,
        },
    ));
    try expect(!colliderOverlaps(circle, .{
        .box = .{ .x = 0, .y = 0, .w = 10, .h = 10 },
        .layer = 1,
        .mask = 2,
    }));
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

test "ray against a box returns the first contact and reports starts inside at zero" {
    const box = Box{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const hit = rayVsBox(3, .{ .x = -5, .y = 5 }, .{ .x = 20, .y = 0 }, box).?;
    try std.testing.expectEqual(@as(usize, 3), hit.index);
    try std.testing.expectEqual(@as(f32, 0.25), hit.fraction);
    try std.testing.expectEqual(Point{ .x = 0, .y = 5 }, hit.point);
    try std.testing.expectEqual(Point{ .x = -1, .y = 0 }, hit.normal);

    const inside = rayVsBox(0, .{ .x = 5, .y = 4 }, .{ .x = 0, .y = 0 }, box).?;
    try std.testing.expectEqual(@as(f32, 0), inside.fraction);
    try std.testing.expectEqual(Point{ .x = 0, .y = -1 }, inside.normal);
    try expect(rayVsBox(0, .{ .x = -5, .y = 5 }, .{ .x = 4, .y = 0 }, box) == null);
}

test "ray against a circle counts tangency and reports an outward normal" {
    const circle = Circle{ .x = 0, .y = 0, .r = 5 };
    const tangent = rayVsCircle(1, .{ .x = -10, .y = 5 }, .{ .x = 20, .y = 0 }, circle).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), tangent.fraction, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), tangent.point.x, 1e-6);
    try std.testing.expectEqual(Point{ .x = 0, .y = 1 }, tangent.normal);
    try expect(rayVsCircle(0, .{ .x = -10, .y = 5.1 }, .{ .x = 20, .y = 0 }, circle) == null);

    const inside = rayVsCircle(0, .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 0 }, circle).?;
    try std.testing.expectEqual(@as(f32, 0), inside.fraction);
}

test "ray against a rotated box returns world-space contact and normal" {
    const box = OrientedBox{ .x = 0, .y = 0, .w = 20, .h = 4, .rotation = std.math.pi / 4.0 };
    const hit = rayVsOrientedBox(0, .{ .x = 0, .y = 2 }, .{ .x = 20, .y = 0 }, box).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.3586), hit.fraction, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 7.17), hit.point.x, 0.02);
    try std.testing.expectApproxEqAbs(@as(f32, 2), hit.point.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -0.7071), hit.normal.x, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7071), hit.normal.y, 1e-3);
}

test "box and circle casts use rounded exact contacts" {
    const wall = Collider{ .box = .{ .x = 50, .y = 0, .w = 10, .h = 20 }, .layer = 1 };
    const box_hit = castBoxVsCollider(0, .{ .x = 0, .y = 0, .w = 10, .h = 10 }, .{ .x = 100, .y = 0 }, wall).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), box_hit.fraction, 1e-6);
    try std.testing.expectEqual(Point{ .x = 40, .y = 0 }, box_hit.point);
    try std.testing.expectEqual(Point{ .x = -1, .y = 0 }, box_hit.normal);

    const circle_hit = castCircleVsCollider(
        0,
        .{ .x = 0, .y = 10, .r = 5 },
        .{ .x = 100, .y = 0 },
        wall,
    ).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.45), circle_hit.fraction, 1e-6);
    try std.testing.expectEqual(Point{ .x = 45, .y = 10 }, circle_hit.point);

    const corner_target = Collider{ .box = .{ .x = 10, .y = 10, .w = 4, .h = 4 }, .layer = 1 };
    const corner = castCircleVsCollider(0, .{ .x = 0, .y = 0, .r = 5 }, .{ .x = 20, .y = 20 }, corner_target).?;
    try std.testing.expect(corner.fraction > 0 and corner.fraction < 1);
    try std.testing.expect(corner.normal.x < 0 and corner.normal.y < 0);
}
