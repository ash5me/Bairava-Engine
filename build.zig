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
        .name = "my-game",
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

    // cglm: vector and matrix math. See addCglm above.
    addCglm(b, exe.root_module);

    b.installArtifact(exe);

    // Compile Slang shaders directly to SPIR-V (SPIR-V 1.5) into zig-out/shaders/.
    // The device requests Vulkan 1.2 at runtime to accept this output.
    inline for (.{
        .{ "vertexMain", "vertex", "triangle.vert" },
        .{ "fragmentMain", "fragment", "triangle.frag" },
    }) |s| {
        const compile = b.addSystemCommand(&.{
            "slangc", "-target", "spirv",
            "-entry", s[0],      "-stage",
            s[1],
        });
        compile.addFileArg(b.path("shaders/triangle.slang"));
        compile.addArg("-o");
        const spv = compile.addOutputFileArg(s[2] ++ ".spv");

        const install = b.addInstallFile(spv, "shaders/" ++ s[2] ++ ".spv");
        b.getInstallStep().dependOn(&install.step);
    }

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
    const tests = b.addTest(.{ .root_module = test_module });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests (no GPU needed)").dependOn(&run_tests.step);
}
