const std = @import("std");

const c = @import("sdl.zig").c;

/// Shader formats the engine can load. Declaration order is the preference order: when the device
/// accepts more than one, the first one listed here is used. Adding a format doesn't compile until
/// every switch below handles it.
pub const Format = enum {
    spirv,
    dxil,

    /// The SDL flag the device must accept for this format to be usable.
    fn sdlFlag(self: Format) c.SDL_GPUShaderFormat {
        return switch (self) {
            .spirv => c.SDL_GPU_SHADERFORMAT_SPIRV,
            .dxil => c.SDL_GPU_SHADERFORMAT_DXIL,
        };
    }

    /// The entry point name inside the compiled code. Slang names SPIR-V entry points "main" whatever
    /// the function is called in the source. DXIL keeps the source name, so it is passed in.
    fn entryName(self: Format, source_entry: [:0]const u8) [:0]const u8 {
        return switch (self) {
            .spirv => "main",
            .dxil => source_entry,
        };
    }

    /// The compiled code of `source` in this format.
    fn codeOf(self: Format, source: Source) []const u8 {
        return switch (self) {
            .spirv => source.code.spirv,
            .dxil => source.code.dxil,
        };
    }
};

/// Resource counts a shader declares. SDL_GPU needs these when the shader is created.
pub const Resources = struct {
    samplers: u32 = 0,
    uniform_buffers: u32 = 0,
};

/// Compiled code for one shader, with one field per format. The bytes come from the build's
/// generated `embedded_shaders` module, so no file is read at runtime. SPIR-V and DXIL are read as
/// 32-bit words, so their slices carry 4-byte alignment. DXIL is empty unless the build was run with
/// -Ddxil=true, and the renderer only asks for DXIL when it isn't empty.
pub const Code = struct {
    spirv: []align(4) const u8,
    dxil: []align(4) const u8,
};

/// One shader program: its name for error messages, its compiled code, the stage it runs in, and
/// the resources it reads. Declare these as constants beside the code that binds them.
pub const Source = struct {
    /// Name for error messages, such as "triangle.vert".
    name: []const u8,
    /// The entry function's name in the Slang source, such as "vertexMain".
    entry: [:0]const u8,
    stage: c.SDL_GPUShaderStage,
    code: Code,
    resources: Resources = .{},
};

/// The first format in `Format` order that the device accepts. Panics when there is none, because
/// nothing can be drawn without a shader format.
pub fn pickFormat(device: *c.SDL_GPUDevice) Format {
    const supported = c.SDL_GetGPUShaderFormats(device);
    for (std.enums.values(Format)) |format| {
        if ((supported & format.sdlFlag()) != 0) return format;
    }
    std.debug.panic("device accepts no shader format the engine supports (flags {d})", .{supported});
}

/// Creates a GPU shader from `source` compiled in `format`. The code is already in the executable,
/// so nothing is read from disk here.
pub fn load(device: *c.SDL_GPUDevice, format: Format, source: Source) *c.SDL_GPUShader {
    const code = format.codeOf(source);

    var info = std.mem.zeroes(c.SDL_GPUShaderCreateInfo);
    info.code_size = code.len;
    info.code = code.ptr;
    info.entrypoint = format.entryName(source.entry).ptr;
    info.format = format.sdlFlag();
    info.stage = source.stage;
    info.num_samplers = source.resources.samplers;
    info.num_uniform_buffers = source.resources.uniform_buffers;

    return c.SDL_CreateGPUShader(device, &info) orelse {
        std.debug.panic("SDL_CreateGPUShader('{s}') failed: {s}", .{ source.name, c.SDL_GetError() });
    };
}
