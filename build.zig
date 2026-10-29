const std = @import("std");

/// cglm's C sources (v0.9.7), in the order its CMakeLists.txt lists them. They are vendored under
/// vendor/cglm/ with its headers and license.
const cglm_sources = [_][]const u8{
    "vendor/cglm/src/euler.c",
    "vendor/cglm/src/affine.c",
    "vendor/cglm/src/io.c",
    "vendor/cglm/src/quat.c",
    "vendor/cglm/src/cam.c",
    "vendor/cglm/src/vec2.c",
    "vendor/cglm/src/ivec2.c",
    "vendor/cglm/src/vec3.c",
    "vendor/cglm/src/ivec3.c",
    "vendor/cglm/src/vec4.c",
    "vendor/cglm/src/ivec4.c",
    "vendor/cglm/src/mat2.c",
    "vendor/cglm/src/mat2x3.c",
    "vendor/cglm/src/mat2x4.c",
    "vendor/cglm/src/mat3.c",
    "vendor/cglm/src/mat3x2.c",
    "vendor/cglm/src/mat3x4.c",
    "vendor/cglm/src/mat4.c",
    "vendor/cglm/src/mat4x2.c",
    "vendor/cglm/src/mat4x3.c",
    "vendor/cglm/src/plane.c",
    "vendor/cglm/src/noise.c",
    "vendor/cglm/src/frustum.c",
    "vendor/cglm/src/box.c",
    "vendor/cglm/src/aabb2d.c",
    "vendor/cglm/src/project.c",
    "vendor/cglm/src/sphere.c",
    "vendor/cglm/src/ease.c",
    "vendor/cglm/src/curve.c",
    "vendor/cglm/src/bezier.c",
    "vendor/cglm/src/ray.c",
    "vendor/cglm/src/affine2d.c",
    "vendor/cglm/src/clipspace/ortho_lh_no.c",
    "vendor/cglm/src/clipspace/ortho_lh_zo.c",
    "vendor/cglm/src/clipspace/ortho_rh_no.c",
    "vendor/cglm/src/clipspace/ortho_rh_zo.c",
    "vendor/cglm/src/clipspace/persp_lh_no.c",
    "vendor/cglm/src/clipspace/persp_lh_zo.c",
    "vendor/cglm/src/clipspace/persp_rh_no.c",
    "vendor/cglm/src/clipspace/persp_rh_zo.c",
    "vendor/cglm/src/clipspace/view_lh_no.c",
    "vendor/cglm/src/clipspace/view_lh_zo.c",
    "vendor/cglm/src/clipspace/view_rh_no.c",
    "vendor/cglm/src/clipspace/view_rh_zo.c",
    "vendor/cglm/src/clipspace/project_no.c",
    "vendor/cglm/src/clipspace/project_zo.c",
};

/// Gives `module` cglm's headers and compiles cglm's C sources into it. Two macros must match the
/// @cImport in src/engine/math.zig, so the C library and the translated headers agree.
/// CGLM_ALL_UNALIGNED stops cglm from assuming 16-byte alignment, which Zig arrays don't guarantee.
/// CGLM_FORCE_DEPTH_ZERO_TO_ONE gives depth from 0 (near) to 1 (far), as SDL_GPU expects. Without
/// it, cglm's exported glmc_* functions would use depth from -1 to 1 while math.zig uses 0 to 1.
/// cglm's SIMD paths are off here. Zig's @cImport translates cglm's SIMD wrappers into calls to
/// helpers that are never defined, so the build would fail to link. The portable scalar code is
/// used on every target, and src/engine/math.zig undefines the same macros before its @cImport.
const cglm_simd_flags = [_][]const u8{
    "-U__SSE__",
    "-U__SSE2__",
    "-U__SSE3__",
    "-U__SSE4_1__",
    "-U__SSE4_2__",
    "-U__AVX__",
    "-U__ARM_NEON",
    "-U__ARM_NEON__",
    "-U__wasm_simd128__",
};

fn addCglm(b: *std.Build, module: *std.Build.Module) void {
    module.addIncludePath(b.path("vendor/cglm/include"));
    module.addCMacro("CGLM_ALL_UNALIGNED", "1");
    module.addCMacro("CGLM_FORCE_DEPTH_ZERO_TO_ONE", "1");
    for (cglm_sources) |path| {
        module.addCSourceFile(.{ .file = b.path(path), .flags = &cglm_simd_flags });
    }
}

