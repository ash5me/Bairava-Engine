const std = @import("std");

const c = @import("sdl.zig").c;
const math = @import("math.zig");
const shader = @import("shader.zig");
const embedded = @import("embedded_shaders");
const Texture = @import("texture.zig").Texture;

/// Vertex layout for sprite quads. Positions are in normalized device coordinates.
pub const Vertex = extern struct {
    pos: [2]f32,
    uv: [2]f32,
    color: [3]f32,
};

/// A rectangle in pixels (for destinations) or texels (for sources).
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

/// Storage starts at these sizes and doubles when a frame needs more. A frame has no sprite or
/// texture-switch limit.
const initial_sprites = 1024;
const initial_batches = 64;
const vertices_per_sprite = 6;

/// The sprite shaders. build.zig compiles them and embeds the code under the `decl` names in its
/// `shader_entries` table. The resource counts sit here, beside the pipeline that binds them.
const vertex_source = shader.Source{
    .name = "default.vert",
    .entry = "vertexMain",
    .stage = c.SDL_GPU_SHADERSTAGE_VERTEX,
    .code = .{ .spirv = embedded.default_vert, .dxil = embedded.default_vert_dxil },
};
const fragment_source = shader.Source{
    .name = "default.frag",
    .entry = "fragmentMain",
    .stage = c.SDL_GPU_SHADERSTAGE_FRAGMENT,
    .code = .{ .spirv = embedded.default_frag, .dxil = embedded.default_frag_dxil },
    // The fragment shader samples one texture, which takes one sampler slot.
    .resources = .{ .samplers = 1 },
};

/// Consecutive vertices that sample the same texture, drawn in one call. Public so tests can build
/// a batch without a GPU.
pub const Batch = struct {
    texture: *const Texture,
    first_vertex: u32,
    vertex_count: u32,
};

