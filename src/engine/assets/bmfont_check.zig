//! BMFont descriptor checks for the asset tools (plan Phase 2, item 4).
//!
//! A descriptor is parsed and validated by text/bmfont.zig. Each page image is then checked against the descriptor's
//! atlas size, using the PNG header that validate.zig reads. The caller reads the page files and passes their sizes, so
//! this file does no file I/O.
//!
//! Issues go into the same `validate.Report` the other asset checks use. A problem in the descriptor text carries the
//! line it is on. A page problem uses line 0, because the parser keeps no line numbers for pages.
//!
//! Messages are built in `arena`. The report keeps slices into it, so the caller must keep the arena alive until the
//! report has been printed.

const std = @import("std");
const bmfont = @import("../text/bmfont.zig");
const validate = @import("validate.zig");

/// Checks the BMFont descriptor `text`, read from `path`. `page_images[i]` is the PNG size of the image for the page with
/// the `i`th smallest id, or null when that file is missing or is not a PNG. Pass one entry per declared page.
pub fn checkDescriptor(arena: std.mem.Allocator, path: []const u8, text: []const u8, page_images: []const ?validate.ImageSize, report: *validate.Report) void {
    var diagnostic: bmfont.Diagnostic = .{};
    var font = bmfont.parse(arena, text, .{}, &diagnostic) catch |err| {
        report.add(path, @intCast(diagnostic.line), describeFailure(arena, err, diagnostic));
        return;
    };
    defer font.deinit();
    checkPages(arena, path, &font, page_images, report);
}

fn checkPages(arena: std.mem.Allocator, path: []const u8, font: *const bmfont.Font, page_images: []const ?validate.ImageSize, report: *validate.Report) void {
    if (page_images.len != font.pages.len) {
        const text = message(arena, "{d} page image(s) were given, but the descriptor declares {d} page(s)", .{ page_images.len, font.pages.len }, "the page images do not match the declared pages");
        report.add(path, 0, text);
        return;
    }
    for (font.pages, page_images) |page, image| {
        const size = image orelse {
            const text = message(arena, "the image for page {d} is missing or is not a PNG", .{page.id}, "a page image is missing or is not a PNG");
            report.add(path, 0, text);
            continue;
        };
        if (size.w != font.scale_w or size.h != font.scale_h) {
            const text = message(arena, "page {d} is {d}x{d}, but scaleW and scaleH give {d}x{d}", .{ page.id, size.w, size.h, font.scale_w, font.scale_h }, "a page image is not the size the descriptor gives");
            report.add(path, 0, text);
        }
    }
}

/// The formatted message, or `fallback` when the arena cannot hold it.
fn message(arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype, fallback: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, fmt, args) catch fallback;
}

/// The text of a parse failure. A kerning failure names its pair, and the missing id when there is one.
fn describeFailure(arena: std.mem.Allocator, err: bmfont.ParseError, diagnostic: bmfont.Diagnostic) []const u8 {
    return switch (err) {
        error.UnmappedKerning => message(arena, "kerning pair {d} {d} names glyph {d}, which the font does not map", .{ diagnostic.kerning_first, diagnostic.kerning_second, diagnostic.unmapped_id }, literalFor(err)),
        error.DuplicateKerning => message(arena, "kerning pair {d} {d} appears twice", .{ diagnostic.kerning_first, diagnostic.kerning_second }, literalFor(err)),
        else => literalFor(err),
    };
}

