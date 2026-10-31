//! A fixed-capacity list of short text lines. The engine fills one each frame with the game's debug
//! lines, and the overlay draws it. It allocates nothing, so filling it costs no memory traffic. A
//! line that is too long is cut short, and a line past the capacity is counted in `dropped`, so a
//! full list is visible rather than silent. Pure code with no SDL, so `zig build test` covers it.

const std = @import("std");

/// Lines kept at once.
pub const max_lines = 40;
/// Longest line kept, in bytes. Longer text is cut at this length.
pub const max_line_len = 96;

pub const Text = struct {
    bytes: [max_lines][max_line_len]u8 = undefined,
    lens: [max_lines]u8 = [_]u8{0} ** max_lines,
    /// Lines in use, from 0 to `max_lines`.
    count: usize = 0,
    /// Lines that did not fit since the last `clear`.
    dropped: u32 = 0,

    /// Empties the list, ready for a new frame.
    pub fn clear(self: *Text) void {
        self.count = 0;
        self.dropped = 0;
    }

    /// Appends one line, formatted with `fmt`. Text past `max_line_len` is cut off. A format that
    /// does not fit its scratch buffer is replaced by a short note, so the call never fails.
    pub fn print(self: *Text, comptime fmt: []const u8, args: anytype) void {
        if (self.count == max_lines) {
            self.dropped += 1;
            return;
        }
        var scratch: [512]u8 = undefined;
        const full: []const u8 = std.fmt.bufPrint(&scratch, fmt, args) catch "(line too long)";
        const n = @min(full.len, max_line_len);
        @memcpy(self.bytes[self.count][0..n], full[0..n]);
        self.lens[self.count] = @intCast(n);
        self.count += 1;
    }

    /// The line at index `i`, which must be below `count`.
    pub fn line(self: *const Text, i: usize) []const u8 {
        return self.bytes[i][0..self.lens[i]];
    }
};

test "lines keep their text, and a full list counts what it drops" {
    var text = Text{};
    text.print("fps {d}", .{60});
    try std.testing.expectEqual(@as(usize, 1), text.count);
    try std.testing.expectEqualStrings("fps 60", text.line(0));

    var i: usize = 0;
    while (i < max_lines + 3) : (i += 1) text.print("x", .{});
    try std.testing.expectEqual(@as(usize, max_lines), text.count);
    try std.testing.expectEqual(@as(u32, 4), text.dropped);

    text.clear();
    try std.testing.expectEqual(@as(usize, 0), text.count);
    try std.testing.expectEqual(@as(u32, 0), text.dropped);
}

test "a line longer than the line length is cut to it" {
    var text = Text{};
    const long: []const u8 = "0123456789" ** 12;
    text.print("{s}", .{long});
    try std.testing.expectEqual(@as(usize, max_line_len), text.line(0).len);
    try std.testing.expectEqualStrings("0123456789", text.line(0)[0..10]);
}
