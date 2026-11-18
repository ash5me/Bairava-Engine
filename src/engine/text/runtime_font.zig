//! Runtime outline font face (Phase 2 of the rendering migration plan).
//!
//! A RuntimeFont owns one TrueType file, a HarfBuzz face and font bound to it, and an stb_truetype
//! face. It rasterizes glyphs by glyph ID, the IDs HarfBuzz returns, and converts stb's bounds to
//! baseline and screen conventions. It owns no atlas. The glyph cache (Phase 3) decides where
//! coverage bitmaps are stored.
//!
//! The file comes from Bairava's packaged assets through `staging.Reader`, the seam the texture
//! loader uses. `loadPackaged` reads a name through that reader; the engine passes
//! `staging.packagedReader()`. `init` takes bytes the caller already holds. Neither path logs or
//! touches the GPU, so a face can be built on a worker thread.
//!
//! Pixel height follows the gray convention recorded in docs/Bairava_Phase0/design-note.md (D2):
//! em in pixels = pixel_height * upem / (ascent - descent). stb's stbtt_ScaleForPixelHeight and the
//! HarfBuzz scale both use it, so a runtime face and a gray BFNT at the same size measure the same.
//!
//! Only TrueType glyf outlines are accepted. OpenType CFF, CFF2, and TrueType collections return
//! error.UnsupportedFontFormat. CFF stays prebaked (Phase 0 decision).

const std = @import("std");
const staging = @import("../assets/staging.zig");

/// The HarfBuzz C API. shaper.zig imports it from here so both files name the same types; a second @cImport would
/// produce distinct, incompatible HarfBuzz types. HarfBuzz types stay inside the text package.
pub const hb = @cImport({
    @cInclude("hb.h");
});

const stb = @cImport({
    // stb_truetype.h names size_t in its declarations and includes nothing that defines it, so
    // stddef.h comes first. tools/assets/font_bake.h does the same before its stb include.
    @cInclude("stddef.h");
    @cInclude("stb_truetype.h");
});

pub const Error = error{
    InvalidFont,
    UnsupportedFontFormat,
    InvalidPixelHeight,
    GlyphOutOfRange,
} || std.mem.Allocator.Error;

/// What `loadPackaged` can return: the face's own errors, plus the reader's, under the names the
/// engine's file loaders use (`Context.readFile` reports a missing file as FileNotFound).
pub const LoadError = Error || error{ FileNotFound, ReadFailed, PathTooLong };

/// The largest pixel height a face accepts. HarfBuzz keeps its scale in 26.6 fixed point in a C int,
/// so a larger height would overflow the conversion. The bound is a guard on that conversion, not a
/// rendering limit; the glyph cache sets its own.
pub const max_pixel_height: f32 = 4096;

pub const GlyphMetrics = struct {
    /// Pen advance in pixels.
    advance: f32,
    /// Left edge of the bitmap from the pen, in pixels, x to the right.
    xoff: f32,
    /// Top edge of the bitmap from the baseline, in pixels, y down. Negative means above the baseline.
    yoff: f32,
    /// Bitmap size in pixels. Zero for glyphs with no ink, such as a space.
    width: u32,
    height: u32,
};

pub const Bitmap = struct {
    metrics: GlyphMetrics,
    /// width * height coverage bytes, row 0 at the top. Empty for glyphs with no ink.
    coverage: []u8,

    pub fn deinit(self: Bitmap, allocator: std.mem.Allocator) void {
        allocator.free(self.coverage);
    }
};

