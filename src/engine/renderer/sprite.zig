const std = @import("std");

const c = @import("../platform/sdl/sdl.zig").c;
const math = @import("../core/math.zig");
const shader = @import("shader.zig");
const embedded = @import("embedded_shaders");
const texture_renderer = @import("texture.zig");
const Texture = texture_renderer.Texture;
const profile = @import("../profiling/profile.zig");

/// Vertex layout for sprite quads. Positions are in normalized device coordinates. Color is RGBA:
/// the tint in RGB, and the sprite's alpha in A.
pub const Vertex = extern struct {
    pos: [2]f32,
    uv: [2]f32,
    color: [4]f32,
    sdf: f32,
};

/// A rectangle in pixels (for destinations) or texels (for sources).
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

/// Per-sprite settings beyond the source and destination rectangles. The defaults draw the sprite as
/// it is: untinted, opaque, unflipped, unrotated, and in the order it was added.
pub const Options = struct {
    /// Multiplies the texture's RGB, each channel from 0 to 1.
    tint: [3]f32 = .{ 1, 1, 1 },
    /// Multiplies the texture's alpha. 0 is invisible and 1 is opaque.
    alpha: f32 = 1,
    /// Mirrors the texture left to right, or top to bottom. The place the sprite covers stays the same.
    flip_x: bool = false,
    flip_y: bool = false,
    /// The point inside the destination rectangle, in pixels from its top-left corner, that the
    /// sprite turns around. Rotation leaves this point where it is.
    origin: [2]f32 = .{ 0, 0 },
    /// Clockwise rotation in radians around `origin`. Screen y points down, so a positive angle turns
    /// clockwise as seen on screen.
    rotation: f32 = 0,
    /// Draw order. Lower values draw first. Sprites with equal values keep the order they were added in.
    /// Batches only merge neighbors with the same texture, so alternating textures in z order costs draw calls.
    z: i32 = 0,
    /// Treat the texture alpha channel as a signed distance field and reconstruct smooth coverage.
    sdf: bool = false,
};

/// Storage starts at these sizes and doubles when a frame needs more. A frame has no sprite or
/// texture-switch limit.
const initial_sprites = 1024;
const initial_batches = 64;
/// A sprite is one quad: four vertices, drawn as two triangles through the index buffer.
const vertices_per_quad = 4;
const indices_per_quad = 6;
/// Indices are 32-bit, so one batch can hold any number of quads. 16-bit indices would cap a batch
/// at about 16 thousand.
const index_size = @sizeOf(u32);

/// The corners of one quad in the two triangles, as offsets into the quad's four vertices. drawSprite
/// writes the corners top-left, bottom-left, bottom-right, top-right, so these triangles are the ones
/// six separate vertices used to make.
const quad_corner_order = [indices_per_quad]usize{ 0, 1, 2, 0, 2, 3 };

/// The index the index buffer holds at position `k` of quad number `quad`. It is an absolute vertex
/// number in the frame's vertex storage, so a draw needs no base vertex. Each quad needs its own
/// numbers. A pattern shared by every quad would send a batch of many quads to the first quad's
/// vertices.
pub fn indexValue(quad: usize, k: usize) u32 {
    return @intCast(quad * vertices_per_quad + quad_corner_order[k]);
}

/// The sprite shaders. build.zig compiles them and embeds the code under the `decl` names in its
/// `shader_entries` table. The resource counts sit here, beside the pipeline that binds them.
const vertex_source = shader.Source{
    .name = "default.vert",
    .entry = "vertexMain",
    .stage = c.SDL_GPU_SHADERSTAGE_VERTEX,
    .code = .{ .spirv = embedded.default_vert, .dxil = embedded.default_vert_dxil, .msl = embedded.default_vert_msl },
};
const fragment_source = shader.Source{
    .name = "default.frag",
    .entry = "fragmentMain",
    .stage = c.SDL_GPU_SHADERSTAGE_FRAGMENT,
    .code = .{ .spirv = embedded.default_frag, .dxil = embedded.default_frag_dxil, .msl = embedded.default_frag_msl },
    // The fragment shader samples one texture, which takes one sampler slot.
    .resources = .{ .samplers = 1 },
};

