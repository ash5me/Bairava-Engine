//! BMFont text descriptor import: the first step of the hand-authored bitmap font path (plan Phase 2, D-08).
//!
//! An AngelCode BMFont text descriptor (`.fnt`) names an atlas image, gives each glyph a rectangle in that image, and may
//! give kerning pairs. This file parses one into Bairava-owned structures (`Font`, `Glyph`, `Kerning`, `Page`) and
//! validates it. BMFont's own names stay in this file. Nothing here reads an image, uploads a texture, or draws: those
//! steps belong to the bitmap provider, which is not written yet.
//!
//! Accepted tags are `info`, `common`, `page`, `chars`, `char`, `kernings`, and `kerning`. Any other tag is rejected, so
//! a feature this importer does not handle cannot pass silently. A descriptor needs `info`, `common`, at least one
//! `page`, and `chars`. Values may be quoted: the quotes are removed and spaces inside them are kept. Line order does
//! not matter, because every check runs after the whole file is read.
//!
//! Checks, each with its own error:
//! - page ids are unique and run from 0 to `pages - 1`, and the page count matches `common pages=`;
//! - the `chars` and `kernings` counts match the lines that follow;
//! - each codepoint is a Unicode scalar value, and no codepoint appears twice;
//! - each glyph names an existing page and lies inside the atlas (`scaleW` by `scaleH`);
//! - metrics are in range: line height and base are positive, base is at most the line height, and advances are not
//!   negative (unsigned by parse);
//! - each kerning pair is unique and names two mapped glyphs. A pair that names an unmapped glyph is an error that
//!   reports the pair, its line, and the missing BMFont id, and is never dropped silently (D-28);
//! - the fallback codepoint (default `?`, D-09) has a glyph.
//!
//! A zero-width or zero-height glyph is valid. A space has no ink, but it keeps its advance.

const std = @import("std");

/// The highest Unicode scalar value.
pub const max_codepoint: u32 = 0x10FFFF;
/// The fallback codepoint when the caller names none. D-09 uses '?'.
pub const default_fallback: u32 = '?';
/// BMFont's channel mask for a glyph drawn from all four channels. No glyph may name a larger mask.
const max_channel: u32 = 15;
/// Most key=value fields one line may carry. BMFont's longest line, `char`, has ten.
const max_fields = 32;

pub const Error = error{
    MalformedLine,
    UnknownTag,
    DuplicateSection,
    MissingSection,
    MissingKey,
    BadValue,
    CountMismatch,
    DuplicatePage,
    PageOutOfRange,
    GlyphOutsideAtlas,
    InvalidCodepoint,
    DuplicateCodepoint,
    DuplicateKerning,
    UnmappedKerning,
    MissingFallback,
};

pub const ParseError = std.mem.Allocator.Error || Error;

/// Where a parse failed. `line` is 1-based when one line failed. It is 0 when the failure is found after the whole
/// file is read.
pub const Diagnostic = struct {
    /// 1-based line of the failure. 0 when the failure is not tied to one line.
    line: usize = 0,
    /// For DuplicateKerning and UnmappedKerning: the pair as the file names it.
    kerning_first: u32 = 0,
    kerning_second: u32 = 0,
    /// For UnmappedKerning: the BMFont `id` the font lacks. BMFont's `id` is the codepoint. Bairava has no separate
    /// glyph index yet (plan Phase 2, item 2).
    unmapped_id: u32 = 0,
};

/// The version of the normalized `Font` layout this file produces (D-27). The importer writes it, and a reader of a
/// `Font` checks it. Changing a field means a new version, not an edit in place.
pub const schema_version: u32 = 1;

pub const Options = struct {
    /// The codepoint that must have a glyph. It is drawn for any character the font does not map.
    fallback: u32 = default_fallback,
};

/// One atlas image, named by the descriptor. `file` is owned by the `Font`.
pub const Page = struct {
    id: u32,
    file: []u8,
};

/// One glyph: its rectangle in a page, the offset from the pen, and how far the pen moves after it.
pub const Glyph = struct {
    codepoint: u32,
    /// Top-left corner and size of the glyph's rectangle in its page, in texels.
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    /// Offset of the glyph's top-left corner from the pen, in pixels, y down.
    x_offset: i32,
    y_offset: i32,
    /// How far the pen moves after the glyph, in pixels.
    x_advance: u32,
    page: u32,
    /// The BMFont channel mask: which channels of the page hold the glyph's coverage.
    channel: u32,
};

