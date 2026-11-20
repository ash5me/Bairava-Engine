const std = @import("std");
const shapes = @import("../physics/shapes.zig");

pub const Bounds = shapes.Box;

/// Returns whether non-empty world-space bounds intersect the view grown by `pad`.
/// Right and bottom edges are exclusive; contact at the left or top edge counts as visible.
pub fn overlapsView(view: Bounds, bounds: Bounds, pad: f32) bool {
    if (!validBounds(view) or !validBounds(bounds) or !std.math.isFinite(pad) or pad < 0) return false;
    const left = view.x - pad;
    const top = view.y - pad;
    const right = view.x + view.w + pad;
    const bottom = view.y + view.h + pad;
    const bounds_right = bounds.x + bounds.w;
    const bounds_bottom = bounds.y + bounds.h;
    if (!(std.math.isFinite(left) and std.math.isFinite(top) and
        std.math.isFinite(right) and std.math.isFinite(bottom) and
        std.math.isFinite(bounds_right) and std.math.isFinite(bounds_bottom))) return false;
    return bounds.x < right and left <= bounds_right and
        bounds.y < bottom and top <= bounds_bottom;
}

/// Returns the world-space AABB of a destination rectangle after clockwise rotation around `origin`.
/// `dst` must expose x, y, w, and h fields, as does `renderer.sprite.Rect`.
pub fn spriteBounds(dst: anytype, origin: [2]f32, rotation: f32) Bounds {
    if (!std.math.isFinite(rotation) or
        !std.math.isFinite(origin[0]) or !std.math.isFinite(origin[1]))
    {
        return .{ .x = std.math.nan(f32), .y = 0, .w = 0, .h = 0 };
    }
    const rect = Bounds{ .x = dst.x, .y = dst.y, .w = dst.w, .h = dst.h };
    if (!validBounds(rect)) return rect;
    const pivot_x = rect.x + origin[0];
    const pivot_y = rect.y + origin[1];
    const cosine = @cos(rotation);
    const sine = @sin(rotation);
    var min_x: f32 = std.math.inf(f32);
    var max_x: f32 = -std.math.inf(f32);
    var min_y: f32 = std.math.inf(f32);
    var max_y: f32 = -std.math.inf(f32);
    for ([_]f32{ 0, rect.w }) |x| {
        for ([_]f32{ 0, rect.h }) |y| {
            const dx = x - origin[0];
            const dy = y - origin[1];
            const world_x = pivot_x + dx * cosine - dy * sine;
            const world_y = pivot_y + dx * sine + dy * cosine;
            min_x = @min(min_x, world_x);
            max_x = @max(max_x, world_x);
            min_y = @min(min_y, world_y);
            max_y = @max(max_y, world_y);
        }
    }
    if (!(std.math.isFinite(min_x) and std.math.isFinite(max_x) and
        std.math.isFinite(min_y) and std.math.isFinite(max_y)))
    {
        return .{ .x = std.math.nan(f32), .y = 0, .w = 0, .h = 0 };
    }
    const width = max_x - min_x;
    const height = max_y - min_y;
    if (!std.math.isFinite(width) or !std.math.isFinite(height)) {
        return .{ .x = std.math.nan(f32), .y = 0, .w = 0, .h = 0 };
    }
    return .{ .x = min_x, .y = min_y, .w = width, .h = height };
}

fn validBounds(bounds: Bounds) bool {
    if (!(std.math.isFinite(bounds.x) and std.math.isFinite(bounds.y) and
        std.math.isFinite(bounds.w) and std.math.isFinite(bounds.h)) or bounds.w <= 0 or bounds.h <= 0) return false;
    return std.math.isFinite(bounds.x + bounds.w) and std.math.isFinite(bounds.y + bounds.h);
}

pub const Scroll = struct {
    factor_x: f32 = 1,
    factor_y: f32 = 1,
    /// Added after the factor. The game owns this value, such as a speed multiplied by elapsed time.
    offset_x: f32 = 0,
    offset_y: f32 = 0,
};

pub const Constraint = struct {
    /// World-pixel look-ahead, applied after the dead-zone and capped to half the view.
    lead_x: f32 = 0,
    lead_y: f32 = 0,
    /// Dead-zone half-extents as view fractions, clamped to [0, 0.5].
    dead_x: f32 = 0,
    dead_y: f32 = 0,
    /// Hard keep-inside half-extents as view fractions, clamped to [0, 0.5].
    limit_x: f32 = 0,
    limit_y: f32 = 0,
};
const FollowConstraint = Constraint;