/// One queued sprite. Its corners are in the order drawSprite writes them: top-left, bottom-left,
/// bottom-right, top-right. `seq` is the order the sprite was added in. It breaks ties in the z sort.
const Quad = struct {
    texture: *const Texture,
    corners: [vertices_per_quad]Vertex,
    z: i32,
    seq: u32,
};

/// Consecutive quads that sample the same texture, drawn in one call. `first_vertex` and
/// `vertex_count` count vertices. Public so tests can build a batch without a GPU.
pub const Batch = struct {
    texture: *const Texture,
    first_vertex: u32,
    vertex_count: u32,
};

const SpriteBatchHandle = opaque {};

const SpriteGpuState = struct {
    device: *c.SDL_GPUDevice,
    pipeline: *c.SDL_GPUGraphicsPipeline,
    vertex_buffer: *c.SDL_GPUBuffer,
    vb_binding: c.SDL_GPUBufferBinding,
    upload_buffer: *c.SDL_GPUTransferBuffer,
    index_buffer: *c.SDL_GPUBuffer,
    ib_binding: c.SDL_GPUBufferBinding,
    index_filled: bool = false,
    index_staging: ?*c.SDL_GPUTransferBuffer = null,
    gpu_vertex_capacity: usize,
};

pub const SpriteBatch = struct {
    gpu_state: *SpriteBatchHandle,
    allocator: std.mem.Allocator,

    /// Sprites queued this frame, in the order they were added. `prepare` sorts them by z in place.
    /// Heap-allocated, and doubled when a frame needs more.
    quads: []Quad = &.{},
    /// Sprites queued this frame. Each one is a quad.
    sprite_count: u32 = 0,

    /// CPU-side vertices for the current frame, in draw order. `prepare` fills them.
    vertices: []Vertex,
    vertex_count: u32 = 0,
    /// Runs of sprites that share a texture, in draw order. `prepare` fills them.
    batches: []Batch,
    batch_count: u32 = 0,
    /// Draw calls issued by draw() this frame. Shows whether batching is working.
    draw_calls: u32 = 0,
    /// Maps pixel coordinates in the viewport to normalized device coordinates. Set by `begin`.
    projection: math.Mat4 = undefined,

    /// Builds the pipeline and GPU buffers. `color_format` is the swapchain format
    /// the sprites render into.
    fn init(allocator: std.mem.Allocator, device: *c.SDL_GPUDevice, color_format: c.SDL_GPUTextureFormat) SpriteBatch {
        const format = shader.pickFormat(device);
        const vert = shader.load(device, format, vertex_source);
        defer c.SDL_ReleaseGPUShader(device, vert);
        const frag = shader.load(device, format, fragment_source);
        defer c.SDL_ReleaseGPUShader(device, frag);

        // Alpha blending, so transparent pixels show what's behind them.
        var color_desc = std.mem.zeroes(c.SDL_GPUColorTargetDescription);
        color_desc.format = color_format;
        color_desc.blend_state = .{
            .enable_blend = true,
            .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_SRC_ALPHA,
            .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
            .color_blend_op = c.SDL_GPU_BLENDOP_ADD,
            .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
            .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
            .alpha_blend_op = c.SDL_GPU_BLENDOP_ADD,
        };

        var vb_desc = std.mem.zeroes(c.SDL_GPUVertexBufferDescription);
        vb_desc.slot = 0;
        vb_desc.pitch = @sizeOf(Vertex);
        vb_desc.input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX;

        // Locations must match the [vk::location] values in shaders/default.slang.
        var vb_attrs = [_]c.SDL_GPUVertexAttribute{
            .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(Vertex, "pos") },
            .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(Vertex, "uv") },
            .{ .location = 2, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4, .offset = @offsetOf(Vertex, "color") },
            .{ .location = 3, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT, .offset = @offsetOf(Vertex, "sdf") },
        };

        var pipeline_info = std.mem.zeroes(c.SDL_GPUGraphicsPipelineCreateInfo);
        pipeline_info.vertex_shader = vert;
        pipeline_info.fragment_shader = frag;
        pipeline_info.vertex_input_state.vertex_buffer_descriptions = &vb_desc;
        pipeline_info.vertex_input_state.num_vertex_buffers = 1;
        pipeline_info.vertex_input_state.vertex_attributes = &vb_attrs;
        pipeline_info.vertex_input_state.num_vertex_attributes = @intCast(vb_attrs.len);
        pipeline_info.primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
        pipeline_info.depth_stencil_state.compare_op = c.SDL_GPU_COMPAREOP_ALWAYS;
        pipeline_info.target_info.num_color_targets = 1;
        pipeline_info.target_info.color_target_descriptions = &color_desc;

        const pipeline = c.SDL_CreateGPUGraphicsPipeline(device, &pipeline_info) orelse {
            std.debug.panic("SDL_CreateGPUGraphicsPipeline failed: {s}", .{c.SDL_GetError()});
        };

        // The GPU buffers start at the initial size and are replaced when a frame needs more. The
        // index buffer has one set of six indices for each quad the vertex buffer holds.
        const gpu_vertex_capacity = initial_sprites * vertices_per_quad;
        const vertex_buffer = createVertexBuffer(device, gpu_vertex_capacity);
        const upload_buffer = createUploadBuffer(device, gpu_vertex_capacity);
        const index_buffer = createIndexBuffer(device, gpu_vertex_capacity / vertices_per_quad);
        const gpu_state = allocator.create(SpriteGpuState) catch @panic("out of memory");
        gpu_state.* = .{
            .device = device,
            .pipeline = pipeline,
            .vertex_buffer = vertex_buffer,
            .vb_binding = .{ .buffer = vertex_buffer, .offset = 0 },
            .upload_buffer = upload_buffer,
            .index_buffer = index_buffer,
            .ib_binding = .{ .buffer = index_buffer, .offset = 0 },
            .gpu_vertex_capacity = gpu_vertex_capacity,
        };

        return .{
            .gpu_state = @ptrCast(gpu_state),
            .allocator = allocator,
            .quads = allocQuads(allocator, initial_sprites),
            .vertices = allocVertices(allocator, gpu_vertex_capacity),
            .batches = allocBatches(allocator, initial_batches),
            .projection = math.ortho2d(1.0, 1.0),
        };
    }

    /// Starts a new frame of sprites. `viewport_w` and `viewport_h` are the drawing area in pixels,
    /// with (0,0) at the top-left.
    pub fn begin(self: *SpriteBatch, viewport_w: f32, viewport_h: f32) void {
        self.sprite_count = 0;
        self.vertex_count = 0;
        self.batch_count = 0;
        self.draw_calls = 0;
        self.projection = math.ortho2d(viewport_w, viewport_h);
    }

    /// Queues one sprite. `src` is the texel rectangle to sample, and `dst` is the on-screen rectangle
    /// in pixels, before `opts` applies. `opts` sets the tint, alpha, flip, origin, rotation, and z.
    /// Sprites draw in z order, and sprites with equal z draw in the order they were added.
    pub fn drawSprite(self: *SpriteBatch, texture: *const Texture, src: Rect, dst: Rect, opts: Options) void {
        // Make room before writing. Storage doubles when it fills, so a frame has no sprite limit.
        if (self.sprite_count == self.quads.len) self.growQuads(self.sprite_count + 1);
        self.quads[self.sprite_count] = .{
            .texture = texture,
            .corners = cornersFor(&self.projection, texture, src, dst, opts),
            .z = opts.z,
            .seq = self.sprite_count,
        };
        self.sprite_count += 1;
    }

    /// Puts this frame's sprites in draw order, and writes their vertices and texture runs. `upload`
    /// calls this, and so do tests, which have no GPU. It rebuilds the same result if it runs again.
    pub fn prepare(self: *SpriteBatch) void {
        const zone = profile.zoneNamed(@src(), "sprite prepare");
        defer zone.End();
        const queued = self.quads[0..self.sprite_count];
        if (!inZOrder(queued)) heapSort(queued);

        self.vertex_count = 0;
        self.batch_count = 0;
        const needed = @as(usize, self.sprite_count) * vertices_per_quad;
        if (needed > self.vertices.len) self.growVertices(needed);

        for (queued) |quad| {
            // Start a new run whenever the texture changes. Runs double too, so there is no switch limit.
            if (self.batch_count == 0 or self.batches[self.batch_count - 1].texture != quad.texture) {
                if (self.batch_count == self.batches.len) self.growBatches(self.batch_count + 1);
                self.batches[self.batch_count] = .{
                    .texture = quad.texture,
                    .first_vertex = self.vertex_count,
                    .vertex_count = 0,
                };
                self.batch_count += 1;
            }
            self.batches[self.batch_count - 1].vertex_count += vertices_per_quad;
            for (quad.corners) |corner| {
                self.vertices[self.vertex_count] = corner;
                self.vertex_count += 1;
            }
        }
    }

    /// Copies this frame's vertices to the GPU. Call before beginPass, since the copy
    /// has to happen outside a render pass.
    fn upload(self: *SpriteBatch, cmd: *c.SDL_GPUCommandBuffer) void {
        const zone = profile.zoneNamed(@src(), "sprite upload");
        defer zone.End();
        const gpu = spriteGpuState(self);
        self.prepare();
        if (self.vertex_count == 0) return;
        if (self.vertex_count > gpu.gpu_vertex_capacity) self.growGpuBuffers(self.vertex_count);
        if (!gpu.index_filled) self.fillIndexBuffer(cmd);
        const bytes = vertexBytes(self.vertex_count);

        // cycle = true lets SDL hand us a fresh buffer if the GPU is still reading the last one.
        const mapped = c.SDL_MapGPUTransferBuffer(gpu.device, gpu.upload_buffer, true) orelse {
            std.debug.panic("SDL_MapGPUTransferBuffer failed: {s}", .{c.SDL_GetError()});
        };
        const dst: [*]u8 = @ptrCast(mapped);
        @memcpy(dst[0..bytes], std.mem.sliceAsBytes(self.vertices[0..self.vertex_count]));
        c.SDL_UnmapGPUTransferBuffer(gpu.device, gpu.upload_buffer);

        const copy_pass = c.SDL_BeginGPUCopyPass(cmd);
        const src = c.SDL_GPUTransferBufferLocation{ .transfer_buffer = gpu.upload_buffer, .offset = 0 };
        const region = c.SDL_GPUBufferRegion{ .buffer = gpu.vertex_buffer, .offset = 0, .size = bytes };
        c.SDL_UploadToGPUBuffer(copy_pass, &src, &region, true);
        c.SDL_EndGPUCopyPass(copy_pass);
    }

    /// Records one draw call per batch. Call inside a render pass, after upload().
    fn draw(self: *SpriteBatch, pass: ?*c.SDL_GPURenderPass) void {
        const zone = profile.zoneNamed(@src(), "sprite draw");
        defer zone.End();
        if (self.batch_count == 0) return;
        const gpu = spriteGpuState(self);

        c.SDL_BindGPUGraphicsPipeline(pass, gpu.pipeline);
        c.SDL_BindGPUVertexBuffers(pass, 0, &gpu.vb_binding, 1);
        c.SDL_BindGPUIndexBuffer(pass, &gpu.ib_binding, c.SDL_GPU_INDEXELEMENTSIZE_32BIT);

        for (self.batches[0..self.batch_count]) |batch| {
            // A texture whose upload is still running has nothing to sample yet. Skip its batch this
            // frame. The game queues the sprite again next frame.
            if (!batch.texture.isReady()) continue;
            const sampler = texture_renderer.backendBinding(batch.texture);
            c.SDL_BindGPUFragmentSamplers(pass, 0, &sampler, 1);
            // The indices name absolute vertices, so the draw starts at this batch's first quad in the
            // index buffer and uses no base vertex.
            const first_quad = batch.first_vertex / vertices_per_quad;
            const quads = batch.vertex_count / vertices_per_quad;
            c.SDL_DrawGPUIndexedPrimitives(pass, quads * indices_per_quad, 1, first_quad * indices_per_quad, 0, 0);
            self.draw_calls += 1;
        }
    }

    /// Doubles the quad storage until it holds `needed` sprites. Sprites already queued this frame
    /// are kept.
    fn growQuads(self: *SpriteBatch, needed: usize) void {
        const bigger = allocQuads(self.allocator, grownCapacity(self.quads.len, needed));
        @memcpy(bigger[0..self.sprite_count], self.quads[0..self.sprite_count]);
        freeSlice(self.allocator, Quad, self.quads);
        self.quads = bigger;
    }

    /// Doubles the vertex storage until it holds `needed` vertices. Vertices already written this
    /// frame are kept.
    fn growVertices(self: *SpriteBatch, needed: usize) void {
        const bigger = allocVertices(self.allocator, grownCapacity(self.vertices.len, needed));
        @memcpy(bigger[0..self.vertex_count], self.vertices[0..self.vertex_count]);
        freeSlice(self.allocator, Vertex, self.vertices);
        self.vertices = bigger;
    }

    /// Doubles the batch storage until it holds `needed` batches. Batches already built this frame
    /// are kept.
    fn growBatches(self: *SpriteBatch, needed: usize) void {
        const bigger = allocBatches(self.allocator, grownCapacity(self.batches.len, needed));
        @memcpy(bigger[0..self.batch_count], self.batches[0..self.batch_count]);
        freeSlice(self.allocator, Batch, self.batches);
        self.batches = bigger;
    }

    /// Replaces the GPU vertex, upload, and index buffers with ones that hold `needed` vertices. The
    /// old buffers are released at once. SDL frees each one after the frames still using it finish,
    /// so this doesn't wait for the GPU. The new index buffer is written by the next upload.
    fn growGpuBuffers(self: *SpriteBatch, needed: usize) void {
        const gpu = spriteGpuState(self);
        const capacity = grownCapacity(gpu.gpu_vertex_capacity, needed);
        c.SDL_ReleaseGPUBuffer(gpu.device, gpu.vertex_buffer);
        c.SDL_ReleaseGPUTransferBuffer(gpu.device, gpu.upload_buffer);
        c.SDL_ReleaseGPUBuffer(gpu.device, gpu.index_buffer);
        if (gpu.index_staging) |staging| c.SDL_ReleaseGPUTransferBuffer(gpu.device, staging);
        gpu.index_staging = null;
        gpu.vertex_buffer = createVertexBuffer(gpu.device, capacity);
        gpu.upload_buffer = createUploadBuffer(gpu.device, capacity);
        gpu.index_buffer = createIndexBuffer(gpu.device, capacity / vertices_per_quad);
        gpu.vb_binding = .{ .buffer = gpu.vertex_buffer, .offset = 0 };
        gpu.ib_binding = .{ .buffer = gpu.index_buffer, .offset = 0 };
        gpu.gpu_vertex_capacity = capacity;
        gpu.index_filled = false;
    }

    /// Writes the index of every quad corner into the whole index buffer. The indices name this
    /// frame's vertices, so no draw needs a base vertex. The copy is recorded on `cmd`, so it runs
    /// before this frame's draws. The contents depend only on the capacity, so this runs once per
    /// creation.
    fn fillIndexBuffer(self: *SpriteBatch, cmd: *c.SDL_GPUCommandBuffer) void {
        const gpu = spriteGpuState(self);
        const quads = gpu.gpu_vertex_capacity / vertices_per_quad;
        const bytes = indexBytes(quads);

        if (gpu.index_staging == null) {
            var info = std.mem.zeroes(c.SDL_GPUTransferBufferCreateInfo);
            info.usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
            info.size = bytes;
            gpu.index_staging = c.SDL_CreateGPUTransferBuffer(gpu.device, &info) orelse {
                std.debug.panic("SDL_CreateGPUTransferBuffer failed: {s}", .{c.SDL_GetError()});
            };
        }
        const staging = gpu.index_staging.?;

        const mapped = c.SDL_MapGPUTransferBuffer(gpu.device, staging, false) orelse {
            std.debug.panic("SDL_MapGPUTransferBuffer failed: {s}", .{c.SDL_GetError()});
        };
        const dst: [*]u8 = @ptrCast(mapped);
        for (0..quads) |quad| {
            for (0..indices_per_quad) |k| {
                const at = (quad * indices_per_quad + k) * index_size;
                std.mem.writeInt(u32, dst[at .. at + index_size][0..index_size], indexValue(quad, k), .little);
            }
        }
        c.SDL_UnmapGPUTransferBuffer(gpu.device, staging);

        const copy_pass = c.SDL_BeginGPUCopyPass(cmd);
        const src = c.SDL_GPUTransferBufferLocation{ .transfer_buffer = staging, .offset = 0 };
        const region = c.SDL_GPUBufferRegion{ .buffer = gpu.index_buffer, .offset = 0, .size = bytes };
        c.SDL_UploadToGPUBuffer(copy_pass, &src, &region, false);
        c.SDL_EndGPUCopyPass(copy_pass);

        gpu.index_filled = true;
    }

    /// Releases GPU resources. Call before the renderer is deinitialized.
    pub fn deinit(self: *SpriteBatch) void {
        const gpu = spriteGpuState(self);
        c.SDL_ReleaseGPUTransferBuffer(gpu.device, gpu.upload_buffer);
        if (gpu.index_staging) |staging| c.SDL_ReleaseGPUTransferBuffer(gpu.device, staging);
        c.SDL_ReleaseGPUBuffer(gpu.device, gpu.index_buffer);
        c.SDL_ReleaseGPUBuffer(gpu.device, gpu.vertex_buffer);
        c.SDL_ReleaseGPUGraphicsPipeline(gpu.device, gpu.pipeline);
        freeSlice(self.allocator, Quad, self.quads);
        freeSlice(self.allocator, Vertex, self.vertices);
        freeSlice(self.allocator, Batch, self.batches);
        self.allocator.destroy(gpu);
        self.* = undefined;
    }
};

