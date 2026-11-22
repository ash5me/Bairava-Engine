//! TB-20 renders one deterministic 2D scene and records the actual SDL_GPU backend and capabilities.

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("bairava");

const log = engine.log.scoped("tb20");
const white = engine.ui.Color{ .r = 1, .g = 1, .b = 1, .a = 1 };
const muted = engine.ui.Color{ .r = 0.72, .g = 0.78, .b = 0.86, .a = 1 };

const Options = struct {
    frames: u64 = 360,
    seed: u64 = 20,
    source_revision: []const u8 = "not_recorded",
};

var options = Options{};
var config = engine.Config{
    .title = "Bairava TB-20 SDL_GPU parity smoke",
    .window_w = 960,
    .window_h = 540,
    .native_w = 320,
    .native_h = 180,
    .clear_rgb = .{ 0.035, 0.045, 0.065 },
    .settings_file = "tb20_settings.txt",
    .vsync = false,
    .post_effects = &.{ .scanlines, .vignette },
};

const Tb20 = struct {
    atlas: engine.LoadedAtlas,
    albedo: engine.Texture,
    normal: engine.Texture,
    white_texture: engine.Texture,
    font: engine.ui.FontHandle,
    canvas: engine.ui.Canvas,
    driver_name: []const u8,
    device_name: []const u8,
    tick: u64 = 0,
    started_at_ns: u64,
    render_frames: u64 = 0,
    sprite_submissions: u64 = 0,
    lit_submissions: u64 = 0,
    reported: bool = false,

    pub fn init(ctx: *engine.Context) !Tb20 {
        var atlas = try ctx.loadAtlas("assets/atlas.png", "assets/atlas.txt");
        errdefer atlas.deinit();
        var albedo = try ctx.loadTexture("assets/testbeds/tb13/stone_albedo.png");
        errdefer albedo.deinit();
        var normal = try ctx.loadTexture("assets/testbeds/tb13/stone_normal.png");
        errdefer normal.deinit();
        var white_texture = try ctx.loadTexture("assets/sample/white.png");
        errdefer white_texture.deinit();
        const font = try ctx.loadFont("assets/ui_font_9px.bfnt", 9);
        errdefer ctx.unloadFont(font) catch |err| log.err("font cleanup failed during init: {s}", .{@errorName(err)});
        const canvas = engine.ui.Canvas.create(ctx.allocators.game, ctx.fonts, font);

        return .{
            .atlas = atlas,
            .albedo = albedo,
            .normal = normal,
            .white_texture = white_texture,
            .font = font,
            .canvas = canvas,
            .driver_name = ctx.gpuDriverName(),
            .device_name = ctx.gpuDeviceName(),
            .started_at_ns = ctx.monotonicTimeNs(),
        };
    }

    pub fn update(self: *Tb20, ctx: *engine.Context, _: *engine.SceneNavigator) void {
        if (ctx.input.wasPressed(.escape)) ctx.running = false;
        self.tick += 1;
        if (!self.reported and self.tick >= options.frames) self.writeReport(ctx);
        if (self.tick >= options.frames) ctx.running = false;
    }

    pub fn draw(self: *Tb20, dc: *const engine.DrawContext) void {
        self.render_frames += 1;
        const batch = dc.batch;
        const tile = self.atlas.region("tile");
        const warrior = self.atlas.region("warrior");
        const pulse = @as(f32, @floatFromInt(self.tick % 120)) / 120.0;
        const seed_phase = @as(f32, @floatFromInt(options.seed % 360)) * (std.math.tau / 360.0);
        const phase = pulse * std.math.tau + seed_phase;

        batch.setAmbient(.{ 0.32, 0.36, 0.44 });
        if (batch.addLight(.{
            .x = 160 + @cos(phase) * 55,
            .y = 92 + @sin(phase) * 28,
            .height = 25,
            .radius = 112,
            .color = .{ 1.0, 0.72, 0.42 },
            .intensity = 0.9,
        })) self.lit_submissions += 1;

        batch.drawSprite(
            &self.atlas.texture,
            source(tile),
            .{ .x = 12, .y = 37, .w = 116, .h = 62 },
            .{ .tint = .{ 0.86, 0.96, 1.0 }, .alpha = 0.9, .rotation = 0.08, .origin = .{ 58, 31 } },
        );
        batch.drawSprite(
            &self.atlas.texture,
            source(warrior),
            .{ .x = 34, .y = 55, .w = 32, .h = 52 },
            .{ .tint = .{ 1.0, 0.7, 0.56 }, .alpha = 0.88, .rotation = @sin(phase) * 0.12 },
        );

        for (0..3) |index| {
            const x = 138 + @as(f32, @floatFromInt(index)) * 56;
            const y = 52 + @as(f32, @floatFromInt(index % 2)) * 52;
            batch.drawSprite(
                &self.albedo,
                .{ .x = 0, .y = 0, .w = @floatFromInt(self.albedo.width), .h = @floatFromInt(self.albedo.height) },
                .{ .x = x, .y = y, .w = 48, .h = 48 },
                .{
                    .normal = &self.normal,
                    .tint = .{ 0.78 + @as(f32, @floatFromInt(index)) * 0.08, 0.86, 1.0 },
                    .rotation = phase * (0.035 + @as(f32, @floatFromInt(index)) * 0.01),
                    .origin = .{ 24, 24 },
                },
            );
        }
        batch.drawSprite(
            &self.white_texture,
            .{ .x = 0, .y = 0, .w = 4, .h = 4 },
            .{ .x = 8, .y = 8, .w = 304, .h = 20 },
            .{ .tint = .{ 0.06, 0.09, 0.14 }, .alpha = 0.92, .z = 100 },
        );
        self.sprite_submissions += 6;
        self.canvas.clear();
        self.canvas.text(12, 10, "TB-20  SDL_GPU 2D BACKEND PARITY", white);
        self.canvas.text(12, 22, "Atlas / alpha / tint / rotation / normal map / light / post FX", muted);
        self.canvas.text(12, 154, "Deterministic tick animation | Escape exits", muted);
        self.canvas.queue(batch, 1000);
    }

    pub fn deinitWithContext(self: *Tb20, ctx: *engine.Context) void {
        self.canvas.deinit();
        ctx.unloadFont(self.font) catch |err| log.err("font cleanup failed: {s}", .{@errorName(err)});
        self.white_texture.deinit();
        self.normal.deinit();
        self.albedo.deinit();
        self.atlas.deinit();
    }

    pub fn deinit(self: *Tb20) void {
        self.canvas.deinit();
        self.white_texture.deinit();
        self.normal.deinit();
        self.albedo.deinit();
        self.atlas.deinit();
    }

    fn writeReport(self: *Tb20, ctx: *engine.Context) void {
        self.reported = true;
        const capabilities = ctx.capabilities();
        const frames = ctx.diagnostics.stats.of(.frame);
        const ended_at_ns = ctx.monotonicTimeNs();
        const report = .{
            .testbed_id = "TB-20",
            .scenario = "deterministic-2d-parity-smoke",
            .seed = options.seed,
            .source_revision = options.source_revision,
            .build_mode = @tagName(builtin.mode),
            .os = @tagName(builtin.os.tag),
            .os_version = "not_collected",
            .cpu = "not_collected",
            .ram_bytes = @as(?u64, null),
            .gpu = self.device_name,
            .gpu_driver = self.driver_name,
            .window_width = config.window_w,
            .window_height = config.window_h,
            .display_refresh_hz = @as(?u32, null),
            .shader_formats = capabilities.shader_formats,
            .workload_frames = self.tick,
            .render_frames = self.render_frames,
            .sprite_submissions = self.sprite_submissions,
            .light_submissions = self.lit_submissions,
            .post_effects = [_][]const u8{ "scanlines", "vignette" },
            .correctness = "smoke_setup_pass",
            .visual_comparison = "not_run",
            .frame_average_ms = frames.average() * 1000,
            .frame_p95_ms = frames.percentile(0.95) * 1000,
            .start_monotonic_ns = self.started_at_ns,
            .end_monotonic_ns = ended_at_ns,
            .duration_seconds = @as(f64, @floatFromInt(ended_at_ns - self.started_at_ns)) / 1_000_000_000,
        };
        const json = std.json.Stringify.valueAlloc(ctx.allocators.game, report, .{ .whitespace = .indent_2 }) catch |err| {
            log.err("TB-20 JSON serialization failed: {s}", .{@errorName(err)});
            return;
        };
        defer ctx.allocators.game.free(json);
        ctx.writeFile("TB-20-sdl-gpu-backend-parity-results.json", json) catch |err| {
            log.err("TB-20 report write failed: {s}", .{@errorName(err)});
            return;
        };
        log.info(
            "smoke setup recorded: SDL_GPU driver {s}, device {s}, shaders SPIR-V={any} DXIL={any} MSL={any}; visual comparison not run",
            .{ self.driver_name, self.device_name, capabilities.shader_formats.spirv, capabilities.shader_formats.dxil, capabilities.shader_formats.msl },
        );
    }
};

