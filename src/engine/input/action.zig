//! Semantic actions. A game names what it wants, such as `jump`, and the engine answers from the
//! physical controls bound to that action. An action can have several bindings, and any one of them
//! can trigger it: a key, a mouse button, a gamepad button, or one half of a gamepad axis.
//!
//! The game owns its action enum and its defaults. `ActionMap` only evaluates them, and
//! input/mapping.zig reads a game's rebindings from the settings file.

const std = @import("std");
const types = @import("../platform/types.zig");
const input = @import("input.zig");
const gamepad = @import("gamepad.zig");

const Input = input.Input;
const Key = input.Key;

/// One physical control an action can be bound to.
pub const Binding = union(enum) {
    key: Key,
    mouse: types.MouseButton,
    gamepad_button: types.GamepadButton,
    /// One half of a gamepad axis: a stick pushed left (negative) or right (positive), or a trigger,
    /// which has only the positive half.
    gamepad_axis: struct { axis: types.GamepadAxis, direction: gamepad.Direction },
};

/// The most bindings one action can have. A settings line that names more has the extra ones dropped,
/// and the reader reports it.
pub const max_bindings_per_action = 4;

/// The starting bindings of every action in `Action`, as a table indexed by the action.
pub fn Defaults(comptime Action: type) type {
    return std.EnumArray(Action, []const Binding);
}

/// Maps each action in `Action` to the bindings that trigger it. Build one from the defaults with
/// `fromDefaults`, and then ask it about actions each update step.
pub fn ActionMap(comptime Action: type) type {
    if (@typeInfo(Action) != .@"enum") @compileError("an action map needs an enum of actions");
    const count = std.enums.values(Action).len;

    return struct {
        const Self = @This();

        bindings: [count][max_bindings_per_action]Binding,
        counts: [count]usize,

        /// Copies the defaults into a map. A default with more bindings than the limit is a
        /// programmer error, so it panics.
        pub fn fromDefaults(defaults: Defaults(Action)) Self {
            var self: Self = undefined;
            for (std.enums.values(Action)) |action| {
                const list = defaults.get(action);
                if (list.len > max_bindings_per_action) {
                    @panic("an action has more default bindings than max_bindings_per_action");
                }
                self.set(action, list);
            }
            return self;
        }

        /// Replaces the bindings of `action`. The caller keeps `list` within `max_bindings_per_action`.
        pub fn set(self: *Self, action: Action, list: []const Binding) void {
            const index = @intFromEnum(action);
            @memcpy(self.bindings[index][0..list.len], list);
            self.counts[index] = list.len;
        }

        /// The bindings of `action`, in the order they were given.
        pub fn bindingsOf(self: *const Self, action: Action) []const Binding {
            const index = @intFromEnum(action);
            return self.bindings[index][0..self.counts[index]];
        }

        /// True while any binding of `action` is held.
        pub fn held(self: *const Self, state: *const Input, action: Action) bool {
            for (self.bindingsOf(action)) |binding| {
                if (heldBy(state, binding)) return true;
            }
            return false;
        }

        /// Hands the name of each action that is held now to `list`, which takes names with `add`. The names
        /// are the enum's, so a game can show which actions its bindings resolve to.
        pub fn addHeldNames(self: *const Self, state: *const Input, list: anytype) void {
            for (std.enums.values(Action)) |action| {
                if (self.held(state, action)) list.add(@tagName(action));
            }
        }

        /// True during the update step that first sees any binding of `action` go down.
        pub fn pressed(self: *const Self, state: *const Input, action: Action) bool {
            for (self.bindingsOf(action)) |binding| {
                if (pressedBy(state, binding)) return true;
            }
            return false;
        }

        /// True during the update step that first sees any binding of `action` go up.
        pub fn released(self: *const Self, state: *const Input, action: Action) bool {
            for (self.bindingsOf(action)) |binding| {
                if (releasedBy(state, binding)) return true;
            }
            return false;
        }

        /// How strongly `action` is pressed, from 0 to 1. A key, a button, or a trigger reads 1 while it
        /// is down. A stick reads its position past the dead zone, so partial pushes give partial values.
        /// The strongest binding wins.
        pub fn value(self: *const Self, state: *const Input, action: Action) f32 {
            var strongest: f32 = 0;
            for (self.bindingsOf(action)) |binding| {
                strongest = @max(strongest, valueBy(state, binding));
            }
            return strongest;
        }
    };
}

fn heldBy(state: *const Input, binding: Binding) bool {
    return switch (binding) {
        .key => |key| state.held(key),
        .mouse => |button| state.mouseDown(button),
        .gamepad_button => |button| if (state.primaryPad()) |pad| pad.held[gamepad.buttonControl(button)] else false,
        .gamepad_axis => |axis| if (state.primaryPad()) |pad| pad.held[gamepad.axisControl(axis.axis, axis.direction)] else false,
    };
}