pub const SpriteBatch = struct {
    device: *c.SDL_GPUDevice,
    pipeline: *c.SDL_GPUGraphicsPipeline,
    vertex_buffer: *c.SDL_GPUBuffer,
    vb_binding: c.SDL_GPUBufferBinding,
    upload_buffer: *c.SDL_GPUTransferBuffer,

    /// CPU-side vertices for the current frame. Heap-allocated, and doubled when a frame needs more.
    vertices: []Vertex,
    vertex_count: u32 = 0,
    sprite_count: u32 = 0,
    /// Runs of sprites that share a texture. Heap-allocated, and doubled when a frame needs more.
    batches: []Batch,
    batch_count: u32 = 0,
    /// How many vertices the GPU vertex and upload buffers hold. They are replaced when a frame needs more.
    gpu_vertex_capacity: usize = 0,
    /// Draw calls issued by draw() this frame. Shows whether batching is working.
    draw_calls: u32 = 0,
    /// Maps pixel coordinates in the viewport to normalized device coordinates. Set by `begin`.
    projection: math.Mat4 = undefined,

    /// Builds the pipeline and GPU buffers. `color_format` is the swapchain format
    /// the sprites render into.
    pub fn init(device: *c.SDL_GPUDevice, color_format: c.SDL_GPUTextureFormat) SpriteBatch {
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
            .{ .location = 2, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3, .offset = @offsetOf(Vertex, "color") },
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

        // The GPU buffers start at the initial size and are replaced when a frame needs more.
        const gpu_vertex_capacity = initial_sprites * vertices_per_sprite;
        const vertex_buffer = createVertexBuffer(device, gpu_vertex_capacity);
        const upload_buffer = createUploadBuffer(device, gpu_vertex_capacity);

        return .{
            .device = device,
            .pipeline = pipeline,
            .vertex_buffer = vertex_buffer,
            .vb_binding = .{ .buffer = vertex_buffer, .offset = 0 },
            .upload_buffer = upload_buffer,
            .vertices = allocVertices(gpu_vertex_capacity),
            .batches = allocBatches(initial_batches),
            .gpu_vertex_capacity = gpu_vertex_capacity,
            .projection = math.ortho2d(1.0, 1.0),
        };
    }

    /// Starts a new frame of sprites. `viewport_w` and `viewport_h` are the drawing area in pixels,
    /// with (0,0) at the top-left.
    pub fn begin(self: *SpriteBatch, viewport_w: f32, viewport_h: f32) void {
        self.vertex_count = 0;
        self.sprite_count = 0;
        self.batch_count = 0;
        self.draw_calls = 0;
        self.projection = math.ortho2d(viewport_w, viewport_h);
    }

    /// Queues one sprite. `src` is the texel rectangle to sample, `dst` is the on-screen
    /// rectangle in pixels, and `tint` multiplies the texture color.
    /// Sprites draw in the order they're added.
    pub fn drawSprite(self: *SpriteBatch, texture: *const Texture, src: Rect, dst: Rect, tint: [3]f32) void {
        // Make room before writing. Storage doubles when it fills, so a frame has no sprite limit.
        const needed_vertices = self.vertex_count + vertices_per_sprite;
        if (needed_vertices > self.vertices.len) self.growVertices(needed_vertices);

        // Start a new batch whenever the texture changes. Batches double too, so there is no switch limit.
        if (self.batch_count == 0 or self.batches[self.batch_count - 1].texture != texture) {
            if (self.batch_count == self.batches.len) self.growBatches(self.batch_count + 1);
            self.batches[self.batch_count] = .{
                .texture = texture,
                .first_vertex = self.vertex_count,
                .vertex_count = 0,
            };
            self.batch_count += 1;
        }
        self.batches[self.batch_count - 1].vertex_count += vertices_per_sprite;

        // Texel rectangle -> UV coordinates (0..1).
        // Names avoid u0/u1, which are Zig's unsigned integer type names.
        const tw: f32 = @floatFromInt(texture.width);
        const th: f32 = @floatFromInt(texture.height);
        const u_left = src.x / tw;
        const v_top = src.y / th;
        const u_right = (src.x + src.w) / tw;
        const v_bottom = (src.y + src.h) / th;

        // Pixel corners (top-left origin) -> normalized device coordinates (y up), through the projection.
        const p_tl = math.transformPoint(&self.projection, dst.x, dst.y);
        const p_tr = math.transformPoint(&self.projection, dst.x + dst.w, dst.y);
        const p_br = math.transformPoint(&self.projection, dst.x + dst.w, dst.y + dst.h);
        const p_bl = math.transformPoint(&self.projection, dst.x, dst.y + dst.h);

        const tl = Vertex{ .pos = p_tl, .uv = .{ u_left, v_top }, .color = tint };
        const tr = Vertex{ .pos = p_tr, .uv = .{ u_right, v_top }, .color = tint };
        const br = Vertex{ .pos = p_br, .uv = .{ u_right, v_bottom }, .color = tint };
        const bl = Vertex{ .pos = p_bl, .uv = .{ u_left, v_bottom }, .color = tint };

        const start = self.vertex_count;
        self.vertices[start + 0] = tl;
        self.vertices[start + 1] = bl;
        self.vertices[start + 2] = br;
        self.vertices[start + 3] = tl;
        self.vertices[start + 4] = br;
        self.vertices[start + 5] = tr;

        self.vertex_count += vertices_per_sprite;
        self.sprite_count += 1;
    }

    /// Copies this frame's vertices to the GPU. Call before beginPass, since the copy
    /// has to happen outside a render pass.
    pub fn upload(self: *SpriteBatch, cmd: *c.SDL_GPUCommandBuffer) void {
        if (self.vertex_count == 0) return;
        if (self.vertex_count > self.gpu_vertex_capacity) self.growGpuBuffers(self.vertex_count);
        const bytes = vertexBytes(self.vertex_count);

        // cycle = true lets SDL hand us a fresh buffer if the GPU is still reading the last one.
        const mapped = c.SDL_MapGPUTransferBuffer(self.device, self.upload_buffer, true) orelse {
            std.debug.panic("SDL_MapGPUTransferBuffer failed: {s}", .{c.SDL_GetError()});
        };
        const dst: [*]u8 = @ptrCast(mapped);
        @memcpy(dst[0..bytes], std.mem.sliceAsBytes(self.vertices[0..self.vertex_count]));
        c.SDL_UnmapGPUTransferBuffer(self.device, self.upload_buffer);

        const copy_pass = c.SDL_BeginGPUCopyPass(cmd);
        const src = c.SDL_GPUTransferBufferLocation{ .transfer_buffer = self.upload_buffer, .offset = 0 };
        const region = c.SDL_GPUBufferRegion{ .buffer = self.vertex_buffer, .offset = 0, .size = bytes };
        c.SDL_UploadToGPUBuffer(copy_pass, &src, &region, true);
        c.SDL_EndGPUCopyPass(copy_pass);
    }

    /// Records one draw call per batch. Call inside a render pass, after upload().
    pub fn draw(self: *SpriteBatch, pass: ?*c.SDL_GPURenderPass) void {
        if (self.batch_count == 0) return;

        c.SDL_BindGPUGraphicsPipeline(pass, self.pipeline);
        c.SDL_BindGPUVertexBuffers(pass, 0, &self.vb_binding, 1);

        for (self.batches[0..self.batch_count]) |batch| {
            // A texture whose upload is still running has nothing to sample yet. Skip its batch this
            // frame. The game queues the sprite again next frame.
            if (!batch.texture.isReady()) continue;
            const sampler = batch.texture.binding();
            c.SDL_BindGPUFragmentSamplers(pass, 0, &sampler, 1);
            c.SDL_DrawGPUPrimitives(pass, batch.vertex_count, 1, batch.first_vertex, 0);
            self.draw_calls += 1;
        }
    }

    /// Doubles the vertex storage until it holds `needed` vertices. Vertices already queued this
    /// frame are kept.
    fn growVertices(self: *SpriteBatch, needed: usize) void {
        const bigger = allocVertices(grownCapacity(self.vertices.len, needed));
        @memcpy(bigger[0..self.vertex_count], self.vertices[0..self.vertex_count]);
        freeSlice(Vertex, self.vertices);
        self.vertices = bigger;
    }

    /// Doubles the batch storage until it holds `needed` batches. Batches already queued this frame
    /// are kept.
    fn growBatches(self: *SpriteBatch, needed: usize) void {
        const bigger = allocBatches(grownCapacity(self.batches.len, needed));
        @memcpy(bigger[0..self.batch_count], self.batches[0..self.batch_count]);
        freeSlice(Batch, self.batches);
        self.batches = bigger;
    }

    /// Replaces the GPU vertex and upload buffers with ones that hold `needed` vertices. The old
    /// buffers are released at once. SDL frees each one after the frames still using it finish, so
    /// this doesn't wait for the GPU.
    fn growGpuBuffers(self: *SpriteBatch, needed: usize) void {
        const capacity = grownCapacity(self.gpu_vertex_capacity, needed);
        c.SDL_ReleaseGPUBuffer(self.device, self.vertex_buffer);
        c.SDL_ReleaseGPUTransferBuffer(self.device, self.upload_buffer);
        self.vertex_buffer = createVertexBuffer(self.device, capacity);
        self.upload_buffer = createUploadBuffer(self.device, capacity);
        self.vb_binding = .{ .buffer = self.vertex_buffer, .offset = 0 };
        self.gpu_vertex_capacity = capacity;
    }

    /// Releases GPU resources. Call before the renderer is deinitialized.
    pub fn deinit(self: *SpriteBatch) void {
        c.SDL_ReleaseGPUTransferBuffer(self.device, self.upload_buffer);
        c.SDL_ReleaseGPUBuffer(self.device, self.vertex_buffer);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.pipeline);
        freeSlice(Vertex, self.vertices);
        freeSlice(Batch, self.batches);
    }
};