/// A view into the world, measured in native pixels. `x` and `y` are the world position of the
/// view's top-left corner. They are not rounded, so smoothing keeps its fractions. Drawing rounds
/// each sprite's screen position once, with `screenX` and `screenY`.
pub const Camera = struct {
    pub const Constraint = FollowConstraint;

    x: f32 = 0,
    y: f32 = 0,
    view_w: f32,
    view_h: f32,
    world_w: f32,
    world_h: f32,
    /// False until the camera has been placed once. The first placement jumps, so the view doesn't
    /// glide in from the corner of the world when the game starts.
    placed: bool = false,
    /// The zoom the view is drawn at. 1 is the normal view. Above 1 the view shows less of the
    /// world, with each pixel larger. Below 1 it shows more. The engine sets `view_w` and `view_h`
    /// from this each frame, so clamping and culling already follow the zoom.
    zoom: f32 = 1.0,

    /// The visible world rectangle. Zoom is already reflected in `view_w` and `view_h`.
    pub fn viewRect(self: Camera) Bounds {
        return .{ .x = self.x, .y = self.y, .w = self.view_w, .h = self.view_h };
    }

    /// Centers the view on a world point, clamped so the view never shows past the world edges.
    pub fn follow(self: *Camera, target_x: f32, target_y: f32) void {
        self.followWith(target_x, target_y, .{});
    }

    /// Centers the view using a dead-zone and lead, then applies the optional hard keep-inside
    /// region. Constraints are fractions of the current view except for lead, which is in pixels.
    pub fn followWith(self: *Camera, target_x: f32, target_y: f32, constraint: FollowConstraint) void {
        if (!std.math.isFinite(target_x) or !std.math.isFinite(target_y) or
            !std.math.isFinite(self.view_w) or !std.math.isFinite(self.view_h) or
            !std.math.isFinite(self.world_w) or !std.math.isFinite(self.world_h) or
            self.view_w <= 0 or self.view_h <= 0)
        {
            return;
        }
        const was_placed = self.placed;
        self.x = goalAxis(self.x, target_x, self.view_w, self.world_w, constraint.lead_x, constraint.dead_x, was_placed);
        self.y = goalAxis(self.y, target_y, self.view_h, self.world_h, constraint.lead_y, constraint.dead_y, was_placed);
        self.placed = true;
        if (was_placed) {
            self.x = applyLimit(self.x, target_x, self.view_w, self.world_w, constraint.limit_x);
            self.y = applyLimit(self.y, target_y, self.view_h, self.world_h, constraint.limit_y);
        }
    }

    /// Like `follow`, but eases toward the target. `rate` is how fast the camera closes the gap, per
    /// second. Each `dt` seconds it covers `1 - e^(-rate * dt)` of the distance that remains, so the
    /// result doesn't depend on the frame rate. A rate of zero or less snaps, as `follow` does.
    pub fn followSmooth(self: *Camera, target_x: f32, target_y: f32, dt: f32, rate: f32) void {
        self.followSmoothWith(target_x, target_y, dt, rate, .{});
    }

    /// Like `followWith`, but eases toward its clamped goal at an exponential rate.
    pub fn followSmoothWith(self: *Camera, target_x: f32, target_y: f32, dt: f32, rate: f32, constraint: FollowConstraint) void {
        if (!std.math.isFinite(target_x) or !std.math.isFinite(target_y) or
            !std.math.isFinite(self.view_w) or !std.math.isFinite(self.view_h) or
            !std.math.isFinite(self.world_w) or !std.math.isFinite(self.world_h) or
            self.view_w <= 0 or self.view_h <= 0)
        {
            return;
        }
        if (!self.placed) {
            self.followWith(target_x, target_y, constraint);
            return;
        }
        const goal_x = goalAxis(self.x, target_x, self.view_w, self.world_w, constraint.lead_x, constraint.dead_x, true);
        const goal_y = goalAxis(self.y, target_y, self.view_h, self.world_h, constraint.lead_y, constraint.dead_y, true);
        if (!std.math.isFinite(dt) or !std.math.isFinite(rate) or rate <= 0) {
            self.x = goal_x;
            self.y = goal_y;
        } else {
            const t = 1.0 - @exp(-rate * dt);
            self.x += (goal_x - self.x) * t;
            self.y += (goal_y - self.y) * t;
        }
        self.x = applyLimit(self.x, target_x, self.view_w, self.world_w, constraint.limit_x);
        self.y = applyLimit(self.y, target_y, self.view_h, self.world_h, constraint.limit_y);
    }

    /// Eases `zoom` toward `target`. The steps are geometric, so going from 1x to 2x takes as long
    /// as going from 2x to 4x. `rate` is how fast the zoom closes the gap, per second, as in
    /// `followSmooth`, and a rate of zero or less snaps. `target` must be positive.
    pub fn approachZoom(self: *Camera, target: f32, dt: f32, rate: f32) void {
        const safe_target = if (std.math.isFinite(target) and target > 0) target else 1.0;
        const safe_current = if (std.math.isFinite(self.zoom) and self.zoom > 0) self.zoom else 1.0;
        if (!std.math.isFinite(dt) or !std.math.isFinite(rate)) {
            self.zoom = safe_target;
            return;
        }
        if (rate <= 0) {
            self.zoom = safe_target;
            return;
        }
        const t = 1.0 - @exp(-rate * dt);
        // Moving the logarithm of the zoom keeps each zoom step the same size on screen.
        self.zoom = safe_current * @exp((@log(safe_target) - @log(safe_current)) * t);
    }

    /// The zoom target after multiplying `current` by `factor`, kept within `lo` and `hi`. A factor
    /// above 1 zooms in, and a factor below 1 zooms out.
    pub fn zoomTarget(current: f32, factor: f32, lo: f32, hi: f32) f32 {
        return std.math.clamp(current * factor, lo, hi);
    }

    /// The screen x of a world x, in whole native pixels from the view's left edge. It rounds once,
    /// from the unrounded camera. Rounding the camera and then the sprite separately makes a sprite
    /// that keeps pace with the camera step by a pixel now and then.
    pub fn screenX(self: *const Camera, world_x: f32) f32 {
        return @round(world_x - self.x);
    }

    /// The screen y of a world y, in whole native pixels from the view's top edge. See `screenX`.
    pub fn screenY(self: *const Camera, world_y: f32) f32 {
        return @round(world_y - self.y);
    }

    /// Returns a draw-only camera copy offset from the follow position. The gameplay camera remains unchanged.
    pub fn offset(self: Camera, dx: f32, dy: f32) Camera {
        var result = self;
        if (std.math.isFinite(dx)) result.x += dx;
        if (std.math.isFinite(dy)) result.y += dy;
        return result;
    }

    /// Returns a draw-only camera copy. Gameplay camera state and view/world dimensions are unchanged.
    pub fn scrolled(self: Camera, scroll: Scroll) Camera {
        var result = self;
        result.x = scrolledOrigin(self.x, scroll.factor_x, scroll.offset_x);
        result.y = scrolledOrigin(self.y, scroll.factor_y, scroll.offset_y);
        return result;
    }
};

