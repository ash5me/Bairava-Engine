//! The texture atlas index: where each sprite sits inside the atlas image. `tools/atlas/pack.c`
//! packs the sprites at build time and writes this index beside the image, and this module reads
//! it back. It loads no image and touches no GPU, so `zig build test` runs its tests.
//!
//! The index has a size line, then one line per sprite:
//!
//!     size 512 512
//!     tile 1 1 320 180
//!     warrior 323 1 80 128
//!
//! Each sprite line gives a name and the sprite's rectangle in texels, measured from the top-left
//! corner of the atlas image.

const std = @import("std");
const strings = @import("string.zig");

/// A rectangle in texels of the atlas image.
pub const Region = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

/// The parsed index. `find` returns a sprite's region by name.
pub const Atlas = struct {
    pub const Error = std.mem.Allocator.Error || strings.Error || error{
        /// The first line is not `size <width> <height>`.
        MissingSize,
        /// A line does not have exactly the fields it should, or a number is not a valid u32.
        BadLine,
        /// Two lines use the same sprite name.
        Duplicate,
        /// A sprite is empty, or reaches past the edge of the atlas.
        OutOfBounds,
    };

    const Entry = struct {
        name: strings.Name,
        region: Region,
    };

    allocator: std.mem.Allocator,
    /// Size of the atlas image in texels, from the size line.
    width: u32,
    height: u32,
    /// Room for one entry per line, which is an upper bound. The first `len` entries are in use.
    entries: []Entry,
    len: usize,

    /// Parses the index text. Blank lines and CRLF line endings are accepted. The text is not kept,
    /// so the caller may free it once this returns. Free the result with `deinit`.
    pub fn parse(allocator: std.mem.Allocator, text: []const u8) Error!Atlas {
        const capacity = std.mem.count(u8, text, "\n") + 1;
        const entries = try allocator.alloc(Entry, capacity);
        errdefer allocator.free(entries);

        var atlas = Atlas{
            .allocator = allocator,
            .width = 0,
            .height = 0,
            .entries = entries,
            .len = 0,
        };
        var have_size = false;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            if (have_size) {
                try atlas.addEntry(line);
            } else {
                const size = try parseSize(line);
                atlas.width = size.w;
                atlas.height = size.h;
                have_size = true;
            }
        }
        if (!have_size) return error.MissingSize;
        return atlas;
    }

    /// Frees the entries. The atlas must not be used afterwards.
    pub fn deinit(self: *Atlas) void {
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    /// The region of the sprite called `name`, or null if the atlas has no such sprite. This is a
    /// linear scan, which is fast enough for the few dozen sprites a game packs.
    pub fn find(self: *const Atlas, name: []const u8) ?Region {
        for (self.entries[0..self.len]) |entry| {
            if (std.mem.eql(u8, entry.name.slice(), name)) return entry.region;
        }
        return null;
    }

    fn addEntry(self: *Atlas, line: []const u8) Error!void {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const name_text = fields.next() orelse return error.BadLine;
        const x = try parseNumber(fields.next() orelse return error.BadLine);
        const y = try parseNumber(fields.next() orelse return error.BadLine);
        const w = try parseNumber(fields.next() orelse return error.BadLine);
        const h = try parseNumber(fields.next() orelse return error.BadLine);
        if (fields.next() != null) return error.BadLine;

        const name = try strings.Name.init(name_text);
        if (w == 0 or h == 0) return error.OutOfBounds;
        // Sum in u64, so a huge x or w can't wrap around and pass the check.
        if (@as(u64, x) + w > self.width or @as(u64, y) + h > self.height) return error.OutOfBounds;
        if (self.find(name_text) != null) return error.Duplicate;

        self.entries[self.len] = .{
            .name = name,
            .region = .{ .x = x, .y = y, .w = w, .h = h },
        };
        self.len += 1;
    }
};

const Size = struct {
    w: u32,
    h: u32,
};

