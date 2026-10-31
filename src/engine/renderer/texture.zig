const std = @import("std");

const c = @import("../platform/sdl/sdl.zig").c;
const image = @import("../assets/loaders/image.zig");
const logging = @import("../logging/log.zig");
const profile = @import("../profiling/profile.zig");

/// A 2D texture and a nearest-neighbor sampler for it.
/// Nearest filtering keeps pixel art sharp when it's scaled up.
pub const Texture = struct {
    device: *c.SDL_GPUDevice,
    texture: *c.SDL_GPUTexture,
    sampler: *c.SDL_GPUSampler,
    width: u32,
    height: u32,
    /// Signaled by the GPU once the upload copy is finished. Null for targets, which have nothing to upload.
    upload_fence: ?*c.SDL_GPUFence = null,

    /// Uploads tightly packed RGBA8 pixels (4 bytes per pixel, row 0 at the top). The copy is queued,
    /// and this returns without waiting for the GPU. `isReady` says when the texture can be sampled.
    pub fn initRgba8(device: *c.SDL_GPUDevice, width: u32, height: u32, pixels: []const u8) Texture {
        const zone = profile.zoneNamed(@src(), "upload texture");
        defer zone.End();
        const expected_len = @as(usize, width) * height * 4;
        logging.assert(pixels.len == expected_len, @src(), "pixel buffer is {d} bytes, expected {d} for a {d}x{d} texture", .{ pixels.len, expected_len, width, height });
        return upload(device, width, height, c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM, pixels, width, height, false);
    }

    /// Uploads RGBA8 pixels with linear filtering. Use for signed distance field textures, where
    /// interpolated distance values are required for smooth edge reconstruction.
    pub fn initRgba8Linear(device: *c.SDL_GPUDevice, width: u32, height: u32, pixels: []const u8) Texture {
        const expected_len = @as(usize, width) * height * 4;
        logging.assert(pixels.len == expected_len, @src(), "pixel buffer is {d} bytes, expected {d} for a {d}x{d} texture", .{ pixels.len, expected_len, width, height });
        return upload(device, width, height, c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM, pixels, width, height, true);
    }

    /// Whether the active GPU can sample this precompressed format.
    pub fn supportsCompression(device: *c.SDL_GPUDevice, compression: image.Compression) bool {
        const format = gpuFormat(compression) orelse return true;
        return c.SDL_GPUTextureSupportsFormat(device, format, c.SDL_GPU_TEXTURETYPE_2D, c.SDL_GPU_TEXTUREUSAGE_SAMPLER);
    }

    /// Uploads tightly packed BC1, BC3, or ASTC 4x4 blocks.
    pub fn initCompressed(device: *c.SDL_GPUDevice, width: u32, height: u32, compression: image.Compression, blocks: []const u8) Texture {
        const format = gpuFormat(compression) orelse unreachable;
        return upload(device, width, height, format, blocks, 0, 0, false);
    }

    fn upload(device: *c.SDL_GPUDevice, width: u32, height: u32, format: c.SDL_GPUTextureFormat, pixels: []const u8, pixels_per_row: u32, rows_per_layer: u32, linear: bool) Texture {
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
        // Submit without waiting. The fence tells isReady when the copy is done. The transfer buffer is
        // released when this function returns, which is safe because SDL frees a released buffer only
        // after the GPU has finished with it.
        const fence = c.SDL_SubmitGPUCommandBufferAndAcquireFence(cmd) orelse {
            std.debug.panic("SDL_SubmitGPUCommandBufferAndAcquireFence failed: {s}", .{c.SDL_GetError()});
        };

        return .{
            .device = device,
            .texture = texture,
            .sampler = createSampler(device, linear),
            .width = width,
            .height = height,
            .upload_fence = fence,
        };
    }

    /// Creates an empty texture that can be drawn into and then sampled.
    /// `format` must match the pipelines that draw into it.
    pub fn initTarget(device: *c.SDL_GPUDevice, width: u32, height: u32, format: c.SDL_GPUTextureFormat) Texture {
        return .{
            .device = device,
            .texture = createTexture(device, width, height, format, c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER),
            .sampler = createSampler(device, false),
            .width = width,
            .height = height,
        };
    }

    /// The texture and sampler pair that a fragment shader samples through.
    pub fn binding(self: *const Texture) c.SDL_GPUTextureSamplerBinding {
        return .{ .texture = self.texture, .sampler = self.sampler };
    }

    /// True once the GPU has finished uploading the texture, so sampling it is safe. Targets have no
    /// upload, so they are always ready.
    pub fn isReady(self: *const Texture) bool {
        const fence = self.upload_fence orelse return true;
        return c.SDL_QueryGPUFence(self.device, fence);
    }

    /// Releases GPU resources. Call before the device is destroyed.
    pub fn deinit(self: *Texture) void {
        if (self.upload_fence) |fence| c.SDL_ReleaseGPUFence(self.device, fence);
        c.SDL_ReleaseGPUSampler(self.device, self.sampler);
        c.SDL_ReleaseGPUTexture(self.device, self.texture);
    }
};

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
