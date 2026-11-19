//! Wraps and aligns shaped text: the Phase 5 layout over the shaper, beside layout.zig, which static providers use.
//! It keeps layout.zig's line rules: wrap at spaces and tabs, keep explicit newlines and blank lines, drop the break
//! spaces at a wrap, and split a word wider than the line. Two things change:
//! - Each candidate line is shaped before it is measured, and each kept line is shaped once more to get its glyphs.
//!   A line therefore measures exactly what it draws, with its own kerning and no kerning carried over from outside.
//! - A word wider than the line is split only at grapheme boundaries (cluster starts), never inside a grapheme.
//!
//! Break policy for the first release: explicit newlines (LF, CR, CRLF) and ASCII space and tab. There are no Unicode
//! line-breaking rules and no hyphenation. A line never starts or ends inside a grapheme, because breaks happen only at
//! spaces, tabs, and grapheme starts. Each glyph's cluster is its byte offset in the source text.
//!
//! Known limit: a combining mark placed directly after a space forms one grapheme with that space. The wrap logic
//! breaks at the space byte, so such a mark can be detached from the space. Left to right text is otherwise covered.

const std = @import("std");
const shaper = @import("shaper.zig");
const text_layout = @import("layout.zig");

pub const Alignment = text_layout.Alignment;

pub const LayoutError = text_layout.LayoutError;
pub const Line = text_layout.Line;
pub const Layout = text_layout.Layout;

const GlyphRange = struct {
    start: usize,
    end: usize,
};

const ShapedData = struct {
    allocator: std.mem.Allocator,
    glyphs: []shaper.Glyph,
    ranges: []GlyphRange,
    font_id: u64,
};

fn destroyShapedData(raw: *anyopaque) void {
    const data: *ShapedData = @ptrCast(@alignCast(raw));
    data.allocator.free(data.glyphs);
    data.allocator.free(data.ranges);
    data.allocator.destroy(data);
}

fn dataOf(lay: *const Layout) ?*const ShapedData {
    const raw = lay.shaped_data orelse return null;
    return @ptrCast(@alignCast(raw));
}

pub fn fontIdOf(lay: *const Layout) ?u64 {
    const data = dataOf(lay) orelse return null;
    return data.font_id;
}

pub fn glyphsOf(lay: *const Layout, line_index: usize) []const shaper.Glyph {
    const data = dataOf(lay) orelse return &.{};
    const range = data.ranges[line_index];
    return data.glyphs[range.start..range.end];
}