pub fn create(allocator: std.mem.Allocator, device: *c.SDL_GPUDevice, color_format: c.SDL_GPUTextureFormat) SpriteBatch {
    return SpriteBatch.init(allocator, device, color_format);
}

pub fn upload(batch: *SpriteBatch, cmd: *c.SDL_GPUCommandBuffer) void {
    batch.upload(cmd);
}

pub fn draw(batch: *SpriteBatch, pass: ?*c.SDL_GPURenderPass) void {
    batch.draw(pass);
}

fn spriteGpuState(batch: *const SpriteBatch) *SpriteGpuState {
    return @ptrCast(@alignCast(batch.gpu_state));
}

/// The four corners of one sprite in pixels, through `projection`. The texture coordinates, flip,
/// origin, rotation, and color are applied. The order is top-left, bottom-left, bottom-right, top-right.
fn cornersFor(projection: *const math.Mat4, texture: *const Texture, src: Rect, dst: Rect, opts: Options) [vertices_per_quad]Vertex {
    // Texel rectangle -> UV coordinates (0..1). A flip swaps the two ends of an axis.
    // Names avoid u0/u1, which are Zig's unsigned integer type names.
    const tw: f32 = @floatFromInt(texture.width);
    const th: f32 = @floatFromInt(texture.height);
    var u_left = src.x / tw;
    var u_right = (src.x + src.w) / tw;
    var v_top = src.y / th;
    var v_bottom = (src.y + src.h) / th;
    if (opts.flip_x) std.mem.swap(f32, &u_left, &u_right);
    if (opts.flip_y) std.mem.swap(f32, &v_top, &v_bottom);

    // The corners relative to the origin, before rotation. The origin is the pivot, and it stays at
    // dst.x + origin[0], dst.y + origin[1].
    const ox = opts.origin[0];
    const oy = opts.origin[1];
    const s = @sin(opts.rotation);
    const co = @cos(opts.rotation);
    const pivot_x = dst.x + ox;
    const pivot_y = dst.y + oy;
    const o_tl = turned(-ox, -oy, s, co);
    const o_bl = turned(-ox, dst.h - oy, s, co);
    const o_br = turned(dst.w - ox, dst.h - oy, s, co);
    const o_tr = turned(dst.w - ox, -oy, s, co);

    const p_tl = math.transformPoint(projection, pivot_x + o_tl[0], pivot_y + o_tl[1]);
    const p_bl = math.transformPoint(projection, pivot_x + o_bl[0], pivot_y + o_bl[1]);
    const p_br = math.transformPoint(projection, pivot_x + o_br[0], pivot_y + o_br[1]);
    const p_tr = math.transformPoint(projection, pivot_x + o_tr[0], pivot_y + o_tr[1]);

    const color = [4]f32{ opts.tint[0], opts.tint[1], opts.tint[2], opts.alpha };
    const sdf: f32 = if (opts.sdf) 1 else 0;
    return .{
        .{ .pos = p_tl, .uv = .{ u_left, v_top }, .color = color, .sdf = sdf },
        .{ .pos = p_bl, .uv = .{ u_left, v_bottom }, .color = color, .sdf = sdf },
        .{ .pos = p_br, .uv = .{ u_right, v_bottom }, .color = color, .sdf = sdf },
        .{ .pos = p_tr, .uv = .{ u_right, v_top }, .color = color, .sdf = sdf },
    };
}

