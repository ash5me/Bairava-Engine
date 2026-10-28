const std = @import("std");

/// A view into the world, measured in native pixels. `x` and `y` are the world position of the
/// view's top-left corner, rounded to whole pixels for drawing.
pub const Camera = struct {
    x: f32 = 0,
    y: f32 = 0,
    view_w: f32,
    view_h: f32,
    world_w: f32,
    world_h: f32,
    /// The unrounded position that smoothing moves. `x` and `y` are this, rounded. Keeping the
    /// fraction matters: a step that rounds to zero would never close the gap.
    smooth_x: f32 = 0,
    smooth_y: f32 = 0,
    /// False until the camera has been placed once. The first placement snaps, so the view doesn't
    /// glide in from the corner of the world when the game starts.
    placed: bool = false,

    /// Centers the view on a world point, clamped so the view never shows past the world edges.
    /// The result snaps to whole pixels so pixel art doesn't shimmer as the camera moves.
    pub fn follow(self: *Camera, target_x: f32, target_y: f32) void {
        self.smooth_x = goalX(self, target_x);
        self.smooth_y = goalY(self, target_y);
        self.placed = true;
        self.snapToPixels();
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
        self.smooth_x += (goalX(self, target_x) - self.smooth_x) * t;
        self.smooth_y += (goalY(self, target_y) - self.smooth_y) * t;
        self.snapToPixels();
    }

    fn goalX(self: *const Camera, target_x: f32) f32 {
        return clampAxis(target_x - self.view_w / 2.0, self.view_w, self.world_w);
    }

    fn goalY(self: *const Camera, target_y: f32) f32 {
        return clampAxis(target_y - self.view_h / 2.0, self.view_h, self.world_h);
    }

    fn snapToPixels(self: *Camera) void {
        self.x = @round(self.smooth_x);
        self.y = @round(self.smooth_y);
    }
};

/// Keeps a view position within [0, world - view]. If the world is smaller than the view,
/// the world is centered in it.
fn clampAxis(pos: f32, view: f32, world: f32) f32 {
    if (world <= view) return (world - view) / 2.0;
    return std.math.clamp(pos, 0.0, world - view);
}