fn pressedBy(state: *const Input, binding: Binding) bool {
    return switch (binding) {
        .key => |key| state.wasPressed(key),
        .mouse => |button| state.mousePressed(button),
        .gamepad_button => |button| if (state.primaryPad()) |pad| pad.pressed[gamepad.buttonControl(button)] else false,
        .gamepad_axis => |axis| if (state.primaryPad()) |pad| pad.pressed[gamepad.axisControl(axis.axis, axis.direction)] else false,
    };
}

fn releasedBy(state: *const Input, binding: Binding) bool {
    return switch (binding) {
        .key => |key| state.wasReleased(key),
        .mouse => |button| state.mouseReleased(button),
        .gamepad_button => |button| if (state.primaryPad()) |pad| pad.released[gamepad.buttonControl(button)] else false,
        .gamepad_axis => |axis| if (state.primaryPad()) |pad| pad.released[gamepad.axisControl(axis.axis, axis.direction)] else false,
    };
}

fn valueBy(state: *const Input, binding: Binding) f32 {
    return switch (binding) {
        .gamepad_axis => |axis| if (state.primaryPad()) |pad|
            gamepad.halfValue(pad.axes[@intFromEnum(axis.axis)], axis.direction)
        else
            0,
        else => if (heldBy(state, binding)) 1 else 0,
    };
}

/// Each bindable control has a code, so a widget can report the control a player pressed without seeing a key or a
/// button. Codes run from 1 up to `control_code_count`, and 0 means no control. Keys come first, in `Key` order, then
/// the mouse buttons, then the gamepad controls from gamepad.zig: the buttons, then each stick and trigger half.
const key_count = std.enums.values(Key).len;
const mouse_count = std.enums.values(types.MouseButton).len;
pub const control_code_count: u32 = @intCast(key_count + mouse_count + gamepad.control_count);

/// The code of the control at `index`, counting keys, then mouse buttons, then gamepad controls.
fn codeAt(index: usize) u32 {
    return @intCast(index + 1);
}

/// The code that names `binding`.
pub fn codeOf(binding: Binding) u32 {
    return switch (binding) {
        .key => |key| codeAt(@intFromEnum(key)),
        .mouse => |button| codeAt(key_count + @as(usize, @intFromEnum(button))),
        .gamepad_button => |button| codeAt(key_count + mouse_count + gamepad.buttonControl(button)),
        .gamepad_axis => |axis| codeAt(key_count + mouse_count + gamepad.axisControl(axis.axis, axis.direction)),
    };
}

/// The binding that `code` names. Null for code 0, for a code past `control_code_count`, and for the negative half
/// of a trigger, which no binding names because a trigger has only its positive half.
pub fn bindingOf(code: u32) ?Binding {
    if (code == 0 or code > control_code_count) return null;
    const index: usize = code - 1;
    if (index < key_count) return .{ .key = @enumFromInt(index) };
    if (index < key_count + mouse_count) return .{ .mouse = @enumFromInt(index - key_count) };
    const control = index - key_count - mouse_count;
    if (control < gamepad.button_count) return .{ .gamepad_button = @enumFromInt(control) };
    const half = control - gamepad.button_count;
    const direction: gamepad.Direction = @enumFromInt(half % 2);
    const axis: types.GamepadAxis = @enumFromInt(half / 2);
    if (direction == .negative and (axis == .left_trigger or axis == .right_trigger)) return null;
    return .{ .gamepad_axis = .{ .axis = axis, .direction = direction } };
}

/// The code of the first bindable control that went down this frame, or 0 when none did. Keys are checked first,
/// then the mouse buttons other than the left, then the primary gamepad. The left button is never reported: the
/// UI's own pointer uses it, so a click on the Controls list cannot bind it.
pub fn pressedCode(state: *const Input) u32 {
    for (std.enums.values(Key)) |key| {
        if (state.wasPressed(key)) return codeOf(.{ .key = key });
    }
    for (std.enums.values(types.MouseButton)) |button| {
        if (button != .left and state.mousePressed(button)) return codeOf(.{ .mouse = button });
    }
    if (state.primaryPad()) |pad| {
        for (0..gamepad.control_count) |control| {
            if (pad.pressed[control]) return codeAt(key_count + mouse_count + control);
        }
    }
    return 0;
}

const TestAction = enum { jump, fire, pause };

const pad_a = types.GamepadId{ .slot = 0, .generation = 1 };

