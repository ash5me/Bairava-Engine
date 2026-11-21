const std = @import("std");

/// Compile flags for text.c. The BFNT measurement parity test (src/engine/text/bfnt_measure.zig) compares text.c
/// bit for bit with the Zig port, which never fuses a multiply and an add. Clang and GCC do fuse `width += a * b`
/// into one fused multiply-add when the target has FMA, and the results then differ in the last bits. This flag keeps
/// text.c on the unfused arithmetic, in every build that compiles it.
const text_c_flags = [_][]const u8{"-ffp-contract=off"};

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

/// FreeType sources for the offline font baker, which rasterizes OpenType CFF outlines (tools/assets/font_bake.c).
/// The runtime engine never links them. Optional compressed-font modules are disabled in the vendored ftoption.h.
const freetype_sources = [_][]const u8{
    "vendor/freetype-2.15.0/src/autofit/autofit.c",
    "vendor/freetype-2.15.0/src/base/ftbase.c",
    "vendor/freetype-2.15.0/src/base/ftbbox.c",
    "vendor/freetype-2.15.0/src/base/ftbitmap.c",
    "vendor/freetype-2.15.0/src/base/ftglyph.c",
    "vendor/freetype-2.15.0/src/base/ftinit.c",
    "vendor/freetype-2.15.0/src/base/ftmm.c",
    "vendor/freetype-2.15.0/src/base/ftsystem.c",
    "vendor/freetype-2.15.0/src/base/ftdebug.c",
    "vendor/freetype-2.15.0/src/cff/cff.c",
    "vendor/freetype-2.15.0/src/psaux/psaux.c",
    "vendor/freetype-2.15.0/src/pshinter/pshinter.c",
    "vendor/freetype-2.15.0/src/psnames/psnames.c",
    "vendor/freetype-2.15.0/src/raster/raster.c",
    "vendor/freetype-2.15.0/src/sdf/sdf.c",
    "vendor/freetype-2.15.0/src/sfnt/sfnt.c",
    "vendor/freetype-2.15.0/src/smooth/smooth.c",
    "vendor/freetype-2.15.0/src/truetype/truetype.c",
};

/// msdfgen 1.13.0 core and the font-import extension, linked only into the host asset builder.
const msdfgen_sources = [_][]const u8{
    "vendor/msdfgen-1.13/core/Contour.cpp",
    "vendor/msdfgen-1.13/core/DistanceMapping.cpp",
    "vendor/msdfgen-1.13/core/EdgeHolder.cpp",
    "vendor/msdfgen-1.13/core/MSDFErrorCorrection.cpp",
    "vendor/msdfgen-1.13/core/Projection.cpp",
    "vendor/msdfgen-1.13/core/Scanline.cpp",
    "vendor/msdfgen-1.13/core/Shape.cpp",
    "vendor/msdfgen-1.13/core/convergent-curve-ordering.cpp",
    "vendor/msdfgen-1.13/core/contour-combiners.cpp",
    "vendor/msdfgen-1.13/core/edge-coloring.cpp",
    "vendor/msdfgen-1.13/core/edge-selectors.cpp",
    "vendor/msdfgen-1.13/core/edge-segments.cpp",
    "vendor/msdfgen-1.13/core/equation-solver.cpp",
    "vendor/msdfgen-1.13/core/export-svg.cpp",
    "vendor/msdfgen-1.13/core/msdf-error-correction.cpp",
    "vendor/msdfgen-1.13/core/msdfgen.cpp",
    "vendor/msdfgen-1.13/core/rasterization.cpp",
    "vendor/msdfgen-1.13/core/render-sdf.cpp",
    "vendor/msdfgen-1.13/core/save-bmp.cpp",
    "vendor/msdfgen-1.13/core/save-fl32.cpp",
    "vendor/msdfgen-1.13/core/save-rgba.cpp",
    "vendor/msdfgen-1.13/core/save-tiff.cpp",
    "vendor/msdfgen-1.13/core/shape-description.cpp",
    "vendor/msdfgen-1.13/core/sdf-error-estimation.cpp",
    "vendor/msdfgen-1.13/ext/import-font.cpp",
};
const msdfgen_flags = [_][]const u8{
    "-std=c++11",
    "-DMSDFGEN_USE_CPP11",
    "-DMSDFGEN_DISABLE_SVG",
    "-DMSDFGEN_DISABLE_PNG",
    "-DMSDFGEN_DISABLE_VARIABLE_FONTS",
    "-DMSDFGEN_PUBLIC=",
};

/// Gives `module` cglm's headers and compiles cglm's C sources into it. Two macros must match the
/// @cImport in src/engine/core/math.zig, so the C library and the translated headers agree.
/// CGLM_ALL_UNALIGNED stops cglm from assuming 16-byte alignment, which Zig arrays don't guarantee.
/// CGLM_FORCE_DEPTH_ZERO_TO_ONE gives depth from 0 (near) to 1 (far), as SDL_GPU expects. Without
/// it, cglm's exported glmc_* functions would use depth from -1 to 1 while math.zig uses 0 to 1.
/// cglm's SIMD paths are off here. Zig's @cImport translates cglm's SIMD wrappers into calls to
/// helpers that are never defined, so the build would fail to link. The portable scalar code is
/// used on every target, and src/engine/core/math.zig undefines the same macros before its @cImport.
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

