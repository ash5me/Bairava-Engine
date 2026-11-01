//! Runtime features supported by the active GPU device and this executable.

const backend = @import("renderer/backends/sdl_gpu/backend.zig");
const embedded = @import("embedded_shaders");
const shader = backend.shader;
const texture = @import("renderer/texture.zig");
const std = @import("std");

pub const ShaderFormats = struct {
    spirv: bool,
    dxil: bool,
    msl: bool,
};

pub const TextureFormats = struct {
    /// RGBA8 sampling is required by the engine's uncompressed image and font paths.
    rgba8: bool,
    bc1: bool,
    bc3: bool,
    astc_4x4: bool,
};

pub const PresentationCapabilities = struct {
    /// Whether the active window can present without vsync.
    immediate: bool,
};

pub const GpuCapabilities = struct {
    shader_formats: ShaderFormats,
    texture_formats: TextureFormats,
    presentation: PresentationCapabilities,
};

pub const Capabilities = struct {
    /// False when playback-device initialization failed. The game still runs silently.
    audio_playback: bool,
    /// Shader formats must be embedded in this executable and accepted by the active device.
    shader_formats: ShaderFormats,
    /// RGBA8 is required; compressed formats are optional and image loading falls back to RGBA8.
    texture_formats: TextureFormats,
    presentation: PresentationCapabilities,
};

pub const RequiredGpuFeature = enum {
    shader_format,
    rgba8_sampling,
};

pub fn queryGpu(device: *backend.Device, immediate_present: bool) GpuCapabilities {
    const supported_shaders = shader.supportedFormats(device);
    return .{
        .shader_formats = .{
            .spirv = embedded.default_vert.len != 0 and embedded.default_frag.len != 0 and supported_shaders.spirv,
            .dxil = embedded.default_vert_dxil.len != 0 and embedded.default_frag_dxil.len != 0 and supported_shaders.dxil,
            .msl = embedded.default_vert_msl.len != 0 and embedded.default_frag_msl.len != 0 and supported_shaders.msl,
        },
        .texture_formats = .{
            .rgba8 = texture.supportsRgba8Sampling(device),
            .bc1 = texture.supportsCompression(device, .bc1),
            .bc3 = texture.supportsCompression(device, .bc3),
            .astc_4x4 = texture.supportsCompression(device, .astc_4x4),
        },
        .presentation = .{ .immediate = immediate_present },
    };
}

pub fn query(device: *backend.Device, audio_playback: bool, immediate_present: bool) Capabilities {
    const gpu = queryGpu(device, immediate_present);
    return .{
        .audio_playback = audio_playback,
        .shader_formats = gpu.shader_formats,
        .texture_formats = gpu.texture_formats,
        .presentation = gpu.presentation,
    };
}

pub fn missingRequiredGpuFeature(gpu: GpuCapabilities) ?RequiredGpuFeature {
    if (!gpu.shader_formats.spirv and !gpu.shader_formats.dxil and !gpu.shader_formats.msl) return .shader_format;
    if (!gpu.texture_formats.rgba8) return .rgba8_sampling;
    return null;
}

test "required GPU capabilities identify the missing renderer prerequisite" {
    const shaders = ShaderFormats{ .spirv = false, .dxil = false, .msl = false };
    const textures = TextureFormats{ .rgba8 = true, .bc1 = false, .bc3 = false, .astc_4x4 = false };
    const presentation = PresentationCapabilities{ .immediate = false };
    try std.testing.expectEqual(
        RequiredGpuFeature.shader_format,
        missingRequiredGpuFeature(.{ .shader_formats = shaders, .texture_formats = textures, .presentation = presentation }).?,
    );

    const supported_shaders = ShaderFormats{ .spirv = true, .dxil = false, .msl = false };
    const unsupported_rgba8 = TextureFormats{ .rgba8 = false, .bc1 = true, .bc3 = true, .astc_4x4 = true };
    try std.testing.expectEqual(
        RequiredGpuFeature.rgba8_sampling,
        missingRequiredGpuFeature(.{ .shader_formats = supported_shaders, .texture_formats = unsupported_rgba8, .presentation = presentation }).?,
    );
    try std.testing.expectEqual(
        @as(?RequiredGpuFeature, null),
        missingRequiredGpuFeature(.{ .shader_formats = supported_shaders, .texture_formats = textures, .presentation = presentation }),
    );
}
