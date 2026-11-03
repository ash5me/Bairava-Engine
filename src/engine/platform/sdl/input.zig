//! Keyboard, mouse, and gamepads through SDL3. This file turns SDL events and the keyboard state into
//! the platform-neutral types in platform/types.zig. It is the only place that names SDL keys, and
//! gamepad.zig holds the table of open gamepads that it reads.

const std = @import("std");
const c = @import("sdl.zig").c;
const types = @import("../types.zig");
const gamepad = @import("gamepad.zig");
const Scancode = types.Scancode;
const Event = types.Event;
const MouseButton = types.MouseButton;

/// The gamepads that are open, by slot. Only `poll` and `releaseGamepads` change it.
var pads: gamepad.Table = .{};

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
        .backspace => c.SDL_SCANCODE_BACKSPACE,
        .f8 => c.SDL_SCANCODE_F8,
        .f5 => c.SDL_SCANCODE_F5,
        .f9 => c.SDL_SCANCODE_F9,
        .f2 => c.SDL_SCANCODE_F2,
        .f3 => c.SDL_SCANCODE_F3,
        .f11 => c.SDL_SCANCODE_F11,
        .f4 => c.SDL_SCANCODE_F4,
        .f10 => c.SDL_SCANCODE_F10,
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
/// consume, and for keys, buttons, and axes it does not name. Repeat is passed through, so the engine
/// decides what an auto-repeated key-down means. A gamepad event from a device `table` does not hold
/// is dropped, since the engine has no id for that device.
pub fn translate(event: *const c.SDL_Event, table: *const gamepad.Table) ?Event {
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
        c.SDL_EVENT_TEXT_INPUT => {
            const text = std.mem.sliceTo(event.text.text[0..], 0);
            var input: types.TextInput = .{};
            const len = @min(text.len, input.bytes.len);
            @memcpy(input.bytes[0..len], text[0..len]);
            input.len = @intCast(len);
            return .{ .text_input = input };
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
        c.SDL_EVENT_GAMEPAD_BUTTON_DOWN => return gamepadButton(event, table, true),
        c.SDL_EVENT_GAMEPAD_BUTTON_UP => return gamepadButton(event, table, false),
        c.SDL_EVENT_GAMEPAD_AXIS_MOTION => {
            const id = gamepad.idOf(table, event.gaxis.which) orelse return null;
            const axis = gamepad.axisFromSdl(event.gaxis.axis) orelse return null;
            return .{ .gamepad_axis = .{ .id = id, .axis = axis, .value = gamepad.normalizeAxis(axis, event.gaxis.value) } };
        },
        else => return null,
    }
}

/// A gamepad button event as a platform event, read against `table`.
fn gamepadButton(event: *const c.SDL_Event, table: *const gamepad.Table, down: bool) ?Event {
    const id = gamepad.idOf(table, event.gbutton.which) orelse return null;
    const button = gamepad.buttonFromSdl(event.gbutton.button) orelse return null;
    if (down) return .{ .gamepad_button_down = .{ .id = id, .button = button } };
    return .{ .gamepad_button_up = .{ .id = id, .button = button } };
}

/// Returns the next event the engine consumes from SDL's queue, or null when none is waiting.
/// A gamepad that connects or disconnects is opened or closed here, before its event is translated,
/// since that changes the table the translation reads. Events the engine does not consume are drained
/// here, so a null means nothing more is waiting.
pub fn poll() ?Event {
    var raw: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&raw)) {
        switch (raw.type) {
            c.SDL_EVENT_GAMEPAD_ADDED => {
                if (gamepad.attach(&pads, raw.gdevice.which)) |id| return .{ .gamepad_added = id };
                continue;
            },
            c.SDL_EVENT_GAMEPAD_REMOVED => {
                if (gamepad.detach(&pads, raw.gdevice.which)) |id| return .{ .gamepad_removed = id };
                continue;
            },
            else => {},
        }
        if (translate(&raw, &pads)) |event| return event;
    }
    return null;
}