fn addFreeType(b: *std.Build, module: *std.Build.Module) void {
    module.addIncludePath(b.path("vendor/freetype-2.15.0/include"));
    module.addCMacro("FT2_BUILD_LIBRARY", "1");
    for (freetype_sources) |path| module.addCSourceFile(.{ .file = b.path(path) });
}

/// HarfBuzz 15.1.0, vendored under vendor/harfbuzz-15.1.0. Its one translation unit includes every
/// shaper and table. Platform backends (CoreText, DirectWrite, GDI, FreeType, GLib, Graphite2) compile
/// to nothing unless a HAVE_* macro is defined, so none is defined here. Upstream builds it as C++11
/// without exceptions or RTTI, and these flags match that.
const harfbuzz_source = "vendor/harfbuzz-15.1.0/src/harfbuzz.cc";
const harfbuzz_flags = [_][]const u8{ "-std=c++11", "-fno-exceptions", "-fno-rtti" };

fn addHarfBuzz(b: *std.Build, module: *std.Build.Module) void {
    module.addIncludePath(b.path("vendor/harfbuzz-15.1.0/src"));
    module.addCSourceFile(.{ .file = b.path(harfbuzz_source), .flags = &harfbuzz_flags });
    // HarfBuzz is C++, so the compile step must link the C++ runtime. The compile step reads this field.
    module.link_libcpp = true;
}

/// The job system and the scripting runtime are plain C with no SDL. The engine and the test module both link them.
fn addJobsAndScript(b: *std.Build, module: *std.Build.Module) void {
    module.addIncludePath(b.path("src/engine/jobs"));
    module.addIncludePath(b.path("src/engine/script"));
    module.addCSourceFile(.{ .file = b.path("src/engine/jobs/jobs.c") });
    module.addCSourceFile(.{ .file = b.path("src/engine/script/script.c") });
}

/// Builds one C test program from its test source and the one C library it checks. It runs with no arguments, and
/// it exits nonzero when a check fails.
fn addCUnitHarness(b: *std.Build, name: []const u8, test_source: []const u8, library_source: []const u8, include_dir: []const u8) *std.Build.Step.Run {
    const module = b.createModule(.{
        .target = b.graph.host,
        .optimize = .Debug,
        .link_libc = true,
    });
    module.addIncludePath(b.path(include_dir));
    module.addCSourceFile(.{ .file = b.path(test_source) });
    module.addCSourceFile(.{ .file = b.path(library_source) });

    const harness = b.addExecutable(.{ .name = name, .root_module = module });
    const run = b.addRunArtifact(harness);
    run.setCwd(b.path("."));
    return run;
}

fn addUiTestHarness(b: *std.Build, name: []const u8, test_source: []const u8, with_imgui: bool) *std.Build.Step.Run {
    const module = b.createModule(.{
        .target = b.graph.host,
        .optimize = .Debug,
        .link_libc = true,
        // Same FreeType build as the asset builder; see the note there.
        .sanitize_c = .off,
    });
    module.addIncludePath(b.path("vendor"));
    module.addIncludePath(b.path("src/engine/text"));
    module.addIncludePath(b.path("src/engine/ui"));
    module.addIncludePath(b.path("tools/assets"));
    addFreeType(b, module);
    module.addCSourceFile(.{ .file = b.path(test_source) });
    module.addCSourceFile(.{ .file = b.path("tests/ui/test_support.c") });
    module.addCSourceFile(.{ .file = b.path("src/engine/text/text.c"), .flags = &text_c_flags });
    module.addCSourceFile(.{ .file = b.path("tools/assets/font_bake.c") });
    module.addCSourceFile(.{ .file = b.path("vendor/stb_truetype_impl.c") });
    if (with_imgui) module.addCSourceFile(.{ .file = b.path("src/engine/ui/imgui.c") });

    const harness = b.addExecutable(.{ .name = name, .root_module = module });
    const run = b.addRunArtifact(harness);
    run.setCwd(b.path("."));
    if (b.args) |args| {
        const tb01_args = args.len > 0 and (std.mem.eql(u8, args[0], "--count") or
            std.mem.eql(u8, args[0], "--textures") or
            std.mem.eql(u8, args[0], "--seed") or
            std.mem.eql(u8, args[0], "--frames") or
            std.mem.eql(u8, args[0], "--gpu-timing") or
            std.mem.eql(u8, args[0], "--cycles") or
            std.mem.eql(u8, args[0], "--count") or
            std.mem.eql(u8, args[0], "--cols") or
            std.mem.eql(u8, args[0], "--rows") or
            std.mem.eql(u8, args[0], "--hz") or
            std.mem.eql(u8, args[0], "--probes") or
            std.mem.eql(u8, args[0], "--capacity") or
            std.mem.eql(u8, args[0], "--burst") or
            std.mem.eql(u8, args[0], "--help"));
        if (tb01_args) {
            run.addFileArg(b.path("assets/font.ttf"));
        } else {
            if (args.len != 1) @panic("UI tests accept one font path after `--`");
            run.addArgs(args);
        }
    } else {
        run.addFileArg(b.path("assets/font.ttf"));
    }
    return run;
}

