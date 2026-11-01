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
    .resources = .{ .samplers = 1 },
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
    .resources = .{ .samplers = 1 },
};

/// The fragment shader that runs `effect`.
pub fn fragmentSource(effect: render_types.Effect) shader.Source {
    return switch (effect) {
        .grayscale => grayscale,
        .vignette => vignette,
    };
}

test "each effect has its own fragment entry point" {
    const first = fragmentSource(.grayscale);
    const second = fragmentSource(.vignette);
    try std.testing.expect(first.stage == c.SDL_GPU_SHADERSTAGE_FRAGMENT);
    try std.testing.expect(second.stage == c.SDL_GPU_SHADERSTAGE_FRAGMENT);
    try std.testing.expect(!std.mem.eql(u8, first.entry, second.entry));
    try std.testing.expect(!std.mem.eql(u8, first.name, second.name));
}