fn literalFor(err: bmfont.ParseError) []const u8 {
    return switch (err) {
        error.OutOfMemory => "the descriptor could not be read: out of memory",
        error.MalformedLine => "the line is not a tag followed by key=value fields, or a quote is not closed",
        error.UnknownTag => "the tag is not one the font importer reads",
        error.DuplicateSection => "a section appears more than once",
        error.MissingSection => "a required section (info, common, page, or chars) is missing",
        error.MissingKey => "a required key is missing from its line",
        error.BadValue => "a value is not a number in its allowed range",
        error.CountMismatch => "a declared count does not match the lines that follow it",
        error.DuplicatePage => "two pages have the same id",
        error.PageOutOfRange => "a page id or a glyph's page is outside the declared pages",
        error.GlyphOutsideAtlas => "a glyph's rectangle extends past the atlas",
        error.InvalidCodepoint => "a codepoint is not a Unicode scalar value",
        error.DuplicateCodepoint => "two glyphs have the same codepoint",
        error.DuplicateKerning => "a kerning pair appears more than once",
        error.UnmappedKerning => "a kerning pair names a glyph the font does not map",
        error.MissingFallback => "the fallback glyph is missing",
    };
}

// ---- tests -----------------------------------------------------------------------------------------------------------

const testing = std.testing;

/// One glyph, one page, a 128 by 48 atlas. Line 5 is the glyph.
const descriptor = "info size=8\ncommon lineHeight=8 base=7 scaleW=128 scaleH=48 pages=1\npage id=0 file=\"p.png\"\nchars count=1\nchar id=63 x=0 y=0 width=8 height=8 xoffset=0 yoffset=0 xadvance=8 page=0\n";

fn onlyIssue(report: *const validate.Report) !validate.Issue {
    try testing.expectEqual(@as(usize, 1), report.count);
    return report.slice()[0];
}

test "a descriptor whose page matches its atlas size passes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var report = validate.Report{};
    const images = [_]?validate.ImageSize{.{ .w = 128, .h = 48 }};
    checkDescriptor(arena_state.allocator(), "font.fnt", descriptor, &images, &report);
    try testing.expect(report.ok());
}

test "a page image of the wrong size is reported, and the message names the page" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var report = validate.Report{};
    const images = [_]?validate.ImageSize{.{ .w = 256, .h = 48 }};
    checkDescriptor(arena_state.allocator(), "font.fnt", descriptor, &images, &report);
    const issue = try onlyIssue(&report);
    try testing.expect(std.mem.indexOf(u8, issue.message, "page 0") != null);
}

test "a missing page image is reported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var report = validate.Report{};
    const images = [_]?validate.ImageSize{null};
    checkDescriptor(arena_state.allocator(), "font.fnt", descriptor, &images, &report);
    _ = try onlyIssue(&report);
}

test "a page-image count that disagrees with the descriptor is reported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var report = validate.Report{};
    const images = [_]?validate.ImageSize{ .{ .w = 128, .h = 48 }, .{ .w = 128, .h = 48 } };
    checkDescriptor(arena_state.allocator(), "font.fnt", descriptor, &images, &report);
    _ = try onlyIssue(&report);
}

test "an unmapped kerning pair is reported with its pair, its line, and the missing id" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var report = validate.Report{};
    // Line 6 is the kernings count, and line 7 is the pair. The second glyph, 66, is not in the font.
    const text = descriptor ++ "kernings count=1\nkerning first=63 second=66 amount=-1\n";
    const images = [_]?validate.ImageSize{.{ .w = 128, .h = 48 }};
    checkDescriptor(arena_state.allocator(), "font.fnt", text, &images, &report);
    const issue = try onlyIssue(&report);
    try testing.expectEqual(@as(u32, 7), issue.line);
    try testing.expect(std.mem.indexOf(u8, issue.message, "kerning pair 63 66") != null);
    try testing.expect(std.mem.indexOf(u8, issue.message, "names glyph 66") != null);
}

test "a malformed descriptor is reported at the line that is wrong" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var report = validate.Report{};
    const images = [_]?validate.ImageSize{.{ .w = 128, .h = 48 }};
    checkDescriptor(arena_state.allocator(), "font.fnt", "info size=8\nbogus x=1\n", &images, &report);
    const issue = try onlyIssue(&report);
    try testing.expectEqual(@as(u32, 2), issue.line);
}
