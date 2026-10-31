const std = @import("std");

const c = @import("../../platform/sdl/sdl.zig").c;

// Declarations only. The implementation is compiled from vendor/stb_image_impl.c.
const stb = @cImport({
    @cInclude("stb_image.h");
});

/// A decoded image in RGBA8 format, 4 bytes per pixel, row 0 at the top.
pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []u8,

    pub fn deinit(self: *Image) void {
        stb.stbi_image_free(@ptrCast(self.pixels.ptr));
    }
};

pub const Compression = enum(u8) { rgba8 = 0, bc1 = 1, bc3 = 2, astc_4x4 = 3 };

/// A block-compressed texture read from the asset builder's BRTX container.
pub const CompressedImage = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    format: Compression,
    blocks: []u8,

    pub fn deinit(self: *CompressedImage) void {
        self.allocator.free(self.blocks);
    }
};

/// Loads a builder-generated compressed texture variant. The 16-byte header keeps dimensions and
/// compression metadata alongside the tightly packed GPU blocks.
pub fn loadCompressed(path: [*:0]const u8, expected: Compression) !CompressedImage {
    var size: usize = 0;
    const file = c.SDL_LoadFile(path, &size) orelse return error.FileNotFound;
    defer c.SDL_free(file);
    if (size < 16) return error.InvalidCompressedImage;
    const bytes: [*]const u8 = @ptrCast(file);
    return parseCompressed(std.heap.page_allocator, bytes[0..size], expected);
}

/// Validates a BRTX variant and copies its payload. Kept separate from file I/O so format and
/// length validation can be tested without opening SDL or a GPU device.
pub fn parseCompressed(allocator: std.mem.Allocator, data: []const u8, expected: Compression) !CompressedImage {
    if (data.len < 16) return error.InvalidCompressedImage;
    if (!std.mem.eql(u8, data[0..4], "BRTX") or data[4] != @intFromEnum(expected)) return error.InvalidCompressedImage;
    const width = @as(u32, data[8]) | (@as(u32, data[9]) << 8) | (@as(u32, data[10]) << 16) | (@as(u32, data[11]) << 24);
    const height = @as(u32, data[12]) | (@as(u32, data[13]) << 8) | (@as(u32, data[14]) << 16) | (@as(u32, data[15]) << 24);
    if (width == 0 or height == 0) return error.InvalidCompressedImage;
    const expected_size: usize = if (expected == .rgba8) blk: {
        const pixels = std.math.mul(usize, width, height) catch return error.InvalidCompressedImage;
        break :blk std.math.mul(usize, pixels, 4) catch return error.InvalidCompressedImage;
    } else blk: {
        const bytes_per_block: usize = if (expected == .bc1) 8 else 16;
        const blocks_x = (@as(usize, width) + 3) / 4;
        const blocks_y = (@as(usize, height) + 3) / 4;
        const blocks = std.math.mul(usize, blocks_x, blocks_y) catch return error.InvalidCompressedImage;
        break :blk std.math.mul(usize, blocks, bytes_per_block) catch return error.InvalidCompressedImage;
    };
    if (data.len - 16 != expected_size) return error.InvalidCompressedImage;
    const blocks = try allocator.dupe(u8, data[16..]);
    return .{ .allocator = allocator, .width = width, .height = height, .format = expected, .blocks = blocks };
}

fn variantFixture(allocator: std.mem.Allocator, format: Compression, width: u32, height: u32, payload_size: usize) ![]u8 {
    const data = try allocator.alloc(u8, 16 + payload_size);
    @memset(data, 0xAB);
    @memcpy(data[0..4], "BRTX");
    data[4] = @intFromEnum(format);
    data[8] = @truncate(width);
    data[9] = @truncate(width >> 8);
    data[10] = @truncate(width >> 16);
    data[11] = @truncate(width >> 24);
    data[12] = @truncate(height);
    data[13] = @truncate(height >> 8);
    data[14] = @truncate(height >> 16);
    data[15] = @truncate(height >> 24);
    return data;
}

