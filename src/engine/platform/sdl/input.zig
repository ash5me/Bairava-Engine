//! Keyboard and mouse through SDL3. This file turns SDL events and the keyboard state into the
//! platform-neutral types in platform/types.zig. It is the only place that names SDL keys.

const std = @import("std");
const c = @import("sdl.zig").c;
const types = @import("../types.zig");
const Scancode = types.Scancode;
const Event = types.Event;
const MouseButton = types.MouseButton;

/// SDL's keyboard state has one entry per scancode, so arrays of that size index it.
const scancode_count: usize = @intCast(c.SDL_SCANCODE_COUNT);

/// Maps a scancode to its SDL scancode. The switch names every `Scancode`, so a new one does not
/// build until it has an SDL name here.
fn sdlScancode(code: Scancode) c.SDL_Scancode {
    return switch (code) {
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
        .f3 => c.SDL_SCANCODE_F3,
        .f11 => c.SDL_SCANCODE_F11,
    };
}

/// The platform scancode for an SDL scancode, or null if the engine does not name that key.
fn scancodeFromSdl(code: c.SDL_Scancode) ?Scancode {
    for (std.enums.values(Scancode)) |s| {
        if (sdlScancode(s) == code) return s;
    }
    return null;
}

/// The button for an SDL mouse button number, or null for buttons the engine does not name.
fn mouseButton(button: u8) ?MouseButton {
    if (button == c.SDL_BUTTON_LEFT) return .left;
    if (button == c.SDL_BUTTON_RIGHT) return .right;
    if (button == c.SDL_BUTTON_MIDDLE) return .middle;
    return null;
}

/// Turns one SDL event into a platform event. Returns null for event types the engine does not
/// consume, and for keys and buttons it does not name. Repeat is passed through, so the engine
/// decides what an auto-repeated key-down means.
pub fn translate(event: *const c.SDL_Event) ?Event {
    switch (event.type) {
        c.SDL_EVENT_QUIT => return .quit,
        c.SDL_EVENT_KEY_DOWN => {
            const code = scancodeFromSdl(event.key.scancode) orelse return null;
            return .{ .key_down = .{ .scancode = code, .repeat = event.key.repeat } };
        },
        c.SDL_EVENT_KEY_UP => {
            const code = scancodeFromSdl(event.key.scancode) orelse return null;
            return .{ .key_up = .{ .scancode = code } };
        },
        c.SDL_EVENT_MOUSE_MOTION => return .{ .mouse_motion = .{ .x = event.motion.x, .y = event.motion.y } },
        c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
            const button = mouseButton(event.button.button) orelse return null;
            return .{ .mouse_button_down = button };
        },
        c.SDL_EVENT_MOUSE_BUTTON_UP => {
            const button = mouseButton(event.button.button) orelse return null;
            return .{ .mouse_button_up = button };
        },
        else => return null,
    }
}

/// Returns the next event the engine consumes from SDL's queue, or null when none is waiting.
/// Events the engine does not consume are drained here, so a null means nothing more is waiting.
pub fn poll() ?Event {
    var raw: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&raw)) {
        if (translate(&raw)) |event| return event;
    }
    return null;
}

/// Whether the physical key is held, as of SDL's current keyboard state.
pub fn isHeld(code: Scancode) bool {
    const keys: [*]const bool = @ptrCast(c.SDL_GetKeyboardState(null));
    return isDown(keys[0..scancode_count], code);
}

/// Whether `code` is down in a keyboard state indexed by SDL scancode.
fn isDown(keys: []const bool, code: Scancode) bool {
    return keys[@intCast(sdlScancode(code))];
}

// Tests. They build SDL events by hand and never call SDL, so they need no window or keyboard.

/// SDL's keyboard state has one entry per scancode, so the tests use an array that size.
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

/// An event with only its type set, for events that carry no fields the engine reads.
fn typeOnly(event_type: anytype) c.SDL_Event {
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = @intCast(event_type);
    return event;
}

