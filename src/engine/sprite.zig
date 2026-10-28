const std = @import("std");

const c = @import("sdl.zig").c;
const math = @import("math.zig");
const shader = @import("shader.zig");
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

const max_sprites = 8192;
const max_batches = 256;
const vertices_per_sprite = 6;
const max_vertices = max_sprites * vertices_per_sprite;

/// Consecutive vertices that sample the same texture, drawn in one call.
const Batch = struct {
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

    /// CPU-side vertices for the current frame. Heap-allocated because it's large.
    vertices: []Vertex,
    vertex_count: u32 = 0,
    sprite_count: u32 = 0,
    batches: [max_batches]Batch = undefined,
    batch_count: u32 = 0,
    /// Draw calls issued by draw() this frame. Shows whether batching is working.
    draw_calls: u32 = 0,
    /// Maps pixel coordinates in the viewport to normalized device coordinates. Set by `begin`.
    projection: math.Mat4 = undefined,

    /// Builds the pipeline and GPU buffers. `color_format` is the swapchain format
    /// the sprites render into.
    pub fn init(device: *c.SDL_GPUDevice, color_format: c.SDL_GPUTextureFormat) SpriteBatch {
        // Slang writes each entry point as "main" in the SPIR-V output.
        const vert = shader.loadSpirv(device, "zig-out/shaders/triangle.vert.spv", "main", c.SDL_GPU_SHADERSTAGE_VERTEX, .{});
        defer c.SDL_ReleaseGPUShader(device, vert);
        // The fragment shader samples one texture, which takes one sampler slot.
        const frag = shader.loadSpirv(device, "zig-out/shaders/triangle.frag.spv", "main", c.SDL_GPU_SHADERSTAGE_FRAGMENT, .{ .samplers = 1 });
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

        // One vertex buffer big enough for the largest possible frame.
        const buffer_bytes: u32 = max_vertices * @sizeOf(Vertex);
        var buf_info = std.mem.zeroes(c.SDL_GPUBufferCreateInfo);
        buf_info.usage = c.SDL_GPU_BUFFERUSAGE_VERTEX;
        buf_info.size = buffer_bytes;
        const vertex_buffer = c.SDL_CreateGPUBuffer(device, &buf_info) orelse {
            std.debug.panic("SDL_CreateGPUBuffer failed: {s}", .{c.SDL_GetError()});
        };

        // Staging buffer the CPU writes each frame's vertices into.
        var tb_info = std.mem.zeroes(c.SDL_GPUTransferBufferCreateInfo);
        tb_info.usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
        tb_info.size = buffer_bytes;
        const upload_buffer = c.SDL_CreateGPUTransferBuffer(device, &tb_info) orelse {
            std.debug.panic("SDL_CreateGPUTransferBuffer failed: {s}", .{c.SDL_GetError()});
        };

        const vertices = std.heap.page_allocator.alloc(Vertex, max_vertices) catch @panic("out of memory");

        return .{
            .device = device,
            .pipeline = pipeline,
            .vertex_buffer = vertex_buffer,
            .vb_binding = .{ .buffer = vertex_buffer, .offset = 0 },
            .upload_buffer = upload_buffer,
            .vertices = vertices,
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
        if (self.sprite_count >= max_sprites) {
            std.debug.panic("SpriteBatch is full: more than {d} sprites in one frame", .{max_sprites});
        }

        // Start a new batch whenever the texture changes.
        if (self.batch_count == 0 or self.batches[self.batch_count - 1].texture != texture) {
            if (self.batch_count >= max_batches) {
                std.debug.panic("SpriteBatch has more than {d} texture switches in one frame", .{max_batches});
            }
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
        const bytes: u32 = self.vertex_count * @sizeOf(Vertex);

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
            const sampler = batch.texture.binding();
            c.SDL_BindGPUFragmentSamplers(pass, 0, &sampler, 1);
            c.SDL_DrawGPUPrimitives(pass, batch.vertex_count, 1, batch.first_vertex, 0);
            self.draw_calls += 1;
        }
    }

    /// Releases GPU resources. Call before the renderer is deinitialized.
    pub fn deinit(self: *SpriteBatch) void {
        c.SDL_ReleaseGPUTransferBuffer(self.device, self.upload_buffer);
        c.SDL_ReleaseGPUBuffer(self.device, self.vertex_buffer);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.pipeline);
        std.heap.page_allocator.free(self.vertices);
    }
};