/// An offset (x, y) turned clockwise by the angle with sine `s` and cosine `co`. Screen y points
/// down, so this turns clockwise as seen on screen.
fn turned(x: f32, y: f32, s: f32, co: f32) [2]f32 {
    return .{ x * co - y * s, x * s + y * co };
}

/// True when the quads are already in non-decreasing z order, so no sort is needed. Most frames are.
fn inZOrder(quads: []const Quad) bool {
    var i: usize = 1;
    while (i < quads.len) : (i += 1) {
        if (quads[i].z < quads[i - 1].z) return false;
    }
    return true;
}

/// Quads sort by z, and then by the order they were added. The second key makes every quad distinct,
/// so the heap sort below gives the same result a stable sort would.
fn quadBefore(a: Quad, b: Quad) bool {
    return a.z < b.z or (a.z == b.z and a.seq < b.seq);
}

/// Sifts the quad at `root` down until the heap property holds below it, within the first `end` quads.
fn siftDown(quads: []Quad, root_start: usize, end: usize) void {
    var root = root_start;
    while (true) {
        var child = 2 * root + 1;
        if (child >= end) return;
        if (child + 1 < end and quadBefore(quads[child], quads[child + 1])) child += 1;
        if (!quadBefore(quads[root], quads[child])) return;
        std.mem.swap(Quad, &quads[root], &quads[child]);
        root = child;
    }
}

