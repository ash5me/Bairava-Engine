//! Keyboard and mouse state, with no platform code. The platform layer (platform/sdl/input.zig)
//! fills it from SDL: held keys once per frame, and presses, releases, and clicks as they arrive.
//! The game reads it during `update`, where each press or click appears in exactly one step.

const std = @import("std");

/// Keys the engine can report. To add one, add it here and map it to its SDL scancode in platform/sdl/input.zig.
pub const Key = enum {
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
};


/// Number of keys in `Key`. Per-key arrays are indexed by `@intFromEnum(key)`.
const key_count = std.enums.values(Key).len;


/// Input state. Held keys are set by the platform once per frame. Presses, releases, and clicks
/// gather as events arrive, and `latch` hands them to the game one update step at a time.
pub const Input = struct {
    /// Held state of each key, indexed by `@intFromEnum(key)`, as of the latest event pump.
    held_keys: [key_count]bool = [_]bool{false} ** key_count,
    /// Events gathered since the last `latch`.
    pending_pressed: [key_count]bool = [_]bool{false} ** key_count,
    pending_released: [key_count]bool = [_]bool{false} ** key_count,
    pending_left_click: bool = false,
    /// Left button edges gathered since the last `latch`.
    pending_mouse_pressed: bool = false,
    pending_mouse_released: bool = false,
    /// Events handed to the game by the latest `latch`. These are what the query methods report.
    pressed: [key_count]bool = [_]bool{false} ** key_count,
    released: [key_count]bool = [_]bool{false} ** key_count,
    left_clicked: bool = false,
    /// The left button is held down, as of the latest event. Unlike the one-shot fields, this is live.
    mouse_down: bool = false,
    /// Left button edges handed to the game by the latest `latch`.
    mouse_pressed: bool = false,
    mouse_released: bool = false,
    /// Mouse position in window points. `Context.mouseWorld` converts it to world pixels.
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,

    /// Hands the events gathered since the last call to the game, and starts gathering afresh.
    /// The engine calls this before each update step, so each press or click reaches exactly one update.
    pub fn latch(self: *Input) void {
        self.pressed = self.pending_pressed;
        self.released = self.pending_released;
        self.left_clicked = self.pending_left_click;
        self.mouse_pressed = self.pending_mouse_pressed;
        self.mouse_released = self.pending_mouse_released;
        @memset(&self.pending_pressed, false);
        @memset(&self.pending_released, false);
        self.pending_left_click = false;
        self.pending_mouse_pressed = false;
        self.pending_mouse_released = false;
    }

    /// True while the key is held down, as of the latest event pump.
    pub fn held(self: *const Input, key: Key) bool {
        return self.held_keys[@intFromEnum(key)];
    }

    /// True during the update step that first sees the key go down.
    pub fn wasPressed(self: *const Input, key: Key) bool {
        return self.pressed[@intFromEnum(key)];
    }

    /// True during the update step that first sees the key go up.
    pub fn wasReleased(self: *const Input, key: Key) bool {
        return self.released[@intFromEnum(key)];
    }

    /// True while any of `keys` is held.
    pub fn anyHeld(self: *const Input, keys: []const Key) bool {
        for (keys) |key| {
            if (self.held(key)) return true;
        }
        return false;
    }

    /// True during the update step that first sees any of `keys` go down.
    pub fn anyPressed(self: *const Input, keys: []const Key) bool {
        for (keys) |key| {
            if (self.wasPressed(key)) return true;
        }
        return false;
    }

    /// True during the update step that first sees any of `keys` go up.
    pub fn anyReleased(self: *const Input, keys: []const Key) bool {
        for (keys) |key| {
            if (self.wasReleased(key)) return true;
        }
        return false;
    }

    /// Sets whether a key is held. The platform calls this from the keyboard state.
    pub fn setHeld(self: *Input, key: Key, down: bool) void {
        self.held_keys[@intFromEnum(key)] = down;
    }

    /// Records a key going down. The platform drops auto-repeat before calling this.
    pub fn keyDown(self: *Input, key: Key) void {
        self.pending_pressed[@intFromEnum(key)] = true;
    }

    /// Records a key going up.
    pub fn keyUp(self: *Input, key: Key) void {
        self.pending_released[@intFromEnum(key)] = true;
    }

    /// Records the mouse position, in window points.
    pub fn moveMouse(self: *Input, x: f32, y: f32) void {
        self.mouse_x = x;
        self.mouse_y = y;
    }

    /// Records a left button press (`down` true) or release. Other buttons are not recorded.
    pub fn leftButton(self: *Input, down: bool) void {
        if (down) {
            self.pending_left_click = true;
            self.pending_mouse_pressed = true;
            self.mouse_down = true;
        } else {
            self.pending_mouse_released = true;
            self.mouse_down = false;
        }
    }
};

