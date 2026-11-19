const std = @import("std");

pub const Scroll = struct {
    factor_x: f32 = 1,
    factor_y: f32 = 1,
    /// Added after the factor. The game owns this value, such as a speed multiplied by elapsed time.
    offset_x: f32 = 0,
    offset_y: f32 = 0,
};

/// A view into the world, measured in native pixels. `x` and `y` are the world position of the
/// view's top-left corner. They are not rounded, so smoothing keeps its fractions. Drawing rounds
/// each sprite's screen position once, with `screenX` and `screenY`.
pub const Camera = struct {
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

    /// Centers the view on a world point, clamped so the view never shows past the world edges.
    pub fn follow(self: *Camera, target_x: f32, target_y: f32) void {
        if (!std.math.isFinite(target_x) or !std.math.isFinite(target_y) or
            !std.math.isFinite(self.view_w) or !std.math.isFinite(self.view_h) or
            !std.math.isFinite(self.world_w) or !std.math.isFinite(self.world_h) or
            self.view_w <= 0 or self.view_h <= 0)
        {
            return;
        }
        self.x = goalX(self, target_x);
        self.y = goalY(self, target_y);
        self.placed = true;
    }

    /// Like `follow`, but eases toward the target. `rate` is how fast the camera closes the gap, per
    /// second. Each `dt` seconds it covers `1 - e^(-rate * dt)` of the distance that remains, so the
    /// result doesn't depend on the frame rate. A rate of zero or less snaps, as `follow` does.
    pub fn followSmooth(self: *Camera, target_x: f32, target_y: f32, dt: f32, rate: f32) void {
        if (!std.math.isFinite(target_x) or !std.math.isFinite(target_y) or !std.math.isFinite(dt) or
            !std.math.isFinite(rate) or !std.math.isFinite(self.view_w) or !std.math.isFinite(self.view_h) or
            !std.math.isFinite(self.world_w) or !std.math.isFinite(self.world_h) or
            self.view_w <= 0 or self.view_h <= 0)
        {
            self.follow(target_x, target_y);
            return;
        }
        if (!self.placed or rate <= 0) {
            self.follow(target_x, target_y);
            return;
        }
        const t = 1.0 - @exp(-rate * dt);
        self.x += (goalX(self, target_x) - self.x) * t;
        self.y += (goalY(self, target_y) - self.y) * t;
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

    /// Returns a draw-only camera copy. Gameplay camera state and view/world dimensions are unchanged.
    pub fn scrolled(self: Camera, scroll: Scroll) Camera {
        var result = self;
        result.x = scrolledOrigin(self.x, scroll.factor_x, scroll.offset_x);
        result.y = scrolledOrigin(self.y, scroll.factor_y, scroll.offset_y);
        return result;
    }

    fn goalX(self: *const Camera, target_x: f32) f32 {
        return clampAxis(target_x - self.view_w / 2.0, self.view_w, self.world_w);
    }

    fn goalY(self: *const Camera, target_y: f32) f32 {
        return clampAxis(target_y - self.view_h / 2.0, self.view_h, self.world_h);
    }
};

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
