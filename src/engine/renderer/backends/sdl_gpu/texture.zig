//! GPU textures on SDL_GPU: the sampled image, its sampler, and the fence that says when the upload has
//! finished. The engine's Texture (renderer/texture.zig) holds a pointer to a State from here.

const std = @import("std");
const c = @import("../../../platform/sdl/sdl.zig").c;
const image = @import("../../../assets/loaders/image.zig");

/// The GPU objects behind one texture. The state is heap-allocated, so the engine keeps a pointer to
/// it, and `destroy` frees it with the allocator it came from.
pub const State = struct {
    device: *c.SDL_GPUDevice,
    texture: *c.SDL_GPUTexture,
    nearest_sampler: ?*c.SDL_GPUSampler,
    linear_sampler: ?*c.SDL_GPUSampler,
    upload_fence: ?*c.SDL_GPUFence,
    allocator: std.mem.Allocator,
    msdf_px_range: f32 = 0,
};

/// Uploads tightly packed RGBA8 pixels. Sampling is nearest-neighbor, so pixel art stays sharp when it is scaled up.
pub fn uploadRgba8(allocator: std.mem.Allocator, device: *c.SDL_GPUDevice, width: u32, height: u32, pixels: []const u8) *State {
    return upload(allocator, device, width, height, c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM, pixels, width, height, .nearest);
}

/// Uploads an MSDF atlas with its own clamp-to-edge linear sampler. Other textures remain nearest-filtered.
pub fn uploadMsdf(allocator: std.mem.Allocator, device: *c.SDL_GPUDevice, width: u32, height: u32, pixels: []const u8, px_range: f32) *State {
    const state = upload(allocator, device, width, height, c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM, pixels, width, height, .linear);
    state.msdf_px_range = px_range;
    return state;
}

/// Uploads one coverage byte per texel as an R8 texture, for the glyph atlas of a prebaked font. Sampling returns the
/// coverage in the red channel, which the coverage fragment shader reads. A quarter of the memory of RGBA8.
pub fn uploadCoverage(allocator: std.mem.Allocator, device: *c.SDL_GPUDevice, width: u32, height: u32, alpha: []const u8) *State {
    return upload(allocator, device, width, height, c.SDL_GPU_TEXTUREFORMAT_R8_UNORM, alpha, width, height, .nearest);
}

/// Uploads a prebuilt block-compressed image. The caller checks `supportsCompression` first.
pub fn uploadCompressed(allocator: std.mem.Allocator, device: *c.SDL_GPUDevice, width: u32, height: u32, compression: image.Compression, blocks: []const u8) *State {
    const format = gpuFormat(compression) orelse unreachable;
    return upload(allocator, device, width, height, format, blocks, 0, 0, .nearest);
}

/// Creates a texture the GPU can both sample and draw into. The native view is one of these.
pub fn createTarget(allocator: std.mem.Allocator, device: *c.SDL_GPUDevice, width: u32, height: u32, format: c.SDL_GPUTextureFormat) *State {
    const texture = createTexture(device, width, height, format, c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER);
    return wrap(allocator, device, texture, createSampler(device, .nearest), null, .nearest);
}

/// True when the device can sample the block-compressed format.
pub fn supportsCompression(device: *c.SDL_GPUDevice, compression: image.Compression) bool {
    const format = gpuFormat(compression) orelse return true;
    return supportsSampledFormat(device, format);
}

pub fn supportsRgba8Sampling(device: *c.SDL_GPUDevice) bool {
    return supportsSampledFormat(device, c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM);
}

fn supportsSampledFormat(device: *c.SDL_GPUDevice, format: c.SDL_GPUTextureFormat) bool {
    return c.SDL_GPUTextureSupportsFormat(device, format, c.SDL_GPU_TEXTURETYPE_2D, c.SDL_GPU_TEXTUREUSAGE_SAMPLER);
}

/// True once the GPU has finished the upload, so sampling the texture is safe. Only call this when
/// `hasUploadFence` is true.
pub fn isUploadDone(state: *const State) bool {
    return c.SDL_QueryGPUFence(state.device, state.upload_fence.?);
}

/// True when the texture has an upload to wait for. Render targets have none.
pub fn hasUploadFence(state: *const State) bool {
    return state.upload_fence != null;
}

/// The texture object itself, for drawing into it as a render target.
pub fn gpuTexture(state: *const State) *c.SDL_GPUTexture {
    return state.texture;
}

/// The texture and sampler pair a fragment shader reads through.
pub fn binding(state: *const State) c.SDL_GPUTextureSamplerBinding {
    return .{ .texture = state.texture, .sampler = state.linear_sampler orelse state.nearest_sampler.? };
}

/// One rectangle of a coverage texture to overwrite. Row r of the rectangle is `w` bytes at `coverage[r * stride]`, so a
/// region of a larger page can be sent without copying it first. `coverage` must reach the last row's `w` bytes.
pub const CoverageRegion = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    stride: u32,
    coverage: []const u8,
    /// Ask SDL to cycle the destination texture for a full-page rewrite that may overlap in-flight sampling.
    cycle: bool = false,
};