test "a press reaches the update step only after latch, and only once" {
    var input = Input{};
    input.keyDown(.w);
    try std.testing.expect(!input.wasPressed(.w));

    input.latch();
    try std.testing.expect(input.wasPressed(.w));

    // The next update step has no new events, so the press is gone.
    input.latch();
    try std.testing.expect(!input.wasPressed(.w));
}

test "a release reaches the update step only after latch, and only once" {
    var input = Input{};
    input.keyUp(.s);
    try std.testing.expect(!input.wasReleased(.s));

    input.latch();
    try std.testing.expect(input.wasReleased(.s));

    input.latch();
    try std.testing.expect(!input.wasReleased(.s));
}

test "a press and a release in the same frame both reach the next update" {
    var input = Input{};
    input.keyDown(.a);
    input.keyUp(.a);
    input.latch();
    try std.testing.expect(input.wasPressed(.a));
    try std.testing.expect(input.wasReleased(.a));
}

test "events from a frame with no update wait for the next latch" {
    // A frame with no update step never latches, so its events must survive until one does.
    var input = Input{};
    input.keyDown(.w);
    input.keyDown(.d);
    input.latch();
    try std.testing.expect(input.wasPressed(.w));
    try std.testing.expect(input.wasPressed(.d));
}

test "held is set by setHeld, and a press does not make a key held" {
    var input = Input{};
    input.setHeld(.s, true);
    try std.testing.expect(input.held(.s));
    try std.testing.expect(!input.wasPressed(.s));
    input.setHeld(.s, false);
    try std.testing.expect(!input.held(.s));
}

test "held reports only the key that was set" {
    for (std.enums.values(Key)) |down| {
        var input = Input{};
        input.setHeld(down, true);
        for (std.enums.values(Key)) |key| {
            try std.testing.expectEqual(key == down, input.held(key));
        }
    }
}

test "anyHeld, anyPressed and anyReleased are true when any listed key matches" {
    var input = Input{};
    input.setHeld(.left, true);
    try std.testing.expect(input.anyHeld(&.{ .w, .left }));
    try std.testing.expect(!input.anyHeld(&.{ .w, .d }));
    const none: []const Key = &.{};
    try std.testing.expect(!input.anyHeld(none));

    input.keyDown(.d);
    input.latch();
    try std.testing.expect(input.anyPressed(&.{ .w, .d }));
    try std.testing.expect(!input.anyPressed(&.{ .w, .a }));
    try std.testing.expect(!input.anyReleased(&.{ .w, .d }));
}

test "mouse motion updates the position at once, before the next latch" {
    var input = Input{};
    input.moveMouse(120.5, 60.25);
    try std.testing.expectEqual(@as(f32, 120.5), input.mouse_x);
    try std.testing.expectEqual(@as(f32, 60.25), input.mouse_y);
}

test "a left button press is latched as one click" {
    var input = Input{};
    input.leftButton(true);
    try std.testing.expect(!input.left_clicked);

    input.latch();
    try std.testing.expect(input.left_clicked);

    input.latch();
    try std.testing.expect(!input.left_clicked);
}

test "a left press sets mouse_down at once, and reaches the update step after latch" {
    var input = Input{};
    input.leftButton(true);
    try std.testing.expect(input.mouse_down);
    try std.testing.expect(!input.mouse_pressed);

    input.latch();
    try std.testing.expect(input.mouse_pressed);

    input.latch();
    try std.testing.expect(!input.mouse_pressed);
}

test "a left release clears mouse_down and reaches the update step once" {
    var input = Input{};
    input.leftButton(true);
    input.latch();
    input.leftButton(false);
    try std.testing.expect(!input.mouse_down);
    try std.testing.expect(!input.mouse_released);

    input.latch();
    try std.testing.expect(input.mouse_released);

    input.latch();
    try std.testing.expect(!input.mouse_released);
}
