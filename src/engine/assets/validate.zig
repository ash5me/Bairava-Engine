//! Asset validation: checks the asset manifest, the sprite list, and the atlas index, and reports each
//! problem with its file, its line, and a fixed reason. Every check here is pure. It reads text it is
//! given and asks a `Files` value whether a file exists, so the same rules run in the
//! `zig build check-assets` tool, in the engine when it loads an atlas, and in tests with no disk.
//!
//! A check keeps going after an issue, so one run reports every problem it can find, up to `max_issues`.
//! Line 0 means the problem is about the whole file. See docs/asset-validation.md for the rules.

const std = @import("std");
const strings = @import("../memory/string.zig");

/// Issues kept in one report. Later issues are counted in `Report.overflow`.
pub const max_issues = 64;
/// Most whitespace-separated fields one line may have. A line with more is reported.
const max_fields = 12;
/// Most names one file may declare. A file with more is reported.
const max_names = 256;

/// One problem: the file it is in, the line (0 for the whole file), and the reason.
pub const Issue = struct {
    path: []const u8,
    line: u32,
    message: []const u8,
};

pub const Report = struct {
    items: [max_issues]Issue = undefined,
    count: usize = 0,
    /// Issues found after the list was full. They are counted, not kept.
    overflow: u32 = 0,

    pub fn add(self: *Report, path: []const u8, line: u32, message: []const u8) void {
        if (self.count == max_issues) {
            self.overflow += 1;
            return;
        }
        self.items[self.count] = .{ .path = path, .line = line, .message = message };
        self.count += 1;
    }

    /// True when no issue was found.
    pub fn ok(self: *const Report) bool {
        return self.count == 0 and self.overflow == 0;
    }

    pub fn slice(self: *const Report) []const Issue {
        return self.items[0..self.count];
    }
};

/// Answers whether a project file exists. The tool and the engine answer from the disk; tests answer
/// from a list.
pub const Files = struct {
    context: *anyopaque,
    exists: *const fn (context: *anyopaque, path: []const u8) bool,

    pub fn has(self: Files, path: []const u8) bool {
        return self.exists(self.context, path);
    }
};

/// The size of an image in pixels.
pub const ImageSize = struct {
    w: u32,
    h: u32,
};

/// The asset types a manifest line may name, and the file formats each accepts.
pub const image_exts = [_][]const u8{ "png", "jpg", "jpeg", "bmp", "tga" };
pub const audio_exts = [_][]const u8{"wav"};
pub const font_exts = [_][]const u8{ "ttf", "otf" };
pub const map_exts = [_][]const u8{"txt"};

/// True when `path` can name a file inside the project: relative, with forward slashes, no drive or
/// URL prefix, no empty or `.`/`..` segments, and no trailing slash. Paths from manifests are checked
/// with this before anything reads them.
pub fn isSafePath(path: []const u8) bool {
    if (path.len == 0 or path.len > 255) return false;
    if (path[0] == '/' or path[0] == '\\') return false;
    if (std.mem.indexOfScalar(u8, path, ':') != null) return false;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn validName(name: []const u8) bool {
    _ = strings.Name.init(name) catch return false;
    return true;
}

fn parseU32(text: []const u8) ?u32 {
    return std.fmt.parseInt(u32, text, 10) catch null;
}

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, name)) return true;
    }
    return false;
}

/// True when the file's extension (case ignored) is one of `allowed`.
fn hasExtension(path: []const u8, allowed: []const []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
    if (dot < slash) return false;
    const ext = path[dot + 1 ..];
    for (allowed) |want| {
        if (std.ascii.eqlIgnoreCase(ext, want)) return true;
    }
    return false;
}

/// The whitespace-separated fields of one line.
const Fields = struct {
    items: [max_fields][]const u8 = undefined,
    len: usize = 0,
    /// True when the line has more fields than `items` holds.
    too_many: bool = false,

    fn of(line: []const u8) Fields {
        var out = Fields{};
        var it = std.mem.tokenizeAny(u8, line, " \t\r");
        while (it.next()) |word| {
            if (out.len == max_fields) {
                out.too_many = true;
                break;
            }
            out.items[out.len] = word;
            out.len += 1;
        }
        return out;
    }

    fn at(self: *const Fields, index: usize) ?[]const u8 {
        return if (index < self.len) self.items[index] else null;
    }
};

// ---- Asset manifest ----------------------------------------------------------------------------------

const kinds = [_][]const u8{ "image", "audio", "wav", "font", "map", "file" };