fn goalAxis(origin: f32, target: f32, view: f32, world: f32, raw_lead: f32, raw_dead: f32, placed: bool) f32 {
    const lead = safeLead(raw_lead, view);
    var windowed = target;
    if (placed) {
        const dead = safeFraction(raw_dead);
        const center = origin + view / 2.0;
        const half = dead * view;
        if (dead > 0) {
            if (target < center - half) {
                windowed = target + half;
            } else if (target > center + half) {
                windowed = target - half;
            } else {
                windowed = center;
            }
        }
    }
    return clampAxis(windowed + lead - view / 2.0, view, world);
}

fn applyLimit(origin: f32, target: f32, view: f32, world: f32, raw_limit: f32) f32 {
    const limit = safeFraction(raw_limit);
    if (limit == 0) return origin;
    const half = limit * view;
    const min_origin = target - half - view / 2.0;
    const max_origin = target + half - view / 2.0;
    return clampAxis(std.math.clamp(origin, min_origin, max_origin), view, world);
}

fn safeFraction(value: f32) f32 {
    if (!std.math.isFinite(value)) return 0;
    return std.math.clamp(value, 0, 0.5);
}

fn safeLead(value: f32, view: f32) f32 {
    if (!std.math.isFinite(value)) return 0;
    return std.math.clamp(value, -view / 2.0, view / 2.0);
}