/// One entry point of shaders/default.slang. To add a shader, add a row here, then declare a
/// `shader.Source` in the code that uses it.
const ShaderEntry = struct {
    /// Function name in the Slang source.
    entry: []const u8,
    /// Stage name that slangc expects: "vertex" or "fragment".
    stage: []const u8,
    /// Output file name without an extension, such as "default.vert".
    file: []const u8,
    /// Declaration name in the generated `embedded_shaders` module, such as "default_vert".
    /// A target's `suffix` is added to this name, so each format gets its own declaration.
    decl: []const u8,
};

const shader_entries = [_]ShaderEntry{
    .{ .entry = "vertexMain", .stage = "vertex", .file = "default.vert", .decl = "default_vert" },
    .{ .entry = "fragmentMain", .stage = "fragment", .file = "default.frag", .decl = "default_frag" },
};

/// One output format for every shader entry point.
const ShaderTarget = struct {
    /// File extension for the output, such as "spv" or "dxil".
    ext: []const u8,
    /// slangc arguments that select the target and profile.
    args: []const []const u8,
    /// Added to each declaration name for this format, such as "_dxil".
    suffix: []const u8,
    /// An extra slangc argument, or null. DXIL compiles pass -DDXIL_TARGET so the shader can pick
    /// the D3D12 register layout.
    define: ?[]const u8,
    /// Built only when -Ddxil=true. When off, the generated module declares an empty slice for it,
    /// so a machine without DXIL support still builds the SPIR-V game.
    optional: bool,
};

const shader_targets = [_]ShaderTarget{
    .{
        .ext = "spv",
        .args = &.{ "-target", "spirv", "-profile", "spirv_1_5" },
        .suffix = "",
        .define = null,
        .optional = false,
    },
    .{
        .ext = "dxil",
        .args = &.{ "-target", "dxil", "-profile", "sm_6_0" },
        .suffix = "_dxil",
        .define = "-DDXIL_TARGET",
        .optional = true,
    },
};

/// Source of the generated `embedded_shaders` module. Each compiled shader's bytes are copied into a
/// 4-byte-aligned global, because SPIR-V is read as 32-bit words. An optional format that isn't
/// built gets an empty slice. It is built at comptime from the tables above, so the module and the
/// compile steps can't disagree about names.
fn embeddedSource(b: *std.Build, dxil_enabled: bool) []const u8 {
    var source: []const u8 = "";
    inline for (shader_targets) |t| {
        inline for (shader_entries) |s| {
            const decl = s.decl ++ t.suffix;
            const text: []const u8 = if (t.optional and !dxil_enabled)
                "pub const " ++ decl ++ ": []align(4) const u8 = &.{};\n"
            else
                "const " ++ decl ++ "_storage align(4) = @embedFile(\"" ++ s.file ++ "." ++ t.ext ++ "\").*;\n" ++
                    "pub const " ++ decl ++ ": []align(4) const u8 = &" ++ decl ++ "_storage;\n";
            source = std.mem.concat(b.allocator, u8, &.{ source, text }) catch @panic("out of memory");
        }
    }
    return source;
}

/// One sprite packed into the texture atlas. `name` is the handle game code looks it up by, through
/// engine/atlas.zig, and follows the rules in engine/string.zig. `file` is relative to the project root.
const AtlasSprite = struct {
    name: []const u8,
    file: []const u8,
};