/// Creates a GPU vertex buffer that holds `vertex_count` vertices.
fn createVertexBuffer(device: *c.SDL_GPUDevice, vertex_count: usize) *c.SDL_GPUBuffer {
    var info = std.mem.zeroes(c.SDL_GPUBufferCreateInfo);
    info.usage = c.SDL_GPU_BUFFERUSAGE_VERTEX;
    info.size = vertexBytes(vertex_count);
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
/// the one ceiling left: about 25 million sprites in a single frame.
fn vertexBytes(vertex_count: usize) u32 {
    const bytes = vertex_count * @sizeOf(Vertex);
    if (bytes > std.math.maxInt(u32)) {
        std.debug.panic("a frame of {d} vertices needs {d} bytes, more than SDL's 32-bit buffer size allows", .{ vertex_count, bytes });
    }
    return @intCast(bytes);
}

/// The capacity to grow to: `current` doubled, starting from at least 1, until it holds `needed`.
fn grownCapacity(current: usize, needed: usize) usize {
    var capacity = @max(current, 1);
    while (capacity < needed) capacity *= 2;
    return capacity;
}

fn allocVertices(count: usize) []Vertex {
    return std.heap.page_allocator.alloc(Vertex, count) catch @panic("out of memory");
}

fn allocBatches(count: usize) []Batch {
    return std.heap.page_allocator.alloc(Batch, count) catch @panic("out of memory");
}

/// Frees storage from `allocVertices` or `allocBatches`. A zero-length slice owns no memory, so it is skipped.
fn freeSlice(comptime T: type, slice: []T) void {
    if (slice.len != 0) std.heap.page_allocator.free(slice);
}