fn isKnownKind(kind: []const u8) bool {
    return contains(&kinds, kind);
}

/// The one format rule each kind has, as a fixed reason.
fn formatMessage(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "image")) return "image source must be png, jpg, jpeg, bmp, or tga";
    if (std.mem.eql(u8, kind, "audio") or std.mem.eql(u8, kind, "wav")) return "audio source must be a wav file";
    if (std.mem.eql(u8, kind, "font")) return "font source must be a ttf or otf file";
    return "map source must be a txt file";
}

fn formatAccepted(kind: []const u8, source: []const u8) bool {
    if (std.mem.eql(u8, kind, "image")) return hasExtension(source, &image_exts);
    if (std.mem.eql(u8, kind, "audio") or std.mem.eql(u8, kind, "wav")) return hasExtension(source, &audio_exts);
    if (std.mem.eql(u8, kind, "font")) return hasExtension(source, &font_exts);
    if (std.mem.eql(u8, kind, "map")) return hasExtension(source, &map_exts);
    return true; // `file` takes any format.
}

/// Checks the asset manifest: `name type source output dependencies`, one asset per line. A font line
/// adds `pixel_height first_codepoint glyph_count [bitmap|sdf]` after the dependencies. Names must be
/// valid and unique. Types must be known. A source must exist, be inside the project, and have a format
/// its type accepts. Each dependency must name an asset declared in the same manifest.
pub fn checkManifest(path: []const u8, text: []const u8, files: Files, report: *Report) void {
    var names: [max_names][]const u8 = undefined;
    var name_count: usize = 0;

    // Names first, so a dependency can name an asset that is declared on a later line.
    var number: u32 = 0;
    var first = std.mem.splitScalar(u8, text, '\n');
    while (first.next()) |raw| {
        number += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const first_fields = Fields.of(line);
        const name = first_fields.at(0) orelse continue;
        if (!validName(name)) {
            report.add(path, number, "asset name must start with a lowercase letter or digit and use only lowercase letters, digits, '_', or '-'");
            continue;
        }
        if (contains(names[0..name_count], name)) {
            report.add(path, number, "duplicate asset name");
            continue;
        }
        if (name_count == max_names) {
            report.add(path, number, "too many assets in one manifest");
            return;
        }
        names[name_count] = name;
        name_count += 1;
    }

    number = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        number += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        checkManifestLine(path, number, line, names[0..name_count], files, report);
    }
}

fn checkManifestLine(path: []const u8, number: u32, line: []const u8, declared: []const []const u8, files: Files, report: *Report) void {
    const fields = Fields.of(line);
    if (fields.too_many) {
        report.add(path, number, "too many fields on one line");
        return;
    }
    if (fields.len < 5) {
        report.add(path, number, "a manifest line is: name type source output dependencies");
        return;
    }
    const kind = fields.items[1];
    const source = fields.items[2];
    const output = fields.items[3];
    const deps = fields.items[4];

    if (!isKnownKind(kind)) {
        report.add(path, number, "unknown asset type (use image, audio, wav, font, map, or file)");
        return;
    }
    if (!isSafePath(source)) {
        report.add(path, number, "source path must be relative, inside the project, and free of '..'");
    } else if (!files.has(source)) {
        report.add(path, number, "source file does not exist");
    } else if (!formatAccepted(kind, source)) {
        report.add(path, number, formatMessage(kind));
    }
    if (!isSafePath(output)) {
        report.add(path, number, "output path must be relative, inside the project, and free of '..'");
    }
    if (!std.mem.eql(u8, deps, "-")) {
        var parts = std.mem.splitScalar(u8, deps, ',');
        while (parts.next()) |dep| {
            if (!contains(declared, dep)) report.add(path, number, "dependency names an asset this manifest does not declare");
        }
    }

    if (std.mem.eql(u8, kind, "font")) {
        checkFontFields(path, number, fields, report);
    } else if (fields.len != 5) {
        report.add(path, number, "this asset type takes five fields: name type source output dependencies");
    }
}

fn checkFontFields(path: []const u8, number: u32, fields: Fields, report: *Report) void {
    if (fields.len != 8 and fields.len != 9) {
        report.add(path, number, "a font line is: name font source output deps pixel_height first_codepoint glyph_count [mode]");
        return;
    }
    const px = std.fmt.parseFloat(f32, fields.items[5]) catch -1.0;
    if (!(px > 0)) report.add(path, number, "font pixel height must be a number above 0");
    if (parseU32(fields.items[6]) == null) report.add(path, number, "font first codepoint must be a whole number");
    const glyphs = parseU32(fields.items[7]) orelse 0;
    if (glyphs == 0) report.add(path, number, "font glyph count must be a whole number above 0");
    if (fields.len == 9) {
        const mode = fields.items[8];
        if (!std.mem.eql(u8, mode, "bitmap") and !std.mem.eql(u8, mode, "sdf")) {
            report.add(path, number, "font mode must be bitmap or sdf");
        }
    }
}

