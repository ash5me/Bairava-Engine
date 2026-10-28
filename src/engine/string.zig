//! Fixed-capacity, validated strings for asset names and asset paths.
//!
//! Both types store their bytes inline, so they never allocate and never overflow. They are
//! validated once, when they enter the engine. Everything after that can rely on the rules
//! below without checking again. Nothing in this file imports SDL or the logger, so it runs in
//! `zig build test` without a GPU.

const std = @import("std");

/// Longest asset name, in bytes.
pub const max_name_len = 64;
/// Longest asset path, in bytes. Paths go to C as null-terminated strings, so `Path` keeps one
/// extra byte for the terminator.
pub const max_path_len = 255;

pub const Error = error{
    /// The string is empty.
    Empty,
    /// The string is longer than its field allows.
    TooLong,
    /// The string contains a character that isn't allowed.
    BadCharacter,
    /// A segment is empty, or is `.` or `..`, or starts with a character that isn't allowed.
    BadSegment,
    /// The path starts with `/`, so it isn't relative to the project root.
    Absolute,
};

/// Rules for an asset name. A name is one or more segments separated by `/`, such as `tile` or
/// `ui/button_ok`. The first character of the name must be a lowercase letter. Each segment
/// must start with a lowercase letter or a digit, and may contain only lowercase letters,
/// digits, `_`, `-`, and `.`. Because a segment can't start with `.`, the segments `.` and `..`
/// are rejected too.
pub fn validateName(s: []const u8) Error!void {
    if (s.len == 0) return error.Empty;
    if (s.len > max_name_len) return error.TooLong;
    if (!isLowerLetter(s[0])) return error.BadCharacter;

    var segments = std.mem.splitScalar(u8, s, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) return error.BadSegment;
        if (!isLowerLetter(segment[0]) and !isDigit(segment[0])) return error.BadSegment;
        for (segment) |ch| {
            if (!isLowerLetter(ch) and !isDigit(ch) and ch != '_' and ch != '-' and ch != '.') {
                return error.BadCharacter;
            }
        }
    }
}

/// Rules for an asset path. A path is relative to the project root, uses `/` as its separator,
/// and is case-sensitive, so `Assets/a.png` and `assets/a.png` are different paths. Allowed
/// characters are printable ASCII, except `\` and `:`, which rules out Windows separators and
/// drive letters. Empty segments are rejected, which rules out a leading or trailing `/`. The
/// segments `.` and `..` are rejected too, so a path can't climb out of the project.
pub fn validatePath(s: []const u8) Error!void {
    if (s.len == 0) return error.Empty;
    if (s.len > max_path_len) return error.TooLong;
    if (s[0] == '/') return error.Absolute;
    for (s) |ch| {
        if (ch < 0x20 or ch > 0x7e or ch == '\\' or ch == ':') return error.BadCharacter;
    }

    var segments = std.mem.splitScalar(u8, s, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) return error.BadSegment;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.BadSegment;
    }
}

