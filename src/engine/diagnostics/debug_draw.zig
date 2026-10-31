//! Debug shapes in view pixels. Game code and the engine queue them during `draw`, and the overlay
//! draws them above the game. The shapes are in view space, not world space, because the caller
//! maps world positions through the camera before adding them. That keeps this file free of any
//! camera or GPU type. The list is cleared every frame, and a shape past the capacity is counted in
//! `dropped`, so a busy scene shows that it lost some.

pub const max_shapes = 512;

/// An RGBA color, each channel from 0 to 1.
pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

pub const Kind = enum {
    /// A one-pixel border drawn just inside the rectangle.
    outline,
    /// A solid rectangle.
    fill,
};

pub const Shape = struct {
    kind: Kind,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    color: Color,
};

pub const Draw = struct {
    shapes: [max_shapes]Shape = undefined,
    /// Shapes queued this frame.
    count: usize = 0,
    /// Shapes that did not fit this frame.
    dropped: u32 = 0,

    /// Empties the list. The engine calls this before each frame's draw.
    pub fn clear(self: *Draw) void {
        self.count = 0;
        self.dropped = 0;
    }

    pub fn add(self: *Draw, shape: Shape) void {
        if (self.count == max_shapes) {
            self.dropped += 1;
            return;
        }
        self.shapes[self.count] = shape;
        self.count += 1;
    }

    /// A one-pixel outline of the rectangle, in view pixels.
    pub fn outline(self: *Draw, x: f32, y: f32, w: f32, h: f32, color: Color) void {
        self.add(.{ .kind = .outline, .x = x, .y = y, .w = w, .h = h, .color = color });
    }

    /// A solid rectangle, in view pixels.
    pub fn fill(self: *Draw, x: f32, y: f32, w: f32, h: f32, color: Color) void {
        self.add(.{ .kind = .fill, .x = x, .y = y, .w = w, .h = h, .color = color });
    }

    /// A 3 by 3 marker centered on (x, y), in view pixels.
    pub fn point(self: *Draw, x: f32, y: f32, color: Color) void {
        self.fill(x - 1, y - 1, 3, 3, color);
    }

    /// The shapes queued this frame, in the order they were added.
    pub fn slice(self: *const Draw) []const Shape {
        return self.shapes[0..self.count];
    }
};

const std = @import("std");

const red = Color{ .r = 1, .g = 0, .b = 0, .a = 1 };

test "shapes are kept in the order they were added" {
    var draw = Draw{};
    draw.outline(1, 2, 3, 4, red);
    draw.fill(5, 6, 7, 8, red);
    try std.testing.expectEqual(@as(usize, 2), draw.slice().len);
    try std.testing.expectEqual(Kind.outline, draw.slice()[0].kind);
    try std.testing.expectEqual(Kind.fill, draw.slice()[1].kind);
    try std.testing.expectEqual(@as(f32, 5), draw.slice()[1].x);
}

test "a point is a 3 by 3 fill centered on its position" {
    var draw = Draw{};
    draw.point(10, 20, red);
    const shape = draw.slice()[0];
    try std.testing.expectEqual(Kind.fill, shape.kind);
    try std.testing.expectEqual(@as(f32, 9), shape.x);
    try std.testing.expectEqual(@as(f32, 19), shape.y);
    try std.testing.expectEqual(@as(f32, 3), shape.w);
}

test "a full list counts what it drops, and clear empties it" {
    var draw = Draw{};
    var i: usize = 0;
    while (i < max_shapes + 2) : (i += 1) draw.fill(0, 0, 1, 1, red);
    try std.testing.expectEqual(@as(usize, max_shapes), draw.count);
    try std.testing.expectEqual(@as(u32, 2), draw.dropped);

    draw.clear();
    try std.testing.expectEqual(@as(usize, 0), draw.slice().len);
    try std.testing.expectEqual(@as(u32, 0), draw.dropped);
}
