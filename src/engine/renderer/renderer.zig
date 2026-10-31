//! Render passes. A pass draws into one target: the native view, or the window's swapchain.
//! The GPU device and the swapchain are in platform/sdl/gpu.zig.

const std = @import("std");
const c = @import("../platform/sdl/sdl.zig").c;

/// Starts a render pass that clears `target` to `clear`.
/// The target can be the swapchain or any texture created with Texture.initTarget.
pub fn beginPass(cmd: *c.SDL_GPUCommandBuffer, target: *c.SDL_GPUTexture, clear: c.SDL_FColor) ?*c.SDL_GPURenderPass {
    const color_target = colorTargetInfo(target, clear);
    return c.SDL_BeginGPURenderPass(cmd, &color_target, 1, null);
}

/// Ends a render pass that `beginPass` started.
pub fn endPass(pass: ?*c.SDL_GPURenderPass) void {
    c.SDL_EndGPURenderPass(pass);
}

/// The color attachment `Renderer.beginPass` uses. It clears `target` to `clear` when the pass starts
/// and keeps the result when it ends. It's public so `src/tests.zig` can check these settings without
/// a GPU.
pub fn colorTargetInfo(target: *c.SDL_GPUTexture, clear: c.SDL_FColor) c.SDL_GPUColorTargetInfo {
    var color_target = std.mem.zeroes(c.SDL_GPUColorTargetInfo);
    color_target.texture = target;
    color_target.clear_color = clear;
    color_target.load_op = c.SDL_GPU_LOADOP_CLEAR;
    color_target.store_op = c.SDL_GPU_STOREOP_STORE;
    return color_target;
}
