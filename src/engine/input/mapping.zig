//! Reads `bind` lines from the settings file into an action map. A line has this form, and it
//! replaces the bindings of one action:
//!
//!     bind <action> = <binding>, <binding>, ...
//!     bind <action> = none
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
    if (std.mem.eql(u8, std.mem.trim(u8, value, " \t"), "none")) {
        map.set(which, &.{});
        return;
    }
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

/// Serializes a map into settings text. Existing comments, window settings, and unrelated game
/// settings are preserved; bind lines for actions in `Action` are replaced with the map's values.
pub fn serialize(allocator: std.mem.Allocator, comptime Action: type, map: *const action.ActionMap(Action), existing: []const u8) std.mem.Allocator.Error![]u8 {
    var preserved_len: usize = 0;
    var start: usize = 0;
    while (start < existing.len) {
        const end = std.mem.indexOfScalarPos(u8, existing, start, '\n') orelse existing.len;
        const next = if (end < existing.len) end + 1 else end;
        if (!replacesBindingLine(Action, existing[start..end])) preserved_len += next - start;
        start = next;
    }
    if (existing.len > 0 and existing[existing.len - 1] != '\n') {
        if (preserved_len > 0) preserved_len += 1;
    }

    var line_buffer: [512]u8 = undefined;
    var bindings_len: usize = 0;
    for (std.enums.values(Action)) |which| {
        bindings_len += formatBindingLine(&line_buffer, which, map.bindingsOf(which)).len;
    }
    const output = try allocator.alloc(u8, preserved_len + bindings_len);
    errdefer allocator.free(output);

    var cursor: usize = 0;
    start = 0;
    while (start < existing.len) {
        const end = std.mem.indexOfScalarPos(u8, existing, start, '\n') orelse existing.len;
        const next = if (end < existing.len) end + 1 else end;
        if (!replacesBindingLine(Action, existing[start..end])) {
            @memcpy(output[cursor..][0 .. next - start], existing[start..next]);
            cursor += next - start;
        }
        start = next;
    }
    if (cursor > 0 and output[cursor - 1] != '\n') {
        output[cursor] = '\n';
        cursor += 1;
    }
    for (std.enums.values(Action)) |which| {
        const line = formatBindingLine(&line_buffer, which, map.bindingsOf(which));
        @memcpy(output[cursor..][0..line.len], line);
        cursor += line.len;
    }
    return output;
}

fn replacesBindingLine(comptime Action: type, raw: []const u8) bool {
    const text = std.mem.trim(u8, raw, " \t\r");
    if (!std.mem.startsWith(u8, text, "bind ")) return false;
    const name_text = text["bind ".len..];
    const equals = std.mem.indexOfScalar(u8, name_text, '=') orelse return false;
    const name = std.mem.trim(u8, name_text[0..equals], " \t");
    return std.meta.stringToEnum(Action, name) != null;
}

fn formatBindingLine(buffer: []u8, which: anytype, bindings: []const Binding) []const u8 {
    var used = (std.fmt.bufPrint(buffer, "bind {s} = ", .{@tagName(which)}) catch unreachable).len;
    if (bindings.len == 0) {
        used += (std.fmt.bufPrint(buffer[used..], "none", .{}) catch unreachable).len;
    } else {
        for (bindings, 0..) |binding, index| {
            if (index != 0) {
                const separator = std.fmt.bufPrint(buffer[used..], ", ", .{}) catch unreachable;
                used += separator.len;
            }
            const name = bindingName(binding, buffer[used..]);
            used += name.len;
        }
    }
    buffer[used] = '\n';
    return buffer[0 .. used + 1];
}

/// Room for the text of one action's bindings: four names, the longest of them 18 bytes, and the commas between.
pub const binding_text_capacity = 96;

/// Writes `bindings` the way a settings line spells them: names separated by commas, or `none` when there are none.
/// The result is a slice of `buffer`.
pub fn bindingsText(buffer: *[binding_text_capacity]u8, bindings: []const Binding) []const u8 {
    if (bindings.len == 0) return "none";
    var used: usize = 0;
    for (bindings, 0..) |binding, index| {
        if (index != 0) {
            const separator = std.fmt.bufPrint(buffer[used..], ", ", .{}) catch unreachable;
            used += separator.len;
        }
        const name = bindingName(binding, buffer[used..]);
        used += name.len;
    }
    return buffer[0..used];
}

fn bindingName(binding: Binding, output: []u8) []const u8 {
    return switch (binding) {
        .key => |key| std.fmt.bufPrint(output, "{s}", .{@tagName(key)}) catch unreachable,
        .mouse => |button| std.fmt.bufPrint(output, "mouse_{s}", .{@tagName(button)}) catch unreachable,
        .gamepad_button => |button| std.fmt.bufPrint(output, "pad_{s}", .{@tagName(button)}) catch unreachable,
        .gamepad_axis => |axis| blk: {
            const trigger = isTrigger(axis.axis);
            const suffix: []const u8 = if (trigger) "" else switch (axis.direction) {
                .negative => "-",
                .positive => "+",
            };
            break :blk std.fmt.bufPrint(output, "pad_{s}{s}", .{ @tagName(axis.axis), suffix }) catch unreachable;
        },
    };
}

test "a binding list is spelled as its settings line spells it, and reads none when empty" {
    var buffer: [binding_text_capacity]u8 = undefined;
    try std.testing.expectEqualStrings("none", bindingsText(&buffer, &.{}));
    try std.testing.expectEqualStrings("left, a, mouse_right, pad_south", bindingsText(&buffer, &.{
        .{ .key = .left },
        .{ .key = .a },
        .{ .mouse = .right },
        .{ .gamepad_button = .south },
    }));
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
    const saved_level = logging.min_level;
    defer logging.min_level = saved_level;
    logging.min_level = .err;

    const map = load(TestAction, test_defaults, "bind jump = bogus, nothing\n");
    try std.testing.expectEqual(@as(usize, 2), map.bindingsOf(.jump).len);
    try std.testing.expectEqual(Binding{ .key = .w }, map.bindingsOf(.jump)[0]);
}

test "lines that are not actions, window settings, and comments do not change the bindings" {
    const saved_level = logging.min_level;
    defer logging.min_level = saved_level;
    logging.min_level = .err;

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

test "serialized bindings preserve other settings and round trip action values" {
    const original =
        \\# user settings
        \\resolution = 1280x720
        \\bind jump = left
        \\custom = value
        \\bind other_game_action = mouse_right
        \\
    ;
    var map = load(TestAction, test_defaults, original);
    map.set(.jump, &.{
        .{ .gamepad_axis = .{ .axis = .left_x, .direction = .negative } },
        .{ .mouse = .middle },
    });
    map.set(.pause, &.{});

    const saved = try serialize(std.testing.allocator, TestAction, &map, original);
    defer std.testing.allocator.free(saved);
    try std.testing.expect(std.mem.startsWith(u8, saved, "# user settings\nresolution = 1280x720\ncustom = value\nbind other_game_action = mouse_right\n"));
    try std.testing.expect(std.mem.indexOf(u8, saved, "bind jump = pad_left_x-, mouse_middle\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved, "bind pause = none\n") != null);

    const reloaded = load(TestAction, test_defaults, saved);
    try std.testing.expectEqualSlices(Binding, map.bindingsOf(.jump), reloaded.bindingsOf(.jump));
    try std.testing.expectEqual(@as(usize, 0), reloaded.bindingsOf(.pause).len);
}
