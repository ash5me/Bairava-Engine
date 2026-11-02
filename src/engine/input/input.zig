//! Keyboard, mouse, and gamepad state, with no platform code. Platform events reach it through `apply`
//! as they arrive, and held keys are sampled once per frame by `sampleHeld`.
//!
//! Frame order: the platform event queue is drained (each event goes to `apply`), held keys are
//! sampled, each update step runs after `latch`, and then the frame is drawn. Presses, releases, and
//! clicks gather between update steps, so a frame with no update step keeps them for the next one.
//! The game reads them during `update`, where each press or click appears in exactly one step.
//!
//! Gamepads follow the same path. Their buttons and axes arrive as events and set held state as they
//! arrive, so a button that goes down and up within one frame is still seen as a press and a release.
//! Actions read them through `ActionMap` (input/action.zig), not from here.

const std = @import("std");
const types = @import("../platform/types.zig");
const gamepad = @import("gamepad.zig");

const Scancode = types.Scancode;
const Event = types.Event;
const MouseButton = types.MouseButton;
const GamepadId = types.GamepadId;
const GamepadButton = types.GamepadButton;
const GamepadAxis = types.GamepadAxis;

/// Keys the engine can report. To add one, add it here, add its physical key to `Scancode` in
/// platform/types.zig, map it both ways in `scancodeOf` and `keyFor` below, and map the scancode
/// to SDL in platform/sdl/input.zig.
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

/// The physical key each engine key is read from. The switch names every `Key`, so a key without a
/// scancode does not build.
pub fn scancodeOf(key: Key) Scancode {
    return switch (key) {
        .escape => .escape,
        .left => .left,
        .right => .right,
        .up => .up,
        .down => .down,
        .w => .w,
        .a => .a,
        .s => .s,
        .d => .d,
        .i => .i,
        .equal => .equal,
        .minus => .minus,
        .zero => .zero,
        .keypad_plus => .keypad_plus,
        .keypad_minus => .keypad_minus,
        .space => .space,
        .enter => .enter,
        .tab => .tab,
        .q => .q,
        .e => .e,
        .f => .f,
        .r => .r,
        .f5 => .f5,
        .f9 => .f9,
    };
}

/// The engine key for a physical key, or null if the engine does not key on it. F3 and F11 are not
/// keys: the event pump reads them as commands.
pub fn keyFor(code: Scancode) ?Key {
    return switch (code) {
        .escape => .escape,
        .left => .left,
        .right => .right,
        .up => .up,
        .down => .down,
        .w => .w,
        .a => .a,
        .s => .s,
        .d => .d,
        .i => .i,
        .equal => .equal,
        .minus => .minus,
        .zero => .zero,
        .keypad_plus => .keypad_plus,
        .keypad_minus => .keypad_minus,
        .space => .space,
        .enter => .enter,
        .tab => .tab,
        .q => .q,
        .e => .e,
        .f => .f,
        .r => .r,
        .backspace => null,
        .f5 => .f5,
        .f9 => .f9,
        .f2 => null,
        .f3 => null,
        .f4 => null,
        .f11 => null,
    };
}

/// Number of keys in `Key`. Per-key arrays are indexed by `@intFromEnum(key)`.
const key_count = std.enums.values(Key).len;

/// Number of mouse buttons the engine reports. Per-button arrays are indexed by `@intFromEnum`.
const mouse_count = std.enums.values(MouseButton).len;