const test_defaults = Defaults(TestAction).init(.{
    .jump = &.{ .{ .key = .w }, .{ .gamepad_button = .south } },
    .fire = &.{.{ .mouse = .left }},
    .pause = &.{.{ .key = .escape }},
});

test "a key bound to an action makes it held, pressed, and released in turn" {
    const map = ActionMap(TestAction).fromDefaults(test_defaults);
    var state = Input{};
    try std.testing.expect(!map.held(&state, .pause));

    state.keyDown(.escape);
    state.latch();
    try std.testing.expect(map.pressed(&state, .pause));
    try std.testing.expect(!map.released(&state, .pause));
}

test "several bindings of one action all trigger it" {
    const map = ActionMap(TestAction).fromDefaults(test_defaults);
    var by_key = Input{};
    by_key.setHeld(.w, true);
    try std.testing.expect(map.held(&by_key, .jump));

    var by_pad = Input{};
    by_pad.gamepadAdded(.{ .slot = 0, .generation = 1 });
    by_pad.gamepadButton(.{ .slot = 0, .generation = 1 }, .south, true);
    try std.testing.expect(map.held(&by_pad, .jump));
}

test "a keyboard press and a gamepad press trigger the same action" {
    const map = ActionMap(TestAction).fromDefaults(test_defaults);
    const pad = pad_a;

    var keyboard = Input{};
    keyboard.keyDown(.w);
    keyboard.latch();
    try std.testing.expect(map.pressed(&keyboard, .jump));

    var controller = Input{};
    controller.apply(.{ .gamepad_added = pad });
    controller.apply(.{ .gamepad_button_down = .{ .id = pad, .button = .south } });
    controller.latch();
    try std.testing.expect(map.pressed(&controller, .jump));
    try std.testing.expect(map.held(&controller, .jump));
}

test "a mouse binding reads the mouse button it names" {
    const map = ActionMap(TestAction).fromDefaults(test_defaults);
    var state = Input{};
    state.mouseButton(.left, true);
    state.latch();
    try std.testing.expect(map.pressed(&state, .fire));
    try std.testing.expect(map.held(&state, .fire));

    var other = Input{};
    other.mouseButton(.right, true);
    other.latch();
    try std.testing.expect(!map.pressed(&other, .fire));
}

test "a gamepad button reads nothing when no gamepad is connected" {
    const map = ActionMap(TestAction).fromDefaults(test_defaults);
    var state = Input{};
    try std.testing.expect(!map.held(&state, .jump));
    try std.testing.expectEqual(@as(f32, 0), map.value(&state, .jump));
}

test "only the primary gamepad triggers an action" {
    const map = ActionMap(TestAction).fromDefaults(test_defaults);
    const first = types.GamepadId{ .slot = 0, .generation = 1 };
    const second = types.GamepadId{ .slot = 1, .generation = 1 };
    var state = Input{};
    state.gamepadAdded(first);
    state.gamepadAdded(second);
    state.gamepadButton(second, .south, true);
    try std.testing.expect(!map.held(&state, .jump));

    state.gamepadButton(first, .south, true);
    try std.testing.expect(map.held(&state, .jump));
}

const stick_map_defaults = Defaults(TestAction).init(.{
    .jump = &.{.{ .gamepad_axis = .{ .axis = .left_x, .direction = .positive } }},
    .fire = &.{.{ .gamepad_axis = .{ .axis = .right_trigger, .direction = .positive } }},
    .pause = &.{.{ .gamepad_axis = .{ .axis = .left_y, .direction = .negative } }},
});

test "an axis half is held past the threshold, and its value follows the stick past the dead zone" {
    const map = ActionMap(TestAction).fromDefaults(stick_map_defaults);
    const pad = pad_a;
    var state = Input{};
    state.gamepadAdded(pad);

    state.gamepadAxis(pad, .left_x, 0.1);
    state.latch();
    try std.testing.expect(!map.held(&state, .jump));
    try std.testing.expectEqual(@as(f32, 0), map.value(&state, .jump));

    state.gamepadAxis(pad, .left_x, 0.6);
    state.latch();
    try std.testing.expect(map.pressed(&state, .jump));
    try std.testing.expect(map.held(&state, .jump));
    const partial = map.value(&state, .jump);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), partial, 1e-6);

    state.gamepadAxis(pad, .left_x, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1), map.value(&state, .jump), 1e-6);
}

test "a negative stick half answers to the stick pushed the other way" {
    const map = ActionMap(TestAction).fromDefaults(stick_map_defaults);
    const pad = pad_a;
    var state = Input{};
    state.gamepadAdded(pad);

    state.gamepadAxis(pad, .left_y, -1.0);
    state.latch();
    try std.testing.expect(map.pressed(&state, .pause));

    // Pushing the stick down reads on the positive half, which this action does not bind.
    state.gamepadAxis(pad, .left_y, 1.0);
    state.latch();
    try std.testing.expect(!map.held(&state, .pause));
    try std.testing.expect(map.released(&state, .pause));
    try std.testing.expectEqual(@as(f32, 0), map.value(&state, .pause));
}