/// Builds a Layout. Lines and glyphs accumulate here, so the wrap helpers share one state.
const Builder = struct {
    allocator: std.mem.Allocator,
    shaper: *shaper.Shaper,
    options: shaper.Options,
    text: []const u8,
    max_width: f32,
    alignment: Alignment,
    lines: std.ArrayList(Line) = .empty,
    glyphs: std.ArrayList(shaper.Glyph) = .empty,
    ranges: std.ArrayList(GlyphRange) = .empty,
    /// Grapheme ends of the word being split. Reused, so a long word costs one allocation at most.
    ends: std.ArrayList(usize) = .empty,

    fn deinit(self: *Builder) void {
        self.lines.deinit(self.allocator);
        self.glyphs.deinit(self.allocator);
        self.ranges.deinit(self.allocator);
        self.ends.deinit(self.allocator);
    }

    /// The shaped width of text[start..end], measured with nothing kept.
    fn measure(self: *Builder, start: usize, end: usize) shaper.Error!f32 {
        return self.shaper.measure(self.text[start..end], self.options);
    }

    /// Appends the line text[start..end]. It is shaped here, so the width and glyphs stored are the ones drawn.
    fn appendLine(self: *Builder, start: usize, end: usize) LayoutError!void {
        var run = try self.shaper.shape(self.allocator, self.text[start..end], self.options);
        defer run.deinit();
        const glyph_start = self.glyphs.items.len;
        for (run.glyphs) |glyph| {
            var rebased = glyph;
            // The shaper numbers clusters from the start of the line. Store them against the source text instead.
            rebased.cluster += @intCast(start);
            try self.glyphs.append(self.allocator, rebased);
        }
        const remaining = @max(0, self.max_width - run.width);
        const offset = switch (self.alignment) {
            .left => 0,
            .center => remaining / 2,
            .right => remaining,
        };
        try self.lines.append(self.allocator, .{
            .text = self.text[start..end],
            .width = run.width,
            .x_offset = offset,
        });
        try self.ranges.append(self.allocator, .{ .start = glyph_start, .end = self.glyphs.items.len });
    }

    /// Fills `self.ends` with the offsets in (start, end] where a new grapheme begins. The last entry is `end`.
    fn collectGraphemeEnds(self: *Builder, start: usize, end: usize) LayoutError!void {
        self.ends.clearRetainingCapacity();
        var run = try self.shaper.shape(self.allocator, self.text[start..end], self.options);
        defer run.deinit();
        var previous: u32 = 0;
        for (run.glyphs) |glyph| {
            if (glyph.cluster > previous) {
                try self.ends.append(self.allocator, start + glyph.cluster);
                previous = glyph.cluster;
            }
        }
        try self.ends.append(self.allocator, end);
    }

    /// Splits text[start..end], a word wider than the line, into pieces that each fit, or hold one grapheme when a single
    /// grapheme is wider than the line. Each piece is cut only where `self.ends` says a grapheme begins.
    fn appendLongWord(self: *Builder, start: usize, end: usize) LayoutError!void {
        try self.collectGraphemeEnds(start, end);
        var chunk_start = start;
        while (chunk_start < end) {
            var fitting_end = chunk_start;
            for (self.ends.items) |boundary| {
                if (boundary <= chunk_start) continue;
                if (try self.measure(chunk_start, boundary) > self.max_width) break;
                fitting_end = boundary;
            }
            if (fitting_end == chunk_start) fitting_end = self.nextBoundary(chunk_start);
            try self.appendLine(chunk_start, fitting_end);
            chunk_start = fitting_end;
        }
    }

    /// The first grapheme end after `position`. The last entry is the word's end, so this always finds one.
    fn nextBoundary(self: *const Builder, position: usize) usize {
        for (self.ends.items) |boundary| {
            if (boundary > position) return boundary;
        }
        return self.ends.items[self.ends.items.len - 1];
    }

    /// Wraps one paragraph, text[start..end], which holds no newline.
    fn wrapParagraph(self: *Builder, start: usize, end: usize) LayoutError!void {
        var cursor = start;
        while (cursor < end and isBreakSpace(self.text[cursor])) : (cursor += 1) {}
        if (cursor == end) {
            try self.appendLine(end, end);
            return;
        }

        var line_start = cursor;
        var line_end = cursor;
        var active = false;
        while (cursor < end) {
            while (cursor < end and isBreakSpace(self.text[cursor])) : (cursor += 1) {}
            if (cursor == end) break;

            const word_start = cursor;
            while (cursor < end and !isBreakSpace(self.text[cursor])) : (cursor += 1) {}
            const word_end = cursor;
            const candidate_start = if (active) line_start else word_start;
            const candidate_width = try self.measure(candidate_start, word_end);

            if (candidate_width <= self.max_width) {
                if (!active) line_start = word_start;
                line_end = word_end;
                active = true;
                continue;
            }

            if (active) {
                try self.appendLine(line_start, line_end);
                active = false;
            }

            const word_width = try self.measure(word_start, word_end);
            if (word_width > self.max_width) {
                try self.appendLongWord(word_start, word_end);
            } else {
                line_start = word_start;
                line_end = word_end;
                active = true;
            }
        }

        if (active) try self.appendLine(line_start, line_end);
    }
};

