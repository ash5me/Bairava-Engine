//! Gamepad state as the engine keeps it: one slot per connected device, with its buttons, its axes,
//! and the controls that bindings read. Nothing here touches SDL. The platform reports devices and
//! their events, and `Slot` turns them into held state and presses and releases.
//!
//! A "control" is anything the engine tracks as held or released: one button, or one half of an
//! axis. A stick has two axes, and each axis has two halves, so the stick's left and right (or up
//! and down) are separate controls. A trigger has one half, which is its positive half.

const std = @import("std");
const types = @import("../platform/types.zig");

pub const GamepadId = types.GamepadId;
pub const Button = types.GamepadButton;
pub const Axis = types.GamepadAxis;

/// Which half of an axis a binding reads. A stick's negative half is left or up, and its positive
/// half is right or down. A trigger has only a positive half.
pub const Direction = enum { negative, positive };

pub const button_count = std.enums.values(Button).len;
pub const axis_count = std.enums.values(Axis).len;

/// Every button, then two controls for each axis (negative half, then positive half).
pub const control_count = button_count + axis_count * 2;

/// The control index for a button.
pub fn buttonControl(button: Button) usize {
    return @intFromEnum(button);
}

/// The control index for one half of an axis.
pub fn axisControl(axis: Axis, direction: Direction) usize {
    // Widen the enum tag first: a six-member enum's tag is only 3 bits, so `* 2` would overflow.
    return button_count + @as(usize, @intFromEnum(axis)) * 2 + @intFromEnum(direction);
}

/// The fraction of an axis's travel around the center that reads as 0. Small drift in a resting
/// stick should not move the player, so the dead zone absorbs it. Full travel still reads as 1.
pub const dead_zone: f32 = 0.2;

/// How far an axis half must be pushed to count as held. A press happens as the value crosses this
/// line going out, and a release as it crosses coming back. It sits above the dead zone, so a
/// stick at rest is never held.
pub const axis_threshold: f32 = 0.5;

/// Scales an axis value so the dead zone reads as 0 and full travel reads as 1, keeping the sign.
/// A value that is not finite reads as 0.
pub fn applyDeadZone(value: f32) f32 {
    if (!std.math.isFinite(value)) return 0;
    const clamped = std.math.clamp(value, -1.0, 1.0);
    const magnitude = @abs(clamped);
    if (magnitude <= dead_zone) return 0;
    const scaled = (magnitude - dead_zone) / (1.0 - dead_zone);
    return if (clamped < 0) -scaled else scaled;
}

/// The strength of one half of an axis: its travel in `direction`, never below 0. A stick pushed
/// left reads positive on the negative half, and a trigger reads on its positive half only.
pub fn halfValue(axis_value: f32, direction: Direction) f32 {
    return switch (direction) {
        .positive => @max(axis_value, 0),
        .negative => @max(-axis_value, 0),
    };
}

/// One gamepad slot. `id` is null while the slot is empty. `order` counts connections, so the first
/// controller plugged in is the one that counts for actions.
pub const Slot = struct {
    id: ?GamepadId = null,
    order: u64 = 0,
    /// Each axis's value after the dead zone: -1 to 1 for sticks, 0 to 1 for triggers.
    axes: [axis_count]f32 = [_]f32{0} ** axis_count,
    /// Whether each control is down now.
    held: [control_count]bool = [_]bool{false} ** control_count,
    /// Presses and releases gathered since the last `latch`.
    pending_pressed: [control_count]bool = [_]bool{false} ** control_count,
    pending_released: [control_count]bool = [_]bool{false} ** control_count,
    /// Presses and releases handed to the game by the latest `latch`.
    pressed: [control_count]bool = [_]bool{false} ** control_count,
    released: [control_count]bool = [_]bool{false} ** control_count,

    /// Records a control going down or up. Only a change of state gathers an edge, so a repeated
    /// report of the same state does nothing.
    pub fn setHeld(self: *Slot, control: usize, down: bool) void {
        if (self.held[control] == down) return;
        self.held[control] = down;
        if (down) {
            self.pending_pressed[control] = true;
        } else {
            self.pending_released[control] = true;
        }
    }

    /// Applies one raw axis value. The dead zone is removed first, and then each half of the axis
    /// goes down or up as its travel crosses `axis_threshold`.
    pub fn setAxis(self: *Slot, axis: Axis, raw: f32) void {
        const value = applyDeadZone(raw);
        self.axes[@intFromEnum(axis)] = value;
        for (std.enums.values(Direction)) |direction| {
            self.setHeld(axisControl(axis, direction), halfValue(value, direction) >= axis_threshold);
        }
    }

    /// Hands the gathered presses and releases to `pressed` and `released`, as `Input.latch` does for
    /// keys, so each one reaches exactly one update step.
    pub fn latch(self: *Slot) void {
        self.pressed = self.pending_pressed;
        self.released = self.pending_released;
        self.pending_pressed = [_]bool{false} ** control_count;
        self.pending_released = [_]bool{false} ** control_count;
    }

    /// Releases every control that is still held and empties the slot. A device that leaves therefore
    /// never leaves an action stuck on, and the releases still reach the next update.
    pub fn disconnect(self: *Slot) void {
        for (0..control_count) |control| self.setHeld(control, false);
        self.axes = [_]f32{0} ** axis_count;
        self.id = null;
        self.order = 0;
    }
};