// ---- Sprite list ---------------------------------------------------------------------------------------

/// Checks the sprite list: `name path`, one sprite per line. Names must be valid and unique. Each image
/// must exist, be inside the project, and have a format the atlas packer accepts.
pub fn checkSprites(path: []const u8, text: []const u8, files: Files, report: *Report) void {
    var names: [max_names][]const u8 = undefined;
    var name_count: usize = 0;
    var number: u32 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        number += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const fields = Fields.of(line);
        if (fields.too_many or fields.len != 2) {
            report.add(path, number, "a sprite line is: name image-path");
            continue;
        }
        const name = fields.items[0];
        const image = fields.items[1];
        if (!validName(name)) {
            report.add(path, number, "sprite name must start with a lowercase letter or digit and use only lowercase letters, digits, '_', or '-'");
            continue;
        }
        if (contains(names[0..name_count], name)) {
            report.add(path, number, "duplicate sprite name");
            continue;
        }
        if (!isSafePath(image)) {
            report.add(path, number, "image path must be relative, inside the project, and free of '..'");
        } else if (!files.has(image)) {
            report.add(path, number, "image file does not exist");
        } else if (!hasExtension(image, &image_exts)) {
            report.add(path, number, formatMessage("image"));
        }
        if (name_count < max_names) {
            names[name_count] = name;
            name_count += 1;
        } else {
            report.add(path, number, "too many sprites in one list");
            return;
        }
    }
}

// ---- Atlas index -----------------------------------------------------------------------------------------

/// Checks an atlas index: `size W H`, then one `name x y w h` line per sprite. Each sprite needs a valid,
/// unique name, a nonzero size, and a rectangle inside the atlas. When `image` is given, the size line must
/// match it, so an index and its image are checked together.
pub fn checkAtlasIndex(path: []const u8, text: []const u8, image: ?ImageSize, report: *Report) void {
    var size: ?ImageSize = null;
    var names: [max_names][]const u8 = undefined;
    var name_count: usize = 0;
    var number: u32 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        number += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const fields = Fields.of(line);

        if (size == null) {
            if (fields.too_many or fields.len != 3 or !std.mem.eql(u8, fields.items[0], "size")) {
                report.add(path, number, "the first line must be: size <width> <height>");
                return;
            }
            const w = parseU32(fields.items[1]) orelse 0;
            const h = parseU32(fields.items[2]) orelse 0;
            if (w == 0 or h == 0) {
                report.add(path, number, "atlas width and height must be whole numbers above 0");
                return;
            }
            size = .{ .w = w, .h = h };
            if (image) |img| {
                if (img.w != w or img.h != h) report.add(path, number, "the atlas size does not match its image");
            }
            continue;
        }

        const sz = size.?;
        if (fields.too_many or fields.len != 5) {
            report.add(path, number, "a sprite line is: name x y w h");
            continue;
        }
        const name = fields.items[0];
        if (!validName(name)) {
            report.add(path, number, "sprite name must start with a lowercase letter or digit and use only lowercase letters, digits, '_', or '-'");
            continue;
        }
        if (contains(names[0..name_count], name)) {
            report.add(path, number, "duplicate sprite name");
            continue;
        }
        if (name_count == max_names) {
            report.add(path, number, "too many sprites in one atlas");
            return;
        }
        names[name_count] = name;
        name_count += 1;
        const x = parseU32(fields.items[1]) orelse {
            report.add(path, number, "sprite x must be a whole number");
            continue;
        };
        const y = parseU32(fields.items[2]) orelse {
            report.add(path, number, "sprite y must be a whole number");
            continue;
        };
        const w = parseU32(fields.items[3]) orelse {
            report.add(path, number, "sprite width must be a whole number above 0");
            continue;
        };
        const h = parseU32(fields.items[4]) orelse {
            report.add(path, number, "sprite height must be a whole number above 0");
            continue;
        };
        if (w == 0 or h == 0) {
            report.add(path, number, "sprite width and height must be above 0");
            continue;
        }
        // The sums are taken in 64 bits, so a huge x or y cannot wrap around and pass the check.
        if (@as(u64, x) + w > sz.w or @as(u64, y) + h > sz.h) {
            report.add(path, number, "sprite reaches past the edge of the atlas");
            continue;
        }
    }
    if (size == null) report.add(path, 0, "the file has no size line");
}