/// Every sprite the game draws. `zig build` packs them into zig-out/bin/assets/atlas.png, and writes
/// where each one sits to atlas.txt beside it. To add a sprite, add a row here, then look it up by its
/// name in the game. Names must be unique.
const atlas_sprites = [_]AtlasSprite{
    .{ .name = "tile", .file = "assets/tile.png" },
    .{ .name = "warrior", .file = "assets/warrior_16x32.png" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Usage: zig build run -Dgpu-debug=true
    const gpu_debug = b.option(bool, "gpu-debug", "Enable SDL GPU validation layers") orelse false;

    const options = b.addOptions();
    options.addOption(bool, "gpu_debug", gpu_debug);

    const sdl = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "Semkootru",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.linkLibrary(sdl.artifact("SDL3"));
    exe.root_module.addOptions("build_options", options);

    // stb_image: the header is declared to Zig through @cImport, and this file compiles its implementation.
    exe.root_module.addIncludePath(b.path("vendor"));
    exe.root_module.addCSourceFile(.{ .file = b.path("vendor/stb_image_impl.c") });

    // Text and UI: stb_truetype bakes fonts from vendor/, and the C widget code in src/engine/ui/
    // builds the quads that src/engine/ui.zig draws. None of it touches SDL or the GPU.
    exe.root_module.addIncludePath(b.path("src/engine/ui"));
    exe.root_module.addCSourceFile(.{ .file = b.path("vendor/stb_truetype_impl.c") });
    exe.root_module.addCSourceFile(.{ .file = b.path("src/engine/ui/text.c") });
    exe.root_module.addCSourceFile(.{ .file = b.path("src/engine/ui/imgui.c") });

    // cglm: vector and matrix math. See addCglm above.
    addCglm(b, exe.root_module);

    b.installArtifact(exe);

    // Assets sit beside the executable, in bin/assets, where Context.loadTexture looks for them.
    const install_assets = b.addInstallDirectory(.{
        .source_dir = b.path("assets"),
        .install_dir = .bin,
        .install_subdir = "assets",
    });
    b.getInstallStep().dependOn(&install_assets.step);

    // Texture atlas: every sprite in one image, packed at build time by tools/atlas/pack.c with
    // stb_rect_pack. The packer runs on the build machine, so it is built for the host, not the target.
    const atlas_tool = b.addExecutable(.{
        .name = "atlas_pack",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .link_libc = true,
        }),
    });
    atlas_tool.root_module.addIncludePath(b.path("vendor"));
    atlas_tool.root_module.addCSourceFile(.{ .file = b.path("tools/atlas/pack.c") });

    const pack = b.addRunArtifact(atlas_tool);
    const atlas_png = pack.addOutputFileArg("atlas.png");
    const atlas_index = pack.addOutputFileArg("atlas.txt");
    for (atlas_sprites) |sprite| {
        pack.addArg(sprite.name);
        pack.addFileArg(b.path(sprite.file));
    }
    // The game reads both files from the executable's folder, beside the assets it already installs.
    const install_atlas_png = b.addInstallFile(atlas_png, "bin/assets/atlas.png");
    const install_atlas_index = b.addInstallFile(atlas_index, "bin/assets/atlas.txt");
    b.getInstallStep().dependOn(&install_atlas_png.step);
    b.getInstallStep().dependOn(&install_atlas_index.step);

    // Compile each shader entry point for each target, and embed the results in the executable
    // through a generated module, so the game reads no shader files at runtime. DXIL is optional:
    // pass -Ddxil=true to build it. The device requests Vulkan 1.2 at runtime to accept SPIR-V.
    const dxil_enabled = b.option(bool, "dxil", "Compile DXIL shaders for D3D12") orelse false;
    const shader_files = b.addWriteFiles();
    inline for (shader_targets) |t| {
        if (!t.optional or dxil_enabled) {
            inline for (shader_entries) |s| {
                const compile = b.addSystemCommand(&.{"slangc"});
                compile.addArgs(t.args);
                if (t.define) |d| compile.addArg(d);
                compile.addArgs(&.{ "-entry", s.entry, "-stage", s.stage });
                compile.addFileArg(b.path("shaders/default.slang"));
                compile.addArg("-o");
                const out = compile.addOutputFileArg(s.file ++ "." ++ t.ext);
                _ = shader_files.addCopyFile(out, s.file ++ "." ++ t.ext);
            }
        }
    }
    const embedded_source = embeddedSource(b, dxil_enabled);
    const embedded_module = shader_files.add("embedded_shaders.zig", embedded_source);
    exe.root_module.addAnonymousImport("embedded_shaders", .{ .root_source_file = embedded_module });

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Run the app").dependOn(&run.step);

    // Unit tests for the modules that don't need SDL or a GPU. They run anywhere.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addCglm(b, test_module);
    // input and renderer import SDL's headers and the embedded shaders. The tests open no window and
    // create no GPU device, but the test binary links SDL and needs slangc to build the shaders.
    test_module.linkLibrary(sdl.artifact("SDL3"));
    test_module.addAnonymousImport("embedded_shaders", .{ .root_source_file = embedded_module });
    const tests = b.addTest(.{ .root_module = test_module });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests (no GPU or window; links SDL, needs slangc)").dependOn(&run_tests.step);
}