/// A validated asset name, stored inline. Compare names with `slice()` and `std.mem.eql`.
pub const Name = struct {
    len: u8 = 0,
    bytes: [max_name_len]u8 = undefined,

    /// Validates `s` and copies it. Fails with the first rule `s` breaks.
    pub fn init(s: []const u8) Error!Name {
        try validateName(s);
        var name = Name{ .len = @intCast(s.len) };
        @memcpy(name.bytes[0..s.len], s);
        return name;
    }

    /// The name's bytes. The slice points into `self`, so it's only valid while `self` is.
    pub fn slice(self: *const Name) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// A validated asset path, stored inline with a null terminator for C APIs.
pub const Path = struct {
    len: u16 = 0,
    /// `buf[len]` is always 0, so `cstr` can hand out the buffer without copying.
    buf: [max_path_len + 1]u8 = [_]u8{0} ** (max_path_len + 1),

    /// Validates `s` and copies it. Fails with the first rule `s` breaks.
    pub fn init(s: []const u8) Error!Path {
        try validatePath(s);
        var path = Path{ .len = @intCast(s.len) };
        @memcpy(path.buf[0..s.len], s);
        return path;
    }

    /// The path's bytes, without the terminator.
    pub fn slice(self: *const Path) []const u8 {
        return self.buf[0..self.len];
    }

    /// The path as a null-terminated string for C. Valid while `self` is.
    pub fn cstr(self: *const Path) [*:0]const u8 {
        return self.buf[0..self.len :0].ptr;
    }
};

fn isLowerLetter(ch: u8) bool {
    return ch >= 'a' and ch <= 'z';
}

fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

test "names accept the documented forms" {
    try validateName("tile");
    try validateName("warrior_16x32");
    try validateName("ui/button_ok");
    try validateName("a-b.c/d1");
    try validateName("level2/tiles/grass.v2");
}

test "names reject malformed input" {
    try std.testing.expectError(error.Empty, validateName(""));
    try std.testing.expectError(error.BadCharacter, validateName("Tile"));
    try std.testing.expectError(error.BadCharacter, validateName("_tile"));
    try std.testing.expectError(error.BadCharacter, validateName("1tile"));
    try std.testing.expectError(error.BadCharacter, validateName("a b"));
    try std.testing.expectError(error.BadCharacter, validateName("a\\b"));
    try std.testing.expectError(error.BadCharacter, validateName("a:b"));
    try std.testing.expectError(error.BadSegment, validateName("a//b"));
    try std.testing.expectError(error.BadSegment, validateName("a/"));
    try std.testing.expectError(error.BadCharacter, validateName("/a"));
    try std.testing.expectError(error.BadSegment, validateName("a/../b"));
    try std.testing.expectError(error.BadSegment, validateName("a/./b"));
    try std.testing.expectError(error.BadSegment, validateName("a/.hidden"));
}

test "names respect the length limit" {
    const exact = "a" ** max_name_len;
    try validateName(exact);
    const too_long = "a" ** (max_name_len + 1);
    try std.testing.expectError(error.TooLong, validateName(too_long));
}

test "Name copies its bytes and compares by content" {
    const name = try Name.init("ui/button");
    try std.testing.expectEqualStrings("ui/button", name.slice());

    const copy = name;
    try std.testing.expectEqualStrings("ui/button", copy.slice());
    try std.testing.expectError(error.BadCharacter, Name.init("Button"));
}

test "paths accept relative project paths" {
    try validatePath("assets/tile.png");
    try validatePath("assets/warrior_16x32.png");
    try validatePath("assets/ui files/my art.png");
    try validatePath("a.png");
}

test "paths reject absolute, climbing, and platform-specific forms" {
    try std.testing.expectError(error.Empty, validatePath(""));
    try std.testing.expectError(error.Absolute, validatePath("/etc/passwd"));
    try std.testing.expectError(error.BadCharacter, validatePath("C:/art/a.png"));
    try std.testing.expectError(error.BadCharacter, validatePath("assets\\a.png"));
    try std.testing.expectError(error.BadSegment, validatePath("assets/../secret.png"));
    try std.testing.expectError(error.BadSegment, validatePath("assets/./a.png"));
    try std.testing.expectError(error.BadSegment, validatePath("assets//a.png"));
    try std.testing.expectError(error.BadSegment, validatePath("assets/"));
    try std.testing.expectError(error.BadCharacter, validatePath("assets/tab\there.png"));
    try std.testing.expectError(error.BadCharacter, validatePath("assets/caf\xc3\xa9.png"));
}

test "paths respect the length limit and are null-terminated" {
    const exact = "a" ** max_path_len;
    const path = try Path.init(exact);
    try std.testing.expectEqual(@as(usize, max_path_len), path.slice().len);
    try std.testing.expectEqual(@as(u8, 0), path.buf[max_path_len]);

    const too_long = "a" ** (max_path_len + 1);
    try std.testing.expectError(error.TooLong, Path.init(too_long));
}

test "Path.cstr matches the stored bytes and terminates them" {
    const path = try Path.init("assets/tile.png");
    const c_view = std.mem.span(path.cstr());
    try std.testing.expectEqualStrings("assets/tile.png", c_view);
    try std.testing.expectEqualStrings("assets/tile.png", path.slice());
}