/// A kerning adjustment, in pixels, added before `second` when it follows `first`.
pub const Kerning = struct {
    first: u32,
    second: u32,
    amount: i32,
};

/// A kerning pair as the file gave it, with the line it came from. The copy the `Font` keeps has no line.
const PendingKerning = struct {
    pair: Kerning,
    line: usize,
};

/// A validated descriptor, owned by its allocator. Call `deinit` to release it.
pub const Font = struct {
    allocator: std.mem.Allocator,
    /// The layout version. Always `schema_version` for a font this file produced.
    schema_version: u32,
    /// The font size from `info size=`.
    size: i32,
    line_height: u32,
    /// Distance from the top of a line to its baseline.
    base: u32,
    scale_w: u32,
    scale_h: u32,
    /// Padding around each glyph in texels, in BMFont's order: up, right, down, left.
    padding: [4]u32,
    /// Sorted by id, and the ids are 0 to pages - 1.
    pages: []Page,
    /// Sorted by codepoint, so lookups can binary search.
    glyphs: []Glyph,
    /// Sorted by (first, second).
    kernings: []Kerning,
    fallback: u32,

    pub fn deinit(self: *Font) void {
        for (self.pages) |page| self.allocator.free(page.file);
        self.allocator.free(self.pages);
        self.allocator.free(self.glyphs);
        self.allocator.free(self.kernings);
        self.* = undefined;
    }

    /// The glyph for `codepoint`, or null when the font has none. The result points into the font.
    pub fn glyphFor(self: *const Font, codepoint: u32) ?*const Glyph {
        const index = glyphIndex(self.glyphs, codepoint) orelse return null;
        return &self.glyphs[index];
    }

    /// The kerning added before `second` when it follows `first`, in pixels. Zero when the pair has none.
    pub fn kerningFor(self: *const Font, first: u32, second: u32) i32 {
        var lo: usize = 0;
        var hi: usize = self.kernings.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const pair = self.kernings[mid];
            if (pair.first == first and pair.second == second) return pair.amount;
            if (pairLess(pair.first, pair.second, first, second)) lo = mid + 1 else hi = mid;
        }
        return 0;
    }
};

/// Parses and validates a BMFont text descriptor. The returned `Font` owns its copies, so `text` may be freed once this
/// returns. On a failure on one line, `diagnostic` (if given) names that line.
pub fn parse(allocator: std.mem.Allocator, text: []const u8, options: Options, diagnostic: ?*Diagnostic) ParseError!Font {
    var builder = Builder{ .allocator = allocator };
    defer builder.deinit();
    var line_number: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        line_number += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        builder.addLine(line, line_number) catch |err| {
            if (diagnostic) |d| d.line = line_number;
            return err;
        };
    }
    return builder.finish(options.fallback, diagnostic);
}

// ---- lines and fields ------------------------------------------------------------------------------------------------

/// One `key=value` pair. Both slices point into the parsed text. A quoted value has its quotes removed.
const Field = struct {
    key: []const u8,
    value: []const u8,
};

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// Splits the fields that follow a tag. A key may not contain a space. A quoted value runs to its closing quote, and an
/// unquoted value runs to the next space or tab.
fn splitFields(rest: []const u8, buffer: []Field) ParseError![]Field {
    var count: usize = 0;
    var i: usize = 0;
    while (true) {
        while (i < rest.len and isBlank(rest[i])) i += 1;
        if (i == rest.len) break;
        const equals = std.mem.indexOfScalar(u8, rest[i..], '=') orelse return error.MalformedLine;
        const key = rest[i .. i + equals];
        if (key.len == 0 or std.mem.indexOfAny(u8, key, " \t") != null) return error.MalformedLine;
        i += equals + 1;
        var value: []const u8 = undefined;
        if (i < rest.len and rest[i] == '"') {
            const close = std.mem.indexOfScalarPos(u8, rest, i + 1, '"') orelse return error.MalformedLine;
            value = rest[i + 1 .. close];
            i = close + 1;
        } else {
            const end = std.mem.indexOfAnyPos(u8, rest, i, " \t") orelse rest.len;
            value = rest[i..end];
            i = end;
        }
        if (count == buffer.len) return error.MalformedLine;
        buffer[count] = .{ .key = key, .value = value };
        count += 1;
    }
    return buffer[0..count];
}