pub const RuntimeFont = struct {
    allocator: std.mem.Allocator,
    /// Owned copy of the font file. The HarfBuzz blob and the stb face point into it, so it is freed last.
    bytes: []u8,
    info: stb.stbtt_fontinfo,
    blob: *hb.hb_blob_t,
    face: *hb.hb_face_t,
    font: *hb.hb_font_t,
    pixel_height: f32,
    /// stb scale: pixels per font unit.
    scale: f32,
    upem: u32,
    ascent: c_int,
    descent: c_int,
    glyph_count: u32,

    /// Copies `source`, so the caller may free it after this returns. The height and the format are
    /// checked before the copy, so a rejected file costs no allocation.
    pub fn init(allocator: std.mem.Allocator, source: []const u8, pixel_height: f32) Error!RuntimeFont {
        try checkPixelHeight(pixel_height);
        try checkFormat(source);
        const bytes = try allocator.dupe(u8, source);
        return fromOwned(allocator, bytes, pixel_height);
    }

    /// Reads the packaged file `relative` through `reader` and builds the face on the bytes it returns.
    /// The engine passes `staging.packagedReader()`, which reads beside the executable. The height is
    /// checked before the read, so a bad height never touches the file. The face keeps the reader's
    /// allocation, so the file is copied once. Any failure frees it.
    pub fn loadPackaged(
        allocator: std.mem.Allocator,
        reader: staging.Reader,
        relative: []const u8,
        pixel_height: f32,
    ) LoadError!RuntimeFont {
        try checkPixelHeight(pixel_height);
        const bytes = reader.read(reader.context, allocator, relative) catch |err| return switch (err) {
            error.NotFound => error.FileNotFound,
            error.ReadFailed => error.ReadFailed,
            error.PathTooLong => error.PathTooLong,
            error.OutOfMemory => error.OutOfMemory,
        };
        return fromOwned(allocator, bytes, pixel_height);
    }

    /// Builds the face on `bytes`, which the face takes ownership of. On any error the bytes are freed
    /// here, so no caller frees them after a failed call.
    fn fromOwned(allocator: std.mem.Allocator, bytes: []u8, pixel_height: f32) Error!RuntimeFont {
        errdefer allocator.free(bytes);
        try checkPixelHeight(pixel_height);
        try checkFormat(bytes);
        if (bytes.len > std.math.maxInt(c_uint)) return error.InvalidFont;

        var info: stb.stbtt_fontinfo = undefined;
        if (stb.stbtt_InitFont(&info, bytes.ptr, 0) == 0) return error.InvalidFont;

        var ascent: c_int = 0;
        var descent: c_int = 0;
        var line_gap: c_int = 0;
        stb.stbtt_GetFontVMetrics(&info, &ascent, &descent, &line_gap);
        if (ascent - descent <= 0) return error.InvalidFont;

        const blob = hb.hb_blob_create(bytes.ptr, @intCast(bytes.len), hb.HB_MEMORY_MODE_READONLY, null, null) orelse return error.InvalidFont;
        errdefer hb.hb_blob_destroy(blob);
        const face = hb.hb_face_create(blob, 0) orelse return error.InvalidFont;
        errdefer hb.hb_face_destroy(face);
        const font = hb.hb_font_create(face) orelse return error.InvalidFont;
        errdefer hb.hb_font_destroy(font);

        const upem = hb.hb_face_get_upem(face);
        if (upem == 0) return error.InvalidFont;
        const em_px = pixel_height * @as(f32, @floatFromInt(upem)) / @as(f32, @floatFromInt(ascent - descent));
        const hb_scale: c_int = @intFromFloat(@round(em_px * 64.0));
        hb.hb_font_set_scale(font, hb_scale, hb_scale);

        return .{
            .allocator = allocator,
            .bytes = bytes,
            .info = info,
            .blob = blob,
            .face = face,
            .font = font,
            .pixel_height = pixel_height,
            .scale = stb.stbtt_ScaleForPixelHeight(&info, pixel_height),
            .upem = @intCast(upem),
            .ascent = ascent,
            .descent = descent,
            .glyph_count = @intCast(hb.hb_face_get_glyph_count(face)),
        };
    }

    pub fn deinit(self: *RuntimeFont) void {
        hb.hb_font_destroy(self.font);
        hb.hb_face_destroy(self.face);
        hb.hb_blob_destroy(self.blob);
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    /// Metrics for one glyph ID, with no rasterization. A glyph with no ink reports zero width and height.
    pub fn glyphMetrics(self: *const RuntimeFont, glyph_id: u32) Error!GlyphMetrics {
        if (glyph_id >= self.glyph_count) return error.GlyphOutOfRange;
        const gid: c_int = @intCast(glyph_id);
        var advance: c_int = 0;
        var side_bearing: c_int = 0;
        stb.stbtt_GetGlyphHMetrics(&self.info, gid, &advance, &side_bearing);
        var x0: c_int = 0;
        var y0: c_int = 0;
        var x1: c_int = 0;
        var y1: c_int = 0;
        stb.stbtt_GetGlyphBitmapBox(&self.info, gid, self.scale, self.scale, &x0, &y0, &x1, &y1);
        return .{
            .advance = @as(f32, @floatFromInt(advance)) * self.scale,
            .xoff = @floatFromInt(x0),
            .yoff = @floatFromInt(y0),
            .width = if (x1 > x0) @as(u32, @intCast(x1 - x0)) else 0,
            .height = if (y1 > y0) @as(u32, @intCast(y1 - y0)) else 0,
        };
    }

    /// Rasterizes one glyph ID into an owned coverage bitmap. Free it with Bitmap.deinit.
    pub fn rasterize(self: *const RuntimeFont, allocator: std.mem.Allocator, glyph_id: u32) Error!Bitmap {
        const metrics = try self.glyphMetrics(glyph_id);
        const size = @as(usize, metrics.width) * @as(usize, metrics.height);
        const coverage = try allocator.alloc(u8, size);
        errdefer allocator.free(coverage);
        if (size > 0) {
            @memset(coverage, 0);
            stb.stbtt_MakeGlyphBitmap(&self.info, coverage.ptr, @intCast(metrics.width), @intCast(metrics.height), @intCast(metrics.width), self.scale, self.scale, @intCast(glyph_id));
        }
        return .{ .metrics = metrics, .coverage = coverage };
    }
};

/// Accepts a height above zero and at most `max_pixel_height`. NaN fails the first comparison, and
/// infinity fails the second.
fn checkPixelHeight(pixel_height: f32) Error!void {
    if (!(pixel_height > 0 and pixel_height <= max_pixel_height)) return error.InvalidPixelHeight;
}

/// Accepts a TrueType file with glyf outlines. Rejects everything else before any parser runs.
fn checkFormat(bytes: []const u8) Error!void {
    if (bytes.len < 12) return error.InvalidFont;
    const magic = std.mem.readInt(u32, bytes[0..4], .big);
    switch (magic) {
        0x00010000, 0x74727565 => {},
        0x4F54544F, 0x74746366 => return error.UnsupportedFontFormat, // 'OTTO' (CFF), 'ttcf' (collection)
        else => return error.InvalidFont,
    }
    const num_tables: usize = std.mem.readInt(u16, bytes[4..6], .big);
    if (bytes.len < 12 + 16 * num_tables) return error.InvalidFont;
    var has_glyf = false;
    var has_cff = false;
    var i: usize = 0;
    while (i < num_tables) : (i += 1) {
        const tag = bytes[12 + 16 * i ..][0..4];
        if (std.mem.eql(u8, tag, "glyf")) has_glyf = true;
        if (std.mem.eql(u8, tag, "CFF ") or std.mem.eql(u8, tag, "CFF2")) has_cff = true;
    }
    if (has_cff and !has_glyf) return error.UnsupportedFontFormat;
    if (!has_glyf) return error.InvalidFont;
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

/// Reads a file through HarfBuzz's loader, as hb_shape_test.zig does, and returns an owned copy.
fn readFixture(allocator: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    const blob = hb.hb_blob_create_from_file_or_fail(path.ptr) orelse return error.FixtureMissing;
    defer hb.hb_blob_destroy(blob);
    var len: c_uint = 0;
    const data = hb.hb_blob_get_data(blob, &len);
    if (data == null or len == 0) return error.FixtureMissing;
    // The same C-pointer conversion audio.zig's bytesOf uses before it slices.
    const ptr: [*]const u8 = @ptrCast(data);
    return allocator.dupe(u8, ptr[0..@as(usize, len)]);
}

test "shipped Arial loads with hhea metrics and the gray pixel-height scale" {
    const bytes = try readFixture(testing.allocator, "assets/font.ttf");
    defer testing.allocator.free(bytes);
    var font = try RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    try testing.expectEqual(@as(u32, 2048), font.upem);
    try testing.expectEqual(@as(c_int, 1854), font.ascent);
    try testing.expectEqual(@as(c_int, -434), font.descent);
    try testing.expectEqual(@as(u32, 4652), font.glyph_count);
    try testing.expectApproxEqAbs(@as(f32, 16.0 / 2288.0), font.scale, 1e-7);
}

test "HarfBuzz scale follows the same convention as the baked gray font" {
    const bytes = try readFixture(testing.allocator, "assets/font.ttf");
    defer testing.allocator.free(bytes);
    var font = try RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var x_scale: c_int = 0;
    var y_scale: c_int = 0;
    hb.hb_font_get_scale(font.font, &x_scale, &y_scale);
    // 16 px * 2048 / 2288 em, in 26.6 units: round(916.59) = 917.
    try testing.expectEqual(@as(c_int, 917), x_scale);
    try testing.expectEqual(@as(c_int, 917), y_scale);
}

test "the A glyph has the measured advance, bounds, and baseline" {
    const bytes = try readFixture(testing.allocator, "assets/font.ttf");
    defer testing.allocator.free(bytes);
    var font = try RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    const gid: u32 = @intCast(stb.stbtt_FindGlyphIndex(&font.info, 'A'));
    const m = try font.glyphMetrics(gid);
    try testing.expectApproxEqAbs(@as(f32, 9.5524), m.advance, 0.001);
    try testing.expectEqual(@as(u32, 11), m.width);
    try testing.expectEqual(@as(u32, 11), m.height);
    try testing.expectEqual(@as(f32, -1), m.xoff);
    try testing.expectEqual(@as(f32, -11), m.yoff);
    // A sits on the baseline, so its bottom edge is at zero.
    try testing.expectEqual(@as(f32, 0), m.yoff + @as(f32, @floatFromInt(m.height)));
}

test "rasterizing A produces 11 by 11 coverage with full-strength ink" {
    const bytes = try readFixture(testing.allocator, "assets/font.ttf");
    defer testing.allocator.free(bytes);
    var font = try RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    const gid: u32 = @intCast(stb.stbtt_FindGlyphIndex(&font.info, 'A'));
    const bm = try font.rasterize(testing.allocator, gid);
    defer bm.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 121), bm.coverage.len);
    var sum: u64 = 0;
    var max: u8 = 0;
    for (bm.coverage) |v| {
        sum += @as(u64, v);
        if (v > max) max = v;
    }
    // Pinned to the stb_truetype 1.28 output measured in docs/Bairava_Phase0/baseline/arial/.
    try testing.expectEqual(@as(u64, 8030), sum);
    try testing.expectEqual(@as(u8, 255), max);
}