/// Wraps and aligns `text` for a shaper. `options` sets the script and language of every line; the same text shapes the
/// same way every time. Line slices in the result borrow `text`. Release the result with `Layout.deinit`.
pub fn layout(
    allocator: std.mem.Allocator,
    sh: *shaper.Shaper,
    text: []const u8,
    max_width: f32,
    line_height: f32,
    alignment: Alignment,
    options: shaper.Options,
) LayoutError!Layout {
    if (!std.math.isFinite(max_width) or max_width <= 0) return error.InvalidWidth;
    if (!std.math.isFinite(line_height) or line_height <= 0) return error.InvalidLineHeight;

    var builder = Builder{
        .allocator = allocator,
        .shaper = sh,
        .options = options,
        .text = text,
        .max_width = max_width,
        .alignment = alignment,
    };
    defer builder.deinit();

    var paragraph_start: usize = 0;
    while (true) {
        const paragraph_end = findParagraphEnd(text, paragraph_start);
        try builder.wrapParagraph(paragraph_start, paragraph_end);
        if (paragraph_end == text.len) break;
        const newline_len: usize = if (text[paragraph_end] == '\r' and
            paragraph_end + 1 < text.len and text[paragraph_end + 1] == '\n') 2 else 1;
        paragraph_start = paragraph_end + newline_len;
    }

    const lines = try builder.lines.toOwnedSlice(allocator);
    errdefer allocator.free(lines);
    const glyphs = try builder.glyphs.toOwnedSlice(allocator);
    errdefer allocator.free(glyphs);
    const ranges = try builder.ranges.toOwnedSlice(allocator);
    errdefer allocator.free(ranges);
    const shaped_data = try allocator.create(ShapedData);
    shaped_data.* = .{
        .allocator = allocator,
        .glyphs = glyphs,
        .ranges = ranges,
        .font_id = builder.shaper.font_id,
    };
    var widest: f32 = 0;
    for (lines) |line| widest = @max(widest, line.width);
    return .{
        .allocator = allocator,
        .lines = lines,
        .shaped_data = shaped_data,
        .shaped_data_deinit = &destroyShapedData,
        .width = widest,
        .height = @as(f32, @floatFromInt(lines.len)) * line_height,
        .line_height = line_height,
    };
}

fn findParagraphEnd(text: []const u8, start: usize) usize {
    for (text[start..], start..) |byte, index| {
        if (byte == '\n' or byte == '\r') return index;
    }
    return text.len;
}

fn isBreakSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const runtime_font = @import("runtime_font.zig");

const font_path: [:0]const u8 = "assets/font.ttf";
const test_line_height: f32 = 20;

fn readFixture(allocator: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    const hb = runtime_font.hb;
    const blob = hb.hb_blob_create_from_file_or_fail(path.ptr) orelse return error.FixtureMissing;
    defer hb.hb_blob_destroy(blob);
    var len: c_uint = 0;
    const data = hb.hb_blob_get_data(blob, &len);
    if (data == null or len == 0) return error.FixtureMissing;
    const ptr: [*]const u8 = @ptrCast(data);
    return allocator.dupe(u8, ptr[0..@as(usize, len)]);
}

/// The byte offset of `slice` inside `text`. Line slices always borrow the text they were laid out from.
fn offsetIn(text: []const u8, slice: []const u8) usize {
    return @intFromPtr(slice.ptr) - @intFromPtr(text.ptr);
}

test "wraps at spaces by the line's own shaped width, and drops the break spaces" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var sh = try shaper.Shaper.init(&font);
    defer sh.deinit();

    const text = "AV AV AV";
    const one = try sh.measure("AV", .{});
    const two = try sh.measure("AV AV", .{});
    // One "AV" fits, and two do not.
    var result = try layout(testing.allocator, &sh, text, (one + two) / 2, test_line_height, .left, .{});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 3), result.lines.len);
    for (result.lines) |line| {
        try testing.expectEqualStrings("AV", line.text);
        try testing.expectEqual(one, line.width);
        try testing.expectEqual(@as(f32, 0), line.x_offset);
    }
    try testing.expectEqual(one, result.width);
    try testing.expectEqual(3 * test_line_height, result.height);
}

