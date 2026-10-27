const std = @import("std");

const c = @import("sdl.zig").c;

/// Loads a compiled SPIR-V file from disk and creates a GPU shader from it.
/// Paths are relative to the project root, where `zig build run` runs.
pub fn loadSpirv(
    device: *c.SDL_GPUDevice,
    path: [*c]const u8,
    entry: [*c]const u8,
    stage: c.SDL_GPUShaderStage,
) *c.SDL_GPUShader {
    var size: usize = 0;
    const code = c.SDL_LoadFile(path, &size) orelse {
        std.debug.panic("SDL_LoadFile({s}) failed: {s}", .{ path, c.SDL_GetError() });
    };
    defer c.SDL_free(code);

    var info = std.mem.zeroes(c.SDL_GPUShaderCreateInfo);
    info.code_size = size;
    info.code = @ptrCast(code);
    info.entrypoint = entry;
    info.format = c.SDL_GPU_SHADERFORMAT_SPIRV;
    info.stage = stage;

    return c.SDL_CreateGPUShader(device, &info) orelse {
        std.debug.panic("SDL_CreateGPUShader failed: {s}", .{c.SDL_GetError()});
    };
}
