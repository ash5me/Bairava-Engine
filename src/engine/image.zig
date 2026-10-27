const std = @import("std");

const c = @import("sdl.zig").c;

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