test "explicit newlines, CRLF, and blank lines keep their own lines" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var sh = try shaper.Shaper.init(&font);
    defer sh.deinit();

    var result = try layout(testing.allocator, &sh, "ab\r\n\nxy", 1000, test_line_height, .left, .{});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 3), result.lines.len);
    try testing.expectEqualStrings("ab", result.lines[0].text);
    try testing.expectEqualStrings("", result.lines[1].text);
    try testing.expectEqualStrings("xy", result.lines[2].text);
    try testing.expectEqual(@as(f32, 0), result.lines[1].width);
    try testing.expectEqual(3 * test_line_height, result.height);
}

test "a line of only spaces is one blank line, and leading spaces are not drawn" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var sh = try shaper.Shaper.init(&font);
    defer sh.deinit();

    var blank = try layout(testing.allocator, &sh, "   ", 1000, test_line_height, .left, .{});
    defer blank.deinit();
    try testing.expectEqual(@as(usize, 1), blank.lines.len);
    try testing.expectEqualStrings("", blank.lines[0].text);

    var indented = try layout(testing.allocator, &sh, "  A", 1000, test_line_height, .left, .{});
    defer indented.deinit();
    try testing.expectEqualStrings("A", indented.lines[0].text);
}

test "a word wider than the line splits into pieces that each fit" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var sh = try shaper.Shaper.init(&font);
    defer sh.deinit();

    const text = "AAAAAAAA";
    const three = try sh.measure("AAA", .{});
    var result = try layout(testing.allocator, &sh, text, three, test_line_height, .left, .{});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 3), result.lines.len);
    try testing.expectEqualStrings("AAA", result.lines[0].text);
    try testing.expectEqualStrings("AAA", result.lines[1].text);
    try testing.expectEqualStrings("AA", result.lines[2].text);
    for (result.lines) |line| try testing.expect(line.width <= three);
}

test "a word is split only at grapheme starts, never inside one" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var sh = try shaper.Shaper.init(&font);
    defer sh.deinit();

    // Each grapheme is "e" plus U+0301, three bytes. The line fits exactly one grapheme and no second one.
    const text = "e\u{301}e\u{301}e\u{301}e\u{301}";
    const one = try sh.measure("e\u{301}", .{});
    var result = try layout(testing.allocator, &sh, text, one, test_line_height, .left, .{});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 4), result.lines.len);
    for (result.lines, 0..) |line, k| {
        try testing.expectEqualStrings("e\u{301}", line.text);
        // Every glyph of the line belongs to the one grapheme, so its cluster is that grapheme's start offset.
        for (glyphsOf(&result, k)) |glyph| {
            try testing.expectEqual(@as(u32, @intCast(3 * k)), glyph.cluster);
        }
    }
}

test "widths match the glyphs drawn: each line's width is the sum of its glyph advances" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var sh = try shaper.Shaper.init(&font);
    defer sh.deinit();

    var result = try layout(testing.allocator, &sh, "the quick brown fox jumps over", 70, test_line_height, .left, .{});
    defer result.deinit();
    try testing.expect(result.lines.len > 1);
    for (result.lines, 0..) |line, index| {
        var sum: f32 = 0;
        for (glyphsOf(&result, index)) |glyph| sum += glyph.x_advance;
        try testing.expectApproxEqAbs(line.width, sum, 1e-4);
    }
}

test "wrapping is greedy: each line is as full as the next word allows" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var sh = try shaper.Shaper.init(&font);
    defer sh.deinit();

    const text = "one two three four five six seven eight";
    const max_width: f32 = 80;
    var result = try layout(testing.allocator, &sh, text, max_width, test_line_height, .left, .{});
    defer result.deinit();
    try testing.expect(result.lines.len > 2);
    for (result.lines[0 .. result.lines.len - 1], 0..) |line, i| {
        try testing.expect(line.width <= max_width);
        // The next line begins with a word. Adding that word to this line must overflow it.
        const next = result.lines[i + 1];
        const line_start = offsetIn(text, line.text);
        const next_start = offsetIn(text, next.text);
        var word_end = next_start;
        while (word_end < text.len and text[word_end] != ' ') : (word_end += 1) {}
        const extended = try sh.measure(text[line_start..word_end], .{});
        try testing.expect(extended > max_width);
    }
}

