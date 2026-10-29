const std = @import("std");
const c = @import("sdl.zig").c;

/// Keys the engine can report. To add one, add it here and map it to its SDL scancode in `scancode`.
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
};

/// Number of keys in `Key`. Per-key arrays are indexed by `@intFromEnum(key)`.
const key_count = std.enums.values(Key).len;

/// Input state. Held keys are read from SDL's keyboard state when asked. Presses, releases, and
/// clicks come from the event queue. They gather as events arrive, and `latch` hands them to the
/// game one update step at a time.
pub const Input = struct {
    keys: [*c]const bool,
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
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,

    pub fn init() Input {
        // SDL owns this array, and it stays valid for the life of the app.
        return .{ .keys = c.SDL_GetKeyboardState(null) };
    }

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
        return self.keys[@intCast(scancode(key))];
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

    /// Feeds one event from SDL_PollEvent into the input state.
    pub fn handleEvent(self: *Input, event: *const c.SDL_Event) void {
        switch (event.type) {
            c.SDL_EVENT_KEY_DOWN => {
                if (!event.key.repeat) {
                    if (keyFromScancode(event.key.scancode)) |key| self.pending_pressed[@intFromEnum(key)] = true;
                }
            },
            c.SDL_EVENT_KEY_UP => {
                if (keyFromScancode(event.key.scancode)) |key| self.pending_released[@intFromEnum(key)] = true;
            },
            c.SDL_EVENT_MOUSE_MOTION => {
                self.mouse_x = event.motion.x;
                self.mouse_y = event.motion.y;
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                if (event.button.button == c.SDL_BUTTON_LEFT) {
                    self.pending_left_click = true;
                    self.pending_mouse_pressed = true;
                    self.mouse_down = true;
                }
            },
            c.SDL_EVENT_MOUSE_BUTTON_UP => {
                if (event.button.button == c.SDL_BUTTON_LEFT) {
                    self.pending_mouse_released = true;
                    self.mouse_down = false;
                }
            },
            else => {},
        }
    }
};

/// Maps a key to its SDL scancode. This is the only place that names SDL keys.
fn scancode(key: Key) c.SDL_Scancode {
    return switch (key) {
        .escape => c.SDL_SCANCODE_ESCAPE,
        .left => c.SDL_SCANCODE_LEFT,
        .right => c.SDL_SCANCODE_RIGHT,
        .up => c.SDL_SCANCODE_UP,
        .down => c.SDL_SCANCODE_DOWN,
        .w => c.SDL_SCANCODE_W,
        .a => c.SDL_SCANCODE_A,
        .s => c.SDL_SCANCODE_S,
        .d => c.SDL_SCANCODE_D,
        .i => c.SDL_SCANCODE_I,
        .equal => c.SDL_SCANCODE_EQUALS,
        .minus => c.SDL_SCANCODE_MINUS,
        .zero => c.SDL_SCANCODE_0,
        .keypad_plus => c.SDL_SCANCODE_KP_PLUS,
        .keypad_minus => c.SDL_SCANCODE_KP_MINUS,
    };
}

/// The key for an SDL scancode, or null if the engine doesn't name that key.
fn keyFromScancode(code: c.SDL_Scancode) ?Key {
    for (std.enums.values(Key)) |key| {
        if (scancode(key) == code) return key;
    }
    return null;
}

// Tests. They build SDL events by hand and never call SDL, so they need no window or keyboard.

/// SDL's keyboard state has one entry per scancode, so the tests use an array that size.
const scancode_count: usize = @intCast(c.SDL_SCANCODE_COUNT);
const KeyState = [scancode_count]bool;

/// A key event as SDL fills one in. `repeat` marks an auto-repeated key-down.
fn keyEvent(event_type: anytype, code: anytype, repeat: bool) c.SDL_Event {
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = @intCast(event_type);
    event.key.scancode = @intCast(code);
    event.key.repeat = repeat;
    return event;
}

/// A mouse button event as SDL fills one in.
fn buttonEvent(event_type: anytype, button: anytype) c.SDL_Event {
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = @intCast(event_type);
    event.button.button = @intCast(button);
    return event;
}

/// A mouse motion event at a window position, in points.
fn motionEvent(x: f32, y: f32) c.SDL_Event {
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = @intCast(c.SDL_EVENT_MOUSE_MOTION);
    event.motion.x = x;
    event.motion.y = y;
    return event;
}

