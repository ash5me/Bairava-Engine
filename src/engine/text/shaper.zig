//! Shapes UTF-8 text for a runtime outline font: glyph IDs, clusters, advances, and offsets, from HarfBuzz.
//! Part of Phase 5 of the text and font system migration plan, on the shaping service of Phase 3. It runs on the face
//! that RuntimeFont owns and needs no GPU, atlas, or window, so every test here is CPU-only.
//!
//! What the shaper returns, and what it leaves to its callers:
//! - Glyph IDs are the font's own IDs. A character the font does not map shapes to glyph 0 (.notdef). That glyph is
//!   real, so the glyph cache draws it like any other rather than dropping it.
//! - A cluster is the byte offset, in the text given to `shape`, where a grapheme starts. Glyphs of one grapheme (a base
//!   character and its marks, for instance) share a cluster. Clusters never decrease, because the shaper runs left to
//!   right only.
//! - Advances and offsets are in pixels, in the convention of RuntimeFont metrics. Vertical values use y down.
//! - Script and language are the caller's to set. They are never guessed from the text, so the same text always shapes
//!   the same way. The defaults are Latn and en.
//! - Malformed UTF-8 is not an error. HarfBuzz replaces each invalid byte with U+FFFD and shapes it like any other
//!   character, so a bad byte costs one glyph and does not end the run.
//!
//! A Shaper borrows its RuntimeFont, which must outlive it. It owns one reusable HarfBuzz buffer, so it is not
//! thread-safe: use one per thread. HarfBuzz types do not leave this file.

const std = @import("std");
const runtime_font = @import("runtime_font.zig");
const hb = runtime_font.hb;

pub const Error = error{
    OutOfMemory,
    TextTooLong,
    InvalidScript,
    InvalidLanguage,
    /// A cluster pointed past the text, or went backwards. Left-to-right shaping never does this, so the error means
    /// the HarfBuzz build or the font is not what the pinned lock describes.
    InvalidCluster,
};

/// The script and language to shape with. Both are explicit: the shaper never guesses them from the text.
pub const Options = struct {
    /// ISO 15924 script tag, for example "Latn" or "Taml".
    script: []const u8 = "Latn",
    /// BCP 47 language tag, for example "en" or "ta".
    language: []const u8 = "en",
};

/// One shaped glyph. `glyph_id` is an index into the font's glyph table, never a Unicode codepoint.
pub const Glyph = struct {
    glyph_id: u32,
    /// Byte offset in the shaped text where this glyph's grapheme starts. Glyphs of one grapheme share it.
    cluster: u32,
    /// Pen advance in pixels. The pen moves this far after the glyph.
    x_advance: f32,
    /// Vertical pen advance in pixels, y down. Zero for horizontal text.
    y_advance: f32,
    /// Placement offset from the pen in pixels, x to the right.
    x_offset: f32,
    /// Placement offset from the baseline in pixels, y down.
    y_offset: f32,
};

/// The glyphs of one shaped string, in visual order (left to right). Free it with `deinit`.
pub const ShapedRun = struct {
    allocator: std.mem.Allocator,
    glyphs: []Glyph,
    /// Sum of every glyph's x_advance: the pen position after the last glyph.
    width: f32,

    pub fn deinit(self: *ShapedRun) void {
        self.allocator.free(self.glyphs);
        self.* = undefined;
    }
};