test "a space has an advance and no bitmap" {
    const bytes = try readFixture(testing.allocator, "assets/font.ttf");
    defer testing.allocator.free(bytes);
    var font = try RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    const gid: u32 = @intCast(stb.stbtt_FindGlyphIndex(&font.info, ' '));
    const m = try font.glyphMetrics(gid);
    try testing.expectApproxEqAbs(@as(f32, 3.979), m.advance, 0.001);
    try testing.expectEqual(@as(u32, 0), m.width);
    try testing.expectEqual(@as(u32, 0), m.height);
    const bm = try font.rasterize(testing.allocator, gid);
    defer bm.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), bm.coverage.len);
}

test "every printable ASCII glyph rasterizes from one face, and 94 of 95 have ink" {
    const bytes = try readFixture(testing.allocator, "assets/font.ttf");
    defer testing.allocator.free(bytes);
    var font = try RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    var cp: u8 = 32;
    var inked: usize = 0;
    while (cp < 127) : (cp += 1) {
        const gid: u32 = @intCast(stb.stbtt_FindGlyphIndex(&font.info, cp));
        const bm = try font.rasterize(testing.allocator, gid);
        defer bm.deinit(testing.allocator);
        if (bm.coverage.len > 0) inked += 1;
    }
    try testing.expectEqual(@as(usize, 94), inked);
}

