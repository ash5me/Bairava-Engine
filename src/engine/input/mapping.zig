//! Reads `bind` lines from the settings file into an action map. A line has this form, and it
//! replaces the bindings of one action:
//!
//!     bind <action> = <binding>, <binding>, ...
//!
//! Binding names are the ones below. A name that isn't valid is logged and dropped, and an action
//! whose names are all invalid keeps its defaults.
//!
//!   key            the `Key` enum names, such as `left`, `a`, `f5`, or `keypad_plus`
//!   mouse button   `mouse_left`, `mouse_right`, or `mouse_middle`
//!   gamepad button `pad_` and the button name, such as `pad_south` or `pad_dpad_left`
//!   stick half     `pad_` and the axis name with a sign, such as `pad_left_x-` (left) or
//!                  `pad_right_y+` (down)
//!   trigger        `pad_left_trigger` or `pad_right_trigger`, which read the positive half

const std = @import("std");
const types = @import("../platform/types.zig");
const logging = @import("../logging/log.zig");
const settings = @import("../core/settings.zig");
const action = @import("action.zig");
const gamepad = @import("gamepad.zig");
const input = @import("input.zig");

const Binding = action.Binding;
const Key = input.Key;
const log = logging.scoped("input");

/// Reads one binding name. Returns null for a name that is not one of the forms above.
pub fn parseBinding(text: []const u8) ?Binding {
    if (std.mem.startsWith(u8, text, "mouse_")) {
        const button = std.meta.stringToEnum(types.MouseButton, text["mouse_".len..]) orelse return null;
        return .{ .mouse = button };
    }
    if (std.mem.startsWith(u8, text, "pad_")) return parseGamepad(text["pad_".len..]);
    const key = std.meta.stringToEnum(Key, text) orelse return null;
    return .{ .key = key };
}

/// Reads a gamepad name, without its `pad_` prefix.
fn parseGamepad(name: []const u8) ?Binding {
    if (name.len == 0) return null;
    const last = name[name.len - 1];
    if (last == '+' or last == '-') {
        const axis = std.meta.stringToEnum(types.GamepadAxis, name[0 .. name.len - 1]) orelse return null;
        const direction: gamepad.Direction = if (last == '+') .positive else .negative;
        // A trigger has only a positive half, so a negative sign on it names nothing.
        if (isTrigger(axis) and direction == .negative) return null;
        return .{ .gamepad_axis = .{ .axis = axis, .direction = direction } };
    }
    if (std.meta.stringToEnum(types.GamepadButton, name)) |button| return .{ .gamepad_button = button };
    if (std.meta.stringToEnum(types.GamepadAxis, name)) |axis| {
        if (isTrigger(axis)) return .{ .gamepad_axis = .{ .axis = axis, .direction = .positive } };
    }
    return null;
}

fn isTrigger(axis: types.GamepadAxis) bool {
    return axis == .left_trigger or axis == .right_trigger;
}

/// The most bindings one action can have. The alias keeps the list type and the action type in step.
pub const max_bindings = action.max_bindings_per_action;

/// A parsed list of bindings. `skipped` counts names that aren't bindings and any past `max_bindings`.
pub const BindingList = struct {
    items: [max_bindings]Binding = undefined,
    len: usize = 0,
    skipped: usize = 0,
};

/// Reads a comma-separated list of binding names, such as `left, a, pad_dpad_left`.
pub fn parseBindingList(text: []const u8) BindingList {
    var list = BindingList{};
    var names = std.mem.splitScalar(u8, text, ',');
    while (names.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t");
        if (name.len == 0) continue;
        const binding = parseBinding(name) orelse {
            list.skipped += 1;
            continue;
        };
        if (list.len == max_bindings) {
            list.skipped += 1;
            continue;
        }
        list.items[list.len] = binding;
        list.len += 1;
    }
    return list;
}

/// Builds the action map for a game: the defaults, with the `bind` lines of the settings text applied
/// over them. Problems are logged, and the line that has one is ignored, so the action keeps its
/// defaults. Other lines are left to their own readers.
pub fn load(comptime Action: type, defaults: action.Defaults(Action), text: []const u8) action.ActionMap(Action) {
    var map = action.ActionMap(Action).fromDefaults(defaults);
    var lines = settings.Lines.init(text);
    while (lines.next()) |line| {
        const value = line.value orelse {
            log.warn("settings line {d}: '{s}' has no '=', so it is ignored", .{ line.number, line.key });
            continue;
        };
        if (std.mem.startsWith(u8, line.key, "bind ")) {
            bindLine(Action, &map, line.number, line.key["bind ".len..], value);
        } else if (!settings.isWindowKey(line.key)) {
            log.warn("settings line {d}: unknown setting '{s}'", .{ line.number, line.key });
        }
    }
    return map;
}

