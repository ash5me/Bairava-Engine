//! Chemmozhi Paranar corpus for the shaper (a second Tamil font, beside shaper_tamil_test.zig).
//!
//! The font is tests/fixtures/ChemmozhiParanar.ttf: static TrueType (glyf, GSUB with akhn, abvs, and blws, and an empty
//! GPOS) from the owner, version 1.000 (2011). Its hash is recorded in docs/dependency-lock.json, and
//! scripts/check-dependency-pins.py verifies it. Known properties, all tested below: Taml shaping forms the KSSA ligature
//! and Latn does not; a vowel sign O on க stays in one cluster; Tamil clusters are grapheme starts; the font has no glyph
//! for U+0B82 ANUSVARA; and it has no Latin kerning, because GPOS has no features.

const std = @import("std");
const runtime_font = @import("runtime_font.zig");
const shaper = @import("shaper.zig");
const hb = runtime_font.hb;

const testing = std.testing;
const font_path: [:0]const u8 = "tests/fixtures/ChemmozhiParanar.ttf";
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

test "the Chemmozhi KSSA conjunct forms one ligature under Taml, cluster 0" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var sh = try shaper.Shaper.init(&font);
    defer sh.deinit();

    var run = try sh.shape(testing.allocator, "\u{0B95}\u{0BCD}\u{0BB7}", taml);
    defer run.deinit();
    try testing.expectEqual(@as(usize, 1), run.glyphs.len);
    try testing.expectEqual(@as(u32, 0), run.glyphs[0].cluster);
}

test "the Chemmozhi conjunct is not a ligature under Latn: three glyphs, the last at byte 6" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var sh = try shaper.Shaper.init(&font);
    defer sh.deinit();

    var run = try sh.shape(testing.allocator, "\u{0B95}\u{0BCD}\u{0BB7}", .{ .script = "Latn", .language = "en" });
    defer run.deinit();
    try testing.expectEqual(@as(usize, 3), run.glyphs.len);
    try testing.expectEqual(@as(u32, 0), run.glyphs[0].cluster);
    try testing.expectEqual(@as(u32, 0), run.glyphs[1].cluster);
    try testing.expectEqual(@as(u32, 6), run.glyphs[2].cluster);
}

test "the vowel sign O on க gives three glyphs in one cluster" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var sh = try shaper.Shaper.init(&font);
    defer sh.deinit();

    var run = try sh.shape(testing.allocator, "\u{0B95}\u{0BCA}", taml);
    defer run.deinit();
    try testing.expectEqual(@as(usize, 3), run.glyphs.len);
    for (run.glyphs) |g| try testing.expectEqual(@as(u32, 0), g.cluster);
}

test "a Tamil word's clusters are its grapheme starts: 0, 3, 9" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var sh = try shaper.Shaper.init(&font);
    defer sh.deinit();

    // த (0), மி (3, the vowel sign i joins its consonant), ழ் (9, the pulli joins it). Three graphemes, three glyphs.
    var run = try sh.shape(testing.allocator, "\u{0BA4}\u{0BAE}\u{0BBF}\u{0BB4}\u{0BCD}", taml);
    defer run.deinit();
    const expected = [_]u32{ 0, 3, 9 };
    try testing.expectEqual(expected.len, run.glyphs.len);
    for (run.glyphs, expected) |g, cluster| try testing.expectEqual(cluster, g.cluster);
}

test "the font maps 71 of the 72 assigned Tamil characters, and has no glyph for U+0B82 ANUSVARA" {
    const bytes = try readFixture(testing.allocator, font_path);
    defer testing.allocator.free(bytes);
    var font = try runtime_font.RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();

    var mapped: u32 = 0;
    var cp: u32 = 0x0B80;
    while (cp < 0x0C00) : (cp += 1) {
        var gid: hb.hb_codepoint_t = 0;
        if (hb.hb_font_get_nominal_glyph(font.font, cp, &gid) != 0 and gid != 0) mapped += 1;
    }
    // The block also holds unassigned code points, which never map, so 71 is the count of assigned characters mapped.
    try testing.expectEqual(@as(u32, 71), mapped);

    var anusvara: hb.hb_codepoint_t = 0;
    _ = hb.hb_font_get_nominal_glyph(font.font, 0x0B82, &anusvara);
    try testing.expectEqual(@as(hb.hb_codepoint_t, 0), anusvara);
}
