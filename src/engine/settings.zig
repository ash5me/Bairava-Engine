//! The settings file: `name = value` lines, read once at startup from beside the executable.
//! Blank lines and lines that start with `#` are comments. This file reads the window settings,
//! `resolution`, `fullscreen`, and `vsync`. Lines that start with `bind` are key bindings, which
//! the game reads in game/controls.zig. Each reader skips the lines it doesn't use and reports
//! values it can't read.

const std = @import("std");
const input = @import("input.zig");

/// A key the engine can report. Settings name keys with these enum names, such as `left` or `a`.
pub const Key = input.Key;

/// The most keys one action can be bound to. Extra names in a `bind` line are dropped.
pub const max_keys_per_action = 4;

/// The smallest and largest window side the settings file accepts, in pixels.
const min_side: c_int = 64;
const max_side: c_int = 8192;

/// One line of the file. `value` is null when the line has no `=`, so the reader can report it.
pub const Line = struct {
    /// The line's number in the file, counted from 1.
    number: usize,
    /// The text before `=`, trimmed. A bind line's key is `bind` followed by the action name.
    key: []const u8,
    /// The text after `=`, trimmed. Null when the line has no `=`.
    value: ?[]const u8,
};

/// Walks the lines of a settings file in order, skipping blank lines and comments.
pub const Lines = struct {
    rest: []const u8,
    number: usize = 0,

    pub fn init(text: []const u8) Lines {
        // Some Windows editors start a file with a byte order mark, which is not part of the first line.
        const bom = "\xEF\xBB\xBF";
        const body = if (std.mem.startsWith(u8, text, bom)) text[bom.len..] else text;
        return .{ .rest = body };
    }

    /// The next setting line, or null at the end of the file.
    pub fn next(self: *Lines) ?Line {
        while (self.rest.len > 0) {
            const end = std.mem.indexOfScalar(u8, self.rest, '\n') orelse self.rest.len;
            const raw = self.rest[0..end];
            self.rest = self.rest[@min(end + 1, self.rest.len)..];
            self.number += 1;

            const text = std.mem.trim(u8, raw, " \t\r");
            if (text.len == 0 or text[0] == '#') continue;
            if (std.mem.indexOfScalar(u8, text, '=')) |eq| {
                return .{
                    .number = self.number,
                    .key = std.mem.trim(u8, text[0..eq], " \t"),
                    .value = std.mem.trim(u8, text[eq + 1 ..], " \t"),
                };
            }
            return .{ .number = self.number, .key = text, .value = null };
        }
        return null;
    }
};

/// The window keys the engine reads.
const WindowKey = enum { resolution, fullscreen, vsync };

/// Window settings. `width` and `height` are the window size in pixels, `fullscreen` starts the
/// window full screen, and `vsync` waits for the display's refresh before each frame.
pub const Window = struct {
    width: c_int,
    height: c_int,
    fullscreen: bool,
    vsync: bool,
};

/// A window size in pixels.
pub const Size = struct {
    width: c_int,
    height: c_int,
};

/// What `applyWindowLine` did with a line.
pub const Applied = enum {
    /// The key is not a window key, so another reader may use it.
    not_window,
    /// The value was read and the window changed.
    applied,
    /// The key is a window key but the value isn't valid. The window is unchanged.
    bad_value,
};

/// True when `key` is one the engine reads, so the game should not report it as unknown.
pub fn isWindowKey(key: []const u8) bool {
    return std.meta.stringToEnum(WindowKey, key) != null;
}

/// Applies one `key = value` line to `window`.
pub fn applyWindowLine(window: *Window, key: []const u8, value: []const u8) Applied {
    const window_key = std.meta.stringToEnum(WindowKey, key) orelse return .not_window;
    switch (window_key) {
        .resolution => {
            const size = parseResolution(value) orelse return .bad_value;
            window.width = size.width;
            window.height = size.height;
        },
        .fullscreen => {
            window.fullscreen = parseBool(value) orelse return .bad_value;
        },
        .vsync => {
            window.vsync = parseBool(value) orelse return .bad_value;
        },
    }
    return .applied;
}

/// Reads `true` or `false`, and also `yes`, `no`, `on`, and `off`, in any case.
pub fn parseBool(text: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(text, "true") or std.ascii.eqlIgnoreCase(text, "yes") or std.ascii.eqlIgnoreCase(text, "on")) return true;
    if (std.ascii.eqlIgnoreCase(text, "false") or std.ascii.eqlIgnoreCase(text, "no") or std.ascii.eqlIgnoreCase(text, "off")) return false;
    return null;
}

/// Reads one side of a window size: a whole number from `min_side` to `max_side`.
pub fn parseSide(text: []const u8) ?c_int {
    const side = std.fmt.parseInt(c_int, text, 10) catch return null;
    if (side < min_side or side > max_side) return null;
    return side;
}

/// Reads a resolution such as `1280x720`. The separator may be `x` or `X`, and spaces around the numbers are allowed.
pub fn parseResolution(text: []const u8) ?Size {
    const sep = std.mem.indexOfAny(u8, text, "xX") orelse return null;
    const width = parseSide(std.mem.trim(u8, text[0..sep], " \t")) orelse return null;
    const height = parseSide(std.mem.trim(u8, text[sep + 1 ..], " \t")) orelse return null;
    return .{ .width = width, .height = height };
}