/// Closes every gamepad still open. Shutdown calls this before SDL stops, so no device outlives it.
pub fn releaseGamepads() void {
    gamepad.closeAll(&pads);
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

/// A table with no gamepads open, for the tests that read keys and the mouse.
const no_pads = gamepad.Table{};

/// A gamepad event as SDL fills one in, from the device with this instance id.
fn gamepadButtonEvent(event_type: anytype, instance: u32, button: c_int) c.SDL_Event {
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = @intCast(event_type);
    event.gbutton.which = instance;
    event.gbutton.button = @intCast(button);
    return event;
}

/// A gamepad axis event as SDL fills one in: the raw value runs from -32768 to 32767.
fn gamepadAxisEvent(instance: u32, axis: c_int, value: i16) c.SDL_Event {
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = @intCast(c.SDL_EVENT_GAMEPAD_AXIS_MOTION);
    event.gaxis.which = instance;
    event.gaxis.axis = @intCast(axis);
    event.gaxis.value = value;
    return event;
}

/// A table with one gamepad open: SDL instance 7, in slot 2, at generation 3.
fn tableWithPad() gamepad.Table {
    var table = gamepad.Table{};
    table.instance[2] = 7;
    table.generation[2] = 3;
    return table;
}

/// The engine event for an SDL event. Fails the test if the engine does not consume it.
fn consumed(event: *const c.SDL_Event) !Event {
    return translate(event, &no_pads) orelse error.NotConsumed;
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
    try std.testing.expectEqual(@as(?Scancode, .f8), scancodeFromSdl(c.SDL_SCANCODE_F8));
    try std.testing.expectEqual(@as(?Scancode, .f5), scancodeFromSdl(c.SDL_SCANCODE_F5));
    try std.testing.expectEqual(@as(?Scancode, .f9), scancodeFromSdl(c.SDL_SCANCODE_F9));
    try std.testing.expectEqual(@as(?Scancode, .f3), scancodeFromSdl(c.SDL_SCANCODE_F3));
    try std.testing.expectEqual(@as(?Scancode, .f11), scancodeFromSdl(c.SDL_SCANCODE_F11));
    try std.testing.expectEqual(@as(?Scancode, .f4), scancodeFromSdl(c.SDL_SCANCODE_F4));
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
    try std.testing.expect(translate(&down, &no_pads) == null);
    try std.testing.expect(translate(&up, &no_pads) == null);
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
    try std.testing.expect(translate(&extra, &no_pads) == null);
}

test "quit translates to quit, and an event type the engine does not consume translates to null" {
    const quit = typeOnly(c.SDL_EVENT_QUIT);
    switch (try consumed(&quit)) {
        .quit => {},
        else => return error.WrongEvent,
    }
    const wheel = typeOnly(c.SDL_EVENT_MOUSE_WHEEL);
    try std.testing.expect(translate(&wheel, &no_pads) == null);
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

test "a gamepad button from an open device translates to the engine's id and name" {
    const table = tableWithPad();
    const down = gamepadButtonEvent(c.SDL_EVENT_GAMEPAD_BUTTON_DOWN, 7, c.SDL_GAMEPAD_BUTTON_SOUTH);
    switch (translate(&down, &table) orelse return error.NotConsumed) {
        .gamepad_button_down => |button| {
            try std.testing.expectEqual(types.GamepadId{ .slot = 2, .generation = 3 }, button.id);
            try std.testing.expectEqual(types.GamepadButton.south, button.button);
        },
        else => return error.WrongEvent,
    }
    const up = gamepadButtonEvent(c.SDL_EVENT_GAMEPAD_BUTTON_UP, 7, c.SDL_GAMEPAD_BUTTON_SOUTH);
    switch (translate(&up, &table) orelse return error.NotConsumed) {
        .gamepad_button_up => |button| try std.testing.expectEqual(types.GamepadButton.south, button.button),
        else => return error.WrongEvent,
    }
}

test "a gamepad event from a device the table does not hold, or a button the engine does not name, is dropped" {
    const table = tableWithPad();
    const stranger = gamepadButtonEvent(c.SDL_EVENT_GAMEPAD_BUTTON_DOWN, 9, c.SDL_GAMEPAD_BUTTON_SOUTH);
    try std.testing.expect(translate(&stranger, &table) == null);
    const unnamed = gamepadButtonEvent(c.SDL_EVENT_GAMEPAD_BUTTON_DOWN, 7, c.SDL_GAMEPAD_BUTTON_MISC1);
    try std.testing.expect(translate(&unnamed, &table) == null);
}

test "an axis event translates with its value normalized to the engine's range" {
    const table = tableWithPad();
    const full = gamepadAxisEvent(7, c.SDL_GAMEPAD_AXIS_LEFTX, 32767);
    switch (translate(&full, &table) orelse return error.NotConsumed) {
        .gamepad_axis => |axis| {
            try std.testing.expectEqual(types.GamepadAxis.left_x, axis.axis);
            try std.testing.expectApproxEqAbs(@as(f32, 1), axis.value, 1e-6);
        },
        else => return error.WrongEvent,
    }
}
