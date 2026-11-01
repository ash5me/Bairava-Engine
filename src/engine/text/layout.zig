//! Word wrapping and horizontal alignment over existing font metrics. This lays out codepoints
//! without shaping them; glyph substitutions and complex-script positioning are not performed.

const std = @import("std");

pub const Alignment = enum { left, center, right };

pub const Line = struct {
    text: []const u8,
    width: f32,
    x_offset: f32,
};

pub const Layout = struct {
    allocator: std.mem.Allocator,
    lines: []Line,
    width: f32,
    height: f32,
    line_height: f32,

    pub fn deinit(self: *Layout) void {
        self.allocator.free(self.lines);
        self.* = undefined;
    }
};

pub const LayoutError = std.mem.Allocator.Error || error{ InvalidLineHeight, InvalidWidth };

/// Wraps at spaces and tabs, preserves explicit newlines and blank lines, and splits words wider than
/// the available width at UTF-8 codepoint boundaries. The returned line slices borrow `text`.
pub fn layout(
    allocator: std.mem.Allocator,
    text: []const u8,
    max_width: f32,
    line_height: f32,
    alignment: Alignment,
    measure_context: anytype,
    measure: anytype,
) LayoutError!Layout {
    if (!std.math.isFinite(max_width) or max_width <= 0) return error.InvalidWidth;
    if (!std.math.isFinite(line_height) or line_height <= 0) return error.InvalidLineHeight;

    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(allocator);

    var paragraph_start: usize = 0;
    while (true) {
        const paragraph_end = findParagraphEnd(text, paragraph_start);
        try wrapParagraph(
            allocator,
            &lines,
            text,
            paragraph_start,
            paragraph_end,
            max_width,
            alignment,
            measure_context,
            measure,
        );
        if (paragraph_end == text.len) break;
        const newline_len: usize = if (text[paragraph_end] == '\r' and
            paragraph_end + 1 < text.len and text[paragraph_end + 1] == '\n') 2 else 1;
        paragraph_start = paragraph_end + newline_len;
    }

    const result_lines = try lines.toOwnedSlice(allocator);
    var widest: f32 = 0;
    for (result_lines) |line| widest = @max(widest, line.width);
    return .{
        .allocator = allocator,
        .lines = result_lines,
        .width = widest,
        .height = @as(f32, @floatFromInt(result_lines.len)) * line_height,
        .line_height = line_height,
    };
}

fn findParagraphEnd(text: []const u8, start: usize) usize {
    for (text[start..], start..) |byte, index| {
        if (byte == '\n' or byte == '\r') return index;
    }
    return text.len;
}

fn wrapParagraph(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    text: []const u8,
    paragraph_start: usize,
    paragraph_end: usize,
    max_width: f32,
    alignment: Alignment,
    measure_context: anytype,
    measure: anytype,
) std.mem.Allocator.Error!void {
    var cursor = paragraph_start;
    while (cursor < paragraph_end and isBreakSpace(text[cursor])) : (cursor += 1) {}
    if (cursor == paragraph_end) {
        try appendLine(allocator, lines, text[paragraph_end..paragraph_end], max_width, alignment, measure_context, measure);
        return;
    }

    var line_start = cursor;
    var line_end = cursor;
    var active = false;
    while (cursor < paragraph_end) {
        while (cursor < paragraph_end and isBreakSpace(text[cursor])) : (cursor += 1) {}
        if (cursor == paragraph_end) break;

        const word_start = cursor;
        while (cursor < paragraph_end and !isBreakSpace(text[cursor])) : (cursor += codepointLength(text, cursor)) {}
        const word_end = cursor;
        const candidate_start = if (active) line_start else word_start;
        const candidate_width = measure(measure_context, text[candidate_start..word_end]);

        if (candidate_width <= max_width) {
            if (!active) line_start = word_start;
            line_end = word_end;
            active = true;
            continue;
        }

        if (active) {
            try appendLine(allocator, lines, text[line_start..line_end], max_width, alignment, measure_context, measure);
            active = false;
        }

        const word_width = measure(measure_context, text[word_start..word_end]);
        if (word_width > max_width) {
            try appendLongWord(allocator, lines, text, word_start, word_end, max_width, alignment, measure_context, measure);
        } else {
            line_start = word_start;
            line_end = word_end;
            active = true;
        }
    }

    if (active) try appendLine(allocator, lines, text[line_start..line_end], max_width, alignment, measure_context, measure);
}