test "a trigger is held as it passes the threshold and released when it comes back" {
    const map = ActionMap(TestAction).fromDefaults(stick_map_defaults);
    const pad = pad_a;
    var state = Input{};
    state.gamepadAdded(pad);

    state.gamepadAxis(pad, .right_trigger, 0.9);
    state.latch();
    try std.testing.expect(map.held(&state, .fire));
    state.gamepadAxis(pad, .right_trigger, 0.0);
    state.latch();
    try std.testing.expect(map.released(&state, .fire));
    try std.testing.expect(!map.held(&state, .fire));
}

test "the strongest binding sets the value of an action with analog and digital bindings" {
    const mixed = Defaults(TestAction).init(.{
        .jump = &.{ .{ .key = .w }, .{ .gamepad_axis = .{ .axis = .left_x, .direction = .positive } } },
        .fire = &.{.{ .mouse = .left }},
        .pause = &.{.{ .key = .escape }},
    });
    const map = ActionMap(TestAction).fromDefaults(mixed);
    const pad = pad_a;
    var state = Input{};
    state.gamepadAdded(pad);
    state.gamepadAxis(pad, .left_x, 0.6);
    state.setHeld(.w, true);
    try std.testing.expectApproxEqAbs(@as(f32, 1), map.value(&state, .jump), 1e-6);
}

test "set replaces one action's bindings and leaves the others alone" {
    var map = ActionMap(TestAction).fromDefaults(test_defaults);
    map.set(.pause, &.{ .{ .key = .space }, .{ .mouse = .right } });
    try std.testing.expectEqual(@as(usize, 2), map.bindingsOf(.pause).len);
    try std.testing.expectEqual(@as(usize, 2), map.bindingsOf(.jump).len);

    var state = Input{};
    state.keyDown(.escape);
    state.latch();
    try std.testing.expect(!map.pressed(&state, .pause));
}

test "defaults copy into the map, so a later change to the map leaves the defaults alone" {
    var map = ActionMap(TestAction).fromDefaults(test_defaults);
    map.set(.fire, &.{.{ .key = .q }});
    try std.testing.expectEqual(@as(usize, 1), test_defaults.get(.fire).len);
    try std.testing.expectEqual(Binding{ .mouse = .left }, test_defaults.get(.fire)[0]);
}

const NameSink = struct {
    seen: [8][]const u8 = undefined,
    n: usize = 0,

    pub fn add(self: *NameSink, name: []const u8) void {
        self.seen[self.n] = name;
        self.n += 1;
    }
};

test "held action names are the actions whose bindings are down" {
    const map = ActionMap(TestAction).fromDefaults(test_defaults);
    var state = Input{};
    var none = NameSink{};
    map.addHeldNames(&state, &none);
    try std.testing.expectEqual(@as(usize, 0), none.n);

    state.setHeld(.w, true);
    var sink = NameSink{};
    map.addHeldNames(&state, &sink);
    try std.testing.expectEqual(@as(usize, 1), sink.n);
    try std.testing.expectEqualStrings("jump", sink.seen[0]);
}

test "every code names one binding, and that binding names the code back" {
    var code: u32 = 1;
    while (code <= control_code_count) : (code += 1) {
        // The negative half of a trigger has no binding, so its code names nothing.
        const binding = bindingOf(code) orelse continue;
        try std.testing.expectEqual(code, codeOf(binding));
    }
    try std.testing.expect(bindingOf(0) == null);
    try std.testing.expect(bindingOf(control_code_count + 1) == null);
}

test "the pressed code is the first bindable control down this frame, and the left button is never it" {
    var state = Input{};
    try std.testing.expectEqual(@as(u32, 0), pressedCode(&state));

    state.mouseButton(.left, true);
    state.latch();
    try std.testing.expectEqual(@as(u32, 0), pressedCode(&state));

    state.mouseButton(.left, false);
    state.mouseButton(.right, true);
    state.keyDown(.q);
    state.latch();
    // Keys are checked before mouse buttons, so the key is the one reported.
    try std.testing.expectEqual(codeOf(.{ .key = .q }), pressedCode(&state));

    state.latch();
    try std.testing.expectEqual(@as(u32, 0), pressedCode(&state));

    state.gamepadAdded(pad_a);
    state.gamepadButton(pad_a, .south, true);
    state.latch();
    try std.testing.expectEqual(codeOf(.{ .gamepad_button = .south }), pressedCode(&state));
}
