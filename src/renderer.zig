const std = @import("std");

const c = @import("sdl.zig").c;
const shader = @import("shader.zig");

/// Vertex layout shared by the CPU-side data and the pipeline's vertex inputs.
pub const Vertex = extern struct {
    pos: [2]f32,
    color: [3]f32,
};

pub const Renderer = struct {
    window: *c.SDL_Window,
    device: *c.SDL_GPUDevice,
    pipeline: *c.SDL_GPUGraphicsPipeline,
    vertex_buffer: *c.SDL_GPUBuffer,
    vb_binding: c.SDL_GPUBufferBinding,
    vertex_count: u32,

    /// Creates the GPU device, uploads `vertices`, and builds the pipeline.
    /// `window` must outlive the returned Renderer.
    pub fn init(window: *c.SDL_Window, gpu_debug: bool, vertices: []const Vertex) Renderer {
        // Request Vulkan 1.2 so the device accepts SPIR-V 1.5, which Slang emits by default.
        // Version 1.2.0 is (1 << 22) | (2 << 12); Zig can't translate VK_MAKE_API_VERSION.
        var vk_opts = std.mem.zeroes(c.SDL_GPUVulkanOptions);
        vk_opts.vulkan_api_version = (1 << 22) | (2 << 12);

        const props = c.SDL_CreateProperties();
        if (props == 0) {
            std.debug.panic("SDL_CreateProperties failed: {s}", .{c.SDL_GetError()});
        }
        defer c.SDL_DestroyProperties(props);

        _ = c.SDL_SetBooleanProperty(props, c.SDL_PROP_GPU_DEVICE_CREATE_SHADERS_SPIRV_BOOLEAN, true);
        _ = c.SDL_SetBooleanProperty(props, c.SDL_PROP_GPU_DEVICE_CREATE_DEBUGMODE_BOOLEAN, gpu_debug);
        _ = c.SDL_SetPointerProperty(props, c.SDL_PROP_GPU_DEVICE_CREATE_VULKAN_OPTIONS_POINTER, &vk_opts);

        const device = c.SDL_CreateGPUDeviceWithProperties(props) orelse {
            std.debug.panic("SDL_CreateGPUDeviceWithProperties failed: {s}", .{c.SDL_GetError()});
        };

        if (!c.SDL_ClaimWindowForGPUDevice(device, window)) {
            std.debug.panic("SDL_ClaimWindowForGPUDevice failed: {s}", .{c.SDL_GetError()});
        }

        // Slang writes each entry point as "main" in the SPIR-V output.
        const vert = shader.loadSpirv(device, "zig-out/shaders/triangle.vert.spv", "main", c.SDL_GPU_SHADERSTAGE_VERTEX);
        const frag = shader.loadSpirv(device, "zig-out/shaders/triangle.frag.spv", "main", c.SDL_GPU_SHADERSTAGE_FRAGMENT);

        // Size from the slice's bytes. @sizeOf(@TypeOf(slice)) would give the pointer size.
        const bytes = std.mem.sliceAsBytes(vertices);
        const size: u32 = @intCast(bytes.len);

        // GPU-side vertex buffer.
        var buf_info = std.mem.zeroes(c.SDL_GPUBufferCreateInfo);
        buf_info.usage = c.SDL_GPU_BUFFERUSAGE_VERTEX;
        buf_info.size = size;
        const vertex_buffer = c.SDL_CreateGPUBuffer(device, &buf_info) orelse {
            std.debug.panic("SDL_CreateGPUBuffer failed: {s}", .{c.SDL_GetError()});
        };

        // CPU-visible staging buffer used to upload the vertices.
        var tb_info = std.mem.zeroes(c.SDL_GPUTransferBufferCreateInfo);
        tb_info.usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
        tb_info.size = size;
        const transfer = c.SDL_CreateGPUTransferBuffer(device, &tb_info) orelse {
            std.debug.panic("SDL_CreateGPUTransferBuffer failed: {s}", .{c.SDL_GetError()});
        };

        const mapped = c.SDL_MapGPUTransferBuffer(device, transfer, false) orelse {
            std.debug.panic("SDL_MapGPUTransferBuffer failed: {s}", .{c.SDL_GetError()});
        };
        const dst: [*]u8 = @ptrCast(mapped);
        @memcpy(dst[0..bytes.len], bytes);
        c.SDL_UnmapGPUTransferBuffer(device, transfer);

        // Copy staging buffer -> vertex buffer, then wait for it to finish.
        const upload_cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse {
            std.debug.panic("SDL_AcquireGPUCommandBuffer failed: {s}", .{c.SDL_GetError()});
        };
        const copy_pass = c.SDL_BeginGPUCopyPass(upload_cmd);
        const src_loc = c.SDL_GPUTransferBufferLocation{ .transfer_buffer = transfer, .offset = 0 };
        const dst_region = c.SDL_GPUBufferRegion{ .buffer = vertex_buffer, .offset = 0, .size = size };
        c.SDL_UploadToGPUBuffer(copy_pass, &src_loc, &dst_region, false);
        c.SDL_EndGPUCopyPass(copy_pass);
        if (!c.SDL_SubmitGPUCommandBuffer(upload_cmd)) {
            std.debug.panic("SDL_SubmitGPUCommandBuffer failed: {s}", .{c.SDL_GetError()});
        }
        _ = c.SDL_WaitForGPUIdle(device);
        c.SDL_ReleaseGPUTransferBuffer(device, transfer);

        // Pipeline: describe the vertex layout, then the shaders and output format.
        var color_desc = std.mem.zeroes(c.SDL_GPUColorTargetDescription);
        color_desc.format = c.SDL_GetGPUSwapchainTextureFormat(device, window);

        var vb_desc = std.mem.zeroes(c.SDL_GPUVertexBufferDescription);
        vb_desc.slot = 0;
        vb_desc.pitch = @sizeOf(Vertex);
        vb_desc.input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX;

        var vb_attrs = [_]c.SDL_GPUVertexAttribute{
            .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(Vertex, "pos") },
            .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3, .offset = @offsetOf(Vertex, "color") },
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

        // The pipeline holds the compiled shaders, so the shader objects can go now.
        c.SDL_ReleaseGPUShader(device, vert);
        c.SDL_ReleaseGPUShader(device, frag);

        return .{
            .window = window,
            .device = device,
            .pipeline = pipeline,
            .vertex_buffer = vertex_buffer,
            .vb_binding = .{ .buffer = vertex_buffer, .offset = 0 },
            .vertex_count = @intCast(vertices.len),
        };
    }

    /// Clears the window and draws the vertex buffer. Skips the frame if the swapchain isn't available.
    pub fn draw(self: *Renderer) void {
        const cmd = c.SDL_AcquireGPUCommandBuffer(self.device) orelse return;

        var swapchain: ?*c.SDL_GPUTexture = null;
        var w: u32 = 0;
        var h: u32 = 0;
        if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(cmd, self.window, &swapchain, &w, &h)) {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            return;
        }
        if (swapchain == null) {
            // Window is minimized; nothing to draw into this frame.
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            return;
        }

        var color_target = std.mem.zeroes(c.SDL_GPUColorTargetInfo);
        color_target.texture = swapchain;
        color_target.clear_color = .{ .r = 0.2, .g = 0.3, .b = 0.5, .a = 1.0 };
        color_target.load_op = c.SDL_GPU_LOADOP_CLEAR;
        color_target.store_op = c.SDL_GPU_STOREOP_STORE;

        const pass = c.SDL_BeginGPURenderPass(cmd, &color_target, 1, null);
        c.SDL_BindGPUGraphicsPipeline(pass, self.pipeline);
        c.SDL_BindGPUVertexBuffers(pass, 0, &self.vb_binding, 1);
        c.SDL_DrawGPUPrimitives(pass, self.vertex_count, 1, 0, 0);
        c.SDL_EndGPURenderPass(pass);

        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
    }

    /// Releases GPU resources. Call before destroying the window.
    pub fn deinit(self: *Renderer) void {
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.pipeline);
        c.SDL_ReleaseGPUBuffer(self.device, self.vertex_buffer);
        c.SDL_ReleaseWindowFromGPUDevice(self.device, self.window);
        c.SDL_DestroyGPUDevice(self.device);
    }
};
