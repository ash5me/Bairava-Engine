const std = @import("std");

/// A view into the world, measured in native pixels. `x` and `y` are the world position
/// of the view's top-left corner.
pub const Camera = struct {
    x: f32 = 0,
    y: f32 = 0,
    view_w: f32,
    view_h: f32,
    world_w: f32,
    world_h: f32,

    /// Centers the view on a world point, clamped so the view never shows past the world edges.
    /// The result snaps to whole pixels so pixel art doesn't shimmer as the camera moves.
    pub fn follow(self: *Camera, target_x: f32, target_y: f32) void {
        self.x = @round(clampAxis(target_x - self.view_w / 2.0, self.view_w, self.world_w));
        self.y = @round(clampAxis(target_y - self.view_h / 2.0, self.view_h, self.world_h));
    }
};

/// Keeps a view position within [0, world - view]. If the world is smaller than the view,
/// the world is centered in it.
fn clampAxis(pos: f32, view: f32, world: f32) f32 {
    if (world <= view) return (world - view) / 2.0;
    return std.math.clamp(pos, 0.0, world - view);
}