fn bindLine(comptime Action: type, map: *action.ActionMap(Action), number: usize, name_text: []const u8, value: []const u8) void {
    const name = std.mem.trim(u8, name_text, " \t");
    const which = std.meta.stringToEnum(Action, name) orelse {
        log.warn("settings line {d}: '{s}' is not an action", .{ number, name });
        return;
    };
    const list = parseBindingList(value);
    if (list.skipped > 0) {
        log.warn("settings line {d}: {d} binding name(s) not recognized or past the limit of {d}, so they are dropped", .{ number, list.skipped, max_bindings });
    }
    if (list.len == 0) {
        log.warn("settings line {d}: '{s}' has no valid bindings, so its defaults stay", .{ number, name });
        return;
    }
    map.set(which, list.items[0..list.len]);
}

const TestAction = enum { jump, pause };

const test_defaults = action.Defaults(TestAction).init(.{
    .jump = &.{ .{ .key = .w }, .{ .gamepad_button = .south } },
    .pause = &.{.{ .key = .escape }},
});

test "key names read as keys, and mouse names read as mouse buttons" {
    try std.testing.expectEqual(Binding{ .key = .left }, parseBinding("left").?);
    try std.testing.expectEqual(Binding{ .key = .keypad_plus }, parseBinding("keypad_plus").?);
    try std.testing.expectEqual(Binding{ .mouse = .left }, parseBinding("mouse_left").?);
    try std.testing.expectEqual(Binding{ .mouse = .middle }, parseBinding("mouse_middle").?);
}

test "gamepad button names read after the pad_ prefix" {
    try std.testing.expectEqual(Binding{ .gamepad_button = .south }, parseBinding("pad_south").?);
    try std.testing.expectEqual(Binding{ .gamepad_button = .dpad_left }, parseBinding("pad_dpad_left").?);
    try std.testing.expectEqual(Binding{ .gamepad_button = .left_shoulder }, parseBinding("pad_left_shoulder").?);
}

test "a stick half reads its sign as the direction, and a trigger reads the positive half" {
    try std.testing.expectEqual(
        Binding{ .gamepad_axis = .{ .axis = .left_x, .direction = .negative } },
        parseBinding("pad_left_x-").?,
    );
    try std.testing.expectEqual(
        Binding{ .gamepad_axis = .{ .axis = .right_y, .direction = .positive } },
        parseBinding("pad_right_y+").?,
    );
    try std.testing.expectEqual(
        Binding{ .gamepad_axis = .{ .axis = .right_trigger, .direction = .positive } },
        parseBinding("pad_right_trigger").?,
    );
}

test "names that are not bindings read as null" {
    try std.testing.expect(parseBinding("") == null);
    try std.testing.expect(parseBinding("bogus") == null);
    try std.testing.expect(parseBinding("mouse_x1") == null);
    try std.testing.expect(parseBinding("pad_nothing") == null);
    // A stick needs a sign, and a trigger takes none but the positive one.
    try std.testing.expect(parseBinding("pad_left_x") == null);
    try std.testing.expect(parseBinding("pad_left_trigger-") == null);
    try std.testing.expect(parseBinding("pad_+") == null);
}

test "a binding list reads each name, and counts the ones it drops" {
    const list = parseBindingList(" left, bogus, pad_south ");
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqual(Binding{ .key = .left }, list.items[0]);
    try std.testing.expectEqual(Binding{ .gamepad_button = .south }, list.items[1]);
    try std.testing.expectEqual(@as(usize, 1), list.skipped);
}

test "a binding list stops at the per-action limit and counts the rest as skipped" {
    const list = parseBindingList("a, b, d, s, w");
    try std.testing.expectEqual(@as(usize, max_bindings), list.len);
    try std.testing.expectEqual(@as(usize, 1), list.skipped);
}

test "an empty binding list has no bindings" {
    try std.testing.expectEqual(@as(usize, 0), parseBindingList("  ").len);
}

test "a bind line replaces one action's bindings, and the others keep their defaults" {
    const map = load(TestAction, test_defaults, "bind jump = space, pad_north\n");
    const jump = map.bindingsOf(.jump);
    try std.testing.expectEqual(@as(usize, 2), jump.len);
    try std.testing.expectEqual(Binding{ .key = .space }, jump[0]);
    try std.testing.expectEqual(Binding{ .gamepad_button = .north }, jump[1]);
    try std.testing.expectEqual(@as(usize, 1), map.bindingsOf(.pause).len);
}

test "a bind line with no valid names keeps the defaults" {
    const map = load(TestAction, test_defaults, "bind jump = bogus, nothing\n");
    try std.testing.expectEqual(@as(usize, 2), map.bindingsOf(.jump).len);
    try std.testing.expectEqual(Binding{ .key = .w }, map.bindingsOf(.jump)[0]);
}

test "lines that are not actions, window settings, and comments do not change the bindings" {
    const text =
        \\# a comment
        \\resolution = 960x540
        \\bind nonsense = left
        \\bind pause = escape
        \\
    ;
    const map = load(TestAction, test_defaults, text);
    try std.testing.expectEqual(Binding{ .key = .w }, map.bindingsOf(.jump)[0]);
    try std.testing.expectEqual(Binding{ .key = .escape }, map.bindingsOf(.pause)[0]);
}