/// The engine event for an SDL event. Fails the test if the engine does not consume it.
fn consumed(event: *const c.SDL_Event) !Event {
    return translate(event) orelse error.NotConsumed;
}

test "scancodes map to the SDL names the controls use, and an unnamed key maps to nothing" {
    // Pins the mapping to SDL's own names, so a wrong entry in `sdlScancode` is caught here.
    try std.testing.expectEqual(@as(?Scancode, .escape), scancodeFromSdl(c.SDL_SCANCODE_ESCAPE));
    try std.testing.expectEqual(@as(?Scancode, .left), scancodeFromSdl(c.SDL_SCANCODE_LEFT));
    try std.testing.expectEqual(@as(?Scancode, .right), scancodeFromSdl(c.SDL_SCANCODE_RIGHT));
    try std.testing.expectEqual(@as(?Scancode, .up), scancodeFromSdl(c.SDL_SCANCODE_UP));
    try std.testing.expectEqual(@as(?Scancode, .down), scancodeFromSdl(c.SDL_SCANCODE_DOWN));
    try std.testing.expectEqual(@as(?Scancode, .w), scancodeFromSdl(c.SDL_SCANCODE_W));
    try std.testing.expectEqual(@as(?Scancode, .a), scancodeFromSdl(c.SDL_SCANCODE_A));
    try std.testing.expectEqual(@as(?Scancode, .s), scancodeFromSdl(c.SDL_SCANCODE_S));
    try std.testing.expectEqual(@as(?Scancode, .d), scancodeFromSdl(c.SDL_SCANCODE_D));
    try std.testing.expectEqual(@as(?Scancode, .i), scancodeFromSdl(c.SDL_SCANCODE_I));
    try std.testing.expectEqual(@as(?Scancode, .equal), scancodeFromSdl(c.SDL_SCANCODE_EQUALS));
    try std.testing.expectEqual(@as(?Scancode, .minus), scancodeFromSdl(c.SDL_SCANCODE_MINUS));
    try std.testing.expectEqual(@as(?Scancode, .zero), scancodeFromSdl(c.SDL_SCANCODE_0));
    try std.testing.expectEqual(@as(?Scancode, .keypad_plus), scancodeFromSdl(c.SDL_SCANCODE_KP_PLUS));
    try std.testing.expectEqual(@as(?Scancode, .keypad_minus), scancodeFromSdl(c.SDL_SCANCODE_KP_MINUS));
    try std.testing.expectEqual(@as(?Scancode, .space), scancodeFromSdl(c.SDL_SCANCODE_SPACE));
    try std.testing.expectEqual(@as(?Scancode, .enter), scancodeFromSdl(c.SDL_SCANCODE_RETURN));
    try std.testing.expectEqual(@as(?Scancode, .tab), scancodeFromSdl(c.SDL_SCANCODE_TAB));
    try std.testing.expectEqual(@as(?Scancode, .q), scancodeFromSdl(c.SDL_SCANCODE_Q));
    try std.testing.expectEqual(@as(?Scancode, .e), scancodeFromSdl(c.SDL_SCANCODE_E));
    try std.testing.expectEqual(@as(?Scancode, .f), scancodeFromSdl(c.SDL_SCANCODE_F));
    try std.testing.expectEqual(@as(?Scancode, .r), scancodeFromSdl(c.SDL_SCANCODE_R));
    try std.testing.expectEqual(@as(?Scancode, .f5), scancodeFromSdl(c.SDL_SCANCODE_F5));
    try std.testing.expectEqual(@as(?Scancode, .f9), scancodeFromSdl(c.SDL_SCANCODE_F9));
    try std.testing.expectEqual(@as(?Scancode, .f3), scancodeFromSdl(c.SDL_SCANCODE_F3));
    try std.testing.expectEqual(@as(?Scancode, .f11), scancodeFromSdl(c.SDL_SCANCODE_F11));
    try std.testing.expectEqual(@as(?Scancode, null), scancodeFromSdl(c.SDL_SCANCODE_Z));
}

