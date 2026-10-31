const std = @import("std");

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
        self.x = goalX(self, target_x);
        self.y = goalY(self, target_y);
        self.placed = true;
    }

    /// Like `follow`, but eases toward the target. `rate` is how fast the camera closes the gap, per
    /// second. Each `dt` seconds it covers `1 - e^(-rate * dt)` of the distance that remains, so the
    /// result doesn't depend on the frame rate. A rate of zero or less snaps, as `follow` does.
    pub fn followSmooth(self: *Camera, target_x: f32, target_y: f32, dt: f32, rate: f32) void {
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
        if (rate <= 0) {
            self.zoom = target;
            return;
        }
        const t = 1.0 - @exp(-rate * dt);
        // Moving the logarithm of the zoom keeps each zoom step the same size on screen.
        self.zoom *= @exp((@log(target) - @log(self.zoom)) * t);
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

    fn goalX(self: *const Camera, target_x: f32) f32 {
        return clampAxis(target_x - self.view_w / 2.0, self.view_w, self.world_w);
    }

    fn goalY(self: *const Camera, target_y: f32) f32 {
        return clampAxis(target_y - self.view_h / 2.0, self.view_h, self.world_h);
    }
};

/// Keeps a view position within [0, world - view]. If the world is smaller than the view,
/// the world is centered in it.
fn clampAxis(pos: f32, view: f32, world: f32) f32 {
    if (world <= view) return (world - view) / 2.0;
    return std.math.clamp(pos, 0.0, world - view);
}
