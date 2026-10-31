//! Render passes. A pass draws into one target: the native view, or the window's swapchain.
//! The GPU device and the swapchain are in platform/sdl/gpu.zig.

const std = @import("std");
const c = @import("../platform/sdl/sdl.zig").c;

pub const Color = struct { r: f32, g: f32, b: f32, a: f32 };

/// Starts a render pass that clears `target` to `clear`.
/// The target can be the swapchain or any texture created with Texture.initTarget.
pub fn beginPass(cmd: *c.SDL_GPUCommandBuffer, target: *c.SDL_GPUTexture, clear: Color) ?*c.SDL_GPURenderPass {
    const color_target = colorTargetInfo(target, clear);
    return c.SDL_BeginGPURenderPass(cmd, &color_target, 1, null);
}

/// Ends a render pass that `beginPass` started.
pub fn endPass(pass: ?*c.SDL_GPURenderPass) void {
    c.SDL_EndGPURenderPass(pass);
}

/// Builds the SDL attachment descriptor used by `beginPass`.
fn colorTargetInfo(target: *c.SDL_GPUTexture, clear: Color) c.SDL_GPUColorTargetInfo {
    var color_target = std.mem.zeroes(c.SDL_GPUColorTargetInfo);
    color_target.texture = target;
    color_target.clear_color = .{ .r = clear.r, .g = clear.g, .b = clear.b, .a = clear.a };
    color_target.load_op = c.SDL_GPU_LOADOP_CLEAR;
    color_target.store_op = c.SDL_GPU_STOREOP_STORE;
    return color_target;
}

test "color target clears to the requested color and keeps the result" {
    var marker: u8 = 0;
    const target: *c.SDL_GPUTexture = @ptrCast(&marker);
    const clear = Color{ .r = 0.25, .g = 0.5, .b = 0.75, .a = 1.0 };
    const info = colorTargetInfo(target, clear);

    try std.testing.expect(info.texture == target);
    try std.testing.expectEqual(@as(f32, 0.25), info.clear_color.r);
    try std.testing.expectEqual(@as(f32, 0.5), info.clear_color.g);
    try std.testing.expectEqual(@as(f32, 0.75), info.clear_color.b);
    try std.testing.expectEqual(@as(f32, 1.0), info.clear_color.a);
    try std.testing.expect(info.load_op == c.SDL_GPU_LOADOP_CLEAR);
    try std.testing.expect(info.store_op == c.SDL_GPU_STOREOP_STORE);
}

test "color target leaves unused fields at zero" {
    var marker: u8 = 0;
    const target: *c.SDL_GPUTexture = @ptrCast(&marker);
    const info = colorTargetInfo(target, .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 });
    try std.testing.expectEqual(@as(u32, 0), info.mip_level);
    try std.testing.expectEqual(@as(u32, 0), info.layer_or_depth_plane);
    try std.testing.expect(info.resolve_texture == null);
    try std.testing.expect(!info.cycle);
}
