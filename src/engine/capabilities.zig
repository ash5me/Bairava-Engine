//! Runtime features supported by the active GPU device and this executable.

const backend = @import("renderer/backends/sdl_gpu/backend.zig");
const embedded = @import("embedded_shaders");
const shader = backend.shader;
const texture = @import("renderer/texture.zig");

pub const ShaderFormats = struct {
    spirv: bool,
    dxil: bool,
    msl: bool,
};

pub const TextureFormats = struct {
    /// RGBA8 sampling is the engine's required uncompressed fallback.
    rgba8: bool = true,
    bc1: bool,
    bc3: bool,
    astc_4x4: bool,
};

pub const Capabilities = struct {
    /// False when playback-device initialization failed. The game still runs silently.
    audio_playback: bool,
    /// Shader formats must be both embedded in this executable and accepted by the active device.
    shader_formats: ShaderFormats,
    /// Compressed formats are optional; image loading falls back through other variants to RGBA8.
    texture_formats: TextureFormats,
};

pub fn query(device: *backend.Device, audio_playback: bool) Capabilities {
    return .{
        .audio_playback = audio_playback,
        .shader_formats = .{
            .spirv = embedded.default_vert_spirv.len != 0 and shader.supportsFormat(device, .spirv),
            .dxil = embedded.default_vert_dxil.len != 0 and shader.supportsFormat(device, .dxil),
            .msl = embedded.default_vert_msl.len != 0 and shader.supportsFormat(device, .msl),
        },
        .texture_formats = .{
            .bc1 = texture.supportsCompression(device, .bc1),
            .bc3 = texture.supportsCompression(device, .bc3),
            .astc_4x4 = texture.supportsCompression(device, .astc_4x4),
        },
    };
}