test "glyph IDs at or past the end of the font are rejected" {
    const bytes = try readFixture(testing.allocator, "assets/font.ttf");
    defer testing.allocator.free(bytes);
    var font = try RuntimeFont.init(testing.allocator, bytes, 16);
    defer font.deinit();
    try testing.expectError(error.GlyphOutOfRange, font.glyphMetrics(font.glyph_count));
}

test "the font keeps its own copy of the file" {
    const source = try readFixture(testing.allocator, "assets/font.ttf");
    var font = try RuntimeFont.init(testing.allocator, source, 16);
    defer font.deinit();
    testing.allocator.free(source);
    const gid: u32 = @intCast(stb.stbtt_FindGlyphIndex(&font.info, 'A'));
    const m = try font.glyphMetrics(gid);
    try testing.expectEqual(@as(u32, 11), m.width);
}

test "pixel height must be positive, finite, and at most max_pixel_height" {
    const bytes = try readFixture(testing.allocator, "assets/font.ttf");
    defer testing.allocator.free(bytes);
    try testing.expectError(error.InvalidPixelHeight, RuntimeFont.init(testing.allocator, bytes, 0));
    try testing.expectError(error.InvalidPixelHeight, RuntimeFont.init(testing.allocator, bytes, -4));
    try testing.expectError(error.InvalidPixelHeight, RuntimeFont.init(testing.allocator, bytes, std.math.nan(f32)));
    try testing.expectError(error.InvalidPixelHeight, RuntimeFont.init(testing.allocator, bytes, std.math.inf(f32)));
    // A finite height this large would overflow HarfBuzz's C int scale (about 5.7e10), so it is refused.
    try testing.expectError(error.InvalidPixelHeight, RuntimeFont.init(testing.allocator, bytes, 1e9));
    try testing.expectError(error.InvalidPixelHeight, RuntimeFont.init(testing.allocator, bytes, max_pixel_height + 1));
    // The bound itself is accepted. Its HarfBuzz scale is 4096 * 2048 / 2288 * 64, rounded: 234646.
    var font = try RuntimeFont.init(testing.allocator, bytes, max_pixel_height);
    defer font.deinit();
    var x_scale: c_int = 0;
    var y_scale: c_int = 0;
    hb.hb_font_get_scale(font.font, &x_scale, &y_scale);
    try testing.expectEqual(@as(c_int, 234646), x_scale);
    try testing.expectEqual(@as(c_int, 234646), y_scale);
}