/// Input state. Held keys are set by the platform once per frame. Presses, releases, and clicks
/// gather as events arrive, and `latch` hands them to the game one update step at a time.
pub const Input = struct {
    /// State visible to one deterministic simulation update. Platform-pending events are excluded.
    pub const Snapshot = struct {
        held_keys: [key_count]bool,
        pressed: [key_count]bool,
        released: [key_count]bool,
        mouse_held: [mouse_count]bool,
        mouse_pressed: [mouse_count]bool,
        mouse_released: [mouse_count]bool,
        mouse_x: f32,
        mouse_y: f32,
        pads: [types.max_gamepads]gamepad.Slot,
        connections: u64,
    };

    /// Held state of each key, indexed by `@intFromEnum(key)`, as of the latest event pump.
    held_keys: [key_count]bool = [_]bool{false} ** key_count,
    /// Key events gathered since the last `latch`.
    pending_pressed: [key_count]bool = [_]bool{false} ** key_count,
    pending_released: [key_count]bool = [_]bool{false} ** key_count,
    /// Key events handed to the game by the latest `latch`. These are what the query methods report.
    pressed: [key_count]bool = [_]bool{false} ** key_count,
    released: [key_count]bool = [_]bool{false} ** key_count,
    /// Each mouse button is held down, as of the latest event. Unlike the one-shot arrays, this is live.
    mouse_held: [mouse_count]bool = [_]bool{false} ** mouse_count,
    /// Mouse button edges gathered since the last `latch`, and the ones handed to the game by it.
    pending_mouse_pressed: [mouse_count]bool = [_]bool{false} ** mouse_count,
    pending_mouse_released: [mouse_count]bool = [_]bool{false} ** mouse_count,
    mouse_pressed: [mouse_count]bool = [_]bool{false} ** mouse_count,
    mouse_released: [mouse_count]bool = [_]bool{false} ** mouse_count,
    /// Mouse position in window points. `Context.mouseWorld` converts it to world pixels.
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    /// Gamepad slots, indexed by `GamepadId.slot`. An empty slot has no id.
    pads: [types.max_gamepads]gamepad.Slot = [_]gamepad.Slot{.{}} ** types.max_gamepads,
    /// How many gamepads have connected so far. Each new one takes the next value as its `order`.
    connections: u64 = 0,

    /// Hands the events gathered since the last call to the game, and starts gathering afresh.
    /// The engine calls this before each update step, so each press or click reaches exactly one update.
    pub fn latch(self: *Input) void {
        self.pressed = self.pending_pressed;
        self.released = self.pending_released;
        self.mouse_pressed = self.pending_mouse_pressed;
        self.mouse_released = self.pending_mouse_released;
        @memset(&self.pending_pressed, false);
        @memset(&self.pending_released, false);
        @memset(&self.pending_mouse_pressed, false);
        @memset(&self.pending_mouse_released, false);
        for (&self.pads) |*pad| pad.latch();
    }

    /// Copies the exact input state visible to the current fixed-step update.
    pub fn snapshot(self: *const Input) Snapshot {
        return .{
            .held_keys = self.held_keys,
            .pressed = self.pressed,
            .released = self.released,
            .mouse_held = self.mouse_held,
            .mouse_pressed = self.mouse_pressed,
            .mouse_released = self.mouse_released,
            .mouse_x = self.mouse_x,
            .mouse_y = self.mouse_y,
            .pads = self.pads,
            .connections = self.connections,
        };
    }

    /// Replaces live input with one fixed-step snapshot and clears platform events pending for a later step.
    pub fn restoreSnapshot(self: *Input, snapshot_value: Snapshot) void {
        self.held_keys = snapshot_value.held_keys;
        self.pressed = snapshot_value.pressed;
        self.released = snapshot_value.released;
        self.mouse_held = snapshot_value.mouse_held;
        self.mouse_pressed = snapshot_value.mouse_pressed;
        self.mouse_released = snapshot_value.mouse_released;
        self.mouse_x = snapshot_value.mouse_x;
        self.mouse_y = snapshot_value.mouse_y;
        self.pads = snapshot_value.pads;
        self.connections = snapshot_value.connections;
        @memset(&self.pending_pressed, false);
        @memset(&self.pending_released, false);
        @memset(&self.pending_mouse_pressed, false);
        @memset(&self.pending_mouse_released, false);
        for (&self.pads) |*pad| {
            @memset(&pad.pending_pressed, false);
            @memset(&pad.pending_released, false);
        }
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

    /// How many keys are held, as of the latest event pump. The diagnostics overlay shows it.
    pub fn heldCount(self: *const Input) u32 {
        var count: u32 = 0;
        for (self.held_keys) |down| {
            if (down) count += 1;
        }
        return count;
    }

    /// Hands the name of each held key to `list`, which takes names with `add`. The diagnostics overlay
    /// shows them, so a held key can be read by name.
    pub fn addHeldNames(self: *const Input, list: anytype) void {
        for (std.enums.values(Key)) |key| {
            if (self.held(key)) list.add(@tagName(key));
        }
    }

    /// One bit per key in `Key` order, set for each key held now. The crash report reads it.
    pub fn heldMask(self: *const Input) u64 {
        var mask: u64 = 0;
        for (std.enums.values(Key)) |key| {
            if (self.held(key)) mask |= @as(u64, 1) << @as(u6, @intCast(@intFromEnum(key)));
        }
        return mask;
    }

    /// How many keys were pressed in the update step that is running. The diagnostics overlay shows it.
    pub fn pressedCount(self: *const Input) u32 {
        var count: u32 = 0;
        for (self.pressed) |down| {
            if (down) count += 1;
        }
        return count;
    }

    /// Sets whether a key is held. `sampleHeld` calls this once per frame.
    pub fn setHeld(self: *Input, key: Key, down: bool) void {
        self.held_keys[@intFromEnum(key)] = down;
    }

    /// Samples every key's held state from a platform query. Call once per frame, after the event
    /// queue is drained, so held keys are as of that pump.
    pub fn sampleHeld(self: *Input, comptime isHeld: fn (Scancode) bool) void {
        for (std.enums.values(Key)) |key| {
            self.setHeld(key, isHeld(scancodeOf(key)));
        }
    }

    /// True while the mouse button is held down, as of the latest event.
    pub fn mouseDown(self: *const Input, button: MouseButton) bool {
        return self.mouse_held[@intFromEnum(button)];
    }

    /// True during the update step that first sees the mouse button go down.
    pub fn mousePressed(self: *const Input, button: MouseButton) bool {
        return self.mouse_pressed[@intFromEnum(button)];
    }

    /// True during the update step that first sees the mouse button go up.
    pub fn mouseReleased(self: *const Input, button: MouseButton) bool {
        return self.mouse_released[@intFromEnum(button)];
    }

    /// The gamepad that counts for actions: the one connected first among those still connected.
    /// Null when no gamepad is connected. A second controller is ignored until the first one leaves.
    pub fn primaryPad(self: *const Input) ?*const gamepad.Slot {
        var best: ?*const gamepad.Slot = null;
        for (&self.pads) |*pad| {
            if (pad.id == null) continue;
            if (best == null or pad.order < best.?.order) best = pad;
        }
        return best;
    }

    /// Applies one platform event. Presses ignore auto-repeat. `quit` is handled by the event pump, so
    /// it changes no input state here.
    pub fn apply(self: *Input, event: Event) void {
        switch (event) {
            .quit => {},
            .key_down => |down| {
                if (down.repeat) return;
                if (keyFor(down.scancode)) |key| self.keyDown(key);
            },
            .key_up => |up| {
                if (keyFor(up.scancode)) |key| self.keyUp(key);
            },
            .mouse_motion => |motion| self.moveMouse(motion.x, motion.y),
            .mouse_button_down => |button| self.mouseButton(button, true),
            .mouse_button_up => |button| self.mouseButton(button, false),
            .gamepad_added => |id| self.gamepadAdded(id),
            .gamepad_removed => |id| self.gamepadRemoved(id),
            .gamepad_button_down => |button| self.gamepadButton(button.id, button.button, true),
            .gamepad_button_up => |button| self.gamepadButton(button.id, button.button, false),
            .gamepad_axis => |axis| self.gamepadAxis(axis.id, axis.axis, axis.value),
            .text_input => {},
        }
    }

    /// Records a key going down. `apply` drops auto-repeat before calling this.
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

    /// Records a mouse button press (`down` true) or release.
    pub fn mouseButton(self: *Input, button: MouseButton, down: bool) void {
        const index = @intFromEnum(button);
        if (down) {
            self.pending_mouse_pressed[index] = true;
            self.mouse_held[index] = true;
        } else {
            self.pending_mouse_released[index] = true;
            self.mouse_held[index] = false;
        }
    }

    /// Records a gamepad joining. A repeat report for a gamepad already in its slot changes nothing.
    /// A different device in the slot is released first, so it cannot leave controls stuck on.
    pub fn gamepadAdded(self: *Input, id: GamepadId) void {
        if (id.slot >= self.pads.len) return;
        const pad = &self.pads[id.slot];
        if (pad.id) |current| {
            if (current.generation == id.generation) return;
        }
        pad.disconnect();
        self.connections += 1;
        pad.id = id;
        pad.order = self.connections;
    }

    /// Records a gamepad leaving. Its held controls are released, and an id that no longer matches
    /// its slot is ignored.
    pub fn gamepadRemoved(self: *Input, id: GamepadId) void {
        const pad = self.slotOf(id) orelse return;
        pad.disconnect();
    }

    /// Records a gamepad button going down or up.
    pub fn gamepadButton(self: *Input, id: GamepadId, button: GamepadButton, down: bool) void {
        const pad = self.slotOf(id) orelse return;
        pad.setHeld(gamepad.buttonControl(button), down);
    }

    /// Records an axis moving to a raw value. Sticks run from -1 to 1 and triggers from 0 to 1.
    pub fn gamepadAxis(self: *Input, id: GamepadId, axis: GamepadAxis, value: f32) void {
        const pad = self.slotOf(id) orelse return;
        pad.setAxis(axis, value);
    }

    /// The slot holding the gamepad `id` names, or null when that gamepad is no longer connected.
    fn slotOf(self: *Input, id: GamepadId) ?*gamepad.Slot {
        if (id.slot >= self.pads.len) return null;
        const pad = &self.pads[id.slot];
        const current = pad.id orelse return null;
        if (current.generation != id.generation) return null;
        return pad;
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

test "mouse motion updates the position at once, before the next latch" {
    var input = Input{};
    input.moveMouse(120.5, 60.25);
    try std.testing.expectEqual(@as(f32, 120.5), input.mouse_x);
    try std.testing.expectEqual(@as(f32, 60.25), input.mouse_y);
}

test "a left button press is latched once, and sets the held state at once" {
    var input = Input{};
    input.mouseButton(.left, true);
    try std.testing.expect(input.mouseDown(.left));
    try std.testing.expect(!input.mousePressed(.left));

    input.latch();
    try std.testing.expect(input.mousePressed(.left));

    input.latch();
    try std.testing.expect(!input.mousePressed(.left));
}

test "a left release clears the held state and reaches the update step once" {
    var input = Input{};
    input.mouseButton(.left, true);
    input.latch();
    input.mouseButton(.left, false);
    try std.testing.expect(!input.mouseDown(.left));
    try std.testing.expect(!input.mouseReleased(.left));

    input.latch();
    try std.testing.expect(input.mouseReleased(.left));

    input.latch();
    try std.testing.expect(!input.mouseReleased(.left));
}

test "every engine key has a scancode, and that scancode maps back to it" {
    // Both switches are exhaustive, so a missing entry does not build. This checks that they agree.
    for (std.enums.values(Key)) |key| {
        try std.testing.expectEqual(@as(?Key, key), keyFor(scancodeOf(key)));
    }
}

test "F3 and F11 are read as commands, not as keys" {
    try std.testing.expectEqual(@as(?Key, null), keyFor(.f3));
    try std.testing.expectEqual(@as(?Key, null), keyFor(.f11));
    try std.testing.expectEqual(@as(?Key, null), keyFor(.f4));
    try std.testing.expectEqual(@as(usize, 29), std.enums.values(Scancode).len);
    try std.testing.expectEqual(@as(usize, 24), key_count);
}

test "a key-down presses its key, and an auto-repeated key-down does not" {
    var input = Input{};
    input.apply(.{ .key_down = .{ .scancode = .w, .repeat = true } });
    input.latch();
    try std.testing.expect(!input.wasPressed(.w));

    input.apply(.{ .key_down = .{ .scancode = .w, .repeat = false } });
    input.latch();
    try std.testing.expect(input.wasPressed(.w));
}

test "a key-up releases its key" {
    var input = Input{};
    input.apply(.{ .key_up = .{ .scancode = .s } });
    input.latch();
    try std.testing.expect(input.wasReleased(.s));
}

test "a scancode the engine does not key on changes no key" {
    var input = Input{};
    input.apply(.{ .key_down = .{ .scancode = .f3, .repeat = false } });
    input.apply(.{ .key_up = .{ .scancode = .f11 } });
    input.latch();
    for (std.enums.values(Key)) |key| {
        try std.testing.expect(!input.wasPressed(key));
        try std.testing.expect(!input.wasReleased(key));
    }
}

test "apply moves the mouse, and records every mouse button separately" {
    var input = Input{};
    input.apply(.{ .mouse_motion = .{ .x = 120.5, .y = 60.25 } });
    try std.testing.expectEqual(@as(f32, 120.5), input.mouse_x);
    try std.testing.expectEqual(@as(f32, 60.25), input.mouse_y);

    input.apply(.{ .mouse_button_down = .right });
    input.latch();
    try std.testing.expect(input.mousePressed(.right));
    try std.testing.expect(!input.mousePressed(.left));
    try std.testing.expect(input.mouseDown(.right));
    input.apply(.{ .mouse_button_up = .right });

    input.apply(.{ .mouse_button_down = .left });
    input.latch();
    try std.testing.expect(input.mousePressed(.left));
    try std.testing.expect(input.mouseDown(.left));

    input.apply(.{ .mouse_button_up = .left });
    input.latch();
    try std.testing.expect(input.mouseReleased(.left));
    try std.testing.expect(!input.mouseDown(.left));
}

test "quit changes no input state, because the event pump handles it" {
    var input = Input{};
    input.apply(.quit);
    input.latch();
    for (std.enums.values(Key)) |key| {
        try std.testing.expect(!input.wasPressed(key));
    }
    try std.testing.expect(!input.mouseDown(.left));
}

fn onlyWHeld(code: Scancode) bool {
    return code == .w;
}

fn noneHeld(code: Scancode) bool {
    _ = code;
    return false;
}

test "sampleHeld sets each key's held state from the platform query" {
    var input = Input{};
    input.sampleHeld(onlyWHeld);
    for (std.enums.values(Key)) |key| {
        try std.testing.expectEqual(key == .w, input.held(key));
    }
    // A later sample replaces the earlier one, so a key that is no longer down stops being held.
    input.sampleHeld(noneHeld);
    try std.testing.expect(!input.held(.w));
}

const pad_a = GamepadId{ .slot = 0, .generation = 1 };
const pad_b = GamepadId{ .slot = 1, .generation = 1 };

test "the first gamepad connected is the primary one, and a second waits its turn" {
    var input = Input{};
    try std.testing.expect(input.primaryPad() == null);

    input.apply(.{ .gamepad_added = pad_b });
    input.apply(.{ .gamepad_added = pad_a });
    // pad_b connected first, so it is primary even though it sits in the higher slot.
    try std.testing.expectEqual(@as(u8, 1), input.primaryPad().?.id.?.slot);

    input.apply(.{ .gamepad_removed = pad_b });
    try std.testing.expectEqual(@as(u8, 0), input.primaryPad().?.id.?.slot);
}

test "a gamepad button goes down and up through the event path, and latches like a key" {
    var input = Input{};
    input.apply(.{ .gamepad_added = pad_a });
    input.apply(.{ .gamepad_button_down = .{ .id = pad_a, .button = .south } });
    input.latch();
    const pad = input.primaryPad().?;
    try std.testing.expect(pad.held[gamepad.buttonControl(.south)]);
    try std.testing.expect(pad.pressed[gamepad.buttonControl(.south)]);

    input.apply(.{ .gamepad_button_up = .{ .id = pad_a, .button = .south } });
    input.latch();
    try std.testing.expect(!input.primaryPad().?.held[gamepad.buttonControl(.south)]);
    try std.testing.expect(input.primaryPad().?.released[gamepad.buttonControl(.south)]);
}

test "events from a gamepad that has left are ignored" {
    var input = Input{};
    input.apply(.{ .gamepad_added = pad_a });
    input.apply(.{ .gamepad_removed = pad_a });
    input.apply(.{ .gamepad_button_down = .{ .id = pad_a, .button = .south } });
    input.apply(.{ .gamepad_axis = .{ .id = pad_a, .axis = .left_x, .value = 1.0 } });
    input.latch();
    try std.testing.expect(input.primaryPad() == null);
}

test "a new gamepad in a reused slot does not answer to the id of the one before" {
    var input = Input{};
    input.apply(.{ .gamepad_added = pad_a });
    input.apply(.{ .gamepad_removed = pad_a });
    const reused = GamepadId{ .slot = 0, .generation = 2 };
    input.apply(.{ .gamepad_added = reused });

    // The old id has the same slot but an older generation, so its button press does nothing.
    input.apply(.{ .gamepad_button_down = .{ .id = pad_a, .button = .north } });
    input.latch();
    try std.testing.expect(!input.primaryPad().?.pressed[gamepad.buttonControl(.north)]);

    input.apply(.{ .gamepad_button_down = .{ .id = reused, .button = .north } });
    input.latch();
    try std.testing.expect(input.primaryPad().?.pressed[gamepad.buttonControl(.north)]);
}

test "a gamepad that leaves while a button is held releases it at the next update" {
    var input = Input{};
    input.apply(.{ .gamepad_added = pad_a });
    input.apply(.{ .gamepad_button_down = .{ .id = pad_a, .button = .start } });
    input.latch();

    input.apply(.{ .gamepad_removed = pad_a });
    input.latch();
    // The slot is empty, so no action can read it. The release is still recorded in the slot the
    // gamepad left, so the next update sees it.
    try std.testing.expect(input.primaryPad() == null);
    try std.testing.expect(input.pads[0].released[gamepad.buttonControl(.start)]);
}

test "a repeated arrival for a gamepad already in its slot changes nothing" {
    var input = Input{};
    input.apply(.{ .gamepad_added = pad_a });
    input.apply(.{ .gamepad_added = pad_a });
    try std.testing.expectEqual(@as(u64, 1), input.connections);
    try std.testing.expectEqual(@as(u64, 1), input.pads[0].order);
}

test "held key names come from the keys that are down, in enum order" {
    const Names = struct {
        seen: [8][]const u8 = undefined,
        n: usize = 0,

        pub fn add(self: *@This(), name: []const u8) void {
            self.seen[self.n] = name;
            self.n += 1;
        }
    };
    var state = Input{};
    state.setHeld(.space, true);
    state.setHeld(.w, true);
    var names = Names{};
    state.addHeldNames(&names);
    try std.testing.expectEqual(@as(usize, 2), names.n);
    try std.testing.expectEqualStrings("w", names.seen[0]);
    try std.testing.expectEqualStrings("space", names.seen[1]);
}