/// Sorts the quads in place by z, then by insertion order. Heap sort needs no extra memory.
fn heapSort(quads: []Quad) void {
    if (quads.len < 2) return;
    var start = quads.len / 2;
    while (start > 0) {
        start -= 1;
        siftDown(quads, start, quads.len);
    }
    var end = quads.len;
    while (end > 1) {
        end -= 1;
        std.mem.swap(Quad, &quads[0], &quads[end]);
        siftDown(quads, 0, end);
    }
}

/// Creates a GPU vertex buffer that holds `vertex_count` vertices.
fn createVertexBuffer(device: *c.SDL_GPUDevice, vertex_count: usize) *c.SDL_GPUBuffer {
    var info = std.mem.zeroes(c.SDL_GPUBufferCreateInfo);
    info.usage = c.SDL_GPU_BUFFERUSAGE_VERTEX;
    info.size = vertexBytes(vertex_count);
    return c.SDL_CreateGPUBuffer(device, &info) orelse {
        std.debug.panic("SDL_CreateGPUBuffer failed: {s}", .{c.SDL_GetError()});
    };
}

/// Creates a GPU index buffer that holds the indices of `quad_count` quads.
fn createIndexBuffer(device: *c.SDL_GPUDevice, quad_count: usize) *c.SDL_GPUBuffer {
    var info = std.mem.zeroes(c.SDL_GPUBufferCreateInfo);
    info.usage = c.SDL_GPU_BUFFERUSAGE_INDEX;
    info.size = indexBytes(quad_count);
    return c.SDL_CreateGPUBuffer(device, &info) orelse {
        std.debug.panic("SDL_CreateGPUBuffer failed: {s}", .{c.SDL_GetError()});
    };
}