fn scrolledOrigin(origin: f32, factor: f32, offset: f32) f32 {
    if (!std.math.isFinite(factor) or !std.math.isFinite(offset)) return origin;
    const result = origin * factor + offset;
    return if (std.math.isFinite(result)) result else origin;
}

/// Keeps a view position within [0, world - view]. If the world is smaller than the view,
/// the world is centered in it.
fn clampAxis(pos: f32, view: f32, world: f32) f32 {
    if (world <= view) return (world - view) / 2.0;
    return std.math.clamp(pos, 0.0, world - view);
}

test "camera zoom and center tracking stay finite with invalid input" {
    var camera = Camera{ .x = 0, .y = 0, .view_w = 320, .view_h = 180, .world_w = 640, .world_h = 360 };
    camera.approachZoom(-1.0, 0.25, 2.0);
    try std.testing.expect(std.math.isFinite(camera.zoom));
    try std.testing.expect(camera.zoom > 0);

    camera.follow(std.math.nan(f32), 5.0);
    try std.testing.expect(std.math.isFinite(camera.x));
    try std.testing.expect(std.math.isFinite(camera.y));
}

test "camera offset changes only the returned draw copy" {
    const camera = Camera{
        .x = 10.5,
        .y = 23.25,
        .view_w = 320,
        .view_h = 180,
        .world_w = 1000,
        .world_h = 1000,
        .placed = true,
        .zoom = 1.5,
    };
    const shifted = camera.offset(4, -2);
    try std.testing.expectEqual(@as(f32, 10.5), camera.x);
    try std.testing.expectEqual(@as(f32, 23.25), camera.y);
    try std.testing.expectEqual(@as(f32, 14.5), shifted.x);
    try std.testing.expectEqual(@as(f32, 21.25), shifted.y);
    try std.testing.expectEqual(camera.view_w, shifted.view_w);
    try std.testing.expectEqual(camera.view_h, shifted.view_h);
    try std.testing.expectEqual(camera.zoom, shifted.zoom);
    try std.testing.expectEqual(camera.placed, shifted.placed);
    try std.testing.expectEqual(@as(f32, 6), shifted.screenX(20));
    try std.testing.expectEqual(@as(f32, 19), shifted.screenY(40));
}

test "a non-finite camera offset leaves only that axis unchanged" {
    const camera = Camera{ .x = 10, .y = 20, .view_w = 320, .view_h = 180, .world_w = 1000, .world_h = 1000 };
    const shifted = camera.offset(std.math.nan(f32), 3);
    try std.testing.expectEqual(@as(f32, 10), shifted.x);
    try std.testing.expectEqual(@as(f32, 23), shifted.y);
}

test "a factor-one scrolled camera matches the original screen coordinates" {
    var cam = Camera{ .x = 10.5, .y = 23.25, .view_w = 320, .view_h = 180, .world_w = 1000, .world_h = 1000 };
    const scrolled = cam.scrolled(.{});
    const points = [_][2]f32{ .{ 21.0, 40.1 }, .{ 20.4, 17.9 }, .{ 99.375, 54.625 } };
    for (points) |point| {
        try std.testing.expectEqual(cam.screenX(point[0]), scrolled.screenX(point[0]));
        try std.testing.expectEqual(cam.screenY(point[1]), scrolled.screenY(point[1]));
    }
    try std.testing.expectEqual(cam.x, scrolled.x);
    try std.testing.expectEqual(cam.y, scrolled.y);
}

test "scroll factors preserve gameplay motion at one and scale it at one half" {
    var cam = Camera{ .x = 10.25, .y = 5, .view_w = 320, .view_h = 180, .world_w = 1000, .world_h = 1000 };
    var world_x: f32 = cam.x + 16.3;
    const initial_fixed = cam.scrolled(.{}).screenX(world_x);
    var step: u32 = 0;
    while (step < 20) : (step += 1) {
        cam.x += 0.37;
        world_x += 0.37;
        try std.testing.expectEqual(initial_fixed, cam.scrolled(.{}).screenX(world_x));
    }

    cam.x = 10.25;
    world_x = 40.5;
    const initial_half = cam.scrolled(.{ .factor_x = 0.5 }).screenX(world_x);
    cam.x += 4;
    try std.testing.expectEqual(initial_half - 2, cam.scrolled(.{ .factor_x = 0.5 }).screenX(world_x));
}