pub const Shaper = struct {
    font: *const runtime_font.RuntimeFont,
    buffer: *hb.hb_buffer_t,

    /// Creates a shaper for `font`. The font must outlive the shaper.
    pub fn init(font: *const runtime_font.RuntimeFont) Error!Shaper {
        const buffer = hb.hb_buffer_create() orelse return error.OutOfMemory;
        return .{ .font = font, .buffer = buffer };
    }

    pub fn deinit(self: *Shaper) void {
        hb.hb_buffer_destroy(self.buffer);
        self.* = undefined;
    }

    /// Shapes `text` and returns its glyphs. The caller frees the result with `ShapedRun.deinit`. An empty string shapes
    /// to no glyphs and zero width.
    pub fn shape(self: *Shaper, allocator: std.mem.Allocator, text: []const u8, options: Options) Error!ShapedRun {
        const count = try self.run(text, options);
        const glyphs = try allocator.alloc(Glyph, count);
        errdefer allocator.free(glyphs);
        const infos = hb.hb_buffer_get_glyph_infos(self.buffer, null);
        const positions = hb.hb_buffer_get_glyph_positions(self.buffer, null);
        var width: f32 = 0;
        var previous: u32 = 0;
        for (glyphs, 0..) |*out, i| {
            try checkCluster(infos[i].cluster, previous, text.len);
            previous = infos[i].cluster;
            out.* = toGlyph(infos[i], positions[i]);
            width += out.x_advance;
        }
        return .{ .allocator = allocator, .glyphs = glyphs, .width = width };
    }

    /// Shapes `text` and returns only its width. It runs the same shaping and the same summation as `shape`, so the
    /// result equals `shape(...).width` exactly, with no glyph array.
    pub fn measure(self: *Shaper, text: []const u8, options: Options) Error!f32 {
        const count = try self.run(text, options);
        const infos = hb.hb_buffer_get_glyph_infos(self.buffer, null);
        const positions = hb.hb_buffer_get_glyph_positions(self.buffer, null);
        var width: f32 = 0;
        var previous: u32 = 0;
        for (0..count) |i| {
            try checkCluster(infos[i].cluster, previous, text.len);
            previous = infos[i].cluster;
            width += toGlyph(infos[i], positions[i]).x_advance;
        }
        return width;
    }

    /// Validates the options, shapes `text` into the buffer, and returns the glyph count.
    fn run(self: *Shaper, text: []const u8, options: Options) Error!usize {
        if (text.len > std.math.maxInt(c_int)) return error.TextTooLong;
        const script = hb.hb_script_from_string(options.script.ptr, @intCast(options.script.len));
        if (script == hb.HB_SCRIPT_INVALID) return error.InvalidScript;
        if (options.language.len == 0) return error.InvalidLanguage;
        const language = hb.hb_language_from_string(options.language.ptr, @intCast(options.language.len));
        if (language == hb.HB_LANGUAGE_INVALID) return error.InvalidLanguage;

        hb.hb_buffer_clear_contents(self.buffer);
        hb.hb_buffer_set_direction(self.buffer, hb.HB_DIRECTION_LTR);
        hb.hb_buffer_set_script(self.buffer, script);
        hb.hb_buffer_set_language(self.buffer, language);
        hb.hb_buffer_set_cluster_level(self.buffer, hb.HB_BUFFER_CLUSTER_LEVEL_MONOTONE_GRAPHEMES);
        hb.hb_buffer_add_utf8(self.buffer, text.ptr, @intCast(text.len), 0, @intCast(text.len));
        hb.hb_shape(self.font.font, self.buffer, null, 0);
        return @intCast(hb.hb_buffer_get_length(self.buffer));
    }
};

/// Refuses a cluster that is outside the text or that goes backwards. `previous` is the cluster of the glyph before.
fn checkCluster(cluster: u32, previous: u32, text_len: usize) Error!void {
    if (cluster < previous) return error.InvalidCluster;
    if (cluster >= text_len) return error.InvalidCluster;
}

/// Converts one HarfBuzz glyph into an engine glyph. HarfBuzz positions are in 26.6 units of the scale RuntimeFont set,
/// so 64 units make one pixel. HarfBuzz's y axis points up, so vertical values are negated to match glyph metrics.
fn toGlyph(info: hb.hb_glyph_info_t, pos: hb.hb_glyph_position_t) Glyph {
    return .{
        .glyph_id = info.codepoint,
        .cluster = info.cluster,
        .x_advance = unitsToPixels(pos.x_advance),
        .y_advance = -unitsToPixels(pos.y_advance),
        .x_offset = unitsToPixels(pos.x_offset),
        .y_offset = -unitsToPixels(pos.y_offset),
    };
}

fn unitsToPixels(units: i32) f32 {
    return @as(f32, @floatFromInt(units)) / 64.0;
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

const font_path: [:0]const u8 = "assets/font.ttf";
/// Arial 7.07's glyph index for 'A' (the shipped UI font). hb_shape_test.zig and checks/hb_linux_smoke.c report the same.
const arial_glyph_a: u32 = 36;

/// Reads a file through HarfBuzz's loader and returns an owned copy, as runtime_font.zig's tests do.
fn readFixture(allocator: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    const blob = hb.hb_blob_create_from_file_or_fail(path.ptr) orelse return error.FixtureMissing;
    defer hb.hb_blob_destroy(blob);
    var len: c_uint = 0;
    const data = hb.hb_blob_get_data(blob, &len);
    if (data == null or len == 0) return error.FixtureMissing;
    const ptr: [*]const u8 = @ptrCast(data);
    return allocator.dupe(u8, ptr[0..@as(usize, len)]);
}

test "AVATAR shapes to six glyphs with clusters 0 to 5, in input order" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var shaper = try Shaper.init(&font);
    defer shaper.deinit();

    var run = try shaper.shape(testing.allocator, "AVATAR", .{});
    defer run.deinit();
    try testing.expectEqual(@as(usize, 6), run.glyphs.len);
    for (run.glyphs, 0..) |g, i| try testing.expectEqual(@as(u32, @intCast(i)), g.cluster);
}

