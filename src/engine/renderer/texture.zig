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
    sdl2d_fallback: ?*const Texture = null,
    width: u32,
    height: u32,
    has_upload_fence: bool,
    /// True for an alpha-only atlas (see createCoverage). It samples through the coverage pipeline and is never lit.
    coverage: bool = false,
    /// True for an RGBA MSDF atlas. It uses a per-texture linear sampler and the MSDF pipeline.
    msdf: bool = false,
    msdf_px_range: f32 = 0,

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

/// Uploads a packed RGBA8 MSDF atlas. Its SDL3 2D copy is supplied by the coverage sibling, not the distance field.
pub fn createMsdf(allocator: std.mem.Allocator, device: *backend.Device, width: u32, height: u32, pixels: []const u8, px_range: f32) Texture {
    var result = wrap(backend.texture.uploadMsdf(allocator, device, width, height, pixels, px_range), width, height);
    result.msdf = true;
    result.msdf_px_range = px_range;
    return result;
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

/// One rectangle of a coverage texture to overwrite (see backend.texture.CoverageRegion).
pub const CoverageRegion = backend.texture.CoverageRegion;

/// Creates a coverage texture on the GPU only. A runtime atlas page starts this way and gets its 2D copy from
/// `syncCoverage2d` when the 2D renderer first draws it. It samples through the coverage pipeline, like `createCoverage`.
pub fn createCoverageGpuOnly(allocator: std.mem.Allocator, device: *backend.Device, width: u32, height: u32, alpha: []const u8) Texture {
    var result = wrap(backend.texture.uploadCoverage(allocator, device, width, height, alpha), width, height);
    result.coverage = true;
    return result;
}

/// Records the GPU copies of `regions` into `cmd`, the frame's command buffer, so SDL runs them before any draw recorded
/// after them. Regions must lie inside the texture.
pub fn recordCoverageGpu(texture_ref: *const Texture, cmd: *backend.CommandBuffer, regions: []const CoverageRegion) void {
    std.debug.assert(texture_ref.coverage);
    backend.texture.recordCoverageRegions(backendState(texture_ref), cmd, regions);
}

/// Makes the 2D renderer's copy of a coverage texture match `alpha`, which holds width * height coverage bytes, row 0
/// first. The copy is created on the first call and overwritten after that. With no active 2D renderer no copy is made,
/// and `sdl2dState` returns null, which the caller can see.
pub fn syncCoverage2d(allocator: std.mem.Allocator, texture_ref: *Texture, width: u32, height: u32, alpha: []const u8) void {
    std.debug.assert(texture_ref.coverage);
    const rgba = expandCoverage(allocator, alpha);
    defer allocator.free(rgba);
    if (sdl2dState(texture_ref)) |sdl_texture| {
        platform.renderer2d.updateTexture(sdl_texture, 0, 0, width, height, rgba);
    } else {
        texture_ref.sdl2d_state = if (platform.renderer2d.createTexture(width, height, rgba)) |created| @ptrCast(created) else null;
    }
}

/// Overwrites the listed regions of the 2D copy. Does nothing when the copy does not exist.
pub fn updateCoverage2d(allocator: std.mem.Allocator, texture_ref: *const Texture, regions: []const CoverageRegion) void {
    std.debug.assert(texture_ref.coverage);
    const sdl_texture = sdl2dState(texture_ref) orelse return;
    for (regions) |region| {
        if (region.w == 0 or region.h == 0) continue;
        const texels = @as(usize, region.w) * @as(usize, region.h);
        const rgba = allocator.alloc(u8, texels * 4) catch @panic("out of memory");
        defer allocator.free(rgba);
        var row: u32 = 0;
        while (row < region.h) : (row += 1) {
            const src = region.coverage[@as(usize, row) * @as(usize, region.stride) ..][0..region.w];
            for (src, 0..) |coverage, col| {
                const out = (@as(usize, row) * @as(usize, region.w) + col) * 4;
                rgba[out + 0] = 255;
                rgba[out + 1] = 255;
                rgba[out + 2] = 255;
                rgba[out + 3] = coverage;
            }
        }
        platform.renderer2d.updateTexture(sdl_texture, region.x, region.y, region.w, region.h, rgba);
    }
}

/// Releases the 2D renderer's copy, if there is one. The GPU texture is kept, and the next `syncCoverage2d` makes the
/// copy again.
pub fn releaseCoverage2d(texture_ref: *Texture) void {
    if (texture_ref.sdl2d_state) |state| {
        platform.renderer2d.destroyTexture(@ptrCast(state));
        texture_ref.sdl2d_state = null;
    }
}

/// Expands alpha-only coverage to white RGBA, the layout the 2D renderer tints. The caller frees the result.
fn expandCoverage(allocator: std.mem.Allocator, alpha: []const u8) []u8 {
    const rgba = allocator.alloc(u8, alpha.len * 4) catch @panic("out of memory");
    for (alpha, 0..) |coverage, index| {
        rgba[index * 4 + 0] = 255;
        rgba[index * 4 + 1] = 255;
        rgba[index * 4 + 2] = 255;
        rgba[index * 4 + 3] = coverage;
    }
    return rgba;
}

pub fn sdl2dState(texture_ref: *const Texture) ?*platform.Renderer2dTexture {
    if (texture_ref.sdl2d_fallback) |fallback| return sdl2dState(fallback);
    return if (texture_ref.sdl2d_state) |state| @ptrCast(state) else null;
}