fn find(fields: []const Field, key: []const u8) ?[]const u8 {
    for (fields) |field| {
        if (std.mem.eql(u8, field.key, key)) return field.value;
    }
    return null;
}

fn required(fields: []const Field, key: []const u8) ParseError![]const u8 {
    return find(fields, key) orelse error.MissingKey;
}

fn parseInt(value: []const u8) ParseError!i32 {
    return std.fmt.parseInt(i32, value, 10) catch return error.BadValue;
}

fn parseU32(value: []const u8) ParseError!u32 {
    const number = try parseInt(value);
    if (number < 0) return error.BadValue;
    return @intCast(number);
}

fn parseList4(value: []const u8) ParseError![4]u32 {
    var result: [4]u32 = undefined;
    var parts = std.mem.splitScalar(u8, value, ',');
    for (&result) |*slot| {
        const part = parts.next() orelse return error.BadValue;
        slot.* = try parseU32(part);
    }
    if (parts.next() != null) return error.BadValue;
    return result;
}

// ---- sorting and lookup ----------------------------------------------------------------------------------------------

fn isCodepoint(value: u32) bool {
    return value <= max_codepoint and !(value >= 0xD800 and value <= 0xDFFF);
}

fn pairLess(a_first: u32, a_second: u32, b_first: u32, b_second: u32) bool {
    return a_first < b_first or (a_first == b_first and a_second < b_second);
}

fn glyphLess(_: void, a: Glyph, b: Glyph) bool {
    return a.codepoint < b.codepoint;
}

fn pendingLess(_: void, a: PendingKerning, b: PendingKerning) bool {
    if (a.pair.first != b.pair.first) return a.pair.first < b.pair.first;
    if (a.pair.second != b.pair.second) return a.pair.second < b.pair.second;
    return a.line < b.line;
}

/// The codepoint of `pair` that has no glyph, or null when both have one. `first` is checked before `second`.
fn unmappedOf(glyphs: []const Glyph, pair: Kerning) ?u32 {
    if (glyphIndex(glyphs, pair.first) == null) return pair.first;
    if (glyphIndex(glyphs, pair.second) == null) return pair.second;
    return null;
}

fn reportKerning(diagnostic: ?*Diagnostic, item: PendingKerning) void {
    if (diagnostic) |d| {
        d.line = item.line;
        d.kerning_first = item.pair.first;
        d.kerning_second = item.pair.second;
    }
}

fn pageLess(_: void, a: Page, b: Page) bool {
    return a.id < b.id;
}

/// The index of `codepoint` in `glyphs`, which must be sorted by codepoint.
fn glyphIndex(glyphs: []const Glyph, codepoint: u32) ?usize {
    var lo: usize = 0;
    var hi: usize = glyphs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (glyphs[mid].codepoint < codepoint) lo = mid + 1 else hi = mid;
    }
    if (lo < glyphs.len and glyphs[lo].codepoint == codepoint) return lo;
    return null;
}

// ---- the builder: collects lines, then validates and copies --------------------------------------------------------