test "every scancode has its own SDL scancode, and that one maps back to it" {
    // If two scancodes shared an SDL name, one of them would not map back to itself.
    for (std.enums.values(Scancode)) |code| {
        try std.testing.expectEqual(@as(?Scancode, code), scancodeFromSdl(sdlScancode(code)));
    }
}

test "a key-down translates with its scancode, and keeps the auto-repeat flag" {
    const first = keyEvent(c.SDL_EVENT_KEY_DOWN, c.SDL_SCANCODE_W, false);
    const repeated = keyEvent(c.SDL_EVENT_KEY_DOWN, c.SDL_SCANCODE_W, true);
    const got_first = try consumed(&first);
    const got_repeat = try consumed(&repeated);
    switch (got_first) {
        .key_down => |down| {
            try std.testing.expectEqual(Scancode.w, down.scancode);
            try std.testing.expect(!down.repeat);
        },
        else => return error.WrongEvent,
    }
    switch (got_repeat) {
        .key_down => |down| try std.testing.expect(down.repeat),
        else => return error.WrongEvent,
    }
}

test "a key-up translates to a key_up event" {
    const up = keyEvent(c.SDL_EVENT_KEY_UP, c.SDL_SCANCODE_S, false);
    switch (try consumed(&up)) {
        .key_up => |key| try std.testing.expectEqual(Scancode.s, key.scancode),
        else => return error.WrongEvent,
    }
}

test "a key the engine does not name is not consumed, for key-down and key-up alike" {
    const down = keyEvent(c.SDL_EVENT_KEY_DOWN, c.SDL_SCANCODE_Z, false);
    const up = keyEvent(c.SDL_EVENT_KEY_UP, c.SDL_SCANCODE_Z, false);
    try std.testing.expect(translate(&down) == null);
    try std.testing.expect(translate(&up) == null);
}

test "mouse motion translates with its position in points" {
    const event = motionEvent(120.5, 60.25);
    switch (try consumed(&event)) {
        .mouse_motion => |motion| {
            try std.testing.expectEqual(@as(f32, 120.5), motion.x);
            try std.testing.expectEqual(@as(f32, 60.25), motion.y);
        },
        else => return error.WrongEvent,
    }
}

test "left, right, and middle buttons translate on press and release, and other buttons do not" {
    const buttons = [_]struct { sdl: u8, engine: MouseButton }{
        .{ .sdl = c.SDL_BUTTON_LEFT, .engine = .left },
        .{ .sdl = c.SDL_BUTTON_RIGHT, .engine = .right },
        .{ .sdl = c.SDL_BUTTON_MIDDLE, .engine = .middle },
    };
    for (buttons) |b| {
        const down = buttonEvent(c.SDL_EVENT_MOUSE_BUTTON_DOWN, b.sdl);
        const up = buttonEvent(c.SDL_EVENT_MOUSE_BUTTON_UP, b.sdl);
        switch (try consumed(&down)) {
            .mouse_button_down => |button| try std.testing.expectEqual(b.engine, button),
            else => return error.WrongEvent,
        }
        switch (try consumed(&up)) {
            .mouse_button_up => |button| try std.testing.expectEqual(b.engine, button),
            else => return error.WrongEvent,
        }
    }
    const extra = buttonEvent(c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_BUTTON_X1);
    try std.testing.expect(translate(&extra) == null);
}

test "quit translates to quit, and an event type the engine does not consume translates to null" {
    const quit = typeOnly(c.SDL_EVENT_QUIT);
    switch (try consumed(&quit)) {
        .quit => {},
        else => return error.WrongEvent,
    }
    const wheel = typeOnly(c.SDL_EVENT_MOUSE_WHEEL);
    try std.testing.expect(translate(&wheel) == null);
}

test "isDown reports only the key whose scancode is down" {
    for (std.enums.values(Scancode)) |down| {
        var keys: KeyState = [_]bool{false} ** scancode_count;
        keys[@intCast(sdlScancode(down))] = true;
        for (std.enums.values(Scancode)) |code| {
            try std.testing.expectEqual(code == down, isDown(&keys, code));
        }
    }
}
