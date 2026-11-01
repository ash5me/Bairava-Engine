//! Fits the native view to the window, and maps mouse positions from window space to view and
//! world space. This is pure math with no SDL, so `zig build test` covers it without a window.
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

/// How the native view is fitted to the window.
pub const ScaleMode = enum {
    /// Fill the window exactly. The view grows or shrinks with the window, and some native
    /// pixels cover one more screen pixel than others.
    fit,
    /// Use a whole-number multiple of the view, so every native pixel is the same size. The
    /// result is centered, and any leftover edge pixels are black.
    integer,
};

/// How the native view is drawn into the window for one frame.
pub const Fit = struct {
    /// Window pixels per view pixel. Integer mode makes this a whole number.
    scale: f32,
    /// Size of the view in view pixels, rounded down. The view is stretched over the window at
    /// `scale`, and its size is the part of the world the window shows.
    view_w: u32,
    view_h: u32,
    /// True when integer mode applies, which means `scale` is a whole number.
    pixel_perfect: bool,
};

/// Works out how the view fits the window for one frame. `native_w` and `native_h` are the
/// reference view size from the game config, and `zoom` multiplies the scale. At zoom 1 the native
/// size fits the window on its limiting axis, and the other axis shows more of the world when the
/// window's shape differs. Zoom above 1 shows less of the world at a larger size, and zoom below 1
/// shows more.
///
/// Integer mode uses whole-number scales, so every native pixel is the same size. It applies only
/// when the window holds at least one native view, and otherwise falls back to fit. Its scale is
/// the zoomed scale rounded to a whole number, and it is never below 1.
pub fn chooseFit(win_w: f32, win_h: f32, native_w: f32, native_h: f32, mode: ScaleMode, zoom: f32) Fit {
    const safe_zoom = if (std.math.isFinite(zoom) and zoom > 0) zoom else 1.0;
    if (!std.math.isFinite(win_w) or !std.math.isFinite(win_h) or !std.math.isFinite(native_w) or
        !std.math.isFinite(native_h) or win_w <= 0 or win_h <= 0 or native_w <= 0 or native_h <= 0)
    {
        return .{ .scale = safe_zoom, .view_w = 0, .view_h = 0, .pixel_perfect = false };
    }
    const fit = @min(win_w / native_w, win_h / native_h);
    const pixel_perfect = mode == .integer and fit >= 1.0;
    const scale: f32 = if (pixel_perfect)
        @max(1.0, @round(@floor(fit) * safe_zoom))
    else
        fit * safe_zoom;
    // The 0.01 keeps float rounding from dropping a whole view pixel.
    const view_w: u32 = @intFromFloat(@floor(win_w / scale + 0.01));
    const view_h: u32 = @intFromFloat(@floor(win_h / scale + 0.01));
    return .{
        .scale = scale,
        .view_w = view_w,
        .view_h = view_h,
        .pixel_perfect = pixel_perfect,
    };
}

/// The region of the window the native view fills after the fit is chosen. In fit mode the view
/// stretches to the whole window. In integer mode it is centered and only covers a whole-number
/// multiple, leaving letterbox bars at the edges.
pub fn layoutForFit(win_w: f32, win_h: f32, fit: Fit) Layout {
    const safe_win_w = if (std.math.isFinite(win_w) and win_w > 0) win_w else 1.0;
    const safe_win_h = if (std.math.isFinite(win_h) and win_h > 0) win_h else 1.0;
    const safe_view_w = if (fit.view_w > 0) @as(f32, @floatFromInt(fit.view_w)) else 1.0;
    const safe_view_h = if (fit.view_h > 0) @as(f32, @floatFromInt(fit.view_h)) else 1.0;
    if (!fit.pixel_perfect) {
        return .{ .pixel_density = 1.0, .dst_x = 0, .dst_y = 0, .dst_w = safe_win_w, .dst_h = safe_win_h, .view_w = safe_view_w, .view_h = safe_view_h };
    }
    const content_w = safe_view_w * fit.scale;
    const content_h = safe_view_h * fit.scale;
    return .{
        .pixel_density = 1.0,
        .dst_x = @floor((safe_win_w - content_w) / 2.0),
        .dst_y = @floor((safe_win_h - content_h) / 2.0),
        .dst_w = content_w,
        .dst_h = content_h,
        .view_w = safe_view_w,
        .view_h = safe_view_h,
    };
}

