const std = @import("std");

const c = @import("../platform/sdl/sdl.zig").c;
const image = @import("../assets/loaders/image.zig");
const logging = @import("../logging/log.zig");
const profile = @import("../profiling/profile.zig");

const TextureHandle = opaque {};

const TextureGpuState = struct {
    device: *c.SDL_GPUDevice,
    texture: *c.SDL_GPUTexture,
    sampler: *c.SDL_GPUSampler,
    upload_fence: ?*c.SDL_GPUFence,
    allocator: std.mem.Allocator,
};

/// A 2D texture and a nearest-neighbor sampler for it.
/// Nearest filtering keeps pixel art sharp when it's scaled up.
pub const Texture = struct {
    gpu_state: *TextureHandle,
    width: u32,
    height: u32,
    has_upload_fence: bool,
    /// Releases the GPU resources. The owning engine runtime must outlive the texture.
    pub fn deinit(self: *Texture) void {
        const state = textureGpuState(self);
        if (state.upload_fence) |fence| c.SDL_ReleaseGPUFence(state.device, fence);
        c.SDL_ReleaseGPUSampler(state.device, state.sampler);
        c.SDL_ReleaseGPUTexture(state.device, state.texture);
        state.allocator.destroy(state);
        self.* = undefined;
    }

    /// True once the GPU has finished uploading the texture, so sampling it is safe. Targets have no
    /// upload, so they are always ready.
    pub fn isReady(self: *const Texture) bool {
        if (!self.has_upload_fence) return true;
        const state = textureGpuState(self);
        return c.SDL_QueryGPUFence(state.device, state.upload_fence.?);
    }
};

/// Uploads tightly packed RGBA8 pixels (4 bytes per pixel, row 0 at the top).
pub fn createRgba8(allocator: std.mem.Allocator, device: *c.SDL_GPUDevice, width: u32, height: u32, pixels: []const u8) Texture {
    return upload(allocator, device, width, height, c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM, pixels, width, height, false);
}

/// Uploads RGBA8 pixels with linear filtering, used for signed-distance-field font atlases.
pub fn createRgba8Linear(allocator: std.mem.Allocator, device: *c.SDL_GPUDevice, width: u32, height: u32, pixels: []const u8) Texture {
    return upload(allocator, device, width, height, c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM, pixels, width, height, true);
}

pub fn supportsCompression(device: *c.SDL_GPUDevice, compression: image.Compression) bool {
    const format = gpuFormat(compression) orelse return true;
    return c.SDL_GPUTextureSupportsFormat(device, format, c.SDL_GPU_TEXTURETYPE_2D, c.SDL_GPU_TEXTUREUSAGE_SAMPLER);
}

pub fn createCompressed(allocator: std.mem.Allocator, device: *c.SDL_GPUDevice, width: u32, height: u32, compression: image.Compression, blocks: []const u8) Texture {
    const format = gpuFormat(compression) orelse unreachable;
    return upload(allocator, device, width, height, format, blocks, 0, 0, false);
}

pub fn createTarget(allocator: std.mem.Allocator, device: *c.SDL_GPUDevice, width: u32, height: u32, format: c.SDL_GPUTextureFormat) Texture {
    const texture = createTexture(device, width, height, format, c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER);
    return wrapTexture(allocator, device, texture, createSampler(device, false), null, width, height);
}

pub fn updateRgba8(texture: *Texture, width: u32, height: u32, pixels: []const u8, linear: bool) void {
    const device = textureGpuState(texture).device;
    const allocator = textureGpuState(texture).allocator;
    texture.deinit();
    texture.* = if (linear) createRgba8Linear(allocator, device, width, height, pixels) else createRgba8(allocator, device, width, height, pixels);
}

pub fn backendTexture(texture: *const Texture) *c.SDL_GPUTexture {
    return textureGpuState(texture).texture;
}

pub fn backendBinding(texture: *const Texture) c.SDL_GPUTextureSamplerBinding {
    const state = textureGpuState(texture);
    return .{ .texture = state.texture, .sampler = state.sampler };
}