const Builder = struct {
    allocator: std.mem.Allocator,
    size: ?i32 = null,
    padding: [4]u32 = .{ 0, 0, 0, 0 },
    line_height: ?u32 = null,
    base: u32 = 0,
    scale_w: u32 = 0,
    scale_h: u32 = 0,
    pages_declared: ?u32 = null,
    chars_declared: ?u32 = null,
    kernings_declared: ?u32 = null,
    /// The lines as they arrive. `finish` checks and copies them, and `deinit` frees them.
    pages: std.ArrayList(Page) = .empty,
    glyphs: std.ArrayList(Glyph) = .empty,
    kernings: std.ArrayList(PendingKerning) = .empty,

    fn deinit(self: *Builder) void {
        for (self.pages.items) |page_entry| self.allocator.free(page_entry.file);
        self.pages.deinit(self.allocator);
        self.glyphs.deinit(self.allocator);
        self.kernings.deinit(self.allocator);
    }

    fn addLine(self: *Builder, line: []const u8, line_number: usize) ParseError!void {
        const tag_end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
        const tag = line[0..tag_end];
        var buffer: [max_fields]Field = undefined;
        const fields = try splitFields(line[tag_end..], &buffer);

        if (std.mem.eql(u8, tag, "info")) return self.info(fields);
        if (std.mem.eql(u8, tag, "common")) return self.common(fields);
        if (std.mem.eql(u8, tag, "page")) return self.page(fields);
        if (std.mem.eql(u8, tag, "chars")) return self.charsCount(fields);
        if (std.mem.eql(u8, tag, "char")) return self.char(fields);
        if (std.mem.eql(u8, tag, "kernings")) return self.kerningsCount(fields);
        if (std.mem.eql(u8, tag, "kerning")) return self.kerning(fields, line_number);
        return error.UnknownTag;
    }

    fn info(self: *Builder, fields: []const Field) ParseError!void {
        if (self.size != null) return error.DuplicateSection;
        self.size = try parseInt(try required(fields, "size"));
        if (find(fields, "padding")) |value| self.padding = try parseList4(value);
    }

    fn common(self: *Builder, fields: []const Field) ParseError!void {
        if (self.line_height != null) return error.DuplicateSection;
        const line_height = try parseU32(try required(fields, "lineHeight"));
        const base = try parseU32(try required(fields, "base"));
        const scale_w = try parseU32(try required(fields, "scaleW"));
        const scale_h = try parseU32(try required(fields, "scaleH"));
        const pages = try parseU32(try required(fields, "pages"));
        if (line_height == 0 or base > line_height or scale_w == 0 or scale_h == 0 or pages == 0) return error.BadValue;
        self.line_height = line_height;
        self.base = base;
        self.scale_w = scale_w;
        self.scale_h = scale_h;
        self.pages_declared = pages;
    }

    fn page(self: *Builder, fields: []const Field) ParseError!void {
        const id = try parseU32(try required(fields, "id"));
        const file = try required(fields, "file");
        if (file.len == 0) return error.BadValue;
        const copy = try self.allocator.dupe(u8, file);
        errdefer self.allocator.free(copy);
        try self.pages.append(self.allocator, .{ .id = id, .file = copy });
    }

    fn charsCount(self: *Builder, fields: []const Field) ParseError!void {
        if (self.chars_declared != null) return error.DuplicateSection;
        self.chars_declared = try parseU32(try required(fields, "count"));
    }

    fn char(self: *Builder, fields: []const Field) ParseError!void {
        const id = try parseInt(try required(fields, "id"));
        // A negative id is not a codepoint. A large or surrogate id is refused in `finish`, with the other checks.
        if (id < 0) return error.InvalidCodepoint;
        const channel: u32 = if (find(fields, "chnl")) |value| try parseU32(value) else max_channel;
        if (channel > max_channel) return error.BadValue;
        const glyph = Glyph{
            .codepoint = @intCast(id),
            .x = try parseU32(try required(fields, "x")),
            .y = try parseU32(try required(fields, "y")),
            .width = try parseU32(try required(fields, "width")),
            .height = try parseU32(try required(fields, "height")),
            .x_offset = try parseInt(try required(fields, "xoffset")),
            .y_offset = try parseInt(try required(fields, "yoffset")),
            .x_advance = try parseU32(try required(fields, "xadvance")),
            .page = try parseU32(try required(fields, "page")),
            .channel = channel,
        };
        try self.glyphs.append(self.allocator, glyph);
    }

    fn kerningsCount(self: *Builder, fields: []const Field) ParseError!void {
        if (self.kernings_declared != null) return error.DuplicateSection;
        self.kernings_declared = try parseU32(try required(fields, "count"));
    }

    fn kerning(self: *Builder, fields: []const Field, line_number: usize) ParseError!void {
        const first = try parseInt(try required(fields, "first"));
        const second = try parseInt(try required(fields, "second"));
        if (first < 0 or second < 0) return error.InvalidCodepoint;
        const pair = Kerning{
            .first = @intCast(first),
            .second = @intCast(second),
            .amount = try parseInt(try required(fields, "amount")),
        };
        try self.kernings.append(self.allocator, .{ .pair = pair, .line = line_number });
    }

    /// Checks everything the file implies, then copies the lines into the `Font`. The copies are sorted, so the font
    /// can binary search. On an error, nothing is returned, and the builder still owns its lines for `deinit`.
    fn finish(self: *Builder, fallback: u32, diagnostic: ?*Diagnostic) ParseError!Font {
        const line_height = self.line_height orelse return error.MissingSection;
        const size = self.size orelse return error.MissingSection;
        const pages_declared = self.pages_declared orelse return error.MissingSection;
        const chars_declared = self.chars_declared orelse return error.MissingSection;
        if (self.pages.items.len == 0) return error.MissingSection;

        const page_count: u32 = @intCast(self.pages.items.len);
        const glyph_count: u32 = @intCast(self.glyphs.items.len);
        const kerning_count: u32 = @intCast(self.kernings.items.len);
        if (page_count != pages_declared) return error.CountMismatch;
        if (glyph_count != chars_declared) return error.CountMismatch;
        if (self.kernings_declared) |declared| {
            if (kerning_count != declared) return error.CountMismatch;
        }

        for (self.pages.items, 0..) |page_entry, index| {
            if (page_entry.id >= page_count) return error.PageOutOfRange;
            for (self.pages.items[0..index]) |earlier| {
                if (earlier.id == page_entry.id) return error.DuplicatePage;
            }
        }
        for (self.glyphs.items) |glyph| {
            if (!isCodepoint(glyph.codepoint)) return error.InvalidCodepoint;
            if (glyph.page >= page_count) return error.PageOutOfRange;
            if (@as(u64, glyph.x) + glyph.width > @as(u64, self.scale_w)) return error.GlyphOutsideAtlas;
            if (@as(u64, glyph.y) + glyph.height > @as(u64, self.scale_h)) return error.GlyphOutsideAtlas;
        }
        for (self.kernings.items) |item| {
            if (!isCodepoint(item.pair.first) or !isCodepoint(item.pair.second)) return error.InvalidCodepoint;
        }

        const glyphs = try self.allocator.dupe(Glyph, self.glyphs.items);
        errdefer self.allocator.free(glyphs);
        std.mem.sort(Glyph, glyphs, {}, glyphLess);
        var g: usize = 1;
        while (g < glyphs.len) : (g += 1) {
            if (glyphs[g].codepoint == glyphs[g - 1].codepoint) return error.DuplicateCodepoint;
        }
        if (glyphIndex(glyphs, fallback) == null) return error.MissingFallback;

        // Unmapped pairs are checked in file order, so the first bad pair in the file is the one named.
        for (self.kernings.items) |item| {
            if (unmappedOf(glyphs, item.pair)) |missing| {
                reportKerning(diagnostic, item);
                if (diagnostic) |d| d.unmapped_id = missing;
                return error.UnmappedKerning;
            }
        }
        // A repeated pair is found after sorting. Equal pairs sort by line, so the later line is the one named.
        const pending = try self.allocator.dupe(PendingKerning, self.kernings.items);
        defer self.allocator.free(pending);
        std.mem.sort(PendingKerning, pending, {}, pendingLess);
        var k: usize = 1;
        while (k < pending.len) : (k += 1) {
            const earlier = pending[k - 1].pair;
            const later = pending[k].pair;
            if (earlier.first == later.first and earlier.second == later.second) {
                reportKerning(diagnostic, pending[k]);
                return error.DuplicateKerning;
            }
        }
        const kernings = try self.allocator.alloc(Kerning, pending.len);
        errdefer self.allocator.free(kernings);
        for (pending, 0..) |item, index| kernings[index] = item.pair;

        const pages = try self.allocator.alloc(Page, self.pages.items.len);
        var copied: usize = 0;
        errdefer {
            for (pages[0..copied]) |page_entry| self.allocator.free(page_entry.file);
            self.allocator.free(pages);
        }
        for (self.pages.items, 0..) |source, index| {
            pages[index] = .{ .id = source.id, .file = try self.allocator.dupe(u8, source.file) };
            copied = index + 1;
        }
        std.mem.sort(Page, pages, {}, pageLess);

        return .{
            .allocator = self.allocator,
            .schema_version = schema_version,
            .size = size,
            .line_height = line_height,
            .base = self.base,
            .scale_w = self.scale_w,
            .scale_h = self.scale_h,
            .padding = self.padding,
            .pages = pages,
            .glyphs = glyphs,
            .kernings = kernings,
            .fallback = fallback,
        };
    }
};

