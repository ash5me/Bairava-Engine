//! Shaping tests for the vendored HarfBuzz build. `zig build test` runs from the repository root
//! (see run_tests.setCwd in build.zig), so the shipped VT323 font is read from assets/. These
//! calls run HarfBuzz's font and shaper function tables, which the version-only smoke test does not.

const std = @import("std");

const hb = @cImport({
    @cInclude("hb.h");
});

const font_path: [:0]const u8 = "assets/font.ttf";
const max_glyphs = 16;

const ShapeError = error{ FontLoadFailed, TooManyGlyphs };

const Shaped = struct {
    count: usize,
    gids: [max_glyphs]u32,
    clusters: [max_glyphs]u32,
    advances: [max_glyphs]i32,
};

/// Shapes `text` at `pixel_height` pixels per em with the font file at `path`.
fn shapeWithFont(path: [:0]const u8, text: []const u8, pixel_height: u32) ShapeError!Shaped {
    const blob = hb.hb_blob_create_from_file_or_fail(path.ptr) orelse return error.FontLoadFailed;
    defer hb.hb_blob_destroy(blob);
    const face = hb.hb_face_create(blob, 0) orelse return error.FontLoadFailed;
    defer hb.hb_face_destroy(face);
    const font = hb.hb_font_create(face) orelse return error.FontLoadFailed;
    defer hb.hb_font_destroy(font);

    // HarfBuzz scales in 26.6 fixed point, so one pixel is 64 units.
    const scale: c_int = @intCast(pixel_height * 64);
    hb.hb_font_set_scale(font, scale, scale);

    const buf = hb.hb_buffer_create() orelse return error.FontLoadFailed;
    defer hb.hb_buffer_destroy(buf);
    hb.hb_buffer_add_utf8(buf, text.ptr, @intCast(text.len), 0, @intCast(text.len));
    hb.hb_buffer_guess_segment_properties(buf);
    hb.hb_shape(font, buf, null, 0);

    const n: usize = @intCast(hb.hb_buffer_get_length(buf));
    if (n > max_glyphs) return error.TooManyGlyphs;

    const infos = hb.hb_buffer_get_glyph_infos(buf, null);
    const positions = hb.hb_buffer_get_glyph_positions(buf, null);
    var out: Shaped = .{ .count = n, .gids = undefined, .clusters = undefined, .advances = undefined };
    for (0..n) |i| {
        out.gids[i] = infos[i].codepoint;
        out.clusters[i] = infos[i].cluster;
        out.advances[i] = positions[i].x_advance;
    }
    return out;
}

test "AVATAR shapes to six glyphs, with clusters in input order" {
    const shaped = try shapeWithFont(font_path, "AVATAR", 16);
    try std.testing.expectEqual(@as(usize, 6), shaped.count);
    for (0..6) |i| {
        try std.testing.expectEqual(@as(u32, @intCast(i)), shaped.clusters[i]);
    }
}

test "the repeated A in AVATAR maps to one glyph id" {
    const shaped = try shapeWithFont(font_path, "AVATAR", 16);
    try std.testing.expectEqual(shaped.gids[0], shaped.gids[2]);
    try std.testing.expectEqual(shaped.gids[0], shaped.gids[4]);
}

test "VT323 is monospaced: every AVATAR advance is positive and equal" {
    const shaped = try shapeWithFont(font_path, "AVATAR", 16);
    for (0..6) |i| {
        try std.testing.expect(shaped.advances[i] > 0);
        try std.testing.expectEqual(shaped.advances[0], shaped.advances[i]);
    }
}

test "empty text shapes to zero glyphs" {
    const shaped = try shapeWithFont(font_path, "", 16);
    try std.testing.expectEqual(@as(usize, 0), shaped.count);
}