test "glyph IDs are the font's own IDs, and a repeated letter maps to one glyph" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var shaper = try Shaper.init(&font);
    defer shaper.deinit();

    var run = try shaper.shape(testing.allocator, "AVATAR", .{});
    defer run.deinit();
    try testing.expectEqual(arial_glyph_a, run.glyphs[0].glyph_id);
    try testing.expectEqual(arial_glyph_a, run.glyphs[2].glyph_id);
    try testing.expectEqual(arial_glyph_a, run.glyphs[4].glyph_id);
    // Not the codepoint: 'A' is 65, and the glyph index is 36.
    try testing.expect(run.glyphs[0].glyph_id != 'A');
}

test "a single glyph's advance agrees with the face's own metrics to a 64th of a pixel" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var shaper = try Shaper.init(&font);
    defer shaper.deinit();

    var run = try shaper.shape(testing.allocator, "A", .{});
    defer run.deinit();
    const metrics = try font.glyphMetrics(run.glyphs[0].glyph_id);
    // HarfBuzz rounds an advance to 1/64 px. stb does not, so the two differ by less than one step.
    try testing.expect(@abs(run.glyphs[0].x_advance - metrics.advance) <= 1.0 / 64.0 + 1e-6);
}

test "kerning narrows the A before V: the pair's A is narrower than the A alone" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var shaper = try Shaper.init(&font);
    defer shaper.deinit();

    var pair = try shaper.shape(testing.allocator, "AV", .{});
    defer pair.deinit();
    var alone = try shaper.shape(testing.allocator, "A", .{});
    defer alone.deinit();
    try testing.expectEqual(@as(usize, 2), pair.glyphs.len);
    try testing.expect(pair.glyphs[0].x_advance < alone.glyphs[0].x_advance);
}

test "width is the sum of the glyph advances, and measure returns the same value as shape" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var shaper = try Shaper.init(&font);
    defer shaper.deinit();

    const samples = [_][]const u8{ "AVATAR", "A B", "", "ab cd ef" };
    for (samples) |text| {
        var run = try shaper.shape(testing.allocator, text, .{});
        defer run.deinit();
        var sum: f32 = 0;
        for (run.glyphs) |g| sum += g.x_advance;
        try testing.expectEqual(sum, run.width);
        try testing.expectEqual(run.width, try shaper.measure(text, .{}));
    }
}

test "clusters are byte offsets: a two-byte character moves the next cluster by two" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var shaper = try Shaper.init(&font);
    defer shaper.deinit();

    // U+00E9 is C3 A9 in UTF-8, so the A after it starts at byte 2, not at codepoint 1.
    var run = try shaper.shape(testing.allocator, "\u{e9}A", .{});
    defer run.deinit();
    try testing.expectEqual(@as(usize, 2), run.glyphs.len);
    try testing.expectEqual(@as(u32, 0), run.glyphs[0].cluster);
    try testing.expectEqual(@as(u32, 2), run.glyphs[1].cluster);
}

test "malformed UTF-8 costs one glyph per bad byte and never ends the run" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var shaper = try Shaper.init(&font);
    defer shaper.deinit();

    var run = try shaper.shape(testing.allocator, "A\xffB", .{});
    defer run.deinit();
    try testing.expectEqual(@as(usize, 3), run.glyphs.len);
    try testing.expectEqual(@as(u32, 0), run.glyphs[0].cluster);
    try testing.expectEqual(@as(u32, 1), run.glyphs[1].cluster);
    try testing.expectEqual(@as(u32, 2), run.glyphs[2].cluster);
}

test "a character the font does not map shapes to glyph 0, and keeps its cluster" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var shaper = try Shaper.init(&font);
    defer shaper.deinit();

    // U+4E00 is a CJK ideograph. Arial 7.07 has no glyph for it.
    var run = try shaper.shape(testing.allocator, "\u{4e00}", .{});
    defer run.deinit();
    try testing.expectEqual(@as(usize, 1), run.glyphs.len);
    try testing.expectEqual(@as(u32, 0), run.glyphs[0].glyph_id);
    try testing.expectEqual(@as(u32, 0), run.glyphs[0].cluster);
}