// ---- tests -----------------------------------------------------------------------------------------------------------

const testing = std.testing;

const info_line = "info face=\"Test Face\" size=8 bold=0 italic=0 charset=\"\" unicode=1 stretchH=100 smooth=0 aa=1 padding=0,0,0,0 spacing=1,1 outline=0\n";
const common_line = "common lineHeight=8 base=7 scaleW=128 scaleH=48 pages=1 packed=0 alphaChnl=1 redChnl=0 greenChnl=0 blueChnl=0\n";
const page_line = "page id=0 file=\"ui font 8px.png\"\n";
const space_line = "char id=32 x=0 y=0 width=0 height=0 xoffset=0 yoffset=0 xadvance=8 page=0 chnl=15\n";
const question_line = "char id=63 x=8 y=0 width=8 height=8 xoffset=0 yoffset=0 xadvance=8 page=0 chnl=15\n";
const a_line = "char id=65 x=16 y=0 width=8 height=8 xoffset=0 yoffset=0 xadvance=8 page=0 chnl=15\n";
const chars_block = "chars count=3\n" ++ space_line ++ question_line ++ a_line;
const kerning_block = "kernings count=1\nkerning first=65 second=65 amount=-1\n";
/// A complete, valid descriptor: nine lines, with the kerning pair A-A.
const good = info_line ++ common_line ++ page_line ++ chars_block ++ kerning_block;