test "keys map to the SDL scancodes the controls expect" {
    // Pins the mapping to SDL's own names, so a wrong entry in `scancode` is caught here.
    try std.testing.expectEqual(@as(?Key, .escape), keyFromScancode(c.SDL_SCANCODE_ESCAPE));
    try std.testing.expectEqual(@as(?Key, .left), keyFromScancode(c.SDL_SCANCODE_LEFT));
    try std.testing.expectEqual(@as(?Key, .right), keyFromScancode(c.SDL_SCANCODE_RIGHT));
    try std.testing.expectEqual(@as(?Key, .up), keyFromScancode(c.SDL_SCANCODE_UP));
    try std.testing.expectEqual(@as(?Key, .down), keyFromScancode(c.SDL_SCANCODE_DOWN));
    try std.testing.expectEqual(@as(?Key, .w), keyFromScancode(c.SDL_SCANCODE_W));
    try std.testing.expectEqual(@as(?Key, .a), keyFromScancode(c.SDL_SCANCODE_A));
    try std.testing.expectEqual(@as(?Key, .s), keyFromScancode(c.SDL_SCANCODE_S));
    try std.testing.expectEqual(@as(?Key, .d), keyFromScancode(c.SDL_SCANCODE_D));
    try std.testing.expectEqual(@as(?Key, .i), keyFromScancode(c.SDL_SCANCODE_I));
    try std.testing.expectEqual(@as(?Key, .equal), keyFromScancode(c.SDL_SCANCODE_EQUALS));
    try std.testing.expectEqual(@as(?Key, .minus), keyFromScancode(c.SDL_SCANCODE_MINUS));
    try std.testing.expectEqual(@as(?Key, .zero), keyFromScancode(c.SDL_SCANCODE_0));
    try std.testing.expectEqual(@as(?Key, .keypad_plus), keyFromScancode(c.SDL_SCANCODE_KP_PLUS));
    try std.testing.expectEqual(@as(?Key, .keypad_minus), keyFromScancode(c.SDL_SCANCODE_KP_MINUS));
}

test "every key has its own scancode, and that scancode maps back to it" {
    // If two keys shared a scancode, one of them would not map back to itself.
    for (std.enums.values(Key)) |key| {
        try std.testing.expectEqual(@as(?Key, key), keyFromScancode(scancode(key)));
    }
}

test "held reports only the key whose scancode is down" {
    for (std.enums.values(Key)) |down| {
        var keys: KeyState = [_]bool{false} ** scancode_count;
        keys[@intCast(scancode(down))] = true;
        const input = Input{ .keys = &keys };
        for (std.enums.values(Key)) |key| {
            try std.testing.expectEqual(key == down, input.held(key));
        }
    }
}

test "held follows the keyboard state and needs no event" {
    var keys: KeyState = [_]bool{false} ** scancode_count;
    keys[@intCast(scancode(.s))] = true;
    const input = Input{ .keys = &keys };
    try std.testing.expect(input.held(.s));
    // Held is live state. A press only counts once an event has been latched.
    try std.testing.expect(!input.wasPressed(.s));
}

test "a press reaches the update step only after latch, and only once" {
    const keys: KeyState = [_]bool{false} ** scancode_count;
    var input = Input{ .keys = &keys };
    const event = keyEvent(c.SDL_EVENT_KEY_DOWN, c.SDL_SCANCODE_W, false);
    input.handleEvent(&event);
    try std.testing.expect(!input.wasPressed(.w));

    input.latch();
    try std.testing.expect(input.wasPressed(.w));

    // The next update step has no new events, so the press is gone.
    input.latch();
    try std.testing.expect(!input.wasPressed(.w));
}

test "a release reaches the update step only after latch, and only once" {
    const keys: KeyState = [_]bool{false} ** scancode_count;
    var input = Input{ .keys = &keys };
    const event = keyEvent(c.SDL_EVENT_KEY_UP, c.SDL_SCANCODE_S, false);
    input.handleEvent(&event);
    try std.testing.expect(!input.wasReleased(.s));

    input.latch();
    try std.testing.expect(input.wasReleased(.s));

    input.latch();
    try std.testing.expect(!input.wasReleased(.s));
}

test "an auto-repeated key-down is not a new press" {
    // Holding a key makes the OS send repeats. Each one must not count as a fresh press.
    const keys: KeyState = [_]bool{false} ** scancode_count;
    var input = Input{ .keys = &keys };
    const event = keyEvent(c.SDL_EVENT_KEY_DOWN, c.SDL_SCANCODE_W, true);
    input.handleEvent(&event);
    input.latch();
    try std.testing.expect(!input.wasPressed(.w));
}

test "a press and a release in the same frame both reach the next update" {
    const keys: KeyState = [_]bool{false} ** scancode_count;
    var input = Input{ .keys = &keys };
    const down = keyEvent(c.SDL_EVENT_KEY_DOWN, c.SDL_SCANCODE_A, false);
    const up = keyEvent(c.SDL_EVENT_KEY_UP, c.SDL_SCANCODE_A, false);
    input.handleEvent(&down);
    input.handleEvent(&up);
    input.latch();
    try std.testing.expect(input.wasPressed(.a));
    try std.testing.expect(input.wasReleased(.a));
}

