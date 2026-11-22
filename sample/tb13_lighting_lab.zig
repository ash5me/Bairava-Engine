//! TB-13 exercises normal-mapped sprites, overlapping point lights, shadow segments, and render scaling.

const std = @import("std");
const engine = @import("bairava");

const log = engine.log.scoped("tb13");
const Color = engine.ui.Color;
const white = Color{ .r = 0.94, .g = 0.96, .b = 1, .a = 1 };
const muted = Color{ .r = 0.68, .g = 0.75, .b = 0.85, .a = 1 };
const panel = Color{ .r = 0.025, .g = 0.04, .b = 0.07, .a = 0.91 };
const normal_sprite_count = 6;

const config = engine.Config{
    .title = "Bairava TB-13 Lighting Laboratory",
    .window_w = 960,
    .window_h = 540,
    .native_w = 320,
    .native_h = 180,
    .clear_rgb = .{ 0.012, 0.018, 0.03 },
    .gpu_timing = true,
    .settings_file = "tb13_settings.txt",
};

const Options = struct {
    frames: u64 = 360,
    lights: u32 = 3,
    capacity_sweep: bool = false,
};

var options = Options{};
var bounded_frames: ?u64 = null;

const Tb13 = struct {
    albedo: engine.Texture,
    normal: engine.Texture,
    flat_texture: engine.Texture,
    font: engine.ui.FontHandle,
    canvas: engine.ui.Canvas,
    tick: u64 = 0,
    phase: f32 = 0,
    ambient: f32 = 0.16,
    light_count: u32 = 3,
    shadow_enabled: bool = true,
    high_capacity: bool = false,
    rotate_normals: bool = true,
    capacity_checks: u64 = 0,
    capacity_failures: u64 = 0,
    normal_draw_checks: u64 = 0,
    normal_draw_failures: u64 = 0,
    shadow_checks: u64 = 0,
    shadow_failures: u64 = 0,
    depth_checks: u64 = 0,
    depth_failures: u64 = 0,
    light_samples: u64 = 0,
    shadow_samples: u64 = 0,
    sprite_samples: u64 = 0,
    batch_samples: u64 = 0,
    frame_ms_avg: f32 = 0,
    frame_ms_p95: f32 = 0,
    gpu_ms_avg: f32 = 0,
    gpu_ms_p95: f32 = 0,
    report_written: bool = false,
    limits_validated: bool = false,
    frame_validated: bool = false,

    pub fn init(ctx: *engine.Context) !Tb13 {
        var albedo = try ctx.loadTexture("assets/testbeds/tb13/stone_albedo.png");
        errdefer albedo.deinit();
        var normal = try ctx.loadTexture("assets/testbeds/tb13/stone_normal.png");
        errdefer normal.deinit();
        if (albedo.width != normal.width or albedo.height != normal.height) return error.InvalidNormalMapSize;
        var flat_texture = try ctx.loadTexture("assets/sample/white.png");
        errdefer flat_texture.deinit();
        const font = try ctx.loadFont("assets/ui_font_9px.bfnt", 9);
        errdefer ctx.unloadFont(font) catch |err| log.err("font cleanup failed during init: {s}", .{@errorName(err)});
        const canvas = engine.ui.Canvas.create(ctx.allocators.game, ctx.fonts, font);
        return .{
            .albedo = albedo,
            .normal = normal,
            .flat_texture = flat_texture,
            .font = font,
            .canvas = canvas,
            .light_count = if (options.capacity_sweep) @intCast(engine.max_lights) else options.lights,
            .high_capacity = options.capacity_sweep,
        };
    }

    pub fn update(self: *Tb13, ctx: *engine.Context, _: *engine.SceneNavigator) void {
        if (ctx.input.wasPressed(.escape)) ctx.running = false;
        if (ctx.input.wasPressed(.left)) self.light_count -|= 1;
        if (ctx.input.wasPressed(.right)) self.light_count = @min(engine.max_lights, self.light_count + 1);
        if (ctx.input.wasPressed(.up)) self.ambient = @min(0.65, self.ambient + 0.02);
        if (ctx.input.wasPressed(.down)) self.ambient = @max(0.02, self.ambient - 0.02);
        if (ctx.input.wasPressed(.space)) self.shadow_enabled = !self.shadow_enabled;
        if (ctx.input.wasPressed(.f)) self.high_capacity = !self.high_capacity;
        if (ctx.input.wasPressed(.e)) self.rotate_normals = !self.rotate_normals;

        self.tick += 1;
        self.phase += ctx.dt;
        const frame = ctx.diagnostics.stats.of(.frame);
        self.frame_ms_avg = frame.average() * 1000;
        self.frame_ms_p95 = frame.percentile(0.95) * 1000;
        const gpu = ctx.diagnostics.stats.of(.gpu);
        self.gpu_ms_avg = gpu.average() * 1000;
        self.gpu_ms_p95 = gpu.percentile(0.95) * 1000;
        self.batch_samples += 1;
        if (!self.report_written and ctx.diagnostics.snapshot.frames >= options.frames) self.report(ctx);
        if (bounded_frames) |limit| {
            if (ctx.diagnostics.snapshot.frames >= limit) ctx.running = false;
        }
    }

    pub fn draw(self: *Tb13, dc: *const engine.DrawContext) void {
        const batch = dc.batch;
        if (!self.limits_validated) self.validateLimits(batch, dc.view_w, dc.view_h);

        batch.setAmbient(.{ self.ambient, self.ambient * 1.03, self.ambient * 1.12 });
        const active_lights = if (self.high_capacity) @as(u32, @intCast(engine.max_lights)) else self.light_count;
        for (0..active_lights) |index| {
            const light = self.makeLight(index, dc.view_w, dc.view_h);
            if (!batch.addLight(light)) {
                log.err("light capacity rejected a light before the configured capacity", .{});
                self.capacity_failures += 1;
                break;
            }
        }
        self.light_samples += batch.light_count;

        if (self.shadow_enabled) {
            const x = 155 + @sin(self.phase * 0.72) * 16;
            const accepted = batch.addShadowSegment(.{
                .start = .{ x, 38 },
                .end = .{ x, 154 },
            });
            if (!accepted) self.shadow_failures += 1;
        }
        if (self.high_capacity) {
            for (1..engine.max_shadow_segments) |index| {
                const y = 40 + @as(f32, @floatFromInt(index)) * 7;
                if (!batch.addShadowSegment(.{ .start = .{ 8, y }, .end = .{ 78, y } })) {
                    self.capacity_failures += 1;
                    break;
                }
            }
        }
        self.shadow_samples += batch.shadow_segment_count;

        self.drawRoom(batch, dc.view_w, dc.view_h);
        self.drawNormalMappedSamples(batch, dc.view_w, dc.view_h);
        self.sprite_samples += batch.sprite_count;
        batch.prepare();
        self.verifyLitBatches(batch);

        self.canvas.clear();
        self.canvas.rect(4, 4, 312, 28, panel);
        self.canvas.text(10, 8, "TB-13  Normal Maps / Point Lights / Shadows", white);
        self.canvas.text(10, 20, "Left/Right lights  Up/Down ambient  Space shadow  F capacity  E rotate", muted);
        self.canvas.rect(5, 151, 310, 25, panel);
        var metrics: [128]u8 = undefined;
        const metric_text = std.fmt.bufPrint(&metrics, "L {d}/{d} S {d}/{d} A {d:.2} frame {d:.1}/{d:.1} GPU {d:.1}", .{
            batch.light_count,
            engine.max_lights,
            batch.shadow_segment_count,
            engine.max_shadow_segments,
            self.ambient,
            self.frame_ms_avg,
            self.frame_ms_p95,
            self.gpu_ms_avg,
        }) catch "lighting metrics unavailable";
        self.canvas.text(10, 156, metric_text, white);
        self.canvas.text(10, 166, "Left: unlit reference | Right: normal-mapped tiles", muted);
        self.canvas.queue(batch, 1000);
    }

    fn drawRoom(self: *Tb13, batch: *engine.SpriteBatch, view_w: f32, view_h: f32) void {
        const tile_w: f32 = 64;
        const tile_h: f32 = 64;
        var y: f32 = 34;
        while (y < view_h + tile_h) : (y += tile_h) {
            var x: f32 = 88;
            while (x < view_w) : (x += tile_w) {
                batch.drawSprite(
                    &self.albedo,
                    .{ .x = 0, .y = 0, .w = @floatFromInt(self.albedo.width), .h = @floatFromInt(self.albedo.height) },
                    .{ .x = x, .y = y, .w = tile_w, .h = tile_h },
                    .{ .normal = &self.normal, .depth_y = y + tile_h },
                );
            }
        }
        batch.drawSprite(
            &self.albedo,
            .{ .x = 0, .y = 0, .w = @floatFromInt(self.albedo.width), .h = @floatFromInt(self.albedo.height) },
            .{ .x = 12, .y = 54, .w = 64, .h = 64 },
            .{ .tint = .{ 0.68, 0.68, 0.68 }, .depth_y = 120 },
        );
        if (self.shadow_enabled) {
            const wall_x = 155 + @sin(self.phase * 0.72) * 16;
            batch.drawSprite(
                &self.flat_texture,
                .{ .x = 0, .y = 0, .w = 4, .h = 4 },
                .{ .x = wall_x - 2, .y = 36, .w = 4, .h = 120 },
                .{ .tint = .{ 0.26, 0.36, 0.49 }, .z = 1 },
            );
        }
    }

    fn drawNormalMappedSamples(self: *Tb13, batch: *engine.SpriteBatch, _: f32, _: f32) void {
        for (0..normal_sprite_count) |index| {
            const col: f32 = @floatFromInt(index % 3);
            const row: f32 = @floatFromInt(index / 3);
            const x = 104 + col * 66;
            const y = 50 + row * 66;
            const angle = if (self.rotate_normals) self.phase * (0.32 + col * 0.08) else 0;
            batch.drawSprite(
                &self.albedo,
                .{ .x = 0, .y = 0, .w = @floatFromInt(self.albedo.width), .h = @floatFromInt(self.albedo.height) },
                .{ .x = x, .y = y, .w = 60, .h = 60 },
                .{
                    .normal = &self.normal,
                    .flip_x = index % 2 == 1,
                    .rotation = angle,
                    .origin = .{ 30, 30 },
                    .z = 2,
                    .depth_y = y + 60,
                },
            );
            self.normal_draw_checks += 1;
        }
    }

    fn makeLight(self: *const Tb13, index: usize, view_w: f32, view_h: f32) engine.Light {
        const count: f32 = @floatFromInt(if (self.high_capacity) engine.max_lights else @max(self.light_count, 1));
        const angle = self.phase * 0.38 + @as(f32, @floatFromInt(index)) * (std.math.tau / count);
        const center_x = view_w * 0.62;
        const center_y = view_h * 0.53;
        const radius: f32 = if (self.high_capacity) 104 else 98;
        const colors = [_][3]f32{
            .{ 1.0, 0.35, 0.16 },
            .{ 0.2, 0.66, 1.0 },
            .{ 0.55, 1.0, 0.32 },
            .{ 1.0, 0.72, 0.2 },
        };
        return .{
            .x = center_x + @cos(angle) * radius,
            .y = center_y + @sin(angle) * radius * 0.48,
            .height = 30 + @sin(angle * 1.7) * 8,
            .radius = 104,
            .color = colors[index % colors.len],
            .intensity = if (self.high_capacity) 0.55 else 1.05,
        };
    }

    fn validateLimits(self: *Tb13, batch: *engine.SpriteBatch, view_w: f32, view_h: f32) void {
        batch.begin(view_w, view_h);
        var lights_added: usize = 0;
        for (0..engine.max_lights) |index| {
            if (batch.addLight(self.makeLight(index, view_w, view_h))) lights_added += 1;
        }
        const light_overflow_rejected = !batch.addLight(.{ .x = 1, .y = 1, .radius = 10 });
        var shadows_added: usize = 0;
        for (0..engine.max_shadow_segments) |index| {
            const y = @as(f32, @floatFromInt(index)) * 2;
            if (batch.addShadowSegment(.{ .start = .{ 0, y }, .end = .{ 10, y + 1 } })) shadows_added += 1;
        }
        const shadow_overflow_rejected = !batch.addShadowSegment(.{ .start = .{ 0, 0 }, .end = .{ 1, 1 } });
        self.capacity_checks += 2;
        if (lights_added != engine.max_lights or !light_overflow_rejected) self.capacity_failures += 1;
        if (shadows_added != engine.max_shadow_segments or !shadow_overflow_rejected) self.capacity_failures += 1;
        self.limits_validated = true;
        batch.begin(view_w, view_h);
    }

    fn verifyLitBatches(self: *Tb13, batch: *const engine.SpriteBatch) void {
        if (self.frame_validated) return;
        self.frame_validated = true;
        self.normal_draw_checks += 1;
        if (!batch.has_lit_runs or batch.batch_count < 2) self.normal_draw_failures += 1;
        self.depth_checks += 1;
        var sorted = batch.sprite_count >= normal_sprite_count + 1;
        for (1..batch.sprite_count) |index| {
            const previous = batch.quads[index - 1];
            const current = batch.quads[index];
            if (previous.z > current.z or (previous.z == current.z and previous.depth_y > current.depth_y)) {
                sorted = false;
                break;
            }
        }
        if (!sorted) self.depth_failures += 1;
        self.shadow_checks += 1;
        if (self.shadow_enabled and batch.shadow_segment_count == 0) self.shadow_failures += 1;
    }

    fn report(self: *Tb13, ctx: *engine.Context) void {
        if (self.report_written) return;
        self.report_written = true;
        const frames = ctx.diagnostics.stats.of(.frame);
        const passed = self.capacity_checks == 2 and self.capacity_failures == 0 and
            self.normal_draw_checks > 0 and self.normal_draw_failures == 0 and
            self.shadow_checks > 0 and self.shadow_failures == 0 and self.depth_checks > 0 and self.depth_failures == 0;
        const result: []const u8 = if (passed) "pass" else "incomplete";
        const gpu = ctx.diagnostics.stats.of(.gpu);
        const lights_per_frame = if (self.high_capacity) engine.max_lights else self.light_count;
        log.info("TB-13 {s}: light samples {d}, shadow samples {d}, sprites {d}, frame avg/p95 {d:.3}/{d:.3} ms, GPU avg/p95 {d:.3}/{d:.3} ms, capacity failures {d}", .{
            result,
            self.light_samples,
            self.shadow_samples,
            self.sprite_samples,
            frames.average() * 1000,
            frames.percentile(0.95) * 1000,
            gpu.average() * 1000,
            gpu.percentile(0.95) * 1000,
            self.capacity_failures + self.normal_draw_failures + self.shadow_failures + self.depth_failures,
        });

        var json: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(
            &json,
            "{{\"testbed\":\"TB-13\",\"scenario\":\"lighting-laboratory\",\"result\":\"{s}\",\"frames\":{d},\"lights_capacity\":{d},\"shadow_capacity\":{d},\"configured_lights\":{d},\"lights_per_frame\":{d},\"high_capacity_mode\":{d},\"shadow_enabled\":{d},\"normal_draw_checks\":{d},\"normal_draw_failures\":{d},\"capacity_checks\":{d},\"capacity_failures\":{d},\"shadow_checks\":{d},\"shadow_failures\":{d},\"depth_checks\":{d},\"depth_failures\":{d},\"light_samples\":{d},\"shadow_samples\":{d},\"sprite_samples\":{d},\"batch_samples\":{d},\"frame_ms_avg\":{d:.3},\"frame_ms_p95\":{d:.3},\"gpu_ms_avg\":{d:.3},\"gpu_ms_p95\":{d:.3},\"gpu_timing_enabled\":true}}\n",
            .{
                result,
                ctx.diagnostics.snapshot.frames,
                engine.max_lights,
                engine.max_shadow_segments,
                self.light_count,
                lights_per_frame,
                @intFromBool(self.high_capacity),
                @intFromBool(self.shadow_enabled),
                self.normal_draw_checks,
                self.normal_draw_failures,
                self.capacity_checks,
                self.capacity_failures,
                self.shadow_checks,
                self.shadow_failures,
                self.depth_checks,
                self.depth_failures,
                self.light_samples,
                self.shadow_samples,
                self.sprite_samples,
                self.batch_samples,
                frames.average() * 1000,
                frames.percentile(0.95) * 1000,
                gpu.average() * 1000,
                gpu.percentile(0.95) * 1000,
            },
        ) catch |err| {
            log.err("TB-13 metrics formatting failed: {s}", .{@errorName(err)});
            return;
        };
        var result_path: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&result_path, "TB-13-lighting-results-{d}.json", .{lights_per_frame}) catch |err| {
            log.err("TB-13 result path formatting failed: {s}", .{@errorName(err)});
            return;
        };
        ctx.writeFile(path, text) catch |err| {
            log.err("TB-13 metrics write failed: {s}", .{@errorName(err)});
            return;
        };
    }

    pub fn debugText(self: *const Tb13, out: *engine.diagnostics.Text) void {
        out.print("TB-13 lighting laboratory: {d} lights, ambient {d:.2}, shadows {s}", .{
            self.light_count,
            self.ambient,
            if (self.shadow_enabled) "on" else "off",
        });
        out.print("capacity checks {d} / failures {d}, normal-map failures {d}; Escape exits", .{
            self.capacity_checks,
            self.capacity_failures,
            self.normal_draw_failures,
        });
    }

    pub fn deinitWithContext(self: *Tb13, ctx: *engine.Context) void {
        self.canvas.deinit();
        ctx.unloadFont(self.font) catch |err| log.err("TB-13 font cleanup failed: {s}", .{@errorName(err)});
        self.flat_texture.deinit();
        self.normal.deinit();
        self.albedo.deinit();
    }

    pub fn deinit(self: *Tb13) void {
        self.canvas.deinit();
        self.flat_texture.deinit();
        self.normal.deinit();
        self.albedo.deinit();
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const args = init.args.toSlice(arena_state.allocator()) catch return error.InvalidArgument;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--help")) {
            std.debug.print("TB-13 options: --frames 360 --lights 3 --capacity-sweep. Left/Right changes lights; Up/Down adjusts ambient; Space toggles a moving shadow; F sweeps maximum capacities; E toggles normal-map rotation. Escape exits.\n", .{});
            return;
        } else if (std.mem.eql(u8, args[index], "--capacity-sweep")) {
            options.capacity_sweep = true;
        } else if (std.mem.eql(u8, args[index], "--frames") and index + 1 < args.len) {
            index += 1;
            options.frames = try std.fmt.parseUnsigned(u64, args[index], 10);
            bounded_frames = options.frames;
        } else if (std.mem.eql(u8, args[index], "--lights") and index + 1 < args.len) {
            index += 1;
            options.lights = try std.fmt.parseUnsigned(u32, args[index], 10);
        } else {
            return error.InvalidArgument;
        }
    }
    if (options.capacity_sweep) options.lights = @intCast(engine.max_lights);
    if (options.frames == 0 or options.lights > engine.max_lights) return error.InvalidArgument;
    try engine.run(engine.SceneHost(Tb13), config);
}
