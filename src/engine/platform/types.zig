//! Platform-facing value types. This file imports neither SDL nor engine systems, so the engine and
//! the platform backend can both use it without depending on each other.

/// A physical key, named by its position on the keyboard. A layout changes the character a position
/// produces, not the position, so bindings resolve through these. The engine reports 26 keys: the 24
/// in `Key` (engine/input/input.zig), plus F3 and F11.
pub const Scancode = enum {
    escape,
    left,
    right,
    up,
    down,
    w,
    a,
    s,
    d,
    i,
    equal,
    minus,
    zero,
    keypad_plus,
    keypad_minus,
    space,
    enter,
    tab,
    q,
    e,
    f,
    r,
    f5,
    f9,
    f3,
    f11,
};

pub const MouseButton = enum { left, right, middle };

/// An event the engine consumes. Backends translate native events into these and drop the rest.
/// Quit is never dropped.
pub const Event = union(enum) {
    quit,
    key_down: struct { scancode: Scancode, repeat: bool },
    key_up: struct { scancode: Scancode },
    /// Mouse position in window points.
    mouse_motion: struct { x: f32, y: f32 },
    mouse_button_down: MouseButton,
    mouse_button_up: MouseButton,
};

/// An application window. The engine holds and passes pointers to it. Only the platform backend knows
/// what is behind one, so the type has no fields.
pub const Window = opaque {};

/// A window size in pixels. This is the swapchain size, which on high-DPI displays is larger than the
/// window's size in points.
pub const PixelSize = struct { w: c_int, h: c_int };