fn configureEngineModule(
    b: *std.Build,
    module: *std.Build.Module,
    sdl: *std.Build.Dependency,
    ztracy: *std.Build.Dependency,
    options: *std.Build.Step.Options,
    target: std.Build.ResolvedTarget,
    tracy_enabled: bool,
) void {
    module.linkLibrary(sdl.artifact("SDL3"));
    module.addOptions("build_options", options);
    module.addImport("ztracy", ztracy.module("root"));
    if (tracy_enabled) module.linkLibrary(ztracy.artifact("tracy"));
    if (tracy_enabled and target.result.os.tag == .windows) module.linkSystemLibrary("secur32", .{});

    module.addIncludePath(b.path("vendor"));
    module.addIncludePath(b.path("src/engine/ui"));
    module.addIncludePath(b.path("src/engine/text"));
    module.addIncludePath(b.path("src/engine/logging"));
    addCglm(b, module);
    addHarfBuzz(b, module);
    module.addCSourceFile(.{ .file = b.path("vendor/stb_truetype_impl.c") });
    addJobsAndScript(b, module);
    module.addCSourceFile(.{ .file = b.path("vendor/stb_image_impl.c") });
    module.addCSourceFile(.{ .file = b.path("src/engine/text/text.c"), .flags = &text_c_flags });
    module.addCSourceFile(.{ .file = b.path("src/engine/ui/imgui.c") });
    module.addCSourceFile(.{ .file = b.path("vendor/log.c") });
    module.addCSourceFile(.{ .file = b.path("src/engine/logging/log_file.c") });
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
    /// An entry-point-specific shader define, when only that entry point uses a resource block.
    define: ?[]const u8 = null,
};

const shader_entries = [_]ShaderEntry{
    .{ .entry = "vertexMain", .stage = "vertex", .file = "default.vert", .decl = "default_vert" },
    .{ .entry = "fragmentMain", .stage = "fragment", .file = "default.frag", .decl = "default_frag" },
    .{ .entry = "fontFragmentMain", .stage = "fragment", .file = "default_font.frag", .decl = "default_font_frag" },
    .{ .entry = "msdfFragmentMain", .stage = "fragment", .file = "default_msdf.frag", .decl = "default_msdf_frag", .define = "MSDF_SHADER" },
    .{ .entry = "postGrayscaleMain", .stage = "fragment", .file = "post_grayscale.frag", .decl = "post_grayscale_frag", .define = "POST_SHADER" },
    .{ .entry = "postVignetteMain", .stage = "fragment", .file = "post_vignette.frag", .decl = "post_vignette_frag", .define = "POST_SHADER" },
    .{ .entry = "postScanlinesMain", .stage = "fragment", .file = "post_scanlines.frag", .decl = "post_scanlines_frag", .define = "POST_SHADER" },
    .{ .entry = "litFragmentMain", .stage = "fragment", .file = "default_lit.frag", .decl = "default_lit_frag", .define = "LIT_SHADER" },
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
    /// Build option that enables this format, or null when it is always built.
    option: ?[]const u8,
};

const shader_targets = [_]ShaderTarget{
    .{
        .ext = "spv",
        .args = &.{ "-target", "spirv", "-profile", "spirv_1_5" },
        .suffix = "",
        .define = null,
        .option = null,
    },
    .{
        .ext = "dxil",
        .args = &.{ "-target", "dxil", "-profile", "sm_6_0" },
        .suffix = "_dxil",
        .define = "-DDXIL_TARGET",
        .option = "dxil",
    },
    .{
        .ext = "msl",
        .args = &.{ "-target", "metal" },
        .suffix = "_msl",
        .define = null,
        .option = "metal",
    },
};

fn shaderTargetEnabled(target: ShaderTarget, dxil_enabled: bool, metal_enabled: bool) bool {
    const option = target.option orelse return true;
    if (std.mem.eql(u8, option, "dxil")) return dxil_enabled;
    if (std.mem.eql(u8, option, "metal")) return metal_enabled;
    unreachable;
}

/// Source of the generated `embedded_shaders` module. Each compiled shader's bytes are copied into a
/// 4-byte-aligned global, because SPIR-V is read as 32-bit words. An optional format that isn't
/// built gets an empty slice. It is built at comptime from the tables above, so the module and the
/// compile steps can't disagree about names.
fn embeddedSource(b: *std.Build, dxil_enabled: bool, metal_enabled: bool) []const u8 {
    var source: []const u8 = "";
    inline for (shader_targets) |t| {
        inline for (shader_entries) |s| {
            const decl = s.decl ++ t.suffix;
            const text: []const u8 = if (!shaderTargetEnabled(t, dxil_enabled, metal_enabled))
                "pub const " ++ decl ++ ": []align(4) const u8 = &.{};\n"
            else
                "const " ++ decl ++ "_storage align(4) = @embedFile(\"" ++ s.file ++ "." ++ t.ext ++ "\").*;\n" ++
                    "pub const " ++ decl ++ ": []align(4) const u8 = &" ++ decl ++ "_storage;\n";
            source = std.mem.concat(b.allocator, u8, &.{ source, text }) catch @panic("out of memory");
        }
    }
    return source;
}

/// Sprite names and source paths are maintained by `zig build asset-import`; the build embeds this
/// manifest so imported images automatically enter the next atlas build.
const atlas_manifest = @embedFile("assets/sprites.txt");
/// General runtime assets are declared separately from the atlas packing inputs.
const asset_manifest = @embedFile("assets/asset_manifest.txt");

const BuildProfile = enum { development, debug, release };

