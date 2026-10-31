//! Keyboard and mouse through SDL3. This file turns SDL events and the keyboard state into the
//! platform-independent `Input` in input/input.zig. It is the only place that names SDL keys.

const std = @import("std");
const c = @import("sdl.zig").c;
const input = @import("../../input/input.zig");
const Input = input.Input;
const Key = input.Key;

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
        .space => c.SDL_SCANCODE_SPACE,
        .enter => c.SDL_SCANCODE_RETURN,
        .tab => c.SDL_SCANCODE_TAB,
        .q => c.SDL_SCANCODE_Q,
        .e => c.SDL_SCANCODE_E,
        .f => c.SDL_SCANCODE_F,
        .r => c.SDL_SCANCODE_R,
        .f5 => c.SDL_SCANCODE_F5,
        .f9 => c.SDL_SCANCODE_F9,
    };
}

/// The key for an SDL scancode, or null if the engine doesn't name that key.
fn keyFromScancode(code: c.SDL_Scancode) ?Key {
    for (std.enums.values(Key)) |key| {
        if (scancode(key) == code) return key;
    }
    return null;
}


/// Feeds one SDL event into the input state. Key presses ignore auto-repeat, so holding a key
/// makes one press, not many.
pub fn handleEvent(state: *Input, event: *const c.SDL_Event) void {
    switch (event.type) {
        c.SDL_EVENT_KEY_DOWN => {
            if (!event.key.repeat) {
                if (keyFromScancode(event.key.scancode)) |key| state.keyDown(key);
            }
        },
        c.SDL_EVENT_KEY_UP => {
            if (keyFromScancode(event.key.scancode)) |key| state.keyUp(key);
        },
        c.SDL_EVENT_MOUSE_MOTION => state.moveMouse(event.motion.x, event.motion.y),
        c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
            if (event.button.button == c.SDL_BUTTON_LEFT) state.leftButton(true);
        },
        c.SDL_EVENT_MOUSE_BUTTON_UP => {
            if (event.button.button == c.SDL_BUTTON_LEFT) state.leftButton(false);
        },
        else => {},
    }
}

/// Sets each key's held state from SDL's keyboard state. The runtime calls this once per frame,
/// after the event queue is drained, so held keys are as of that pump.
pub fn syncHeld(state: *Input) void {
    const keys: [*]const bool = @ptrCast(c.SDL_GetKeyboardState(null));
    applyKeyboardState(state, keys[0..scancode_count]);
}

/// Sets the held state of every key from a keyboard state indexed by SDL scancode.
pub fn applyKeyboardState(state: *Input, keys: []const bool) void {
    for (std.enums.values(Key)) |key| {
        state.setHeld(key, keys[@intCast(scancode(key))]);
    }
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
    try std.testing.expectEqual(@as(?Key, .space), keyFromScancode(c.SDL_SCANCODE_SPACE));
    try std.testing.expectEqual(@as(?Key, .enter), keyFromScancode(c.SDL_SCANCODE_RETURN));
    try std.testing.expectEqual(@as(?Key, .tab), keyFromScancode(c.SDL_SCANCODE_TAB));
    try std.testing.expectEqual(@as(?Key, .q), keyFromScancode(c.SDL_SCANCODE_Q));
    try std.testing.expectEqual(@as(?Key, .e), keyFromScancode(c.SDL_SCANCODE_E));
    try std.testing.expectEqual(@as(?Key, .f), keyFromScancode(c.SDL_SCANCODE_F));
    try std.testing.expectEqual(@as(?Key, .r), keyFromScancode(c.SDL_SCANCODE_R));
    try std.testing.expectEqual(@as(?Key, .f5), keyFromScancode(c.SDL_SCANCODE_F5));
    try std.testing.expectEqual(@as(?Key, .f9), keyFromScancode(c.SDL_SCANCODE_F9));
}

test "every key has its own scancode, and that scancode maps back to it" {
    // If two keys shared a scancode, one of them would not map back to itself.
    for (std.enums.values(Key)) |key| {
        try std.testing.expectEqual(@as(?Key, key), keyFromScancode(scancode(key)));
    }
}


test "applyKeyboardState holds only the key whose scancode is down" {
    for (std.enums.values(Key)) |down| {
        var keys: KeyState = [_]bool{false} ** scancode_count;
        keys[@intCast(scancode(down))] = true;
        var state = Input{};
        applyKeyboardState(&state, &keys);
        for (std.enums.values(Key)) |key| {
            try std.testing.expectEqual(key == down, state.held(key));
        }
    }
}

test "a key-down for each key presses exactly that key" {
    // This goes through handleEvent, so it checks the scancode mapping as well.
    for (std.enums.values(Key)) |down| {
        var state = Input{};
        const event = keyEvent(c.SDL_EVENT_KEY_DOWN, scancode(down), false);
        handleEvent(&state, &event);
        state.latch();
        for (std.enums.values(Key)) |other| {
            try std.testing.expectEqual(other == down, state.wasPressed(other));
        }
    }
}

test "an auto-repeated key-down is not a new press" {
    var state = Input{};
    const event = keyEvent(c.SDL_EVENT_KEY_DOWN, c.SDL_SCANCODE_W, true);
    handleEvent(&state, &event);
    state.latch();
    try std.testing.expect(!state.wasPressed(.w));
}

test "a key-up is a release, and a key the engine does not name is ignored" {
    var state = Input{};
    const up = keyEvent(c.SDL_EVENT_KEY_UP, c.SDL_SCANCODE_S, false);
    const unknown = keyEvent(c.SDL_EVENT_KEY_DOWN, c.SDL_SCANCODE_Z, false);
    handleEvent(&state, &up);
    handleEvent(&state, &unknown);
    state.latch();
    try std.testing.expect(state.wasReleased(.s));
    for (std.enums.values(Key)) |key| {
        try std.testing.expect(!state.wasPressed(key));
    }
}

test "mouse motion events move the pointer at once, before the next latch" {
    var state = Input{};
    const event = motionEvent(120.5, 60.25);
    handleEvent(&state, &event);
    try std.testing.expectEqual(@as(f32, 120.5), state.mouse_x);
    try std.testing.expectEqual(@as(f32, 60.25), state.mouse_y);
}

test "a left button press event is latched as one click, and other buttons are ignored" {
    var state = Input{};
    const right = buttonEvent(c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_BUTTON_RIGHT);
    handleEvent(&state, &right);
    state.latch();
    try std.testing.expect(!state.left_clicked);
    const left = buttonEvent(c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_BUTTON_LEFT);
    handleEvent(&state, &left);
    state.latch();
    try std.testing.expect(state.left_clicked);
    try std.testing.expect(state.mouse_down);
}