/// The size of a PNG image, read from its header. Null when the bytes are not a PNG with a nonzero size.
pub fn pngSize(bytes: []const u8) ?ImageSize {
    const signature = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };
    if (bytes.len < 24) return null;
    if (!std.mem.eql(u8, bytes[0..8], &signature)) return null;
    if (!std.mem.eql(u8, bytes[12..16], "IHDR")) return null;
    const w = std.mem.readInt(u32, bytes[16..][0..4], .big);
    const h = std.mem.readInt(u32, bytes[20..][0..4], .big);
    if (w == 0 or h == 0) return null;
    return .{ .w = w, .h = h };
}

// ---- Tests ---------------------------------------------------------------------------------------------

/// A file list for the tests: these paths exist, and every other path does not.
const FakeFiles = struct {
    const present = [_][]const u8{ "assets/tile.png", "assets/warrior.png", "assets/font.ttf", "assets/wind1.wav", "assets/maps/level1.txt" };
    var marker: u8 = 0;

    fn exists(context: *anyopaque, path: []const u8) bool {
        _ = context;
        return contains(&present, path);
    }

    fn files() Files {
        return .{ .context = &marker, .exists = &exists };
    }
};

test "a clean manifest reports nothing" {
    const text =
        \\# name type source output dependencies
        \\tile image assets/tile.png tile.png -
        \\warrior image assets/warrior.png warrior.png -
        \\font font assets/font.ttf font.ttf - 10 32 224
        \\wind1 audio assets/wind1.wav wind1.wav -
        \\level1 map assets/maps/level1.txt maps/level1.txt tile
        \\
    ;
    var report = Report{};
    checkManifest("assets/asset_manifest.txt", text, FakeFiles.files(), &report);
    try std.testing.expect(report.ok());
}

test "a manifest reports a duplicate name, a missing source, and an unknown type, each on its line" {
    const text =
        \\tile image assets/tile.png tile.png -
        \\tile image assets/tile.png tile.png -
        \\warrior image assets/missing.png warrior.png -
        \\bad sprocket assets/tile.png x.png -
        \\
    ;
    var report = Report{};
    checkManifest("assets/asset_manifest.txt", text, FakeFiles.files(), &report);
    try std.testing.expectEqual(@as(usize, 3), report.count);
    try std.testing.expectEqual(@as(u32, 2), report.items[0].line);
    try std.testing.expectEqualStrings("duplicate asset name", report.items[0].message);
    try std.testing.expectEqual(@as(u32, 3), report.items[1].line);
    try std.testing.expectEqualStrings("source file does not exist", report.items[1].message);
    try std.testing.expectEqual(@as(u32, 4), report.items[2].line);
}

test "a source with the wrong format, an unsafe path, and a bad font line are each reported" {
    const text =
        \\tile image assets/wind1.wav tile.png -
        \\warrior image ../secret.png warrior.png -
        \\font font assets/font.ttf font.ttf - 0 32 224
        \\wind1 audio assets/wind1.wav wind1.wav nothere
        \\
    ;
    var report = Report{};
    checkManifest("assets/asset_manifest.txt", text, FakeFiles.files(), &report);
    try std.testing.expectEqual(@as(usize, 4), report.count);
    try std.testing.expectEqualStrings("image source must be png, jpg, jpeg, bmp, or tga", report.items[0].message);
    try std.testing.expectEqualStrings("source path must be relative, inside the project, and free of '..'", report.items[1].message);
    try std.testing.expectEqualStrings("font pixel height must be a number above 0", report.items[2].message);
    try std.testing.expectEqualStrings("dependency names an asset this manifest does not declare", report.items[3].message);
}

test "a dependency may name an asset declared on a later line" {
    const text =
        \\level1 map assets/maps/level1.txt maps/level1.txt tile
        \\tile image assets/tile.png tile.png -
        \\
    ;
    var report = Report{};
    checkManifest("assets/asset_manifest.txt", text, FakeFiles.files(), &report);
    try std.testing.expect(report.ok());
}