fn expectRejected(text: []const u8, expected: ParseError) !void {
    try testing.expectError(expected, parse(testing.allocator, text, .{}, null));
}

test "a descriptor parses into Bairava-owned fields, pages, glyphs, and kerning" {
    var font = try parse(testing.allocator, good, .{}, null);
    defer font.deinit();
    try testing.expectEqual(@as(i32, 8), font.size);
    try testing.expectEqual(@as(u32, 8), font.line_height);
    try testing.expectEqual(@as(u32, 7), font.base);
    try testing.expectEqual(@as(u32, 128), font.scale_w);
    try testing.expectEqual(@as(u32, 48), font.scale_h);
    try testing.expectEqual(@as(usize, 1), font.pages.len);
    try testing.expectEqualStrings("ui font 8px.png", font.pages[0].file);
    try testing.expectEqual(@as(usize, 3), font.glyphs.len);
    try testing.expectEqual(default_fallback, font.fallback);
}

test "glyphs are found by codepoint, and kerning by pair" {
    var font = try parse(testing.allocator, good, .{}, null);
    defer font.deinit();
    const a = font.glyphFor('A') orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 16), a.x);
    try testing.expectEqual(@as(u32, 8), a.width);
    // A space has no ink but keeps its advance.
    const space = font.glyphFor(' ') orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 0), space.width);
    try testing.expectEqual(@as(u32, 8), space.x_advance);
    try testing.expect(font.glyphFor('B') == null);
    try testing.expectEqual(@as(i32, -1), font.kerningFor('A', 'A'));
    try testing.expectEqual(@as(i32, 0), font.kerningFor('A', '?'));
}

test "line order does not change the result" {
    var font = try parse(testing.allocator, chars_block ++ kerning_block ++ info_line ++ common_line ++ page_line, .{}, null);
    defer font.deinit();
    try testing.expectEqual(@as(usize, 3), font.glyphs.len);
    try testing.expectEqual(@as(i32, -1), font.kerningFor('A', 'A'));
}

test "the normalized font carries schema version 1" {
    var font = try parse(testing.allocator, good, .{}, null);
    defer font.deinit();
    try testing.expectEqual(@as(u32, 1), schema_version);
    try testing.expectEqual(schema_version, font.schema_version);
}

test "a descriptor without a page is rejected" {
    try expectRejected(info_line ++ common_line ++ chars_block, error.MissingSection);
}

test "a descriptor without its info or common section is rejected" {
    try expectRejected(page_line ++ chars_block, error.MissingSection);
}

test "a glyph outside the atlas is rejected" {
    const outside = "char id=65 x=124 y=0 width=8 height=8 xoffset=0 yoffset=0 xadvance=8 page=0 chnl=15\n";
    try expectRejected(info_line ++ common_line ++ page_line ++ "chars count=3\n" ++ space_line ++ question_line ++ outside, error.GlyphOutsideAtlas);
}