fn profileOptimizeMode(profile: BuildProfile) std.builtin.OptimizeMode {
    return switch (profile) {
        .development, .debug => .Debug,
        .release => .ReleaseFast,
    };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const build_profile = b.option(BuildProfile, "profile", "Build profile: development, debug, or release") orelse .development;
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size") orelse switch (b.release_mode) {
        .off => profileOptimizeMode(build_profile),
        .any => .ReleaseFast,
        .fast => .ReleaseFast,
        .safe => .ReleaseSafe,
        .small => .ReleaseSmall,
    };

    const gpu_debug = b.option(bool, "gpu-debug", "Enable SDL GPU validation layers") orelse (build_profile == .debug);

    const options = b.addOptions();
    options.addOption(bool, "gpu_debug", gpu_debug);
    options.addOption([]const u8, "profile", @tagName(build_profile));

    const dev_tools = b.option(bool, "dev-tools", "Include the debug overlay, console, and hot reload") orelse (build_profile == .development);
    options.addOption(bool, "dev_tools", dev_tools);

    const sdl = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
    });

    // Tracy profiling zones, through ztracy. Off by default, so a normal build has no profiler code.
    // `zig build run -Dtracy=true` builds Tracy into the game, so the Tracy profiler can connect to it.
    const tracy_enabled = b.option(bool, "tracy", "Record profiling zones for the Tracy profiler") orelse false;
    const ztracy = b.dependency("ztracy", .{ .enable_ztracy = tracy_enabled });

    const engine_module = b.createModule(.{
        .root_source_file = b.path("src/engine/bairava.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureEngineModule(b, engine_module, sdl, ztracy, options, target, tracy_enabled);

    const api_inventory_module = b.createModule(.{
        .root_source_file = b.path("tools/docs/public_api_inventory.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const api_inventory = b.addExecutable(.{
        .name = "bairava_public_api_inventory",
        .root_module = api_inventory_module,
    });
    api_inventory_module.addImport("bairava", engine_module);
    const run_api_inventory = b.addRunArtifact(api_inventory);
    run_api_inventory.setCwd(b.path("."));
    const api_inventory_markdown = run_api_inventory.captureStdOut(.{ .basename = "public-api.md" });
    const install_api_inventory = b.addInstallFile(api_inventory_markdown, "doc/bairava/_api_source.md");
    const docs_step = b.step("docs", "Generate the curated Bairava documentation site");
    const docs_site = b.addSystemCommand(&.{ "python", "scripts/docs/build_site.py" });
    docs_site.setCwd(b.path("."));
    docs_site.step.dependOn(&install_api_inventory.step);
    for ([_][]const u8{
        "scripts/docs/build_site.py",
        "scripts/docs/prepare_publication.py",
        "scripts/docs/test_build_site.py",
        "examples/api_basics.zig",
        "docs/getting-started.md",
        "docs/application-lifecycle.md",
        "docs/assets.md",
        "docs/input.md",
        "docs/rendering.md",
        "docs/scenes.md",
        "docs/LICENSE.md",
        "docs/ai.md",
        "docs/animation.md",
        "docs/asset-streaming.md",
        "docs/audio-streaming.md",
        "docs/build-profiles.md",
        "docs/developer-console.md",
        "docs/lighting.md",
        "docs/localization.md",
        "docs/logging.md",
        "docs/navigation.md",
        "docs/particles.md",
        "docs/physics.md",
        "docs/prefabs.md",
        "docs/profiling.md",
        "docs/replay.md",
        "docs/text.md",
        "docs/platform-capabilities.md",
        "docs/site/_config.yml",
        "build.zig.zon",
        "src/engine/version.zig",
        "docs/site/_layouts/default.html",
        "docs/site/assets/site.css",
        "docs/site/assets/search.js",
        "docs/site/404.md",
    }) |path| docs_site.addFileInput(b.path(path));
    docs_step.dependOn(&docs_site.step);

    const exe = b.addExecutable(.{
        .name = "Semkootru",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addImport("bairava", engine_module);

    // Parson belongs to the game save module, not to the Bairava engine module.
    exe.root_module.addIncludePath(b.path("vendor"));
    exe.root_module.addCSourceFile(.{ .file = b.path("vendor/parson.c") });

    b.installArtifact(exe);

    // Sample game: a second executable that uses only the public Bairava API, so the scene system is
    // shown without any Semkootru code. Its one texture is installed beside it.
    const sample = b.addExecutable(.{
        .name = "BairavaSample",
        .root_module = b.createModule(.{
            .root_source_file = b.path("sample/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    sample.root_module.addImport("bairava", engine_module);
    b.installArtifact(sample);

    const install_sample_texture = b.addInstallFile(b.path("sample/assets/white.png"), "bin/assets/sample/white.png");
    b.getInstallStep().dependOn(&install_sample_texture.step);
    inline for ([_][]const u8{ "forest_bush.png", "forest_rock.png", "forest_tree.png" }) |name| {
        const install_texture = b.addInstallFile(
            b.path("assets/" ++ name),
            "bin/assets/" ++ name,
        );
        b.getInstallStep().dependOn(&install_texture.step);
    }

    const run_sample = b.addRunArtifact(sample);
    run_sample.step.dependOn(b.getInstallStep());
    b.step("run-sample", "Build and run the scene sample").dependOn(&run_sample.step);

    const benchmark = b.addExecutable(.{
        .name = "BairavaBenchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("sample/benchmark.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    benchmark.root_module.addImport("bairava", engine_module);
    b.installArtifact(benchmark);
    const run_benchmark = b.addRunArtifact(benchmark);
    run_benchmark.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_benchmark.addArgs(args);
    b.step("run-benchmark", "Run the deterministic 10000-entity and sprite profiling workload").dependOn(&run_benchmark.step);
    b.step("run-tb01", "Run TB-01 Sprite Rendering Stress Test").dependOn(&run_benchmark.step);

    const tb07 = b.addExecutable(.{
        .name = "BairavaTB07",
        .root_module = b.createModule(.{
            .root_source_file = b.path("sample/tb07_adventure.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tb07.root_module.addImport("bairava", engine_module);
    b.installArtifact(tb07);
    const run_tb07 = b.addRunArtifact(tb07);
    run_tb07.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_tb07.addArgs(args);
    b.step("run-tb07", "Run TB-07 Top-Down Adventure Integration Sample").dependOn(&run_tb07.step);

    const tb02 = b.addExecutable(.{
        .name = "BairavaTB02",
        .root_module = b.createModule(.{
            .root_source_file = b.path("sample/tb02_asset_streaming.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tb02.root_module.addImport("bairava", engine_module);
    b.installArtifact(tb02);
    const run_tb02 = b.addRunArtifact(tb02);
    run_tb02.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_tb02.addArgs(args);
    b.step("run-tb02", "Run TB-02 Asset Loading and Streaming Test").dependOn(&run_tb02.step);

    const tb19 = b.addExecutable(.{
        .name = "BairavaTB19",
        .root_module = b.createModule(.{
            .root_source_file = b.path("sample/tb19_resource_lifecycle.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tb19.root_module.addImport("bairava", engine_module);
    b.installArtifact(tb19);
    const run_tb19 = b.addRunArtifact(tb19);
    run_tb19.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_tb19.addArgs(args);
    b.step("run-tb19", "Run TB-19 Resource and Entity Lifecycle Laboratory").dependOn(&run_tb19.step);

    const tb04 = b.addExecutable(.{
        .name = "BairavaTB04",
        .root_module = b.createModule(.{
            .root_source_file = b.path("sample/tb04_animation.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tb04.root_module.addImport("bairava", engine_module);
    b.installArtifact(tb04);
    const run_tb04 = b.addRunArtifact(tb04);
    run_tb04.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_tb04.addArgs(args);
    b.step("run-tb04", "Run TB-04 Animation Stress Test").dependOn(&run_tb04.step);

    const tb05 = b.addExecutable(.{
        .name = "BairavaTB05",
        .root_module = b.createModule(.{
            .root_source_file = b.path("sample/tb05_collision.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tb05.root_module.addImport("bairava", engine_module);
    b.installArtifact(tb05);
    const run_tb05 = b.addRunArtifact(tb05);
    run_tb05.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_tb05.addArgs(args);
    b.step("run-tb05", "Run TB-05 Collision and Physics Test").dependOn(&run_tb05.step);

    const tb06 = b.addExecutable(.{
        .name = "BairavaTB06",
        .root_module = b.createModule(.{
            .root_source_file = b.path("sample/tb06_camera_viewport.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tb06.root_module.addImport("bairava", engine_module);
    b.installArtifact(tb06);
    const run_tb06 = b.addRunArtifact(tb06);
    run_tb06.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_tb06.addArgs(args);
    b.step("run-tb06", "Run TB-06 Camera and Viewport Test").dependOn(&run_tb06.step);

    const tb21 = b.addExecutable(.{
        .name = "BairavaTB21",
        .root_module = b.createModule(.{
            .root_source_file = b.path("sample/tb21_tilemap_stress.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tb21.root_module.addImport("bairava", engine_module);
    b.installArtifact(tb21);
    const run_tb21 = b.addRunArtifact(tb21);
    run_tb21.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_tb21.addArgs(args);
    b.step("run-tb21", "Run TB-21 Tilemap Validation and Stress Test").dependOn(&run_tb21.step);

    const tb22 = b.addExecutable(.{
        .name = "BairavaTB22",
        .root_module = b.createModule(.{
            .root_source_file = b.path("sample/tb22_particle_stress.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tb22.root_module.addImport("bairava", engine_module);
    b.installArtifact(tb22);
    const run_tb22 = b.addRunArtifact(tb22);
    run_tb22.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_tb22.addArgs(args);
    b.step("run-tb22", "Run TB-22 Particle Pool and Overdraw Stress Test").dependOn(&run_tb22.step);

    const tb23 = b.addExecutable(.{
        .name = "BairavaTB23",
        .root_module = b.createModule(.{
            .root_source_file = b.path("sample/tb23_replay.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tb23.root_module.addImport("bairava", engine_module);
    const run_tb23 = b.addRunArtifact(tb23);
    b.step("run-tb23", "Run TB-23 Deterministic Input Replay and Checkpoint Validation").dependOn(&run_tb23.step);

    const text_benchmark = b.addExecutable(.{
        .name = "BairavaTextBenchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("sample/text_benchmark.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    text_benchmark.root_module.addImport("bairava", engine_module);
    b.installArtifact(text_benchmark);
    const run_text_benchmark = b.addRunArtifact(text_benchmark);
    run_text_benchmark.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_text_benchmark.addArgs(args);
    b.step("run-text-benchmark", "Run the deterministic multi-provider typography reference workload").dependOn(&run_text_benchmark.step);
    b.step("run-tb03", "Run TB-03 Text and Font Rendering Test").dependOn(&run_text_benchmark.step);

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
    var sprite_lines = std.mem.tokenizeScalar(u8, atlas_manifest, '\n');
    while (sprite_lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t\r");
        const name = fields.next() orelse continue;
        const file = fields.next() orelse @panic("assets/sprites.txt: missing image path");
        if (fields.next() != null) @panic("assets/sprites.txt: expected '<name> <image-path>' per line");
        pack.addArg(name);
        pack.addFileArg(b.path(file));
    }
    // The game reads the packed-region index beside the runtime asset directory.
    const install_atlas_index = b.addInstallFile(atlas_index, "bin/assets/atlas.txt");
    b.getInstallStep().dependOn(&install_atlas_index.step);

    // Validate, compress, and stage manifest assets plus the generated runtime atlas on the host.
    const asset_builder = b.addExecutable(.{
        .name = "asset_build",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .link_libc = true,
            // FreeType's module tables call functions through pointers of their own typedefs. Clang's
            // `function` undefined-behavior check traps on that, and the trap is silent. The asset builder
            // is host tooling, and its own C code is checked separately.
            .sanitize_c = .off,
        }),
    });
    asset_builder.root_module.addIncludePath(b.path("vendor"));
    asset_builder.root_module.addIncludePath(b.path("vendor/msdfgen-1.13"));
    asset_builder.root_module.addIncludePath(b.path("src/engine/ui"));
    addFreeType(b, asset_builder.root_module);
    asset_builder.root_module.addCSourceFile(.{ .file = b.path("tools/assets/build.c") });
    asset_builder.root_module.addCSourceFile(.{ .file = b.path("vendor/stb_image_impl.c") });
    asset_builder.root_module.addCSourceFile(.{ .file = b.path("vendor/stb_truetype_impl.c") });
    asset_builder.root_module.addCSourceFile(.{ .file = b.path("src/engine/text/text.c"), .flags = &text_c_flags });
    asset_builder.root_module.addCSourceFile(.{ .file = b.path("tools/assets/font_bake.c") });
    for (msdfgen_sources) |source| {
        asset_builder.root_module.addCSourceFile(.{ .file = b.path(source), .flags = &msdfgen_flags });
    }
    asset_builder.root_module.addCSourceFile(.{ .file = b.path("tools/assets/font_bake_msdf.cpp"), .flags = &msdfgen_flags });
    asset_builder.root_module.link_libcpp = true;
    const run_asset_builder = b.addRunArtifact(asset_builder);
    run_asset_builder.addFileArg(b.path("assets/asset_manifest.txt"));
    const runtime_assets = run_asset_builder.addOutputDirectoryArg("runtime-assets");
    run_asset_builder.addArg("--include-image");
    run_asset_builder.addArg("atlas");
    run_asset_builder.addFileArg(atlas_png);
    run_asset_builder.addArg("atlas.png");
    run_asset_builder.addArg("-");
    var asset_lines = std.mem.tokenizeScalar(u8, asset_manifest, '\n');
    while (asset_lines.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trim(u8, line, " \t\r"), "#")) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t\r");
        _ = fields.next() orelse continue;
        const kind = fields.next() orelse @panic("assets/asset_manifest.txt: missing type");
        const source = fields.next() orelse @panic("assets/asset_manifest.txt: missing source path");
        _ = fields.next() orelse @panic("assets/asset_manifest.txt: missing output path");
        _ = fields.next() orelse @panic("assets/asset_manifest.txt: missing dependencies");
        if (std.mem.eql(u8, kind, "font")) {
            _ = fields.next() orelse @panic("assets/asset_manifest.txt: font entry needs pixel height");
            _ = fields.next() orelse @panic("assets/asset_manifest.txt: font entry needs first codepoint");
            _ = fields.next() orelse @panic("assets/asset_manifest.txt: font entry needs glyph count");
            // An optional mode selects gray, mono, or an offline MFNT/MSDF bake.
            if (fields.peek()) |raster| {
                if (!std.mem.eql(u8, raster, "gray") and !std.mem.eql(u8, raster, "mono") and !std.mem.eql(u8, raster, "msdf")) @panic("assets/asset_manifest.txt: font mode must be gray, mono, or msdf");
                _ = fields.next();
            }
        }
        if (fields.next() != null) @panic("assets/asset_manifest.txt: expected five fields, or eight or nine for a font");
        run_asset_builder.addFileInput(b.path(source));
    }
    const install_runtime_assets = b.addInstallDirectory(.{
        .source_dir = runtime_assets,
        .install_dir = .bin,
        .install_subdir = "assets",
    });
    b.getInstallStep().dependOn(&install_runtime_assets.step);
    b.step("asset-build", "Validate and build compressed runtime assets from the manifest").dependOn(&run_asset_builder.step);

    // Asset check: validates the manifests, the sprite list, and the installed atlas index. It opens no window
    // and needs no GPU. Run it from the project root with `zig build check-assets`.
    const asset_check_module = b.createModule(.{
        .root_source_file = b.path("src/asset_check_root.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const check_assets = b.addExecutable(.{
        .name = "check_assets",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/check/check_assets.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .link_libc = true,
        }),
    });
    check_assets.root_module.addImport("asset_check", asset_check_module);
    const run_check_assets = b.addRunArtifact(check_assets);
    run_check_assets.setCwd(b.path("."));
    b.step("check-assets", "Validate the asset manifest, sprite list, and installed atlas index").dependOn(&run_check_assets.step);

    // Portable, opt-in image tool for removing a checkerboard background. Build it for the host
    // so it can be used during development even when the game is cross-compiled for another OS.
    const asset_keyer = b.addExecutable(.{
        .name = "asset_keyer",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .link_libc = true,
        }),
    });
    asset_keyer.root_module.addIncludePath(b.path("vendor"));
    asset_keyer.root_module.addCSourceFile(.{ .file = b.path("tools/assets/keyer.c") });
    asset_keyer.root_module.addCSourceFile(.{ .file = b.path("vendor/stb_image_impl.c") });
    const run_asset_keyer = b.addRunArtifact(asset_keyer);
    if (b.args) |args| run_asset_keyer.addArgs(args);
    b.step("asset-keyer", "Remove a checkerboard background from an image").dependOn(&run_asset_keyer.step);

    // Import an image into assets/imported and register it in the atlas source manifest.
    const asset_importer = b.addExecutable(.{
        .name = "asset_import",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .link_libc = true,
        }),
    });
    asset_importer.root_module.addCSourceFile(.{ .file = b.path("tools/assets/import.c") });
    asset_importer.root_module.addCSourceFile(.{ .file = b.path("vendor/stb_image_impl.c") });
    const run_asset_importer = b.addRunArtifact(asset_importer);
    if (b.args) |args| run_asset_importer.addArgs(args);
    b.step("asset-import", "Copy and register an image for the sprite atlas").dependOn(&run_asset_importer.step);

    const asset_tool_tests = b.addSystemCommand(&.{ "python", "tools/assets/test_tools.py" });
    asset_tool_tests.addArtifactArg(asset_builder);
    asset_tool_tests.addArtifactArg(asset_keyer);
    asset_tool_tests.addArtifactArg(asset_importer);

    // Compile each shader entry point for each target, and embed the results in the executable
    // through a generated module, so the game reads no shader files at runtime. DXIL and MSL are
    // optional build targets; Vulkan SPIR-V is always present.
    const dxil_enabled = b.option(bool, "dxil", "Compile DXIL shaders for D3D12") orelse false;
    const metal_enabled = b.option(bool, "metal", "Compile MSL shaders for Metal") orelse false;
    const shader_files = b.addWriteFiles();
    inline for (shader_targets) |t| {
        if (shaderTargetEnabled(t, dxil_enabled, metal_enabled)) {
            inline for (shader_entries) |s| {
                const compile = b.addSystemCommand(&.{"slangc"});
                compile.addArgs(t.args);
                if (t.define) |d| compile.addArg(d);
                if (s.define) |d| compile.addArg(b.fmt("-D{s}", .{d}));
                compile.addArgs(&.{ "-entry", s.entry, "-stage", s.stage });
                compile.addFileArg(b.path("shaders/default.slang"));
                compile.addArg("-o");
                const out = compile.addOutputFileArg(s.file ++ "." ++ t.ext);
                _ = shader_files.addCopyFile(out, s.file ++ "." ++ t.ext);
            }
        }
    }
    const embedded_source = embeddedSource(b, dxil_enabled, metal_enabled);
    const embedded_module = shader_files.add("embedded_shaders.zig", embedded_source);
    engine_module.addAnonymousImport("embedded_shaders", .{ .root_source_file = embedded_module });

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Run the app").dependOn(&run.step);

    // Unit tests don't open a window or create a GPU device, but renderer tests use SDL GPU structs.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addCglm(b, test_module);
    // The engine module links HarfBuzz as well (configureEngineModule), so the game, sample, and benchmark link it.
    // This test module links it again because tests.zig compiles the text sources directly, not through the engine module.
    addHarfBuzz(b, test_module);
    // Renderer modules use SDL GPU declarations, and embedded shaders are needed to compile them.
    // Tests open no window and create no GPU device.
    test_module.linkLibrary(sdl.artifact("SDL3"));
    test_module.addAnonymousImport("embedded_shaders", .{ .root_source_file = embedded_module });
    // tests.zig imports the logger, so the test binary builds the log C code too. Zones compile to
    // nothing without -Dtracy, so the tests need only ztracy's Zig module, not the Tracy library.
    test_module.addIncludePath(b.path("vendor"));
    test_module.addIncludePath(b.path("src/engine/logging"));
    test_module.addCSourceFile(.{ .file = b.path("vendor/log.c") });
    test_module.addCSourceFile(.{ .file = b.path("vendor/parson.c") });
    test_module.addCSourceFile(.{ .file = b.path("src/engine/logging/log_file.c") });
    // The image loader and the job and script wrappers need their C code in the test binary as well.
    test_module.addCSourceFile(.{ .file = b.path("vendor/stb_image_impl.c") });
    // The runtime font face (src/engine/text/runtime_font.zig) calls stb_truetype in the test binary.
    test_module.addCSourceFile(.{ .file = b.path("vendor/stb_truetype_impl.c") });
    // font_resource.zig holds the BFNT provider, a font.zig Font. That type carries ui/c.zig's ui_font, which needs
    // imgui.h from src/engine/ui, and its deinit calls text.c. configureEngineModule gives the engine both; the test
    // binary needs the same include path and translation unit. text.c needs only libc, so nothing else is added.
    test_module.addIncludePath(b.path("src/engine/ui"));
    test_module.addCSourceFile(.{ .file = b.path("src/engine/text/text.c"), .flags = &text_c_flags });
    // The test root now compiles the same C the engine does for the parts it reaches: ui.zig needs imgui.c, and
    // lifecycle.zig reads build_options (configureEngineModule gives the engine both).
    test_module.addCSourceFile(.{ .file = b.path("src/engine/ui/imgui.c") });
    test_module.addOptions("build_options", options);
    addJobsAndScript(b, test_module);
    test_module.addImport("ztracy", ztracy.module("root"));
    const tests = b.addTest(.{ .root_module = test_module });
    const run_tests = b.addRunArtifact(tests);
    run_tests.setCwd(b.path("."));

    const docs_test_module = b.createModule(.{
        .root_source_file = b.path("tools/docs/public_api_inventory.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const docs_tests = b.addTest(.{ .root_module = docs_test_module });
    const run_docs_tests = b.addRunArtifact(docs_tests);

    const api_test_module = b.createModule(.{
        .root_source_file = b.path("src/engine_api_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    api_test_module.addImport("bairava", engine_module);
    const api_tests = b.addTest(.{ .root_module = api_test_module });
    const run_api_tests = b.addRunArtifact(api_tests);
    run_api_tests.setCwd(b.path("."));

    const docs_example_module = b.createModule(.{
        .root_source_file = b.path("examples/api_basics.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    docs_example_module.addImport("bairava", engine_module);
    const docs_example_tests = b.addTest(.{ .root_module = docs_example_module });
    const run_docs_example_tests = b.addRunArtifact(docs_example_tests);
    run_docs_example_tests.setCwd(b.path("."));

    const docs_api_validation_module = b.createModule(.{
        .root_source_file = b.path("tools/docs/public_api_validation.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    docs_api_validation_module.addImport("bairava", engine_module);
    const docs_api_validation = b.addTest(.{ .root_module = docs_api_validation_module });
    const run_docs_api_validation = b.addRunArtifact(docs_api_validation);
    install_api_inventory.step.dependOn(&docs_api_validation.step);

    const run_text_ui_tests = addUiTestHarness(b, "test_text", "tests/ui/test_text.c", false);
    const run_imgui_tests = addUiTestHarness(b, "test_imgui", "tests/ui/test_imgui.c", true);
    const run_jobs_tests = addCUnitHarness(b, "test_jobs", "tests/jobs/test_jobs.c", "src/engine/jobs/jobs.c", "src/engine/jobs");
    const run_script_tests = addCUnitHarness(b, "test_script", "tests/script/test_script.c", "src/engine/script/script.c", "src/engine/script");
    const game_script_host_module = b.createModule(.{
        .root_source_file = b.path("src/game/script_host.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    game_script_host_module.addImport("bairava", engine_module);
    const script_host_test_module = b.createModule(.{
        .root_source_file = b.path("tests/script/test_game_host.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    script_host_test_module.addImport("bairava", engine_module);
    script_host_test_module.addImport("game_script_host", game_script_host_module);
    const script_host_tests = b.addTest(.{ .root_module = script_host_test_module });
    const run_script_host_tests = b.addRunArtifact(script_host_tests);
    b.step("test-script-host", "Run game script host integration tests").dependOn(&run_script_host_tests.step);
    const ui_test_step = b.step("test-ui", "Run the C text and widget UI tests");
    ui_test_step.dependOn(&run_text_ui_tests.step);
    ui_test_step.dependOn(&run_imgui_tests.step);

    const test_step = b.step("test", "Run all unit, API, and UI tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_docs_tests.step);
    test_step.dependOn(&run_api_tests.step);
    test_step.dependOn(&run_docs_example_tests.step);
    test_step.dependOn(&run_docs_api_validation.step);
    test_step.dependOn(ui_test_step);
    test_step.dependOn(&asset_tool_tests.step);
    test_step.dependOn(&run_jobs_tests.step);
    test_step.dependOn(&run_script_tests.step);
    test_step.dependOn(&run_script_host_tests.step);
    const docs_site_tests = b.addSystemCommand(&.{ "python", "scripts/docs/test_build_site.py" });
    docs_site_tests.setCwd(b.path("."));
    docs_site_tests.addFileInput(b.path("scripts/docs/build_site.py"));
    docs_site_tests.addFileInput(b.path("scripts/docs/prepare_publication.py"));
    docs_site_tests.addFileInput(b.path("scripts/docs/test_build_site.py"));
    docs_site_tests.addFileInput(b.path("examples/api_basics.zig"));
    docs_site_tests.addFileInput(b.path("docs/application-lifecycle.md"));
    docs_site_tests.addFileInput(b.path("docs/input.md"));
    docs_site_tests.addFileInput(b.path("docs/assets.md"));
    docs_site_tests.addFileInput(b.path("docs/rendering.md"));
    docs_site_tests.addFileInput(b.path("docs/scenes.md"));
    docs_site_tests.addFileInput(b.path("docs/getting-started.md"));
    docs_site_tests.addFileInput(b.path("docs/animation.md"));
    test_step.dependOn(&docs_site_tests.step);
}
