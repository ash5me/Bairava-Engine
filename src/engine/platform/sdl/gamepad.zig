//! Gamepads through SDL3. This file opens and closes devices, keeps the table that maps SDL's
//! instance ids to the engine's gamepad ids, and turns SDL's buttons and axes into the engine's
//! names. No SDL gamepad or instance id leaves the platform backend.

const std = @import("std");
const c = @import("sdl.zig").c;
const types = @import("../types.zig");
const logging = @import("../../logging/log.zig");

const GamepadId = types.GamepadId;
const GamepadButton = types.GamepadButton;
const GamepadAxis = types.GamepadAxis;

const log = logging.scoped("gamepad");

/// The open gamepads, by slot. A slot's generation rises each time a device is opened into it, so an
/// id from an earlier device no longer matches the slot.
pub const Table = struct {
    /// SDL's instance id of the device in each slot, or null when the slot is empty.
    instance: [types.max_gamepads]?c.SDL_JoystickID = [_]?c.SDL_JoystickID{null} ** types.max_gamepads,
    /// The open SDL handle for each slot. It is closed when the device leaves.
    handle: [types.max_gamepads]?*c.SDL_Gamepad = [_]?*c.SDL_Gamepad{null} ** types.max_gamepads,
    generation: [types.max_gamepads]u32 = [_]u32{0} ** types.max_gamepads,
};

/// The slot holding the device with this SDL instance id, if one is open.
pub fn slotOf(table: *const Table, instance: c.SDL_JoystickID) ?u8 {
    for (table.instance, 0..) |held, slot| {
        const current = held orelse continue;
        if (current == instance) return @intCast(slot);
    }
    return null;
}

/// The first empty slot, if any is left.
pub fn freeSlot(table: *const Table) ?u8 {
    for (table.instance, 0..) |held, slot| {
        if (held == null) return @intCast(slot);
    }
    return null;
}

/// The engine id of the open device with this instance id, or null when none is open.
pub fn idOf(table: *const Table, instance: c.SDL_JoystickID) ?GamepadId {
    const slot = slotOf(table, instance) orelse return null;
    return .{ .slot = slot, .generation = table.generation[slot] };
}

/// Opens a device the platform reported as added and gives it a slot. Returns null when the device is
/// already open, since SDL can report one device more than once, when every slot is taken, or when SDL
/// cannot open it.
pub fn attach(table: *Table, instance: c.SDL_JoystickID) ?GamepadId {
    if (slotOf(table, instance) != null) return null;
    const slot = freeSlot(table) orelse {
        log.warn("{d} gamepads are already connected, so another one is not used", .{types.max_gamepads});
        return null;
    };
    const handle = c.SDL_OpenGamepad(instance) orelse {
        log.warn("gamepad {d} could not be opened: {s}", .{ instance, c.SDL_GetError() });
        return null;
    };
    table.instance[slot] = instance;
    table.handle[slot] = handle;
    table.generation[slot] +%= 1;
    return .{ .slot = slot, .generation = table.generation[slot] };
}

/// Closes the device with this instance id and frees its slot. Returns the id it had, or null when no
/// open device matches. The slot's generation stays, so the old id is rejected until the slot is reused.
pub fn detach(table: *Table, instance: c.SDL_JoystickID) ?GamepadId {
    const id = idOf(table, instance) orelse return null;
    if (table.handle[id.slot]) |handle| c.SDL_CloseGamepad(handle);
    table.instance[id.slot] = null;
    table.handle[id.slot] = null;
    return id;
}

/// Closes every open gamepad. Shutdown calls this before SDL stops, so no device outlives the platform.
pub fn closeAll(table: *Table) void {
    for (0..types.max_gamepads) |slot| {
        if (table.instance[slot]) |instance| _ = detach(table, instance);
    }
}

/// The engine button for an SDL gamepad button, or null for one the engine does not report.
pub fn buttonFromSdl(raw: u8) ?GamepadButton {
    const sdl: c_int = raw;
    return switch (sdl) {
        c.SDL_GAMEPAD_BUTTON_SOUTH => .south,
        c.SDL_GAMEPAD_BUTTON_EAST => .east,
        c.SDL_GAMEPAD_BUTTON_WEST => .west,
        c.SDL_GAMEPAD_BUTTON_NORTH => .north,
        c.SDL_GAMEPAD_BUTTON_BACK => .back,
        c.SDL_GAMEPAD_BUTTON_GUIDE => .guide,
        c.SDL_GAMEPAD_BUTTON_START => .start,
        c.SDL_GAMEPAD_BUTTON_LEFT_STICK => .left_stick,
        c.SDL_GAMEPAD_BUTTON_RIGHT_STICK => .right_stick,
        c.SDL_GAMEPAD_BUTTON_LEFT_SHOULDER => .left_shoulder,
        c.SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER => .right_shoulder,
        c.SDL_GAMEPAD_BUTTON_DPAD_UP => .dpad_up,
        c.SDL_GAMEPAD_BUTTON_DPAD_DOWN => .dpad_down,
        c.SDL_GAMEPAD_BUTTON_DPAD_LEFT => .dpad_left,
        c.SDL_GAMEPAD_BUTTON_DPAD_RIGHT => .dpad_right,
        else => null,
    };
}

/// The engine axis for an SDL gamepad axis, or null for one the engine does not report.
pub fn axisFromSdl(raw: u8) ?GamepadAxis {
    const sdl: c_int = raw;
    return switch (sdl) {
        c.SDL_GAMEPAD_AXIS_LEFTX => .left_x,
        c.SDL_GAMEPAD_AXIS_LEFTY => .left_y,
        c.SDL_GAMEPAD_AXIS_RIGHTX => .right_x,
        c.SDL_GAMEPAD_AXIS_RIGHTY => .right_y,
        c.SDL_GAMEPAD_AXIS_LEFT_TRIGGER => .left_trigger,
        c.SDL_GAMEPAD_AXIS_RIGHT_TRIGGER => .right_trigger,
        else => null,
    };
}