fn parseSize(line: []const u8) Atlas.Error!Size {
    var fields = std.mem.tokenizeAny(u8, line, " \t");
    const keyword = fields.next() orelse return error.MissingSize;
    if (!std.mem.eql(u8, keyword, "size")) return error.MissingSize;
    const w = try parseNumber(fields.next() orelse return error.BadLine);
    const h = try parseNumber(fields.next() orelse return error.BadLine);
    if (fields.next() != null) return error.BadLine;
    if (w == 0 or h == 0) return error.BadLine;
    return .{ .w = w, .h = h };
}

fn parseNumber(text: []const u8) Atlas.Error!u32 {
    return std.fmt.parseInt(u32, text, 10) catch error.BadLine;
}

fn expectRegion(expected: Region, actual: ?Region) !void {
    const got = actual orelse return error.TestExpectedRegion;
    try std.testing.expectEqual(expected.x, got.x);
    try std.testing.expectEqual(expected.y, got.y);
    try std.testing.expectEqual(expected.w, got.w);
    try std.testing.expectEqual(expected.h, got.h);
}

test "parse reads the size and each sprite's rectangle" {
    const text =
        \\size 512 256
        \\tile 1 1 320 180
        \\warrior 323 1 80 128
        \\
    ;
    var atlas = try Atlas.parse(std.testing.allocator, text);
    defer atlas.deinit();

    try std.testing.expectEqual(@as(u32, 512), atlas.width);
    try std.testing.expectEqual(@as(u32, 256), atlas.height);
    try expectRegion(.{ .x = 1, .y = 1, .w = 320, .h = 180 }, atlas.find("tile"));
    try expectRegion(.{ .x = 323, .y = 1, .w = 80, .h = 128 }, atlas.find("warrior"));
    try std.testing.expect(atlas.find("missing") == null);
}

test "CRLF line endings and blank lines are accepted" {
    const text = "size 64 64\r\n\r\ntile 0 0 16 16\r\n\r\n";
    var atlas = try Atlas.parse(std.testing.allocator, text);
    defer atlas.deinit();

    try expectRegion(.{ .x = 0, .y = 0, .w = 16, .h = 16 }, atlas.find("tile"));
}

test "a missing or malformed size line is rejected" {
    const testing = std.testing;
    try testing.expectError(error.MissingSize, Atlas.parse(testing.allocator, ""));
    try testing.expectError(error.MissingSize, Atlas.parse(testing.allocator, "tile 0 0 16 16\n"));
    try testing.expectError(error.BadLine, Atlas.parse(testing.allocator, "size 64\n"));
    try testing.expectError(error.BadLine, Atlas.parse(testing.allocator, "size 0 64\n"));
}

test "malformed sprite lines are rejected" {
    const testing = std.testing;
    try testing.expectError(error.BadLine, Atlas.parse(testing.allocator, "size 64 64\ntile 0 0 16\n"));
    try testing.expectError(error.BadLine, Atlas.parse(testing.allocator, "size 64 64\ntile 0 0 16 16 extra\n"));
    try testing.expectError(error.BadLine, Atlas.parse(testing.allocator, "size 64 64\ntile 0 0 sixteen 16\n"));
    try testing.expectError(error.BadCharacter, Atlas.parse(testing.allocator, "size 64 64\nTile 0 0 16 16\n"));
}

test "a sprite that reaches past the atlas edge is rejected" {
    const testing = std.testing;
    try testing.expectError(error.OutOfBounds, Atlas.parse(testing.allocator, "size 64 64\ntile 60 0 16 16\n"));
    try testing.expectError(error.OutOfBounds, Atlas.parse(testing.allocator, "size 64 64\ntile 0 0 0 16\n"));
    // The sum overflows u32 but must still be caught.
    try testing.expectError(error.OutOfBounds, Atlas.parse(testing.allocator, "size 64 64\ntile 4294967295 0 2 2\n"));
}

test "a duplicate sprite name is rejected" {
    const testing = std.testing;
    try testing.expectError(error.Duplicate, Atlas.parse(testing.allocator, "size 64 64\ntile 0 0 16 16\ntile 16 0 16 16\n"));
}