fn source(region: engine.atlas.Region) engine.Rect {
    return .{
        .x = @floatFromInt(region.x),
        .y = @floatFromInt(region.y),
        .w = @floatFromInt(region.w),
        .h = @floatFromInt(region.h),
    };
}

pub fn main(init: std.process.Init.Minimal) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const args = init.args.toSlice(arena_state.allocator()) catch return error.InvalidArgument;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--help")) {
            std.debug.print("TB-20 options: --frames 360 --seed 20 --revision <full-git-sha>. SDL_GPU_DRIVER may request vulkan, direct3d12, or metal; the report always records SDL's actual selected driver. Escape exits.\n", .{});
            return;
        } else if (std.mem.eql(u8, args[index], "--frames") and index + 1 < args.len) {
            index += 1;
            options.frames = try std.fmt.parseUnsigned(u64, args[index], 10);
        } else if (std.mem.eql(u8, args[index], "--seed") and index + 1 < args.len) {
            index += 1;
            options.seed = try std.fmt.parseUnsigned(u64, args[index], 10);
        } else if (std.mem.eql(u8, args[index], "--revision") and index + 1 < args.len) {
            index += 1;
            options.source_revision = args[index];
        } else {
            return error.InvalidArgument;
        }
    }
    if (options.frames == 0) return error.InvalidArgument;
    try engine.run(engine.SceneHost(Tb20), config);
}