/// The keys named in a `bind` line's value, in order. `skipped` counts names that aren't keys and
/// keys past `max_keys_per_action`. The reader drops both and reports them.
pub const KeyList = struct {
    keys: [max_keys_per_action]Key = undefined,
    len: usize = 0,
    skipped: usize = 0,
};

/// Reads a comma-separated list of key names, such as `left, a`.
pub fn parseKeyList(text: []const u8) KeyList {
    var list = KeyList{};
    var names = std.mem.splitScalar(u8, text, ',');
    while (names.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t");
        if (name.len == 0) continue;
        const key = std.meta.stringToEnum(Key, name) orelse {
            list.skipped += 1;
            continue;
        };
        if (list.len == max_keys_per_action) {
            list.skipped += 1;
            continue;
        }
        list.keys[list.len] = key;
        list.len += 1;
    }
    return list;
}

test "Lines skips blank lines and comments, and numbers the rest from 1" {
    var lines = Lines.init("# header\n\nresolution = 960x540\r\n  # indented comment\nfullscreen = true");
    const first = lines.next().?;
    try std.testing.expectEqual(@as(usize, 3), first.number);
    try std.testing.expectEqualStrings("resolution", first.key);
    try std.testing.expectEqualStrings("960x540", first.value.?);
    const second = lines.next().?;
    try std.testing.expectEqual(@as(usize, 5), second.number);
    try std.testing.expectEqualStrings("fullscreen", second.key);
    try std.testing.expectEqualStrings("true", second.value.?);
    try std.testing.expect(lines.next() == null);
}

test "a line without '=' has no value, and its key keeps the text" {
    var lines = Lines.init("vsync\n");
    const line = lines.next().?;
    try std.testing.expectEqualStrings("vsync", line.key);
    try std.testing.expect(line.value == null);
}

test "a bind line keeps its name and its value around the '='" {
    var lines = Lines.init("bind move_left = left, a\n");
    const line = lines.next().?;
    try std.testing.expectEqualStrings("bind move_left", line.key);
    try std.testing.expectEqualStrings("left, a", line.value.?);
}

test "a byte order mark at the start of the file is not part of the first line" {
    var lines = Lines.init("\xEF\xBB\xBFvsync = false\n");
    const line = lines.next().?;
    try std.testing.expectEqualStrings("vsync", line.key);
    try std.testing.expectEqualStrings("false", line.value.?);
}

test "parseBool reads true and false words in any case, and rejects the rest" {
    try std.testing.expectEqual(@as(?bool, true), parseBool("True"));
    try std.testing.expectEqual(@as(?bool, false), parseBool("off"));
    try std.testing.expectEqual(@as(?bool, null), parseBool("maybe"));
}

test "parseResolution reads WIDTHxHEIGHT and rejects anything else" {
    const size = parseResolution("1280 x 720").?;
    try std.testing.expectEqual(@as(c_int, 1280), size.width);
    try std.testing.expectEqual(@as(c_int, 720), size.height);
    try std.testing.expect(parseResolution("1280") == null);
    try std.testing.expect(parseResolution("1280x") == null);
    try std.testing.expect(parseResolution("10x720") == null);
}

test "applyWindowLine sets window values, keeps the old value on a bad one, and passes other keys on" {
    var window = Window{ .width = 960, .height = 540, .fullscreen = false, .vsync = true };
    try std.testing.expectEqual(Applied.applied, applyWindowLine(&window, "resolution", "1280x720"));
    try std.testing.expectEqual(@as(c_int, 1280), window.width);
    try std.testing.expectEqual(@as(c_int, 720), window.height);
    try std.testing.expectEqual(Applied.bad_value, applyWindowLine(&window, "resolution", "wide"));
    try std.testing.expectEqual(@as(c_int, 720), window.height);
    try std.testing.expectEqual(Applied.applied, applyWindowLine(&window, "fullscreen", "yes"));
    try std.testing.expect(window.fullscreen);
    try std.testing.expectEqual(Applied.applied, applyWindowLine(&window, "vsync", "off"));
    try std.testing.expect(!window.vsync);
    try std.testing.expectEqual(Applied.not_window, applyWindowLine(&window, "bind move_left", "a"));
}

test "parseKeyList reads comma-separated names and counts the ones it skips" {
    const list = parseKeyList(" left, a, bogus, keypad_plus ");
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqual(Key.left, list.keys[0]);
    try std.testing.expectEqual(Key.a, list.keys[1]);
    try std.testing.expectEqual(Key.keypad_plus, list.keys[2]);
    try std.testing.expectEqual(@as(usize, 1), list.skipped);
}

test "parseKeyList stops at the per-action limit and counts the rest as skipped" {
    const list = parseKeyList("a, b, d, s, w");
    try std.testing.expectEqual(@as(usize, max_keys_per_action), list.len);
    try std.testing.expectEqual(@as(usize, 1), list.skipped);
}

test "an empty key list has no keys" {
    try std.testing.expectEqual(@as(usize, 0), parseKeyList("  ").len);
}
