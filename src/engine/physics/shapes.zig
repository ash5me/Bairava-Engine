//! Shapes in pixels, shared by movement and collision. Pure code with no SDL, so tests need no window.

/// A point in pixels.
pub const Point = struct {
    x: f32,
    y: f32,
};

/// A rectangle in pixels, with its top-left corner at (x, y).
pub const Box = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};
