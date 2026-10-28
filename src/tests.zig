//! Test root for `zig build test`. It holds every unit test. The pure modules need only the
//! compiler. `input` and `renderer` import SDL's C header and the embedded shaders, so this root
//! links SDL and needs slangc. No test opens a window or creates a GPU device.

const std = @import("std");

const c = @import("engine/sdl.zig").c;
const input = @import("engine/input.zig");
const renderer = @import("engine/renderer.zig");

test {
    _ = @import("engine/string.zig");
    _ = @import("engine/hash_map.zig");
    _ = @import("engine/assets.zig");
    _ = @import("engine/math.zig");
    _ = @import("engine/view.zig");
}

const Input = input.Input;
const Key = input.Key;

/// SDL's keyboard state has one entry per scancode, so the input tests use an array that size.
const scancode_count: usize = @intCast(c.SDL_SCANCODE_COUNT);
const KeyState = [scancode_count]bool;

/// Each key the engine names, with the SDL scancode it maps to. The first input test checks this
/// table against `Key`, so a key added without an entry fails.
const key_scancodes = [_]struct { key: Key, code: c.SDL_Scancode }{
    .{ .key = .escape, .code = c.SDL_SCANCODE_ESCAPE },
    .{ .key = .left, .code = c.SDL_SCANCODE_LEFT },
    .{ .key = .right, .code = c.SDL_SCANCODE_RIGHT },
    .{ .key = .up, .code = c.SDL_SCANCODE_UP },
    .{ .key = .down, .code = c.SDL_SCANCODE_DOWN },
    .{ .key = .w, .code = c.SDL_SCANCODE_W },
    .{ .key = .a, .code = c.SDL_SCANCODE_A },
    .{ .key = .s, .code = c.SDL_SCANCODE_S },
    .{ .key = .d, .code = c.SDL_SCANCODE_D },
    .{ .key = .i, .code = c.SDL_SCANCODE_I },
};

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

test "the scancode table lists every key the engine names, once" {
    // Equal counts plus every key appearing means no key is missing and none is listed twice.
    try std.testing.expectEqual(std.enums.values(Key).len, key_scancodes.len);
    for (std.enums.values(Key)) |key| {
        var found = false;
        for (key_scancodes) |entry| {
            if (entry.key == key) found = true;
        }
        try std.testing.expect(found);
    }
}

test "held reads the scancode in the table for each key" {
    // Pressing one table scancode must hold that key and no other.
    for (key_scancodes) |down| {
        var keys: KeyState = [_]bool{false} ** scancode_count;
        keys[@intCast(down.code)] = true;
        const state = Input{ .keys = &keys };
        for (key_scancodes) |other| {
            try std.testing.expectEqual(other.key == down.key, state.held(other.key));
        }
    }
}

test "a key-down for each table scancode presses exactly its key" {
    // This goes through handleEvent, so it checks the engine's own scancode mapping too.
    const keys: KeyState = [_]bool{false} ** scancode_count;
    for (key_scancodes) |down| {
        var state = Input{ .keys = &keys };
        const event = keyEvent(c.SDL_EVENT_KEY_DOWN, down.code, false);
        state.handleEvent(&event);
        state.latch();
        for (key_scancodes) |other| {
            try std.testing.expectEqual(other.key == down.key, state.wasPressed(other.key));
        }
    }
}

test "held follows the keyboard state and needs no event" {
    var keys: KeyState = [_]bool{false} ** scancode_count;
    keys[@intCast(c.SDL_SCANCODE_S)] = true;
    const state = Input{ .keys = &keys };
    try std.testing.expect(state.held(.s));
    // Held is live state. A press only counts once an event has been latched.
    try std.testing.expect(!state.wasPressed(.s));
}

test "a press reaches the update step only after latch, and only once" {
    const keys: KeyState = [_]bool{false} ** scancode_count;
    var state = Input{ .keys = &keys };
    const event = keyEvent(c.SDL_EVENT_KEY_DOWN, c.SDL_SCANCODE_W, false);
    state.handleEvent(&event);
    try std.testing.expect(!state.wasPressed(.w));

    state.latch();
    try std.testing.expect(state.wasPressed(.w));

    // The next update step has no new events, so the press is gone.
    state.latch();
    try std.testing.expect(!state.wasPressed(.w));
}

test "a release reaches the update step only after latch, and only once" {
    const keys: KeyState = [_]bool{false} ** scancode_count;
    var state = Input{ .keys = &keys };
    const event = keyEvent(c.SDL_EVENT_KEY_UP, c.SDL_SCANCODE_S, false);
    state.handleEvent(&event);
    try std.testing.expect(!state.wasReleased(.s));

    state.latch();
    try std.testing.expect(state.wasReleased(.s));

    state.latch();
    try std.testing.expect(!state.wasReleased(.s));
}

test "an auto-repeated key-down is not a new press" {
    // Holding a key makes the OS send repeats. Each one must not count as a fresh press.
    const keys: KeyState = [_]bool{false} ** scancode_count;
    var state = Input{ .keys = &keys };
    const event = keyEvent(c.SDL_EVENT_KEY_DOWN, c.SDL_SCANCODE_W, true);
    state.handleEvent(&event);
    state.latch();
    try std.testing.expect(!state.wasPressed(.w));
}

test "a press and a release in the same frame both reach the next update" {
    const keys: KeyState = [_]bool{false} ** scancode_count;
    var state = Input{ .keys = &keys };
    const down = keyEvent(c.SDL_EVENT_KEY_DOWN, c.SDL_SCANCODE_A, false);
    const up = keyEvent(c.SDL_EVENT_KEY_UP, c.SDL_SCANCODE_A, false);
    state.handleEvent(&down);
    state.handleEvent(&up);
    state.latch();
    try std.testing.expect(state.wasPressed(.a));
    try std.testing.expect(state.wasReleased(.a));
}