fn appendLongWord(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    text: []const u8,
    start: usize,
    end: usize,
    max_width: f32,
    alignment: Alignment,
    measure_context: anytype,
    measure: anytype,
) std.mem.Allocator.Error!void {
    var chunk_start = start;
    while (chunk_start < end) {
        var cursor = chunk_start;
        var fitting_end = cursor;
        while (cursor < end) {
            const next = cursor + codepointLength(text, cursor);
            if (measure(measure_context, text[chunk_start..next]) > max_width) break;
            fitting_end = next;
            cursor = next;
        }
        if (fitting_end == chunk_start) fitting_end = chunk_start + codepointLength(text, chunk_start);
        try appendLine(allocator, lines, text[chunk_start..fitting_end], max_width, alignment, measure_context, measure);
        chunk_start = fitting_end;
    }
}

fn appendLine(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    text: []const u8,
    max_width: f32,
    alignment: Alignment,
    measure_context: anytype,
    measure: anytype,
) std.mem.Allocator.Error!void {
    const width = measure(measure_context, text);
    const remaining = @max(0, max_width - width);
    const offset = switch (alignment) {
        .left => 0,
        .center => remaining / 2,
        .right => remaining,
    };
    try lines.append(allocator, .{ .text = text, .width = width, .x_offset = offset });
}

fn isBreakSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn codepointLength(text: []const u8, index: usize) usize {
    const length = std.unicode.utf8ByteSequenceLength(text[index]) catch return 1;
    if (index + length > text.len) return 1;
    _ = std.unicode.utf8Decode(text[index .. index + length]) catch return 1;
    return length;
}

const TestMeasure = struct {
    fn width(_: void, text: []const u8) f32 {
        var count: f32 = 0;
        var iterator = (std.unicode.Utf8View.init(text) catch unreachable).iterator();
        while (iterator.nextCodepoint()) |codepoint| count += if (codepoint == ' ') 0.5 else 1;
        return count;
    }
};

test "wraps at words and applies horizontal alignment" {
    var result = try layout(std.testing.allocator, "one two three", 7, 10, .center, {}, TestMeasure.width);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.lines.len);
    try std.testing.expectEqualStrings("one two", result.lines[0].text);
    try std.testing.expectEqualStrings("three", result.lines[1].text);
    try std.testing.expectEqual(@as(f32, 20), result.height);
    try std.testing.expectEqual(@as(f32, 1), result.lines[1].x_offset);
}

test "explicit newlines preserve blank lines and long words split on codepoint boundaries" {
    var result = try layout(std.testing.allocator, "ab\r\n\néxy", 2, 8, .right, {}, TestMeasure.width);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 4), result.lines.len);
    try std.testing.expectEqualStrings("ab", result.lines[0].text);
    try std.testing.expectEqualStrings("", result.lines[1].text);
    try std.testing.expectEqualStrings("éx", result.lines[2].text);
    try std.testing.expectEqualStrings("y", result.lines[3].text);
    try std.testing.expectEqual(@as(f32, 1), result.lines[3].x_offset);
    try std.testing.expectEqual(@as(f32, 32), result.height);
}

test "empty text produces one line and invalid widths are rejected" {
    var result = try layout(std.testing.allocator, "", 10, 12, .left, {}, TestMeasure.width);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.lines.len);
    try std.testing.expectEqual(@as(f32, 0), result.width);
    try std.testing.expectError(error.InvalidWidth, layout(std.testing.allocator, "text", 0, 12, .left, {}, TestMeasure.width));
    try std.testing.expectError(error.InvalidLineHeight, layout(std.testing.allocator, "text", 10, 0, .left, {}, TestMeasure.width));
}
