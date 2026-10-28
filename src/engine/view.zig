//! Maps mouse positions from window space to view and world space. This is pure math with no
//! SDL, so `zig build test` covers it without a window.
//!
//! SDL reports mouse positions in window points. On high-DPI displays one point is several
//! physical pixels, and the swapchain is sized in pixels. The engine stretches the native view
//! into a rectangle of those pixels, so mapping a mouse position back means inverting that
//! rectangle. Adding the camera position then gives world pixels.

const std = @import("std");
const Camera = @import("camera.zig").Camera;

/// A point in some coordinate space.
pub const Point = struct {
    x: f32,
    y: f32,
};

/// Where the native view is drawn in the window. The engine fills this in each frame from the
/// same numbers it uses to draw, so a mouse position maps back to what is on screen.
pub const Layout = struct {
    /// Window pixels per window point. Mouse events are in points, and the swapchain is in pixels.
    pixel_density: f32 = 1.0,
    /// The window-pixel rectangle the view is stretched into. Fit mode covers the whole window.
    /// Integer mode covers a centered whole-number multiple of the view, so the bars around it
    /// are outside the view.
    dst_x: f32 = 0.0,
    dst_y: f32 = 0.0,
    dst_w: f32,
    dst_h: f32,
    /// Size of the view in view pixels.
    view_w: f32,
    view_h: f32,
};

/// Converts a mouse position in window points to view pixels, with (0, 0) at the view's top-left
/// corner. Positions outside the view, such as the black bars in integer mode, map to coordinates
/// below 0 or above the view size. `dst_w` and `dst_h` must be positive. The engine guarantees
/// that because it skips frames while the window has no pixels.
pub fn windowToView(layout: Layout, window: Point) Point {
    const px = window.x * layout.pixel_density;
    const py = window.y * layout.pixel_density;
    return .{
        .x = (px - layout.dst_x) * layout.view_w / layout.dst_w,
        .y = (py - layout.dst_y) * layout.view_h / layout.dst_h,
    };
}

/// Converts a mouse position in window points to world pixels. `camera` must be the camera as the
/// view was drawn with it, since its position sets where the view's corner is in the world.
pub fn windowToWorld(layout: Layout, camera: *const Camera, window: Point) Point {
    const v = windowToView(layout, window);
    return .{ .x = v.x + camera.x, .y = v.y + camera.y };
}

test "fit mode maps the window center to the view center" {
    const layout = Layout{ .dst_w = 960, .dst_h = 540, .view_w = 320, .view_h = 180 };
    const p = windowToView(layout, .{ .x = 480, .y = 270 });
    try std.testing.expectApproxEqAbs(@as(f32, 160), p.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 90), p.y, 1e-4);
}

test "high-DPI converts points to pixels before mapping to the view" {
    // The same window point on a 2x display. Before this mapping existed, the point was read as
    // pixels and landed at (80, 45), halfway to the view's center.
    const layout = Layout{
        .pixel_density = 2.0,
        .dst_w = 1920,
        .dst_h = 1080,
        .view_w = 320,
        .view_h = 180,
    };
    const p = windowToView(layout, .{ .x = 480, .y = 270 });
    try std.testing.expectApproxEqAbs(@as(f32, 160), p.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 90), p.y, 1e-4);
}

test "fit mode reaches the view's far edge when the view size is rounded down" {
    // A 1000-pixel window with a 3x scale gives a 333-pixel view, because the view size is rounded
    // down. The view is stretched over all 1000 pixels, so its right edge is at 333. Dividing by
    // the scale would put it at 333.3.
    const layout = Layout{ .dst_w = 1000, .dst_h = 540, .view_w = 333, .view_h = 180 };
    const p = windowToView(layout, .{ .x = 1000, .y = 540 });
    try std.testing.expectApproxEqAbs(@as(f32, 333), p.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 180), p.y, 1e-4);
}

test "integer mode maps through the centered view and the bars fall outside it" {
    // A 1000-pixel window with the 320x180 view at 3x. The view covers 960 pixels, centered, so
    // it starts 20 pixels in from the left.
    const layout = Layout{
        .dst_x = 20.0,
        .dst_w = 960,
        .dst_h = 540,
        .view_w = 320,
        .view_h = 180,
    };
    const top_left = windowToView(layout, .{ .x = 20, .y = 0 });
    try std.testing.expectApproxEqAbs(@as(f32, 0), top_left.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0), top_left.y, 1e-4);

    const bottom_right = windowToView(layout, .{ .x = 980, .y = 540 });
    try std.testing.expectApproxEqAbs(@as(f32, 320), bottom_right.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 180), bottom_right.y, 1e-4);

    // A point in the left black bar maps to a negative x, which is outside the view.
    const bar = windowToView(layout, .{ .x = 10, .y = 270 });
    try std.testing.expect(bar.x < 0);
}

test "windowToWorld adds the camera position to the view position" {
    const layout = Layout{ .dst_w = 960, .dst_h = 540, .view_w = 320, .view_h = 180 };
    const camera = Camera{ .x = 100, .y = 50, .view_w = 320, .view_h = 180, .world_w = 640, .world_h = 384 };
    const p = windowToWorld(layout, &camera, .{ .x = 480, .y = 270 });
    try std.testing.expectApproxEqAbs(@as(f32, 260), p.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 140), p.y, 1e-4);
}