test "the dead zone reads small travel as 0 and rescales the rest" {
    try std.testing.expectEqual(@as(f32, 0), applyDeadZone(0));
    try std.testing.expectEqual(@as(f32, 0), applyDeadZone(0.2));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), applyDeadZone(0.6), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), applyDeadZone(-0.6), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), applyDeadZone(1), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1), applyDeadZone(-1.5), 1e-6);
}

test "a value that is not finite reads as 0" {
    try std.testing.expectEqual(@as(f32, 0), applyDeadZone(std.math.nan(f32)));
    try std.testing.expectEqual(@as(f32, 0), applyDeadZone(std.math.inf(f32)));
}

test "each half of an axis reads only its own side" {
    try std.testing.expectEqual(@as(f32, 0.5), halfValue(0.5, .positive));
    try std.testing.expectEqual(@as(f32, 0), halfValue(0.5, .negative));
    try std.testing.expectEqual(@as(f32, 0.25), halfValue(-0.25, .negative));
    try std.testing.expectEqual(@as(f32, 0), halfValue(-0.25, .positive));
}

test "every control has its own index, and the axis halves follow the buttons" {
    var seen = [_]bool{false} ** control_count;
    for (std.enums.values(Button)) |button| {
        try std.testing.expect(!seen[buttonControl(button)]);
        seen[buttonControl(button)] = true;
    }
    for (std.enums.values(Axis)) |axis| {
        for (std.enums.values(Direction)) |direction| {
            const index = axisControl(axis, direction);
            try std.testing.expect(index >= button_count);
            try std.testing.expect(!seen[index]);
            seen[index] = true;
        }
    }
    for (seen) |used| try std.testing.expect(used);
}

test "a button going down and up gathers one press and one release" {
    var slot = Slot{ .id = .{ .slot = 0, .generation = 1 } };
    const control = buttonControl(.south);
    slot.setHeld(control, true);
    slot.setHeld(control, true);
    slot.latch();
    try std.testing.expect(slot.pressed[control]);
    try std.testing.expect(slot.held[control]);

    slot.latch();
    try std.testing.expect(!slot.pressed[control]);

    slot.setHeld(control, false);
    slot.latch();
    try std.testing.expect(slot.released[control]);
    try std.testing.expect(!slot.held[control]);
}

test "a press and a release in the same frame both reach the next update" {
    var slot = Slot{};
    const control = buttonControl(.east);
    slot.setHeld(control, true);
    slot.setHeld(control, false);
    slot.latch();
    try std.testing.expect(slot.pressed[control]);
    try std.testing.expect(slot.released[control]);
    try std.testing.expect(!slot.held[control]);
}

test "an axis half goes down across the threshold and up coming back" {
    var slot = Slot{};
    const right = axisControl(.left_x, .positive);
    slot.setAxis(.left_x, 0.3);
    slot.latch();
    try std.testing.expect(!slot.held[right]);
    try std.testing.expect(!slot.pressed[right]);

    slot.setAxis(.left_x, 0.9);
    slot.latch();
    try std.testing.expect(slot.held[right]);
    try std.testing.expect(slot.pressed[right]);
    try std.testing.expect(slot.axes[@intFromEnum(Axis.left_x)] > 0.8);

    slot.setAxis(.left_x, 0.0);
    slot.latch();
    try std.testing.expect(!slot.held[right]);
    try std.testing.expect(slot.released[right]);
}

test "pushing a stick one way never presses the other half" {
    var slot = Slot{};
    slot.setAxis(.left_y, -1.0);
    slot.latch();
    try std.testing.expect(slot.held[axisControl(.left_y, .negative)]);
    try std.testing.expect(!slot.held[axisControl(.left_y, .positive)]);
}

test "a trigger has a positive half that a press crosses, and nothing negative" {
    var slot = Slot{};
    slot.setAxis(.right_trigger, 0.0);
    slot.setAxis(.right_trigger, 1.0);
    slot.latch();
    try std.testing.expect(slot.pressed[axisControl(.right_trigger, .positive)]);
    try std.testing.expect(!slot.held[axisControl(.right_trigger, .negative)]);
}

test "disconnecting releases every held control and empties the slot" {
    var slot = Slot{ .id = .{ .slot = 2, .generation = 5 }, .order = 3 };
    slot.setHeld(buttonControl(.start), true);
    slot.setAxis(.left_x, 1.0);
    slot.latch();

    slot.disconnect();
    try std.testing.expect(slot.id == null);
    try std.testing.expectEqual(@as(u64, 0), slot.order);
    try std.testing.expectEqual(@as(f32, 0), slot.axes[@intFromEnum(Axis.left_x)]);
    slot.latch();
    try std.testing.expect(slot.released[buttonControl(.start)]);
    try std.testing.expect(slot.released[axisControl(.left_x, .positive)]);
    try std.testing.expect(!slot.held[buttonControl(.start)]);
}
