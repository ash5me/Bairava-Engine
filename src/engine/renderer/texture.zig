const std = @import("std");

const backend = @import("backends/sdl_gpu/backend.zig");
const image = @import("../assets/loaders/image.zig");
const platform = @import("../platform/platform.zig");

/// The backend state, hidden behind an opaque type so the public Texture names no backend type.
const TextureHandle = opaque {};

/// A 2D texture and its GPU state. Nearest filtering keeps pixel art sharp when it's scaled up.
pub const Texture = struct {
    gpu_state: *TextureHandle,
    sdl2d_state: ?*platform.Renderer2dTexture = null,
    width: u32,
    height: u32,
    has_upload_fence: bool,
    /// True for an alpha-only atlas (see createCoverage). It samples through the coverage pipeline and is never lit.
    coverage: bool = false,

    /// Releases the GPU resources. The owning engine runtime must outlive the texture.
    pub fn deinit(self: *Texture) void {
        backend.texture.destroy(backendState(self));
        if (self.sdl2d_state) |state| {
            platform.renderer2d.destroyTexture(@ptrCast(state));
        }
        self.* = undefined;
    }

    /// True once the GPU has finished uploading the texture, so sampling it is safe. Targets have no
    /// upload, so they are always ready.
    pub fn isReady(self: *const Texture) bool {
        if (!self.has_upload_fence) return true;
        return backend.texture.isUploadDone(backendState(self));
    }
};

/// Uploads tightly packed RGBA8 pixels (4 bytes per pixel, row 0 at the top).
pub fn createRgba8(allocator: std.mem.Allocator, device: *backend.Device, width: u32, height: u32, pixels: []const u8) Texture {
    return wrapWithSdl(backend.texture.uploadRgba8(allocator, device, width, height, pixels), width, height, pixels);
}

/// Uploads one coverage byte per texel (row 0 at the top) as a coverage texture: the glyph atlas of a prebaked font.
/// It is an R8 texture, a quarter of the memory of RGBA8, and sprites that use it are drawn through the coverage
/// pipeline. The 2D renderer has no such format, so it gets a white RGBA copy, which is freed before this returns.
pub fn createCoverage(allocator: std.mem.Allocator, device: *backend.Device, width: u32, height: u32, alpha: []const u8) Texture {
    var result = wrap(backend.texture.uploadCoverage(allocator, device, width, height, alpha), width, height);
    result.coverage = true;
    const expanded = allocator.alloc(u8, alpha.len * 4) catch @panic("out of memory");
    defer allocator.free(expanded);
    for (alpha, 0..) |coverage, index| {
        expanded[index * 4 + 0] = 255;
        expanded[index * 4 + 1] = 255;
        expanded[index * 4 + 2] = 255;
        expanded[index * 4 + 3] = coverage;
    }
    result.sdl2d_state = if (platform.renderer2d.createTexture(width, height, expanded)) |sdl_texture|
        @ptrCast(sdl_texture)
    else
        null;
    return result;
}

pub fn supportsCompression(device: *backend.Device, compression: image.Compression) bool {
    return backend.texture.supportsCompression(device, compression);
}

pub fn supportsRgba8Sampling(device: *backend.Device) bool {
    return backend.texture.supportsRgba8Sampling(device);
}

pub fn createCompressed(allocator: std.mem.Allocator, device: *backend.Device, width: u32, height: u32, compression: image.Compression, blocks: []const u8) Texture {
    return wrap(backend.texture.uploadCompressed(allocator, device, width, height, compression, blocks), width, height);
}

pub fn createTarget(allocator: std.mem.Allocator, device: *backend.Device, width: u32, height: u32, format: backend.TextureFormat) Texture {
    return wrap(backend.texture.createTarget(allocator, device, width, height, format), width, height);
}

/// The GPU texture object, for drawing into this texture as a render target.
pub fn backendTexture(texture_ref: *const Texture) *backend.GpuTexture {
    return backend.texture.gpuTexture(backendState(texture_ref));
}

/// The backend state of a texture. The cast reverses how `wrap` stored it.
pub fn backendState(texture_ref: *const Texture) *backend.texture.State {
    return @ptrCast(@alignCast(texture_ref.gpu_state));
}

fn wrap(state: *backend.texture.State, width: u32, height: u32) Texture {
    return .{
        .gpu_state = @ptrCast(state),
        .width = width,
        .height = height,
        .has_upload_fence = backend.texture.hasUploadFence(state),
    };
}

fn wrapWithSdl(state: *backend.texture.State, width: u32, height: u32, pixels: []const u8) Texture {
    var result = wrap(state, width, height);
    result.sdl2d_state = if (platform.renderer2d.createTexture(width, height, pixels)) |sdl_texture|
        @ptrCast(sdl_texture) else null;
    return result;
}

pub fn sdl2dState(texture_ref: *const Texture) ?*platform.Renderer2dTexture {
    return if (texture_ref.sdl2d_state) |state| @ptrCast(state) else null;
}