/// Records copies of `regions` into `cmd` outside a render pass. The copies run before any draw recorded after them in
/// the same command buffer, which is how a glyph written this frame is sampled this frame. The rows are staged in one
/// transfer buffer. SDL frees that buffer once the GPU no longer needs it, so it is released before this returns.
/// Regions must lie inside the texture. An empty region is skipped.
pub fn recordCoverageRegions(state: *const State, cmd: *c.SDL_GPUCommandBuffer, regions: []const CoverageRegion) void {
    var total: usize = 0;
    for (regions) |region| {
        if (region.w == 0 or region.h == 0) continue;
        total += @as(usize, region.w) * @as(usize, region.h);
    }
    if (total == 0) return;

    var tb_info = std.mem.zeroes(c.SDL_GPUTransferBufferCreateInfo);
    tb_info.usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
    tb_info.size = @intCast(total);
    const transfer = c.SDL_CreateGPUTransferBuffer(state.device, &tb_info) orelse {
        std.debug.panic("SDL_CreateGPUTransferBuffer failed: {s}", .{c.SDL_GetError()});
    };
    defer c.SDL_ReleaseGPUTransferBuffer(state.device, transfer);

    const mapped = c.SDL_MapGPUTransferBuffer(state.device, transfer, false) orelse {
        std.debug.panic("SDL_MapGPUTransferBuffer failed: {s}", .{c.SDL_GetError()});
    };
    const staged: [*]u8 = @ptrCast(mapped);
    var offset: usize = 0;
    for (regions) |region| {
        if (region.w == 0 or region.h == 0) continue;
        var row: u32 = 0;
        while (row < region.h) : (row += 1) {
            const dst_row = offset + @as(usize, row) * @as(usize, region.w);
            const src_row = @as(usize, row) * @as(usize, region.stride);
            @memcpy(staged[dst_row .. dst_row + @as(usize, region.w)], region.coverage[src_row..][0..region.w]);
        }
        offset += @as(usize, region.w) * @as(usize, region.h);
    }
    c.SDL_UnmapGPUTransferBuffer(state.device, transfer);

    const copy_pass = c.SDL_BeginGPUCopyPass(cmd);
    offset = 0;
    for (regions) |region| {
        if (region.w == 0 or region.h == 0) continue;
        const src = c.SDL_GPUTextureTransferInfo{
            .transfer_buffer = transfer,
            .offset = @intCast(offset),
            .pixels_per_row = region.w,
            .rows_per_layer = region.h,
        };
        const dst = c.SDL_GPUTextureRegion{
            .texture = state.texture,
            .mip_level = 0,
            .layer = 0,
            .x = region.x,
            .y = region.y,
            .z = 0,
            .w = region.w,
            .h = region.h,
            .d = 1,
        };
        c.SDL_UploadToGPUTexture(copy_pass, &src, &dst, region.cycle);
        offset += @as(usize, region.w) * @as(usize, region.h);
    }
    c.SDL_EndGPUCopyPass(copy_pass);
}

/// Releases the GPU objects, then the state. The device must still exist.
pub fn destroy(state: *State) void {
    if (state.upload_fence) |fence| c.SDL_ReleaseGPUFence(state.device, fence);
    if (state.nearest_sampler) |sampler| c.SDL_ReleaseGPUSampler(state.device, sampler);
    if (state.linear_sampler) |sampler| c.SDL_ReleaseGPUSampler(state.device, sampler);
    c.SDL_ReleaseGPUTexture(state.device, state.texture);
    state.allocator.destroy(state);
}

const Filter = enum { nearest, linear };

fn upload(allocator: std.mem.Allocator, device: *c.SDL_GPUDevice, width: u32, height: u32, format: c.SDL_GPUTextureFormat, pixels: []const u8, pixels_per_row: u32, rows_per_layer: u32, filter: Filter) *State {
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
    return wrap(allocator, device, texture, createSampler(device, filter), fence, filter);
}

fn wrap(allocator: std.mem.Allocator, device: *c.SDL_GPUDevice, texture: *c.SDL_GPUTexture, sampler: *c.SDL_GPUSampler, fence: ?*c.SDL_GPUFence, filter: Filter) *State {
    const state = allocator.create(State) catch @panic("out of memory");
    state.* = .{
        .device = device,
        .texture = texture,
        .nearest_sampler = if (filter == .nearest) sampler else null,
        .linear_sampler = if (filter == .linear) sampler else null,
        .upload_fence = fence,
        .allocator = allocator,
    };
    return state;
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

fn createSampler(device: *c.SDL_GPUDevice, filter: Filter) *c.SDL_GPUSampler {
    var info = std.mem.zeroes(c.SDL_GPUSamplerCreateInfo);
    info.min_filter = if (filter == .linear) c.SDL_GPU_FILTER_LINEAR else c.SDL_GPU_FILTER_NEAREST;
    info.mag_filter = if (filter == .linear) c.SDL_GPU_FILTER_LINEAR else c.SDL_GPU_FILTER_NEAREST;
    info.mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST;
    info.address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    info.address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    info.address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    return c.SDL_CreateGPUSampler(device, &info) orelse {
        std.debug.panic("SDL_CreateGPUSampler failed: {s}", .{c.SDL_GetError()});
    };
}
