//! Maps bitmap-font UTF-8 input to one codepoint glyph at a time.
//!
//! This deliberately has no ligatures or complex-script shaping. A missing codepoint uses the font's validated
//! fallback glyph. The cluster is the input byte offset; kerning is applied before the current glyph's advance.

const std = @import("std");
const bmfont = @import("bmfont.zig");

pub const MappedGlyph = struct {
    glyph: *const bmfont.Glyph,
    /// Byte offset in the source UTF-8 string.
    cluster: usize,
    /// Pen position after kerning with the preceding mapped codepoint.
    pen: f32,
    /// The current glyph advance including the preceding pair's kerning adjustment.
    advance: f32,
};

pub const Mapper = struct {
    font: *const bmfont.Font,
    text: []const u8,
    byte_offset: usize = 0,
    pen: f32 = 0,
    previous: ?u32 = null,

    pub fn init(font: *const bmfont.Font, text: []const u8) Mapper {
        return .{ .font = font, .text = text };
    }

    pub fn next(self: *Mapper) ?MappedGlyph {
        if (self.byte_offset >= self.text.len) return null;
        const cluster = self.byte_offset;
        const decoded = decodeNext(self.text, &self.byte_offset);
        const glyph_codepoint = if (self.font.glyphFor(decoded) != null) decoded else self.font.fallback;
        const glyph = self.font.glyphFor(glyph_codepoint) orelse unreachable;
        const kerning: f32 = if (self.previous) |previous|
            @floatFromInt(self.font.kerningFor(previous, glyph_codepoint))
        else
            0;
        self.pen += kerning;
        const mapped = MappedGlyph{
            .glyph = glyph,
            .cluster = cluster,
            .pen = self.pen,
            .advance = kerning + @as(f32, @floatFromInt(glyph.x_advance)),
        };
        self.pen += @floatFromInt(glyph.x_advance);
        self.previous = glyph_codepoint;
        return mapped;
    }

    pub fn width(self: *Mapper) f32 {
        while (self.next()) |_| {}
        return self.pen;
    }
};

fn decodeNext(text: []const u8, offset: *usize) u32 {
    const start = offset.*;
    const first = text[start];
    if (first < 0x80) {
        offset.* += 1;
        return first;
    }
    const length = std.unicode.utf8ByteSequenceLength(first) catch {
        offset.* += 1;
        return 0xFFFD;
    };
    if (length > text.len - start) {
        offset.* += 1;
        return 0xFFFD;
    }
    const codepoint = std.unicode.utf8Decode(text[start .. start + length]) catch {
        offset.* += 1;
        return 0xFFFD;
    };
    offset.* += length;
    return @intCast(codepoint);
}

test "bitmap mapping preserves byte clusters, kerning, and fallback advances" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const text =
        \\info face="Fixture" size=8 padding=0,0,0,0
        \\common lineHeight=8 base=7 scaleW=16 scaleH=8 pages=1
        \\page id=0 file="page.png"
        \\chars count=2
        \\char id=63 x=0 y=0 width=8 height=8 xoffset=0 yoffset=0 xadvance=8 page=0 chnl=15
        \\char id=65 x=8 y=0 width=8 height=8 xoffset=-1 yoffset=0 xadvance=8 page=0 chnl=15
        \\kernings count=1
        \\kerning first=65 second=65 amount=-1
    ;
    var font = try bmfont.parse(allocator, text, .{}, null);
    defer font.deinit();

    var mapper = Mapper.init(&font, "Aé?");
    const a = mapper.next().?;
    const replacement = mapper.next().?;
    const question = mapper.next().?;
    try testing.expectEqual(@as(usize, 0), a.cluster);
    try testing.expectEqual(@as(usize, 1), replacement.cluster);
    try testing.expectEqual(@as(usize, 3), question.cluster);
    try testing.expectEqual(@as(u32, 'A'), a.glyph.codepoint);
    try testing.expectEqual(@as(u32, '?'), replacement.glyph.codepoint);
    try testing.expectEqual(@as(f32, 8), replacement.advance);
    try testing.expectEqual(@as(f32, 24), mapper.pen);

    var kerned = Mapper.init(&font, "AA");
    _ = kerned.next();
    const second = kerned.next().?;
    try testing.expectEqual(@as(f32, 7), second.advance);
    try testing.expectEqual(@as(f32, 15), kerned.pen);
}