test "a font mode other than bitmap or sdf is reported" {
    const text = "font font assets/font.ttf font.ttf - 10 32 224 wobble\n";
    var report = Report{};
    checkManifest("assets/asset_manifest.txt", text, FakeFiles.files(), &report);
    try std.testing.expectEqualStrings("font mode must be bitmap or sdf", report.items[0].message);
}

test "a clean sprite list reports nothing, and a duplicate or missing image is reported" {
    var report = Report{};
    checkSprites("assets/sprites.txt", "tile assets/tile.png\nwarrior assets/warrior.png\n", FakeFiles.files(), &report);
    try std.testing.expect(report.ok());

    var bad = Report{};
    checkSprites("assets/sprites.txt", "tile assets/tile.png\ntile assets/warrior.png\nghost assets/ghost.png\n", FakeFiles.files(), &bad);
    try std.testing.expectEqual(@as(usize, 2), bad.count);
    try std.testing.expectEqual(@as(u32, 2), bad.items[0].line);
    try std.testing.expectEqual(@as(u32, 3), bad.items[1].line);
}

test "a clean atlas index reports nothing, and matches its image" {
    const text = "size 64 64\ntile 1 1 16 16\nwarrior 20 1 16 32\n";
    var report = Report{};
    checkAtlasIndex("assets/atlas.txt", text, .{ .w = 64, .h = 64 }, &report);
    try std.testing.expect(report.ok());
}

test "an atlas sprite past the edge, a duplicate, and a zero size are each reported with a line" {
    const text = "size 64 64\ntile 60 0 16 16\ntile 0 0 8 8\nwide 0 0 0 4\n";
    var report = Report{};
    checkAtlasIndex("assets/atlas.txt", text, null, &report);
    try std.testing.expectEqual(@as(usize, 3), report.count);
    try std.testing.expectEqual(@as(u32, 2), report.items[0].line);
    try std.testing.expectEqualStrings("sprite reaches past the edge of the atlas", report.items[0].message);
    try std.testing.expectEqual(@as(u32, 3), report.items[1].line);
    try std.testing.expectEqualStrings("duplicate sprite name", report.items[1].message);
    try std.testing.expectEqual(@as(u32, 4), report.items[2].line);
}

test "an atlas whose size differs from its image is reported, and a missing size line is too" {
    var report = Report{};
    checkAtlasIndex("assets/atlas.txt", "size 64 32\n", .{ .w = 64, .h = 64 }, &report);
    try std.testing.expectEqualStrings("the atlas size does not match its image", report.items[0].message);

    var missing = Report{};
    checkAtlasIndex("assets/atlas.txt", "tile 0 0 16 16\n", null, &missing);
    try std.testing.expectEqualStrings("the first line must be: size <width> <height>", missing.items[0].message);
}

test "a sprite that overflows 32-bit sums is still caught" {
    var report = Report{};
    checkAtlasIndex("assets/atlas.txt", "size 64 64\ntile 4294967295 0 2 2\n", null, &report);
    try std.testing.expectEqualStrings("sprite reaches past the edge of the atlas", report.items[0].message);
}

test "safe paths stay inside the project" {
    try std.testing.expect(isSafePath("assets/tile.png"));
    try std.testing.expect(!isSafePath(""));
    try std.testing.expect(!isSafePath("/etc/passwd"));
    try std.testing.expect(!isSafePath("\\windows"));
    try std.testing.expect(!isSafePath("C:/x.png"));
    try std.testing.expect(!isSafePath("assets/../secret.png"));
    try std.testing.expect(!isSafePath("assets/./tile.png"));
    try std.testing.expect(!isSafePath("assets//tile.png"));
    try std.testing.expect(!isSafePath("assets/"));
    try std.testing.expect(!isSafePath("assets\\tile.png"));
}

test "a report keeps its first issues and counts the rest" {
    var report = Report{};
    var i: usize = 0;
    while (i < max_issues + 2) : (i += 1) report.add("a.txt", 1, "x");
    try std.testing.expectEqual(@as(usize, max_issues), report.count);
    try std.testing.expectEqual(@as(u32, 2), report.overflow);
    try std.testing.expect(!report.ok());
}

test "the PNG size is read from the header, and anything else is refused" {
    var header = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 'I', 'H', 'D', 'R', 0, 0, 1, 0, 0, 0, 0, 128 };
    const size = pngSize(&header).?;
    try std.testing.expectEqual(@as(u32, 256), size.w);
    try std.testing.expectEqual(@as(u32, 128), size.h);
    header[0] = 0;
    try std.testing.expect(pngSize(&header) == null);
    try std.testing.expect(pngSize("short") == null);
}