/// Creates the staging buffer that the CPU writes a frame's vertices into.
fn createUploadBuffer(device: *c.SDL_GPUDevice, vertex_count: usize) *c.SDL_GPUTransferBuffer {
    var info = std.mem.zeroes(c.SDL_GPUTransferBufferCreateInfo);
    info.usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
    info.size = vertexBytes(vertex_count);
    return c.SDL_CreateGPUTransferBuffer(device, &info) orelse {
        std.debug.panic("SDL_CreateGPUTransferBuffer failed: {s}", .{c.SDL_GetError()});
    };
}

/// The byte size of `vertex_count` vertices. SDL takes buffer sizes as 32-bit integers, so this is
/// the one ceiling left: about 33 million sprites in a single frame.
fn vertexBytes(vertex_count: usize) u32 {
    const bytes = vertex_count * @sizeOf(Vertex);
    if (bytes > std.math.maxInt(u32)) {
        std.debug.panic("a frame of {d} vertices needs {d} bytes, more than SDL's 32-bit buffer size allows", .{ vertex_count, bytes });
    }
    return @intCast(bytes);
}

/// The byte size of the indices for `quad_count` quads. Each quad has six indices.
fn indexBytes(quad_count: usize) u32 {
    const bytes = quad_count * indices_per_quad * index_size;
    if (bytes > std.math.maxInt(u32)) {
        std.debug.panic("{d} quads need {d} index bytes, more than SDL's 32-bit buffer size allows", .{ quad_count, bytes });
    }
    return @intCast(bytes);
}

/// The capacity to grow to: `current` doubled, starting from at least 1, until it holds `needed`.
fn grownCapacity(current: usize, needed: usize) usize {
    var capacity = @max(current, 1);
    while (capacity < needed) capacity *= 2;
    return capacity;
}

fn allocQuads(allocator: std.mem.Allocator, count: usize) []Quad {
    return allocator.alloc(Quad, count) catch @panic("out of memory");
}

fn allocVertices(allocator: std.mem.Allocator, count: usize) []Vertex {
    return allocator.alloc(Vertex, count) catch @panic("out of memory");
}

fn allocBatches(allocator: std.mem.Allocator, count: usize) []Batch {
    return allocator.alloc(Batch, count) catch @panic("out of memory");
}

/// Frees storage from `allocQuads`, `allocVertices`, or `allocBatches`. A zero-length slice owns no
/// memory, so it is skipped.
fn freeSlice(allocator: std.mem.Allocator, comptime T: type, slice: []T) void {
    if (slice.len != 0) allocator.free(slice);
}