test "events from frames with no update wait for the next latch" {
    // A frame with no update step never latches, so its events must survive until one does.
    const keys: KeyState = [_]bool{false} ** scancode_count;
    var input = Input{ .keys = &keys };
    const w_down = keyEvent(c.SDL_EVENT_KEY_DOWN, c.SDL_SCANCODE_W, false);
    const d_down = keyEvent(c.SDL_EVENT_KEY_DOWN, c.SDL_SCANCODE_D, false);
    input.handleEvent(&w_down);
    input.handleEvent(&d_down);
    input.latch();
    try std.testing.expect(input.wasPressed(.w));
    try std.testing.expect(input.wasPressed(.d));

    input.latch();
    try std.testing.expect(!input.wasPressed(.w));
    try std.testing.expect(!input.wasPressed(.d));
}

test "keys the engine does not name are ignored" {
    // Z is not in `Key`, so the event is dropped and no key is reported.
    const keys: KeyState = [_]bool{false} ** scancode_count;
    var input = Input{ .keys = &keys };
    const event = keyEvent(c.SDL_EVENT_KEY_DOWN, c.SDL_SCANCODE_Z, false);
    input.handleEvent(&event);
    input.latch();
    for (std.enums.values(Key)) |key| {
        try std.testing.expect(!input.wasPressed(key));
    }
}

test "anyHeld, anyPressed and anyReleased are true when any listed key matches" {
    var keys: KeyState = [_]bool{false} ** scancode_count;
    keys[@intCast(scancode(.left))] = true;
    var input = Input{ .keys = &keys };
    try std.testing.expect(input.anyHeld(&.{ .w, .left }));
    try std.testing.expect(!input.anyHeld(&.{ .w, .d }));
    const none: []const Key = &.{};
    try std.testing.expect(!input.anyHeld(none));

    const d_down = keyEvent(c.SDL_EVENT_KEY_DOWN, c.SDL_SCANCODE_D, false);
    input.handleEvent(&d_down);
    input.latch();
    try std.testing.expect(input.anyPressed(&.{ .w, .d }));
    try std.testing.expect(!input.anyPressed(&.{ .w, .a }));
    try std.testing.expect(!input.anyReleased(&.{ .w, .d }));
}

test "mouse motion updates the position at once, before the next latch" {
    const keys: KeyState = [_]bool{false} ** scancode_count;
    var input = Input{ .keys = &keys };
    const event = motionEvent(120.5, 60.25);
    input.handleEvent(&event);
    try std.testing.expectEqual(@as(f32, 120.5), input.mouse_x);
    try std.testing.expectEqual(@as(f32, 60.25), input.mouse_y);
}

test "a left button press is latched as one click" {
    const keys: KeyState = [_]bool{false} ** scancode_count;
    var input = Input{ .keys = &keys };
    const event = buttonEvent(c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_BUTTON_LEFT);
    input.handleEvent(&event);
    try std.testing.expect(!input.left_clicked);

    input.latch();
    try std.testing.expect(input.left_clicked);

    input.latch();
    try std.testing.expect(!input.left_clicked);
}

test "other buttons and button releases do not count as a left click" {
    const keys: KeyState = [_]bool{false} ** scancode_count;
    var input = Input{ .keys = &keys };
    const right_down = buttonEvent(c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_BUTTON_RIGHT);
    const left_up = buttonEvent(c.SDL_EVENT_MOUSE_BUTTON_UP, c.SDL_BUTTON_LEFT);
    input.handleEvent(&right_down);
    input.handleEvent(&left_up);
    input.latch();
    try std.testing.expect(!input.left_clicked);
}

test "a left press sets mouse_down at once, and reaches the update step after latch" {
    const keys: KeyState = [_]bool{false} ** scancode_count;
    var input = Input{ .keys = &keys };
    const down = buttonEvent(c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_BUTTON_LEFT);
    input.handleEvent(&down);
    try std.testing.expect(input.mouse_down);
    try std.testing.expect(!input.mouse_pressed);

    input.latch();
    try std.testing.expect(input.mouse_pressed);

    // The next update step has no new events, so the press is gone, but the button is still held.
    input.latch();
    try std.testing.expect(!input.mouse_pressed);
    try std.testing.expect(input.mouse_down);
}

test "a left release clears mouse_down and reaches the update step once" {
    const keys: KeyState = [_]bool{false} ** scancode_count;
    var input = Input{ .keys = &keys };
    const down = buttonEvent(c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_BUTTON_LEFT);
    const up = buttonEvent(c.SDL_EVENT_MOUSE_BUTTON_UP, c.SDL_BUTTON_LEFT);
    input.handleEvent(&down);
    input.latch();
    input.handleEvent(&up);
    try std.testing.expect(!input.mouse_down);
    input.latch();
    try std.testing.expect(input.mouse_released);
    input.latch();
    try std.testing.expect(!input.mouse_released);
}

test "other mouse buttons leave the left-button state alone" {
    const keys: KeyState = [_]bool{false} ** scancode_count;
    var input = Input{ .keys = &keys };
    const right = buttonEvent(c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_BUTTON_RIGHT);
    input.handleEvent(&right);
    input.latch();
    try std.testing.expect(!input.mouse_down);
    try std.testing.expect(!input.mouse_pressed);
}
