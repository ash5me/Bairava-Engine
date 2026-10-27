const std = @import("std");

const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

const Vertex = extern struct {
    pos: [2]f32,
    color: [3]f32,
};

const vertices = [_]Vertex{
    .{ .pos = .{ 0.0, -0.5 }, .color = .{ 1.0, 0.0, 0.0 } },
    .{ .pos = .{ 0.5, 0.5 }, .color = .{ 0.0, 1.0, 0.0 } },
    .{ .pos = .{ -0.5, 0.5 }, .color = .{ 0.0, 0.0, 1.0 } },
};

fn loadShader(
    device: *c.SDL_GPUDevice,
    path: [*c]const u8,
    entry: [*c]const u8,
    stage: c.SDL_GPUShaderStage,
) *c.SDL_GPUShader {
    var size: usize = 0;
    const code = c.SDL_LoadFile(path, &size) orelse {
        std.debug.panic("SDL_LoadFile({s}) failed: {s}", .{ path, c.SDL_GetError() });
    };
    defer c.SDL_free(code);

    var info = std.mem.zeroes(c.SDL_GPUShaderCreateInfo);
    info.code_size = size;
    info.code = @ptrCast(code);
    info.entrypoint = entry;
    info.format = c.SDL_GPU_SHADERFORMAT_SPIRV;
    info.stage = stage;

    return c.SDL_CreateGPUShader(device, &info) orelse {
        std.debug.panic("SDL_CreateGPUShader failed: {s}", .{c.SDL_GetError()});
    };
}

pub fn main() !void {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.debug.panic("SDL_Init failed: {s}", .{c.SDL_GetError()});
    }
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow("My Game", 800, 600, c.SDL_WINDOW_RESIZABLE) orelse {
        std.debug.panic("SDL_CreateWindow failed: {s}", .{c.SDL_GetError()});
    };
    defer c.SDL_DestroyWindow(window);

    const device = c.SDL_CreateGPUDevice(c.SDL_GPU_SHADERFORMAT_SPIRV, true, null) orelse {
        std.debug.panic("SDL_CreateGPUDevice failed: {s}", .{c.SDL_GetError()});
    };
    defer c.SDL_DestroyGPUDevice(device);

    if (!c.SDL_ClaimWindowForGPUDevice(device, window)) {
        std.debug.panic("SDL_ClaimWindowForGPUDevice failed: {s}", .{c.SDL_GetError()});
    }
    defer c.SDL_ReleaseWindowFromGPUDevice(device, window);

    // Slang writes each entry point as "main" in the SPIR-V output.
    const vert = loadShader(device, "zig-out/shaders/triangle.vert.spv", "main", c.SDL_GPU_SHADERSTAGE_VERTEX);
    defer c.SDL_ReleaseGPUShader(device, vert);
    const frag = loadShader(device, "zig-out/shaders/triangle.frag.spv", "main", c.SDL_GPU_SHADERSTAGE_FRAGMENT);
    defer c.SDL_ReleaseGPUShader(device, frag);

    const vertex_bytes: u32 = @sizeOf(@TypeOf(vertices));

    // GPU-side vertex buffer.
    var buf_info = std.mem.zeroes(c.SDL_GPUBufferCreateInfo);
    buf_info.usage = c.SDL_GPU_BUFFERUSAGE_VERTEX;
    buf_info.size = vertex_bytes;
    const vertex_buffer = c.SDL_CreateGPUBuffer(device, &buf_info) orelse {
        std.debug.panic("SDL_CreateGPUBuffer failed: {s}", .{c.SDL_GetError()});
    };
    defer c.SDL_ReleaseGPUBuffer(device, vertex_buffer);

    // CPU-visible staging buffer used to upload the vertices.
    var tb_info = std.mem.zeroes(c.SDL_GPUTransferBufferCreateInfo);
    tb_info.usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
    tb_info.size = vertex_bytes;
    const transfer = c.SDL_CreateGPUTransferBuffer(device, &tb_info) orelse {
        std.debug.panic("SDL_CreateGPUTransferBuffer failed: {s}", .{c.SDL_GetError()});
    };
    defer c.SDL_ReleaseGPUTransferBuffer(device, transfer);

    const mapped = c.SDL_MapGPUTransferBuffer(device, transfer, false) orelse {
        std.debug.panic("SDL_MapGPUTransferBuffer failed: {s}", .{c.SDL_GetError()});
    };
    const dst: [*]u8 = @ptrCast(mapped);
    const src = std.mem.asBytes(&vertices);
    @memcpy(dst[0..src.len], src);
    c.SDL_UnmapGPUTransferBuffer(device, transfer);

    // Copy staging buffer -> vertex buffer, then wait for it to finish.
    const upload_cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse {
        std.debug.panic("SDL_AcquireGPUCommandBuffer failed: {s}", .{c.SDL_GetError()});
    };
    const copy_pass = c.SDL_BeginGPUCopyPass(upload_cmd);
    const src_loc = c.SDL_GPUTransferBufferLocation{ .transfer_buffer = transfer, .offset = 0 };
    const dst_region = c.SDL_GPUBufferRegion{ .buffer = vertex_buffer, .offset = 0, .size = vertex_bytes };
    c.SDL_UploadToGPUBuffer(copy_pass, &src_loc, &dst_region, false);
    c.SDL_EndGPUCopyPass(copy_pass);
    if (!c.SDL_SubmitGPUCommandBuffer(upload_cmd)) {
        std.debug.panic("SDL_SubmitGPUCommandBuffer failed: {s}", .{c.SDL_GetError()});
    }
    _ = c.SDL_WaitForGPUIdle(device);

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
    defer c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);

    const vb_binding = c.SDL_GPUBufferBinding{ .buffer = vertex_buffer, .offset = 0 };

    var running = true;
    while (running) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            if (event.type == c.SDL_EVENT_QUIT) running = false;
        }

        const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse continue;

        var swapchain: ?*c.SDL_GPUTexture = null;
        var w: u32 = 0;
        var h: u32 = 0;
        if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(cmd, window, &swapchain, &w, &h)) {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            continue;
        }
        if (swapchain == null) {
            // Window is minimized; nothing to draw into this frame.
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            continue;
        }

        var color_target = std.mem.zeroes(c.SDL_GPUColorTargetInfo);
        color_target.texture = swapchain;
        color_target.clear_color = .{ .r = 0.2, .g = 0.3, .b = 0.5, .a = 1.0 };
        color_target.load_op = c.SDL_GPU_LOADOP_CLEAR;
        color_target.store_op = c.SDL_GPU_STOREOP_STORE;

        const pass = c.SDL_BeginGPURenderPass(cmd, &color_target, 1, null);
        c.SDL_BindGPUGraphicsPipeline(pass, pipeline);
        c.SDL_BindGPUVertexBuffers(pass, 0, &vb_binding, 1);
        c.SDL_DrawGPUPrimitives(pass, 3, 1, 0, 0);
        c.SDL_EndGPURenderPass(pass);

        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
    }
}