/// Turns SDL's raw axis value, from -32768 to 32767, into the engine's range. A stick runs from -1 to
/// 1, where the most negative value clamps to -1. A trigger runs from 0 to 1.
pub fn normalizeAxis(axis: GamepadAxis, raw: i16) f32 {
    const value = @as(f32, @floatFromInt(raw)) / 32767.0;
    return switch (axis) {
        .left_trigger, .right_trigger => std.math.clamp(value, 0.0, 1.0),
        else => std.math.clamp(value, -1.0, 1.0),
    };
}

test "SDL's gamepad buttons map to the engine's names, and the unnamed ones map to nothing" {
    try std.testing.expectEqual(@as(?GamepadButton, .south), buttonFromSdl(c.SDL_GAMEPAD_BUTTON_SOUTH));
    try std.testing.expectEqual(@as(?GamepadButton, .dpad_right), buttonFromSdl(c.SDL_GAMEPAD_BUTTON_DPAD_RIGHT));
    try std.testing.expectEqual(@as(?GamepadButton, .right_shoulder), buttonFromSdl(c.SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER));
    try std.testing.expectEqual(@as(?GamepadButton, null), buttonFromSdl(c.SDL_GAMEPAD_BUTTON_MISC1));
    try std.testing.expectEqual(@as(?GamepadButton, null), buttonFromSdl(c.SDL_GAMEPAD_BUTTON_TOUCHPAD));
}

test "every standard SDL button maps to a different engine button" {
    const standard = [_]u8{
        c.SDL_GAMEPAD_BUTTON_SOUTH,      c.SDL_GAMEPAD_BUTTON_EAST,           c.SDL_GAMEPAD_BUTTON_WEST,
        c.SDL_GAMEPAD_BUTTON_NORTH,      c.SDL_GAMEPAD_BUTTON_BACK,           c.SDL_GAMEPAD_BUTTON_GUIDE,
        c.SDL_GAMEPAD_BUTTON_START,      c.SDL_GAMEPAD_BUTTON_LEFT_STICK,     c.SDL_GAMEPAD_BUTTON_RIGHT_STICK,
        c.SDL_GAMEPAD_BUTTON_LEFT_SHOULDER, c.SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER, c.SDL_GAMEPAD_BUTTON_DPAD_UP,
        c.SDL_GAMEPAD_BUTTON_DPAD_DOWN,  c.SDL_GAMEPAD_BUTTON_DPAD_LEFT,      c.SDL_GAMEPAD_BUTTON_DPAD_RIGHT,
    };
    var seen = [_]bool{false} ** std.enums.values(GamepadButton).len;
    for (standard) |raw| {
        const button = buttonFromSdl(raw) orelse return error.Unmapped;
        try std.testing.expect(!seen[@intFromEnum(button)]);
        seen[@intFromEnum(button)] = true;
    }
    for (seen) |used| try std.testing.expect(used);
}

test "SDL's axes map to the engine's, and the triggers are named" {
    try std.testing.expectEqual(@as(?GamepadAxis, .left_x), axisFromSdl(c.SDL_GAMEPAD_AXIS_LEFTX));
    try std.testing.expectEqual(@as(?GamepadAxis, .right_y), axisFromSdl(c.SDL_GAMEPAD_AXIS_RIGHTY));
    try std.testing.expectEqual(@as(?GamepadAxis, .left_trigger), axisFromSdl(c.SDL_GAMEPAD_AXIS_LEFT_TRIGGER));
    try std.testing.expectEqual(@as(?GamepadAxis, .right_trigger), axisFromSdl(c.SDL_GAMEPAD_AXIS_RIGHT_TRIGGER));
}

test "a stick's raw range normalizes to -1 through 1, and a trigger's to 0 through 1" {
    try std.testing.expectEqual(@as(f32, 0), normalizeAxis(.left_x, 0));
    try std.testing.expectApproxEqAbs(@as(f32, 1), normalizeAxis(.left_x, 32767), 1e-6);
    try std.testing.expectEqual(@as(f32, -1), normalizeAxis(.left_x, -32768));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), normalizeAxis(.right_trigger, 16384), 1e-3);
    try std.testing.expectEqual(@as(f32, 0), normalizeAxis(.left_trigger, -500));
}

test "a table finds a device by its instance id, and reports the id the engine uses for it" {
    var table = Table{};
    table.instance[2] = 7;
    table.generation[2] = 3;
    try std.testing.expectEqual(@as(?u8, 2), slotOf(&table, 7));
    try std.testing.expectEqual(@as(?u8, null), slotOf(&table, 8));
    try std.testing.expectEqual(GamepadId{ .slot = 2, .generation = 3 }, idOf(&table, 7).?);
    try std.testing.expectEqual(@as(?u8, 0), freeSlot(&table));
}

test "detaching frees the slot and keeps its generation, so the old id stops matching" {
    var table = Table{};
    table.instance[0] = 4;
    table.generation[0] = 9;
    const id = detach(&table, 4).?;
    try std.testing.expectEqual(GamepadId{ .slot = 0, .generation = 9 }, id);
    try std.testing.expectEqual(@as(?u8, null), slotOf(&table, 4));
    try std.testing.expectEqual(@as(u32, 9), table.generation[0]);
    try std.testing.expect(detach(&table, 4) == null);
}

test "a full table has no free slot for another device" {
    var table = Table{};
    for (&table.instance, 0..) |*slot, index| slot.* = @intCast(100 + index);
    try std.testing.expectEqual(@as(?u8, null), freeSlot(&table));
}