/// Converts a mouse position in window points to view pixels, with (0, 0) at the view's top-left
/// corner. Positions outside the view, such as the black bars in integer mode, map to coordinates
/// below 0 or above the view size. `dst_w` and `dst_h` must be positive. The engine guarantees
/// that because it skips frames while the window has no pixels.
pub fn windowToView(layout: Layout, window: Point) Point {
    if (!std.math.isFinite(layout.dst_w) or !std.math.isFinite(layout.dst_h) or
        !std.math.isFinite(layout.view_w) or !std.math.isFinite(layout.view_h) or
        layout.dst_w <= 0 or layout.dst_h <= 0)
    {
        return .{ .x = 0, .y = 0 };
    }
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

test "layoutForFit fills the whole window in fit mode and letterboxes in integer mode" {
    const fit = chooseFit(960, 540, 320, 180, .fit, 1.0);
    const fit_layout = layoutForFit(960, 540, fit);
    try std.testing.expectEqual(@as(f32, 0.0), fit_layout.dst_x);
    try std.testing.expectEqual(@as(f32, 0.0), fit_layout.dst_y);
    try std.testing.expectEqual(@as(f32, 960.0), fit_layout.dst_w);
    try std.testing.expectEqual(@as(f32, 540.0), fit_layout.dst_h);

    const integer_fit = chooseFit(1000, 540, 320, 180, .integer, 1.0);
    const integer_layout = layoutForFit(1000, 540, integer_fit);
    try std.testing.expectEqual(@as(f32, 0.0), integer_layout.dst_x);
    try std.testing.expectEqual(@as(f32, 0.0), integer_layout.dst_y);
    try std.testing.expectEqual(@as(f32, 999.0), integer_layout.dst_w);
    try std.testing.expectEqual(@as(f32, 540.0), integer_layout.dst_h);
}

test "chooseFit at zoom 1 gives the view the window always had" {
    // A 960x540 window is exactly 3x the 320x180 native view.
    const fit = chooseFit(960, 540, 320, 180, .fit, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 3), fit.scale, 1e-4);
    try std.testing.expectEqual(@as(u32, 320), fit.view_w);
    try std.testing.expectEqual(@as(u32, 180), fit.view_h);
    try std.testing.expect(!fit.pixel_perfect);
}

test "chooseFit rounds the view size down when the window is not a whole multiple" {
    // A 1000-pixel window at zoom 1 is 3x, which gives a 333-pixel view.
    const fit = chooseFit(1000, 540, 320, 180, .fit, 1.0);
    try std.testing.expectEqual(@as(u32, 333), fit.view_w);
    try std.testing.expectEqual(@as(u32, 180), fit.view_h);
}

test "zooming in twice as far doubles the scale and halves the view" {
    const fit = chooseFit(960, 540, 320, 180, .fit, 2.0);
    try std.testing.expectApproxEqAbs(@as(f32, 6), fit.scale, 1e-4);
    try std.testing.expectEqual(@as(u32, 160), fit.view_w);
    try std.testing.expectEqual(@as(u32, 90), fit.view_h);
}

test "zooming out shows more of the world at a fractional scale" {
    const fit = chooseFit(960, 540, 320, 180, .fit, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), fit.scale, 1e-4);
    try std.testing.expectEqual(@as(u32, 640), fit.view_w);
    try std.testing.expectEqual(@as(u32, 360), fit.view_h);
}

test "integer mode keeps the zoomed scale whole" {
    // 3x at zoom 1.25 is 3.75, which rounds to 4x, so the view is 240x135.
    const fit = chooseFit(960, 540, 320, 180, .integer, 1.25);
    try std.testing.expectApproxEqAbs(@as(f32, 4), fit.scale, 1e-4);
    try std.testing.expectEqual(@as(u32, 240), fit.view_w);
    try std.testing.expectEqual(@as(u32, 135), fit.view_h);
    try std.testing.expect(fit.pixel_perfect);
}

test "integer mode never zooms out past one screen pixel per view pixel" {
    // A 320x180 window is exactly one native view, so the base scale is 1. A zoom of 0.25 rounds
    // to 0, which is raised to 1, so the view stays at the native size.
    const fit = chooseFit(320, 180, 320, 180, .integer, 0.25);
    try std.testing.expectApproxEqAbs(@as(f32, 1), fit.scale, 1e-4);
    try std.testing.expectEqual(@as(u32, 320), fit.view_w);
    try std.testing.expectEqual(@as(u32, 180), fit.view_h);
    try std.testing.expect(fit.pixel_perfect);
}

test "integer mode falls back to fit when the window cannot hold one native view" {
    // 300x170 is smaller than 320x180 on both axes, so the scale is fractional and not whole.
    const fit = chooseFit(300, 170, 320, 180, .integer, 1.0);
    try std.testing.expect(!fit.pixel_perfect);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9375), fit.scale, 1e-4);
}

test "zero-sized views are clamped to a safe fallback" {
    const fit = chooseFit(0, 0, 320, 180, .fit, 0.0);
    try std.testing.expectEqual(@as(f32, 1.0), fit.scale);
    try std.testing.expectEqual(@as(u32, 0), fit.view_w);
    try std.testing.expectEqual(@as(u32, 0), fit.view_h);

    const mapped = windowToView(.{ .dst_w = 0, .dst_h = 0, .view_w = 320, .view_h = 180 }, .{ .x = 10, .y = 20 });
    try std.testing.expectEqual(@as(f32, 0.0), mapped.x);
    try std.testing.expectEqual(@as(f32, 0.0), mapped.y);
}

test "at zoom 2 the window center maps to the camera's view center" {
    // The view is 160x90 at zoom 2, stretched over the window. The window center is the view center,
    // (80, 45), and adding the camera position at (100, 50) gives the world point.
    const layout = Layout{ .dst_w = 960, .dst_h = 540, .view_w = 160, .view_h = 90 };
    const camera = Camera{ .x = 100, .y = 50, .view_w = 160, .view_h = 90, .world_w = 640, .world_h = 384 };
    const p = windowToWorld(layout, &camera, .{ .x = 480, .y = 270 });
    try std.testing.expectApproxEqAbs(@as(f32, 180), p.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 95), p.y, 1e-4);
}
