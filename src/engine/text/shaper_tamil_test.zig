//! Tamil corpus for the shaper and the shaped layout (Phase 0 corpus, Phase 5 exit gate: Latin and Tamil reference strings
//! keep their glyph order, positions, and cluster behavior).
//!
//! The font is tests/fixtures/NotoSansTamil.ttf: Noto Sans Tamil, variable TrueType (glyf, GSUB, GPOS), from
//! google/fonts at commit 7af0d90b4d532ffa4b041937b560c6df4e7b1e95. It is licensed under the SIL Open Font License 1.1
//! (tests/fixtures/NotoSansTamil-OFL.txt). Its hash is recorded in docs/dependency-lock.json, and
//! scripts/check-dependency-pins.py verifies it.
//!
//! The expected values were read from HarfBuzz 15.1.0 with this font, then checked for their meaning: cluster values are
//! grapheme starts, and the explicit script changes the result.

const std = @import("std");
const runtime_font = @import("runtime_font.zig");
const shaper = @import("shaper.zig");
const shaped_layout = @import("shaped_layout.zig");
const hb = runtime_font.hb;

const testing = std.testing;
const font_path: [:0]const u8 = "tests/fixtures/NotoSansTamil.ttf";
const taml = shaper.Options{ .script = "Taml", .language = "ta" };

fn readFixture(allocator: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    const blob = hb.hb_blob_create_from_file_or_fail(path.ptr) orelse return error.FixtureMissing;
    defer hb.hb_blob_destroy(blob);
    var len: c_uint = 0;
    const data = hb.hb_blob_get_data(blob, &len);
    if (data == null or len == 0) return error.FixtureMissing;
    const ptr: [*]const u8 = @ptrCast(data);
    return allocator.dupe(u8, ptr[0..@as(usize, len)]);
}

test "the conjunct KSSA (க்ஷ) forms one ligature glyph, cluster 0, and the layout never splits it" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var sh = try shaper.Shaper.init(&font);
    defer sh.deinit();

    // U+0B95 U+0BCD U+0BB7: nine bytes, two graphemes (க் and ஷ). The font's ligature covers both in one glyph.
    var run = try sh.shape(testing.allocator, "\u{0B95}\u{0BCD}\u{0BB7}", taml);
    defer run.deinit();
    try testing.expectEqual(@as(usize, 1), run.glyphs.len);
    try testing.expectEqual(@as(u32, 0), run.glyphs[0].cluster);
}

test "the script is never guessed: the same conjunct shapes differently as Latn" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var sh = try shaper.Shaper.init(&font);
    defer sh.deinit();

    const text = "\u{0B95}\u{0BCD}\u{0BB7}";
    // Under Latn the Tamil ligature is not applied: three glyphs, the second with zero advance, and the last at byte 6.
    var latin = try sh.shape(testing.allocator, text, .{ .script = "Latn", .language = "en" });
    defer latin.deinit();
    try testing.expectEqual(@as(usize, 3), latin.glyphs.len);
    try testing.expectEqual(@as(u32, 0), latin.glyphs[0].cluster);
    try testing.expectEqual(@as(u32, 0), latin.glyphs[1].cluster);
    try testing.expectEqual(@as(u32, 6), latin.glyphs[2].cluster);
    try testing.expectEqual(@as(f32, 0), latin.glyphs[1].x_advance);
}

test "the vowel sign O on க splits into three glyphs that all share its cluster" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var sh = try shaper.Shaper.init(&font);
    defer sh.deinit();

    // U+0B95 U+0BCA is one grapheme of six bytes. The vowel sign becomes a pre-base part, the base, and a post-base part.
    var run = try sh.shape(testing.allocator, "\u{0B95}\u{0BCA}", taml);
    defer run.deinit();
    try testing.expectEqual(@as(usize, 3), run.glyphs.len);
    for (run.glyphs) |g| try testing.expectEqual(@as(u32, 0), g.cluster);
}

test "a Tamil word's clusters are exactly its grapheme starts: 0, 3, 3, 9" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var sh = try shaper.Shaper.init(&font);
    defer sh.deinit();

    // த (0), மி (3, the vowel sign i joins its consonant), ழ் (9, the pulli joins it). Three graphemes, four glyphs.
    var run = try sh.shape(testing.allocator, "\u{0BA4}\u{0BAE}\u{0BBF}\u{0BB4}\u{0BCD}", taml);
    defer run.deinit();
    const expected = [_]u32{ 0, 3, 3, 9 };
    try testing.expectEqual(expected.len, run.glyphs.len);
    for (run.glyphs, expected) |g, cluster| try testing.expectEqual(cluster, g.cluster);
}

test "Tamil words wrap at their space, and the conjunct on the second line keeps its absolute cluster" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var sh = try shaper.Shaper.init(&font);
    defer sh.deinit();

    // "தமிழ்" is 15 bytes, then a space at byte 15, then the conjunct at byte 16.
    const word = "\u{0BA4}\u{0BAE}\u{0BBF}\u{0BB4}\u{0BCD}";
    const text = word ++ " \u{0B95}\u{0BCD}\u{0BB7}";
    const word_width = try sh.measure(word, taml);
    var result = try shaped_layout.layout(testing.allocator, &sh, text, word_width, 20, .left, taml);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.lines.len);
    try testing.expectEqualStrings(word, result.lines[0].text);
    try testing.expectEqualStrings("\u{0B95}\u{0BCD}\u{0BB7}", result.lines[1].text);
    const second = result.glyphsOf(result.lines[1]);
    try testing.expectEqual(@as(usize, 1), second.len);
    try testing.expectEqual(@as(u32, 16), second[0].cluster);
    for (result.lines) |line| {
        var sum: f32 = 0;
        for (result.glyphsOf(line)) |g| sum += g.x_advance;
        try testing.expectApproxEqAbs(line.width, sum, 1e-4);
    }
}