test "factor zero pins an axis to its offset independently" {
    const cam = Camera{ .x = 40, .y = 90, .view_w = 320, .view_h = 180, .world_w = 1000, .world_h = 1000 };
    const fixed = cam.scrolled(.{ .factor_x = 0, .offset_x = 12.5 });
    try std.testing.expectEqual(@as(f32, 12.5), fixed.x);
    try std.testing.expectEqual(cam.y, fixed.y);
    try std.testing.expectEqual(@as(f32, 8), fixed.screenX(20));

    const separate_axes = cam.scrolled(.{ .factor_x = 0.25, .factor_y = 0.5, .offset_x = 3, .offset_y = 7 });
    try std.testing.expectEqual(@as(f32, 13), separate_axes.x);
    try std.testing.expectEqual(@as(f32, 52), separate_axes.y);
}

test "non-finite scroll inputs fall back to identity per axis" {
    const cam = Camera{ .x = 10.25, .y = 20.5, .view_w = 320, .view_h = 180, .world_w = 1000, .world_h = 1000 };
    const scrolled = cam.scrolled(.{
        .factor_x = std.math.nan(f32),
        .offset_x = 100,
        .factor_y = 0,
        .offset_y = std.math.inf(f32),
    });
    try std.testing.expectEqual(cam.x, scrolled.x);
    try std.testing.expectEqual(cam.y, scrolled.y);
    try std.testing.expect(std.math.isFinite(scrolled.x));
    try std.testing.expect(std.math.isFinite(scrolled.y));
}

test "view overlap uses half-open edges and grows by its pad" {
    const view = Bounds{ .x = 0, .y = 0, .w = 10, .h = 10 };
    try std.testing.expect(!overlapsView(view, .{ .x = 10, .y = 1, .w = 2, .h = 2 }, 0));
    try std.testing.expect(!overlapsView(view, .{ .x = 1, .y = 10, .w = 2, .h = 2 }, 0));
    try std.testing.expect(overlapsView(view, .{ .x = -2, .y = 1, .w = 2, .h = 2 }, 0));
    try std.testing.expect(overlapsView(view, .{ .x = 1, .y = -2, .w = 2, .h = 2 }, 0));
    try std.testing.expect(overlapsView(view, .{ .x = 10.5, .y = 1, .w = 1, .h = 2 }, 1));
    try std.testing.expect(!overlapsView(view, .{ .x = 0, .y = 0, .w = 0, .h = 1 }, 1));
    try std.testing.expect(!overlapsView(view, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, std.math.nan(f32)));
}

test "camera view follows zoom dimensions and scrolled camera copies" {
    const cam = Camera{ .x = 20, .y = 30, .view_w = 100, .view_h = 80, .world_w = 500, .world_h = 500 };
    const sprite_rect = Bounds{ .x = 110, .y = 35, .w = 2, .h = 2 };
    try std.testing.expect(overlapsView(cam.viewRect(), sprite_rect, 0));
    var zoomed = cam;
    zoomed.view_w = 80;
    zoomed.view_h = 60;
    try std.testing.expect(!overlapsView(zoomed.viewRect(), sprite_rect, 0));

    const layer_cam = cam.scrolled(.{ .factor_x = 0.5 });
    try std.testing.expect(overlapsView(layer_cam.viewRect(), .{ .x = 15, .y = 35, .w = 2, .h = 2 }, 0));
    try std.testing.expect(!overlapsView(cam.viewRect(), .{ .x = 15, .y = 35, .w = 2, .h = 2 }, 0));
}

test "rotated sprite bounds include destination origin and rotation" {
    const Rect = struct { x: f32, y: f32, w: f32, h: f32 };
    const dst = Rect{ .x = 11, .y = 2, .w = 4, .h = 2 };
    const view = Bounds{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const unrotated = spriteBounds(dst, .{ 0, 0 }, 0);
    const rotated = spriteBounds(dst, .{ 0, 0 }, @as(f32, std.math.pi) / 2.0);
    try std.testing.expect(!overlapsView(view, unrotated, 0));
    try std.testing.expect(overlapsView(view, rotated, 0));
    try std.testing.expectApproxEqAbs(@as(f32, 9), rotated.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 11), rotated.x + rotated.w, 1e-5);
}
