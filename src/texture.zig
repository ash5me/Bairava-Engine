const std = @import("std");

const c = @import("sdl.zig").c;

/// A 2D RGBA texture and a nearest-neighbor sampler for it.
/// Nearest filtering keeps pixel art sharp when it's scaled up.
pub const Texture = struct {
    device: *c.SDL_GPUDevice,
    texture: *c.SDL_GPUTexture,
    sampler: *c.SDL_GPUSampler,
    width: u32,
    height: u32,

    /// Uploads tightly packed RGBA8 pixels (4 bytes per pixel, row 0 at the top).
    pub fn initRgba8(device: *c.SDL_GPUDevice, width: u32, height: u32, pixels: []const u8) Texture {
        std.debug.assert(pixels.len == @as(usize, width) * height * 4);

        var tex_info = std.mem.zeroes(c.SDL_GPUTextureCreateInfo);
        tex_info.type = c.SDL_GPU_TEXTURETYPE_2D;
        tex_info.format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
        tex_info.usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER;
        tex_info.width = width;
        tex_info.height = height;
        tex_info.layer_count_or_depth = 1;
        tex_info.num_levels = 1;
        const texture = c.SDL_CreateGPUTexture(device, &tex_info) orelse {
            std.debug.panic("SDL_CreateGPUTexture failed: {s}", .{c.SDL_GetError()});
        };

        var samp_info = std.mem.zeroes(c.SDL_GPUSamplerCreateInfo);
        samp_info.min_filter = c.SDL_GPU_FILTER_NEAREST;
        samp_info.mag_filter = c.SDL_GPU_FILTER_NEAREST;
        samp_info.mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST;
        samp_info.address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
        samp_info.address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
        samp_info.address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
        const sampler = c.SDL_CreateGPUSampler(device, &samp_info) orelse {
            std.debug.panic("SDL_CreateGPUSampler failed: {s}", .{c.SDL_GetError()});
        };

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
            .pixels_per_row = width,
            .rows_per_layer = height,
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
        if (!c.SDL_SubmitGPUCommandBuffer(cmd)) {
            std.debug.panic("SDL_SubmitGPUCommandBuffer failed: {s}", .{c.SDL_GetError()});
        }
        _ = c.SDL_WaitForGPUIdle(device);

        return .{
            .device = device,
            .texture = texture,
            .sampler = sampler,
            .width = width,
            .height = height,
        };
    }

    /// The texture and sampler pair that a fragment shader samples through.
    pub fn binding(self: *const Texture) c.SDL_GPUTextureSamplerBinding {
        return .{ .texture = self.texture, .sampler = self.sampler };
    }

    /// Releases GPU resources. Call before the renderer's device is destroyed.
    pub fn deinit(self: *Texture) void {
        c.SDL_ReleaseGPUSampler(self.device, self.sampler);
        c.SDL_ReleaseGPUTexture(self.device, self.texture);
    }
};