test "empty, unrecognized, and unsupported containers are rejected" {
    try testing.expectError(error.InvalidFont, RuntimeFont.init(testing.allocator, "", 16));
    try testing.expectError(error.InvalidFont, RuntimeFont.init(testing.allocator, "not a font file at all", 16));
    try testing.expectError(error.UnsupportedFontFormat, RuntimeFont.init(testing.allocator, "OTTO\x00\x00\x00\x00\x00\x00\x00\x00", 16));
    try testing.expectError(error.UnsupportedFontFormat, RuntimeFont.init(testing.allocator, "ttcf\x00\x00\x00\x00\x00\x00\x00\x00", 16));
    // A TrueType header with one table record, 'CFF ', and no 'glyf'.
    const cff_only = [_]u8{ 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 'C', 'F', 'F', ' ', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expectError(error.UnsupportedFontFormat, RuntimeFont.init(testing.allocator, &cff_only, 16));
    // A header that promises five table records and carries none.
    const truncated = [_]u8{ 0, 1, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0 };
    try testing.expectError(error.InvalidFont, RuntimeFont.init(testing.allocator, &truncated, 16));
}

test "repeated create and destroy leaves no allocations behind" {
    const bytes = try readFixture(testing.allocator, "assets/font.ttf");
    defer testing.allocator.free(bytes);
    var round: usize = 0;
    while (round < 20) : (round += 1) {
        var font = try RuntimeFont.init(testing.allocator, bytes, 16);
        font.deinit();
    }
}

/// Serves one file by name, counts the reads, and reports every other name as missing. It stands in for
/// the packaged reader, which the tests cannot point at the repository's assets.
const FixtureReader = struct {
    name: []const u8,
    bytes: []const u8,
    calls: usize = 0,

    fn read(context: *anyopaque, allocator: std.mem.Allocator, relative: []const u8) staging.ReadError![]u8 {
        const self: *FixtureReader = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (!std.mem.eql(u8, relative, self.name)) return error.NotFound;
        return allocator.dupe(u8, self.bytes) catch error.OutOfMemory;
    }

    fn reader(self: *FixtureReader) staging.Reader {
        return .{ .context = self, .read = read };
    }
};

test "a face built through the reader matches the direct load, and the file is read once" {
    const bytes = try readFixture(testing.allocator, "assets/font.ttf");
    defer testing.allocator.free(bytes);
    var source = FixtureReader{ .name = "fonts/font.ttf", .bytes = bytes };
    var font = try RuntimeFont.loadPackaged(testing.allocator, source.reader(), "fonts/font.ttf", 16);
    defer font.deinit();

    try testing.expectEqual(@as(usize, 1), source.calls);
    try testing.expectEqual(bytes.len, font.bytes.len);
    try testing.expectEqual(@as(u32, 2048), font.upem);
    try testing.expectEqual(@as(u32, 4652), font.glyph_count);
    const gid: u32 = @intCast(stb.stbtt_FindGlyphIndex(&font.info, 'A'));
    const m = try font.glyphMetrics(gid);
    try testing.expectApproxEqAbs(@as(f32, 9.5524), m.advance, 0.001);
    try testing.expectEqual(@as(u32, 11), m.width);
}

test "a name the package does not hold is FileNotFound, after one read" {
    var source = FixtureReader{ .name = "fonts/font.ttf", .bytes = "" };
    try testing.expectError(error.FileNotFound, RuntimeFont.loadPackaged(testing.allocator, source.reader(), "fonts/other.ttf", 16));
    try testing.expectEqual(@as(usize, 1), source.calls);
}

test "a bad pixel height is refused before the file is read" {
    var source = FixtureReader{ .name = "fonts/font.ttf", .bytes = "" };
    try testing.expectError(error.InvalidPixelHeight, RuntimeFont.loadPackaged(testing.allocator, source.reader(), "fonts/font.ttf", 0));
    try testing.expectError(error.InvalidPixelHeight, RuntimeFont.loadPackaged(testing.allocator, source.reader(), "fonts/font.ttf", max_pixel_height + 1));
    try testing.expectEqual(@as(usize, 0), source.calls);
}

test "a file that is not a font is rejected, and the bytes the reader gave are freed" {
    // testing.allocator fails the test if the reader's copy is still allocated after the failure.
    var junk = FixtureReader{ .name = "fonts/junk.ttf", .bytes = "not a font file at all" };
    try testing.expectError(error.InvalidFont, RuntimeFont.loadPackaged(testing.allocator, junk.reader(), "fonts/junk.ttf", 16));
    var cff = FixtureReader{ .name = "fonts/cff.otf", .bytes = "OTTO\x00\x00\x00\x00\x00\x00\x00\x00" };
    try testing.expectError(error.UnsupportedFontFormat, RuntimeFont.loadPackaged(testing.allocator, cff.reader(), "fonts/cff.otf", 16));
}

fn failWithReadFailed(context: *anyopaque, allocator: std.mem.Allocator, relative: []const u8) staging.ReadError![]u8 {
    _ = context;
    _ = allocator;
    _ = relative;
    return error.ReadFailed;
}

fn failWithPathTooLong(context: *anyopaque, allocator: std.mem.Allocator, relative: []const u8) staging.ReadError![]u8 {
    _ = context;
    _ = allocator;
    _ = relative;
    return error.PathTooLong;
}

test "the reader's failures keep their meaning through the loader" {
    var marker: u8 = 0;
    try testing.expectError(error.ReadFailed, RuntimeFont.loadPackaged(testing.allocator, .{ .context = &marker, .read = failWithReadFailed }, "fonts/font.ttf", 16));
    try testing.expectError(error.PathTooLong, RuntimeFont.loadPackaged(testing.allocator, .{ .context = &marker, .read = failWithPathTooLong }, "fonts/font.ttf", 16));
}

test "the engine's packaged reader reports a missing font as FileNotFound" {
    try testing.expectError(error.FileNotFound, RuntimeFont.loadPackaged(testing.allocator, staging.packagedReader(), "no_such_runtime_font_for_test.ttf", 16));
}

test "the packaged reader refuses a path that leaves the package folder" {
    try testing.expectError(error.ReadFailed, RuntimeFont.loadPackaged(testing.allocator, staging.packagedReader(), "../assets/font.ttf", 16));
}