test "center and right alignment place the line by its shaped width" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var sh = try shaper.Shaper.init(&font);
    defer sh.deinit();

    const width = try sh.measure("AV", .{});
    var centered = try layout(testing.allocator, &sh, "AV", 100, test_line_height, .center, .{});
    defer centered.deinit();
    try testing.expectApproxEqAbs((100 - width) / 2, centered.lines[0].x_offset, 1e-4);

    var right = try layout(testing.allocator, &sh, "AV", 100, test_line_height, .right, .{});
    defer right.deinit();
    try testing.expectApproxEqAbs(100 - width, right.lines[0].x_offset, 1e-4);
}

test "known limit: a combining mark right after a space starts the next line, detached from that space" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var sh = try shaper.Shaper.init(&font);
    defer sh.deinit();

    // "A", a space, then U+0301 and "B". The space and the mark form one grapheme, and the wrap breaks at the space
    // byte, so the mark begins the second line. This test pins the documented limit; it does not endorse it.
    const text = "A \u{301}B";
    const a = try sh.measure("A", .{});
    const after = try sh.measure("\u{301}B", .{});
    var result = try layout(testing.allocator, &sh, text, a + after, test_line_height, .left, .{});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.lines.len);
    try testing.expectEqualStrings("A", result.lines[0].text);
    try testing.expectEqualStrings("\u{301}B", result.lines[1].text);
}

test "malformed UTF-8 and unmapped characters keep every glyph, with clusters on the source bytes" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var sh = try shaper.Shaper.init(&font);
    defer sh.deinit();

    // A (byte 0), a bad byte (1), U+4E00 in three bytes (2 to 4), B (5).
    var result = try layout(testing.allocator, &sh, "A\xff\u{4e00}B", 1000, test_line_height, .left, .{});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.lines.len);
    const glyphs = glyphsOf(&result, 0);
    try testing.expectEqual(@as(usize, 4), glyphs.len);
    try testing.expectEqual(@as(u32, 0), glyphs[0].cluster);
    try testing.expectEqual(@as(u32, 1), glyphs[1].cluster);
    try testing.expectEqual(@as(u32, 2), glyphs[2].cluster);
    try testing.expectEqual(@as(u32, 5), glyphs[3].cluster);
}

test "empty text is one empty line, and a non-positive width or height is refused" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var sh = try shaper.Shaper.init(&font);
    defer sh.deinit();

    var result = try layout(testing.allocator, &sh, "", 10, test_line_height, .left, .{});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.lines.len);
    try testing.expectEqual(@as(f32, 0), result.width);
    try testing.expectEqual(@as(usize, 0), glyphsOf(&result, 0).len);

    try testing.expectError(error.InvalidWidth, layout(testing.allocator, &sh, "text", 0, test_line_height, .left, .{}));
    try testing.expectError(error.InvalidWidth, layout(testing.allocator, &sh, "text", std.math.nan(f32), test_line_height, .left, .{}));
    try testing.expectError(error.InvalidLineHeight, layout(testing.allocator, &sh, "text", 10, 0, .left, .{}));
}

test "a layout can be built and released many times without leaking" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var sh = try shaper.Shaper.init(&font);
    defer sh.deinit();

    // testing.allocator fails the test if a layout, a glyph array, or a long-word scratch list is left behind.
    var round: usize = 0;
    while (round < 50) : (round += 1) {
        var result = try layout(testing.allocator, &sh, "wrap this text and split AAAAAAAAAAAA too", 40, test_line_height, .center, .{});
        defer result.deinit();
        try testing.expect(result.lines.len > 1);
    }
}