test "a glyph on a page that does not exist is rejected" {
    const missing_page = "char id=65 x=16 y=0 width=8 height=8 xoffset=0 yoffset=0 xadvance=8 page=1 chnl=15\n";
    try expectRejected(info_line ++ common_line ++ page_line ++ "chars count=3\n" ++ space_line ++ question_line ++ missing_page, error.PageOutOfRange);
}

test "a duplicate codepoint is rejected" {
    try expectRejected(info_line ++ common_line ++ page_line ++ "chars count=3\n" ++ space_line ++ question_line ++ question_line, error.DuplicateCodepoint);
}

test "a count that disagrees with its lines is rejected" {
    try expectRejected(info_line ++ common_line ++ page_line ++ "chars count=4\n" ++ space_line ++ question_line ++ a_line, error.CountMismatch);
}

test "a missing fallback glyph is rejected" {
    try testing.expectError(error.MissingFallback, parse(testing.allocator, good, .{ .fallback = 'Z' }, null));
}

test "a kerning pair naming an unmapped glyph is rejected, and the diagnostic names the pair, its line, and the missing id" {
    // Line 9 is the kerning line: info, common, page, the chars count and its three chars, the kernings count, then the pair.
    const text = info_line ++ common_line ++ page_line ++ chars_block ++ "kernings count=1\nkerning first=65 second=66 amount=-1\n";
    var diagnostic: Diagnostic = .{};
    try testing.expectError(error.UnmappedKerning, parse(testing.allocator, text, .{}, &diagnostic));
    try testing.expectEqual(@as(usize, 9), diagnostic.line);
    try testing.expectEqual(@as(u32, 65), diagnostic.kerning_first);
    try testing.expectEqual(@as(u32, 66), diagnostic.kerning_second);
    try testing.expectEqual(@as(u32, 66), diagnostic.unmapped_id);
}

test "when both glyphs of a kerning pair are unmapped, the first is named" {
    const text = info_line ++ common_line ++ page_line ++ chars_block ++ "kernings count=1\nkerning first=66 second=67 amount=-1\n";
    var diagnostic: Diagnostic = .{};
    try testing.expectError(error.UnmappedKerning, parse(testing.allocator, text, .{}, &diagnostic));
    try testing.expectEqual(@as(u32, 66), diagnostic.unmapped_id);
}

test "a duplicate kerning pair is rejected, and the diagnostic names the later line" {
    // Lines 9 and 10 are the two copies of the pair.
    const pair = "kerning first=65 second=65 amount=-1\n";
    const text = info_line ++ common_line ++ page_line ++ chars_block ++ "kernings count=2\n" ++ pair ++ pair;
    var diagnostic: Diagnostic = .{};
    try testing.expectError(error.DuplicateKerning, parse(testing.allocator, text, .{}, &diagnostic));
    try testing.expectEqual(@as(usize, 10), diagnostic.line);
    try testing.expectEqual(@as(u32, 65), diagnostic.kerning_first);
}

test "an unknown tag is rejected, and the diagnostic names its line" {
    var diagnostic: Diagnostic = .{};
    try testing.expectError(error.UnknownTag, parse(testing.allocator, good ++ "bogus x=1\n", .{}, &diagnostic));
    try testing.expectEqual(@as(usize, 10), diagnostic.line);
}

test "a value that does not parse is rejected" {
    // The x value is empty, so it cannot be a number.
    const bad = "char id=65 x= y=0 width=8 height=8 xoffset=0 yoffset=0 xadvance=8 page=0\n";
    try expectRejected(info_line ++ common_line ++ page_line ++ "chars count=1\n" ++ bad, error.BadValue);
}

test "an unclosed quote is malformed" {
    try expectRejected(info_line ++ common_line ++ "page id=0 file=\"open.png\n", error.MalformedLine);
}

test "a base past the line height is rejected" {
    const tall_base = "common lineHeight=8 base=9 scaleW=128 scaleH=48 pages=1\n";
    try expectRejected(info_line ++ tall_base ++ page_line ++ chars_block, error.BadValue);
}

test "a codepoint outside Unicode, or a surrogate, is rejected" {
    const surrogate = "char id=55296 x=0 y=0 width=0 height=0 xoffset=0 yoffset=0 xadvance=0 page=0\n";
    try expectRejected(info_line ++ common_line ++ page_line ++ "chars count=1\n" ++ surrogate, error.InvalidCodepoint);
}
