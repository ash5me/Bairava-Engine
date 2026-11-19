//! BFNT text measurement on the common text path: the Zig port of `ui_font_text_width_scaled` in text.c.
//!
//! The port follows text.c line for line. The C mirror, checks/bfnt_measure_mirror.c, compares the two bit for bit on
//! 960,480 cases: synthetic fonts, a fixed corpus of valid and malformed UTF-8, and seeded random strings. The test
//! below repeats the comparison against text.c inside the test binary. Drawing still runs in text.c. This file
//! measures only.
//!
//! Rules carried over from text.c:
//! - Malformed UTF-8 decodes to U+FFFD and moves one byte. Overlong forms and surrogates decode as their bits say.
//! - A codepoint outside the baked range draws the font's fallback, or nothing when the font has none.
//! - A glyph that draws nothing does not move the pen and does not become the previous glyph, so kerning skips it.
//! - Kerning comes from the baked, sorted table and is added before the glyph's advance.
//!
//! The float operations run in the same order as in text.c. The build compiles text.c with `-ffp-contract=off`
//! (`text_c_flags` in build.zig). Without it, a target with FMA fuses `width += a * b` in text.c into one rounding,
//! and this test fails in the last bits. checks/bfnt_fp_contract_repro.c reproduces that outside Zig.

const std = @import("std");
const c = @import("../ui/c.zig").c;

/// Decodes the codepoint at text[pos.*] and moves pos past it, as text.c `utf8_next` does.
fn nextCodepoint(text: []const u8, pos: *usize) i32 {
    const lead = text[pos.*];
    if (lead < 0x80) {
        pos.* += 1;
        return @as(i32, lead);
    }
    var extra: usize = 0;
    var cp: u32 = 0;
    if ((lead & 0xE0) == 0xC0) {
        extra = 1;
        cp = lead & 0x1F;
    } else if ((lead & 0xF0) == 0xE0) {
        extra = 2;
        cp = lead & 0x0F;
    } else if ((lead & 0xF8) == 0xF0) {
        extra = 3;
        cp = lead & 0x07;
    } else {
        pos.* += 1;
        return 0xFFFD;
    }
    if (text.len - pos.* <= extra) {
        pos.* += 1;
        return 0xFFFD;
    }
    var i: usize = 1;
    while (i <= extra) : (i += 1) {
        const next = text[pos.* + i];
        if ((next & 0xC0) != 0x80) {
            pos.* += 1;
            return 0xFFFD;
        }
        cp = (cp << 6) | @as(u32, next & 0x3F);
    }
    pos.* += extra + 1;
    return @intCast(cp);
}

/// The codepoint drawn for `cp`: itself when it is baked, otherwise the font's fallback, which is -1 for none.
fn drawnCodepoint(font: *const c.ui_font, cp: i32) i32 {
    const first: i64 = font.first;
    const count: i64 = font.count;
    const value: i64 = cp;
    if (value >= first and value < first + count) return cp;
    return font.fallback;
}

/// The glyph for a codepoint that `drawnCodepoint` resolved. Null means nothing is drawn.
fn glyphFor(font: *const c.ui_font, drawn: i32) ?*const c.ui_glyph {
    if (drawn < 0) return null;
    const i: i64 = @as(i64, drawn) - @as(i64, font.first);
    const count: i64 = font.count;
    if (i < 0 or i >= count) return null;
    return &font.glyphs[@intCast(i)];
}

/// Kerning for a pair of drawn codepoints, by binary search of the baked table. Pairs not in the table have none.
fn kerningFor(font: *const c.ui_font, left: u32, right: u32) f32 {
    var lo: i64 = 0;
    var hi: i64 = @as(i64, font.kerning_count) - 1;
    while (lo <= hi) {
        const mid: i64 = lo + @divTrunc(hi - lo, 2);
        const k = font.kernings[@intCast(mid)];
        if (k.left == left and k.right == right) return k.advance;
        if (k.left < left or (k.left == left and k.right < right)) {
            lo = mid + 1;
        } else {
            hi = mid - 1;
        }
    }
    return 0;
}

/// The width in pixels of `text` at `scale`. A scale that is not positive gives 0, as in text.c.
pub fn width(font: *const c.ui_font, text: []const u8, scale: f32) f32 {
    if (!(scale > 0)) return 0;
    var total: f32 = 0;
    var pos: usize = 0;
    var previous: i32 = -1;
    while (pos < text.len) {
        const drawn = drawnCodepoint(font, nextCodepoint(text, &pos));
        const glyph = glyphFor(font, drawn) orelse continue;
        if (previous >= 0) {
            total += kerningFor(font, @intCast(previous), @intCast(drawn)) * scale;
        }
        total += glyph.xadvance * scale;
        previous = drawn;
    }
    return total;
}

// ---- tests -----------------------------------------------------------------------------------------------------------

const testing = std.testing;

fn testFont(glyphs: [*c]c.ui_glyph, kernings: [*c]c.ui_kerning, kerning_count: c_int, first: c_int, count: c_int, fallback: c_int) c.ui_font {
    var f = std.mem.zeroes(c.ui_font);
    f.first = first;
    f.count = count;
    f.fallback = fallback;
    f.glyphs = glyphs;
    f.kernings = kernings;
    f.kerning_count = kerning_count;
    return f;
}

test "the BFNT measurement port returns the same float bits as text.c on the same fonts and text" {
    var glyphs: [95]c.ui_glyph = undefined;
    for (&glyphs, 0..) |*g, i| {
        g.* = std.mem.zeroes(c.ui_glyph);
        g.xadvance = 3.1 + @as(f32, @floatFromInt(i % 7)) * 0.1;
    }

    // Sorted by (left, right), as the loader requires.
    var kernings = [_]c.ui_kerning{
        .{ .left = 32, .right = 65, .advance = -0.5 },
        .{ .left = 63, .right = 63, .advance = 0.25 },
        .{ .left = 65, .right = 86, .advance = -1.5 },
        .{ .left = 84, .right = 111, .advance = -0.75 },
        .{ .left = 86, .right = 65, .advance = -1.25 },
    };
    const kerning_count: c_int = @intCast(kernings.len);

    var fonts = [_]c.ui_font{
        testFont(&glyphs[0], &kernings[0], kerning_count, 32, 95, '?'),
        testFont(&glyphs[0], &kernings[0], kerning_count, 65, 26, -1),
        testFont(&glyphs[0], &kernings[0], kerning_count, 0, 0, -1),
        testFont(&glyphs[0], &kernings[0], kerning_count, 0, 0, '?'),
    };

    const corpus = [_][]const u8{
        "",             "A",              "AV",       "VA",     "TAV",               "Hello, world",
        "?",            "\xc3\xa9",       "\xff",     "\xe2\x82", "\xed\xa0\x80",    "\xc0\x80",
        "\xf7\xbf\xbf\xbf", "A\x80V",     "\xe6\x97\xa5", "AAAA\xe2", "a\x00b",     "\xf0\x9f\x98\x80",
        "VAVAV",
    };
    const scales = [_]f32{ 1.0, 0.5, 2.0, 0.0, -1.0, 1.5 };

    for (&fonts) |*f| {
        for (corpus) |text| {
            for (scales) |scale| {
                const expected = c.ui_font_text_width_scaled(f, text.ptr, text.len, scale);
                const actual = width(f, text, scale);
                try testing.expectEqual(@as(u32, @bitCast(expected)), @as(u32, @bitCast(actual)));
            }
        }
    }
}