test "events from frames with no update wait for the next latch" {
    // A frame with no update step never latches, so its events must survive until one does.
    const keys: KeyState = [_]bool{false} ** scancode_count;
    var state = Input{ .keys = &keys };
    const w_down = keyEvent(c.SDL_EVENT_KEY_DOWN, c.SDL_SCANCODE_W, false);
    const d_down = keyEvent(c.SDL_EVENT_KEY_DOWN, c.SDL_SCANCODE_D, false);
    state.handleEvent(&w_down);
    state.handleEvent(&d_down);
    state.latch();
    try std.testing.expect(state.wasPressed(.w));
    try std.testing.expect(state.wasPressed(.d));

    state.latch();
    try std.testing.expect(!state.wasPressed(.w));
    try std.testing.expect(!state.wasPressed(.d));
}

test "keys the engine does not name are ignored" {
    // Z is not in `Key`, so the event is dropped and no key is reported.
    const keys: KeyState = [_]bool{false} ** scancode_count;
    var state = Input{ .keys = &keys };
    const event = keyEvent(c.SDL_EVENT_KEY_DOWN, c.SDL_SCANCODE_Z, false);
    state.handleEvent(&event);
    state.latch();
    for (std.enums.values(Key)) |key| {
        try std.testing.expect(!state.wasPressed(key));
    }
}

test "anyHeld, anyPressed and anyReleased are true when any listed key matches" {
    var keys: KeyState = [_]bool{false} ** scancode_count;
    keys[@intCast(c.SDL_SCANCODE_LEFT)] = true;
    var state = Input{ .keys = &keys };
    try std.testing.expect(state.anyHeld(&.{ .w, .left }));
    try std.testing.expect(!state.anyHeld(&.{ .w, .d }));
    const none: []const Key = &.{};
    try std.testing.expect(!state.anyHeld(none));

    const d_down = keyEvent(c.SDL_EVENT_KEY_DOWN, c.SDL_SCANCODE_D, false);
    state.handleEvent(&d_down);
    state.latch();
    try std.testing.expect(state.anyPressed(&.{ .w, .d }));
    try std.testing.expect(!state.anyPressed(&.{ .w, .a }));
    try std.testing.expect(!state.anyReleased(&.{ .w, .d }));
}

test "mouse motion updates the position at once, before the next latch" {
    const keys: KeyState = [_]bool{false} ** scancode_count;
    var state = Input{ .keys = &keys };
    const event = motionEvent(120.5, 60.25);
    state.handleEvent(&event);
    try std.testing.expectEqual(@as(f32, 120.5), state.mouse_x);
    try std.testing.expectEqual(@as(f32, 60.25), state.mouse_y);
}

test "a left button press is latched as one click" {
    const keys: KeyState = [_]bool{false} ** scancode_count;
    var state = Input{ .keys = &keys };
    const event = buttonEvent(c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_BUTTON_LEFT);
    state.handleEvent(&event);
    try std.testing.expect(!state.left_clicked);

    state.latch();
    try std.testing.expect(state.left_clicked);

    state.latch();
    try std.testing.expect(!state.left_clicked);
}

test "other buttons and button releases do not count as a left click" {
    const keys: KeyState = [_]bool{false} ** scancode_count;
    var state = Input{ .keys = &keys };
    const right_down = buttonEvent(c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_BUTTON_RIGHT);
    const left_up = buttonEvent(c.SDL_EVENT_MOUSE_BUTTON_UP, c.SDL_BUTTON_LEFT);
    state.handleEvent(&right_down);
    state.handleEvent(&left_up);
    state.latch();
    try std.testing.expect(!state.left_clicked);
}

test "colorTargetInfo clears the target to the given color and keeps the result" {
    var marker: u8 = 0;
    const target: *c.SDL_GPUTexture = @ptrCast(&marker);
    const clear = c.SDL_FColor{ .r = 0.25, .g = 0.5, .b = 0.75, .a = 1.0 };
    const info = renderer.colorTargetInfo(target, clear);

    try std.testing.expect(info.texture == target);
    try std.testing.expectEqual(@as(f32, 0.25), info.clear_color.r);
    try std.testing.expectEqual(@as(f32, 0.5), info.clear_color.g);
    try std.testing.expectEqual(@as(f32, 0.75), info.clear_color.b);
    try std.testing.expectEqual(@as(f32, 1.0), info.clear_color.a);
    // A pass that loaded instead of clearing would draw over the last frame's pixels.
    try std.testing.expect(info.load_op == c.SDL_GPU_LOADOP_CLEAR);
    try std.testing.expect(info.store_op == c.SDL_GPU_STOREOP_STORE);
}

test "colorTargetInfo leaves the fields it does not use at zero" {
    // Zero selects the base mip and layer, with no resolve target and no cycling. Those are the
    // defaults the pass was written against, so a stray value here would change what gets drawn.
    var marker: u8 = 0;
    const target: *c.SDL_GPUTexture = @ptrCast(&marker);
    const info = renderer.colorTargetInfo(target, .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 });
    try std.testing.expectEqual(@as(u32, 0), info.mip_level);
    try std.testing.expectEqual(@as(u32, 0), info.layer_or_depth_plane);
    try std.testing.expect(info.resolve_texture == null);
    try std.testing.expect(!info.cycle);
}
