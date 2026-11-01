const std = @import("std");
const sprite = @import("renderer/sprite.zig");
const Texture = @import("renderer/texture.zig").Texture;

pub fn texture(width: u32, height: u32) Texture {
    return .{ .gpu_state = undefined, .width = width, .height = height, .has_upload_fence = false };
}

pub fn batch(no_vertices: *[0]sprite.Vertex, no_batches: *[0]sprite.Batch) sprite.SpriteBatch {
    return .{
        .gpu_state = undefined,
        .allocator = std.testing.allocator,
        .vertices = no_vertices,
        .batches = no_batches,
    };
}

pub fn freeBatch(value: *sprite.SpriteBatch) void {
    if (value.vertices.len != 0) std.testing.allocator.free(value.vertices);
    if (value.batches.len != 0) std.testing.allocator.free(value.batches);
    if (value.quads.len != 0) std.testing.allocator.free(value.quads);
}

pub fn compressedImageVariant(
    allocator: std.mem.Allocator,
    format: u8,
    width: u32,
    height: u32,
    payload_size: usize,
) ![]u8 {
    const data = try allocator.alloc(u8, 16 + payload_size);
    @memset(data, 0xAB);
    @memcpy(data[0..4], "BRTX");
    data[4] = format;
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
