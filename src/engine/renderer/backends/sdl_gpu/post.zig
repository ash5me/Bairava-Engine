//! Fragment shaders for the post-processing effects, as SDL_GPU sources. Each effect is one fragment entry
//! point in shaders/default.slang. The vertex stage is the sprite vertex shader, so an effect's pipeline
//! takes the sprite batch's vertex layout, and the batch's vertex and index buffers feed it unchanged.

const std = @import("std");
const c = @import("../../../platform/sdl/sdl.zig").c;
const embedded = @import("embedded_shaders");
const render_types = @import("../../render_types.zig");
const shader = @import("shader.zig");

const grayscale = shader.Source{
    .name = "post_grayscale.frag",
    .entry = "postGrayscaleMain",
    .stage = c.SDL_GPU_SHADERSTAGE_FRAGMENT,
    .code = .{
        .spirv = embedded.post_grayscale_frag,
        .dxil = embedded.post_grayscale_frag_dxil,
        .msl = embedded.post_grayscale_frag_msl,
    },
    .resources = .{ .samplers = 1, .uniform_buffers = 1 },
};

const vignette = shader.Source{
    .name = "post_vignette.frag",
    .entry = "postVignetteMain",
    .stage = c.SDL_GPU_SHADERSTAGE_FRAGMENT,
    .code = .{
        .spirv = embedded.post_vignette_frag,
        .dxil = embedded.post_vignette_frag_dxil,
        .msl = embedded.post_vignette_frag_msl,
    },
    .resources = .{ .samplers = 1, .uniform_buffers = 1 },
};

const scanlines = shader.Source{
    .name = "post_scanlines.frag",
    .entry = "postScanlinesMain",
    .stage = c.SDL_GPU_SHADERSTAGE_FRAGMENT,
    .code = .{
        .spirv = embedded.post_scanlines_frag,
        .dxil = embedded.post_scanlines_frag_dxil,
        .msl = embedded.post_scanlines_frag_msl,
    },
    .resources = .{ .samplers = 1, .uniform_buffers = 1 },
};

/// Pushes the settings every effect pass reads. They sit in fragment uniform slot 0, where the effects' shaders
/// declare them. SDL copies the bytes, so `settings` need not outlive the call. Call it before a pass that runs an effect.
pub fn pushSettings(cmd: *c.SDL_GPUCommandBuffer, settings: *const render_types.PostParams) void {
    c.SDL_PushGPUFragmentUniformData(cmd, 0, settings, @sizeOf(render_types.PostParams));
}

/// The fragment shader that runs `effect`.
pub fn fragmentSource(effect: render_types.Effect) shader.Source {
    return switch (effect) {
        .grayscale => grayscale,
        .vignette => vignette,
        .scanlines => scanlines,
    };
}

test "each effect has its own fragment entry point" {
    const effects = std.enums.values(render_types.Effect);
    for (effects, 0..) |effect, i| {
        const source = fragmentSource(effect);
        try std.testing.expect(source.stage == c.SDL_GPU_SHADERSTAGE_FRAGMENT);
        for (effects[0..i]) |earlier| {
            const other = fragmentSource(earlier);
            try std.testing.expect(!std.mem.eql(u8, source.entry, other.entry));
            try std.testing.expect(!std.mem.eql(u8, source.name, other.name));
        }
    }
}