test "combining marks share their base's cluster, and the next letter starts after them" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var shaper = try Shaper.init(&font);
    defer shaper.deinit();

    // "e" is one byte and U+0301 is two, so the A after the grapheme "e\u{301}" starts at byte 3.
    var run = try shaper.shape(testing.allocator, "e\u{301}A", .{});
    defer run.deinit();
    try testing.expect(run.glyphs.len >= 2);
    for (run.glyphs[0 .. run.glyphs.len - 1]) |g| try testing.expectEqual(@as(u32, 0), g.cluster);
    try testing.expectEqual(@as(u32, 3), run.glyphs[run.glyphs.len - 1].cluster);
}

test "a space has an advance and no ink" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var shaper = try Shaper.init(&font);
    defer shaper.deinit();

    var run = try shaper.shape(testing.allocator, " ", .{});
    defer run.deinit();
    try testing.expectEqual(@as(usize, 1), run.glyphs.len);
    const metrics = try font.glyphMetrics(run.glyphs[0].glyph_id);
    try testing.expect(run.glyphs[0].x_advance > 0);
    try testing.expectEqual(@as(u32, 0), metrics.width);
    try testing.expectEqual(@as(u32, 0), metrics.height);
}

test "empty text shapes to no glyphs and zero width" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var shaper = try Shaper.init(&font);
    defer shaper.deinit();

    var run = try shaper.shape(testing.allocator, "", .{});
    defer run.deinit();
    try testing.expectEqual(@as(usize, 0), run.glyphs.len);
    try testing.expectEqual(@as(f32, 0), run.width);
    try testing.expectEqual(@as(f32, 0), try shaper.measure("", .{}));
}

test "script and language must be named, and an empty tag is refused" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var shaper = try Shaper.init(&font);
    defer shaper.deinit();

    try testing.expectError(error.InvalidLanguage, shaper.shape(testing.allocator, "A", .{ .language = "" }));
    try testing.expectError(error.InvalidScript, shaper.shape(testing.allocator, "A", .{ .script = "" }));
    // The shaper still works after a refused call.
    var run = try shaper.shape(testing.allocator, "A", .{ .script = "Latn", .language = "en" });
    defer run.deinit();
    try testing.expectEqual(@as(usize, 1), run.glyphs.len);
}

test "one shaper reused for many strings leaves nothing allocated" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var shaper = try Shaper.init(&font);
    defer shaper.deinit();

    // testing.allocator fails the test if any run is left allocated.
    var round: usize = 0;
    while (round < 200) : (round += 1) {
        var long = try shaper.shape(testing.allocator, "AVATAR", .{});
        defer long.deinit();
        try testing.expectEqual(@as(usize, 6), long.glyphs.len);
        var short = try shaper.shape(testing.allocator, "A", .{});
        defer short.deinit();
        try testing.expectEqual(@as(usize, 1), short.glyphs.len);
    }
}

test "a combining overline is a zero-advance glyph placed by its offset, and the base has none" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var shaper = try Shaper.init(&font);
    defer shaper.deinit();

    // Glyph 68 is the Latin a. Glyph 2116 is uni0305, the combining overline. The values were read from HarfBuzz 8.3.0
    // with this font at 16 px, and are not yet confirmed against the pinned 15.1.0. The y axis points down here, so a
    // positive y_offset moves the mark down onto the base: the overline's own outline sits high in the font.
    var run = try shaper.shape(testing.allocator, "a\u{305}", .{});
    defer run.deinit();
    try testing.expectEqual(@as(usize, 2), run.glyphs.len);
    try testing.expectEqual(@as(u32, 68), run.glyphs[0].glyph_id);
    try testing.expectEqual(@as(f32, 7.96875), run.glyphs[0].x_advance);
    try testing.expectEqual(@as(f32, 0), run.glyphs[0].x_offset);
    try testing.expectEqual(@as(f32, 0), run.glyphs[0].y_offset);
    try testing.expectEqual(@as(u32, 2116), run.glyphs[1].glyph_id);
    try testing.expectEqual(@as(f32, 0), run.glyphs[1].x_advance);
    try testing.expectEqual(@as(f32, -4.15625), run.glyphs[1].x_offset);
    try testing.expectEqual(@as(f32, 2.421875), run.glyphs[1].y_offset);
    try testing.expectEqual(@as(u32, 0), run.glyphs[1].cluster);
}