test "compressed variants validate dimensions and format-specific payload lengths" {
    const cases = .{
        .{ .format = Compression.rgba8, .width = 2, .height = 2, .size = 16 },
        .{ .format = Compression.bc1, .width = 4, .height = 4, .size = 8 },
        .{ .format = Compression.bc3, .width = 4, .height = 4, .size = 16 },
        .{ .format = Compression.astc_4x4, .width = 4, .height = 4, .size = 16 },
    };
    inline for (cases) |case| {
        const bytes = try variantFixture(std.testing.allocator, case.format, case.width, case.height, case.size);
        defer std.testing.allocator.free(bytes);
        var parsed = try parseCompressed(std.testing.allocator, bytes, case.format);
        defer parsed.deinit();
        try std.testing.expectEqual(case.width, parsed.width);
        try std.testing.expectEqual(case.height, parsed.height);
        try std.testing.expectEqual(case.format, parsed.format);
        try std.testing.expectEqual(case.size, parsed.blocks.len);
    }
}

test "compressed variants reject truncated headers, mismatched formats, and invalid payload sizes" {
    const valid = try variantFixture(std.testing.allocator, .bc1, 4, 4, 8);
    defer std.testing.allocator.free(valid);
    try std.testing.expectError(error.InvalidCompressedImage, parseCompressed(std.testing.allocator, valid[0..15], .bc1));
    try std.testing.expectError(error.InvalidCompressedImage, parseCompressed(std.testing.allocator, valid, .bc3));
    try std.testing.expectError(error.InvalidCompressedImage, parseCompressed(std.testing.allocator, valid[0 .. valid.len - 1], .bc1));

    var bad_magic = try std.testing.allocator.dupe(u8, valid);
    defer std.testing.allocator.free(bad_magic);
    bad_magic[0] = 'X';
    try std.testing.expectError(error.InvalidCompressedImage, parseCompressed(std.testing.allocator, bad_magic, .bc1));
}

test "compressed variants reject zero dimensions and guard payload size overflow" {
    const zero_width = try variantFixture(std.testing.allocator, .rgba8, 0, 2, 0);
    defer std.testing.allocator.free(zero_width);
    try std.testing.expectError(error.InvalidCompressedImage, parseCompressed(std.testing.allocator, zero_width, .rgba8));

    const huge = try variantFixture(std.testing.allocator, .rgba8, std.math.maxInt(u32), std.math.maxInt(u32), 0);
    defer std.testing.allocator.free(huge);
    try std.testing.expectError(error.InvalidCompressedImage, parseCompressed(std.testing.allocator, huge, .rgba8));
}

/// Decodes PNG (or any format supported by stb_image) bytes into RGBA8 pixels.
pub fn decodeRgba8(bytes: []const u8) !Image {
    if (bytes.len == 0 or bytes.len > std.math.maxInt(c_int)) return error.DecodeFailed;

    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;
    const data = stb.stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &width, &height, &channels, 4);
    if (data == null) return error.DecodeFailed;

    const len = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
    const ptr: [*]u8 = @ptrCast(data);
    return .{
        .width = @intCast(width),
        .height = @intCast(height),
        .pixels = ptr[0..len],
    };
}

/// Loads a PNG (or any format stb_image supports) and converts it to RGBA8.
/// `path` is relative to the project root, where `zig build run` runs.
pub fn loadRgba8(path: [*:0]const u8) !Image {
    var size: usize = 0;
    const file = c.SDL_LoadFile(path, &size) orelse return error.FileNotFound;
    defer c.SDL_free(file);

    var w: c_int = 0;
    var h: c_int = 0;
    var channels: c_int = 0;
    const data = stb.stbi_load_from_memory(@ptrCast(file), @intCast(size), &w, &h, &channels, 4);
    if (data == null) return error.DecodeFailed;

    const len = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
    const ptr: [*]u8 = @ptrCast(data);
    return .{
        .width = @intCast(w),
        .height = @intCast(h),
        .pixels = ptr[0..len],
    };
}