fn upload(allocator: std.mem.Allocator, device: *c.SDL_GPUDevice, width: u32, height: u32, format: c.SDL_GPUTextureFormat, pixels: []const u8, pixels_per_row: u32, rows_per_layer: u32, linear: bool) Texture {
    const texture = createTexture(device, width, height, format, c.SDL_GPU_TEXTUREUSAGE_SAMPLER);

    // Stage the pixels in an upload buffer, then copy them into the texture.
    var tb_info = std.mem.zeroes(c.SDL_GPUTransferBufferCreateInfo);
    tb_info.usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
    tb_info.size = @intCast(pixels.len);
    const transfer = c.SDL_CreateGPUTransferBuffer(device, &tb_info) orelse {
        std.debug.panic("SDL_CreateGPUTransferBuffer failed: {s}", .{c.SDL_GetError()});
    };
    defer c.SDL_ReleaseGPUTransferBuffer(device, transfer);

    const mapped = c.SDL_MapGPUTransferBuffer(device, transfer, false) orelse {
        std.debug.panic("SDL_MapGPUTransferBuffer failed: {s}", .{c.SDL_GetError()});
    };
    const dst: [*]u8 = @ptrCast(mapped);
    @memcpy(dst[0..pixels.len], pixels);
    c.SDL_UnmapGPUTransferBuffer(device, transfer);

    const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse {
        std.debug.panic("SDL_AcquireGPUCommandBuffer failed: {s}", .{c.SDL_GetError()});
    };
    const copy_pass = c.SDL_BeginGPUCopyPass(cmd);
    const src = c.SDL_GPUTextureTransferInfo{
        .transfer_buffer = transfer,
        .offset = 0,
        .pixels_per_row = pixels_per_row,
        .rows_per_layer = rows_per_layer,
    };
    const region = c.SDL_GPUTextureRegion{
        .texture = texture,
        .mip_level = 0,
        .layer = 0,
        .x = 0,
        .y = 0,
        .z = 0,
        .w = width,
        .h = height,
        .d = 1,
    };
    c.SDL_UploadToGPUTexture(copy_pass, &src, &region, false);
    c.SDL_EndGPUCopyPass(copy_pass);
    const fence = c.SDL_SubmitGPUCommandBufferAndAcquireFence(cmd) orelse {
        std.debug.panic("SDL_SubmitGPUCommandBufferAndAcquireFence failed: {s}", .{c.SDL_GetError()});
    };
    return wrapTexture(allocator, device, texture, createSampler(device, linear), fence, width, height);
}

fn wrapTexture(allocator: std.mem.Allocator, device: *c.SDL_GPUDevice, texture: *c.SDL_GPUTexture, sampler: *c.SDL_GPUSampler, fence: ?*c.SDL_GPUFence, width: u32, height: u32) Texture {
    const state = allocator.create(TextureGpuState) catch @panic("out of memory");
    state.* = .{ .device = device, .texture = texture, .sampler = sampler, .upload_fence = fence, .allocator = allocator };
    return .{ .gpu_state = @ptrCast(state), .width = width, .height = height, .has_upload_fence = fence != null };
}

fn textureGpuState(texture: *const Texture) *TextureGpuState {
    return @ptrCast(@alignCast(texture.gpu_state));
}

fn gpuFormat(compression: image.Compression) ?c.SDL_GPUTextureFormat {
    return switch (compression) {
        .rgba8 => null,
        .bc1 => c.SDL_GPU_TEXTUREFORMAT_BC1_RGBA_UNORM,
        .bc3 => c.SDL_GPU_TEXTUREFORMAT_BC3_RGBA_UNORM,
        .astc_4x4 => c.SDL_GPU_TEXTUREFORMAT_ASTC_4x4_UNORM,
    };
}

fn createTexture(device: *c.SDL_GPUDevice, width: u32, height: u32, format: c.SDL_GPUTextureFormat, usage: u32) *c.SDL_GPUTexture {
    var info = std.mem.zeroes(c.SDL_GPUTextureCreateInfo);
    info.type = c.SDL_GPU_TEXTURETYPE_2D;
    info.format = format;
    info.usage = usage;
    info.width = width;
    info.height = height;
    info.layer_count_or_depth = 1;
    info.num_levels = 1;
    return c.SDL_CreateGPUTexture(device, &info) orelse {
        std.debug.panic("SDL_CreateGPUTexture failed: {s}", .{c.SDL_GetError()});
    };
}

fn createSampler(device: *c.SDL_GPUDevice, linear: bool) *c.SDL_GPUSampler {
    var info = std.mem.zeroes(c.SDL_GPUSamplerCreateInfo);
    info.min_filter = if (linear) c.SDL_GPU_FILTER_LINEAR else c.SDL_GPU_FILTER_NEAREST;
    info.mag_filter = if (linear) c.SDL_GPU_FILTER_LINEAR else c.SDL_GPU_FILTER_NEAREST;
    info.mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST;
    info.address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    info.address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    info.address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    return c.SDL_CreateGPUSampler(device, &info) orelse {
        std.debug.panic("SDL_CreateGPUSampler failed: {s}", .{c.SDL_GetError()});
    };
}
