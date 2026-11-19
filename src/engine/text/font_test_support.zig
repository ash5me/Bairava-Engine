const std = @import("std");
const runtime_font = @import("runtime_font.zig");

pub fn runtimeOutlineFixture(allocator: std.mem.Allocator) !runtime_font.RuntimeFont {
    const blob = runtime_font.hb.hb_blob_create_from_file_or_fail("assets/font.ttf") orelse return error.FixtureMissing;
    defer runtime_font.hb.hb_blob_destroy(blob);
    var len: c_uint = 0;
    const data = runtime_font.hb.hb_blob_get_data(blob, &len);
    if (data == null or len == 0) return error.FixtureMissing;
    const ptr: [*]const u8 = @ptrCast(data);
    return runtime_font.RuntimeFont.init(allocator, ptr[0..@as(usize, len)], 16);
}
