const std = @import("std");
const engine = @import("bairava");
const MsdfScaleProbe = @import("text_benchmark.zig").MsdfScaleProbe;

const config = engine.Config{
    .title = "Bairava TB-03 MSDF Scale Probe",
    .window_w = 960,
    .window_h = 540,
    .native_w = 320,
    .native_h = 180,
    .clear_rgb = .{ 0.06, 0.07, 0.09 },
    .settings_file = "benchmark_settings.txt",
    .gpu_timing = false,
};

pub fn main(init: std.process.Init.Minimal) !void {
    _ = init;
    try engine.run(engine.SceneHost(MsdfScaleProbe), config);
}
