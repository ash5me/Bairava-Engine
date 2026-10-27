const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
    b.installArtifact(exe);

    // Compile Slang shaders to SPIR-V into zig-out/shaders/
    inline for (.{
        .{ "vertexMain", "vertex", "triangle.vert" },
        .{ "fragmentMain", "fragment", "triangle.frag" },
    }) |s| {
        const compile = b.addSystemCommand(&.{
            "slangc", "-target", "spirv",  "-emit-spirv-via-glsl",
            "-entry", s[0],      "-stage", s[1],
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
}
