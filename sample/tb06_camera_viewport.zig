//! TB-06 camera and viewport testbed.
//! Exercises follow constraints, zoom, draw-only shake, viewport resizing, DPI mapping, and
//! camera-space coordinate conversion through the public runtime APIs.

const std = @import("std");
const engine = @import("bairava");

const log = engine.log.scoped("tb06");

const Options = struct {
    frames: u64 = 180,
};

var options = Options{};

const world_w: f32 = 1200;
const world_h: f32 = 900;
const target_size: f32 = 12;
const landmarks = [_]Point{
    .{ .x = 40, .y = 40 },
    .{ .x = 1160, .y = 40 },
    .{ .x = 40, .y = 860 },
    .{ .x = 1160, .y = 860 },
    .{ .x = 600, .y = 450 },
    .{ .x = 900, .y = 250 },
    .{ .x = 250, .y = 680 },
};

const Point = struct {
    x: f32,
    y: f32,
};

const config = engine.Config{
    .title = "Bairava TB-06 Camera and Viewport",
    .window_w = 960,
    .window_h = 540,
    .native_w = 320,
    .native_h = 180,
    .clear_rgb = .{ 0.035, 0.045, 0.065 },
    .settings_file = "tb06_settings.txt",
    .post_effects = &.{.vignette},
};

const Tb06 = struct {
    texture: engine.Texture,
    elapsed: f32 = 0,
    next_shake_at: f32 = 2,
    shake: engine.Shake = .{ .seed = 0xB06, .max_offset = 3, .frequency = 18, .decay = 1.4 },
    smooth_follow: bool = true,
    constraints_enabled: bool = true,
    report_written: bool = false,
    update_checks: u64 = 0,
    conversion_checks: u64 = 0,
    conversion_failures: u64 = 0,
    offscreen_landmarks: u64 = 0,
    max_conversion_error: f32 = 0,
    camera_x: f32 = 0,
    camera_y: f32 = 0,
    view_w: f32 = 0,
    view_h: f32 = 0,
    zoom: f32 = 1,
    drawable_w: f32 = 0,
    drawable_h: f32 = 0,
    pixel_density: f32 = 1,

    pub fn init(ctx: *engine.Context) !Tb06 {
        ctx.camera.world_w = world_w;
        ctx.camera.world_h = world_h;
        ctx.camera.follow(40, 40);
        return .{ .texture = try ctx.loadTexture("assets/sample/white.png") };
    }

    pub fn update(self: *Tb06, ctx: *engine.Context, _: *engine.SceneNavigator) void {
        if (ctx.input.wasPressed(.escape)) ctx.running = false;
        if (ctx.input.wasPressed(.equal) or ctx.input.wasPressed(.keypad_plus)) ctx.zoomBy(1.25);
        if (ctx.input.wasPressed(.minus) or ctx.input.wasPressed(.keypad_minus)) ctx.zoomBy(0.8);
        if (ctx.input.wasPressed(.zero)) ctx.resetZoom();
        if (ctx.input.wasPressed(.i)) {
            ctx.scale_mode = if (ctx.scale_mode == .fit) .integer else .fit;
        }
        if (ctx.input.wasPressed(.tab)) self.constraints_enabled = !self.constraints_enabled;
        if (ctx.input.wasPressed(.f)) self.smooth_follow = !self.smooth_follow;
        if (ctx.input.wasPressed(.space)) self.shake.add(0.7);

        self.elapsed += ctx.dt;
        if (self.elapsed >= self.next_shake_at) {
            self.shake.add(0.45);
            self.next_shake_at += 3.5;
        }

        ctx.camera.world_w = world_w;
        ctx.camera.world_h = world_h;
        const target = Point{
            .x = 40 + (world_w - 80) * (0.5 + 0.5 * @sin(self.elapsed * 0.23)),
            .y = 40 + (world_h - 80) * (0.5 + 0.5 * @sin(self.elapsed * 0.17 + 1.1)),
        };
        const direction = Point{
            .x = @cos(self.elapsed * 0.23),
            .y = @cos(self.elapsed * 0.17 + 1.1),
        };
        const constraint: engine.Camera.Constraint = if (self.constraints_enabled)
            .{
                .lead_x = direction.x * 36,
                .lead_y = direction.y * 24,
                .dead_x = 0.14,
                .dead_y = 0.12,
                .limit_x = 0.38,
                .limit_y = 0.34,
            }
        else
            .{};
        if (self.smooth_follow) {
            ctx.camera.followSmoothWith(target.x, target.y, ctx.dt, 3.2, constraint);
        } else {
            ctx.camera.followWith(target.x, target.y, constraint);
        }

        self.update_checks += 1;
        self.camera_x = ctx.camera.x;
        self.camera_y = ctx.camera.y;
        self.view_w = ctx.camera.view_w;
        self.view_h = ctx.camera.view_h;
        self.zoom = ctx.camera.zoom;
        self.drawable_w = ctx.layout.dst_w;
        self.drawable_h = ctx.layout.dst_h;
        self.pixel_density = ctx.layout.pixel_density;
        self.checkCameraAndPointer(ctx);
        self.offscreen_landmarks = 0;
        for (landmarks) |landmark| {
            const bounds = engine.camera.Bounds{
                .x = landmark.x,
                .y = landmark.y,
                .w = target_size,
                .h = target_size,
            };
            if (!engine.camera.overlapsView(ctx.camera.viewRect(), bounds, 0)) self.offscreen_landmarks += 1;
        }

        if (!self.report_written and ctx.diagnostics.snapshot.frames >= options.frames) self.report(ctx);
    }

    fn checkCameraAndPointer(self: *Tb06, ctx: *engine.Context) void {
        const camera = ctx.camera.*;
        const valid = validCameraAxis(camera.x, camera.view_w, camera.world_w) and
            validCameraAxis(camera.y, camera.view_h, camera.world_h);
        if (!valid) {
            self.conversion_failures += 1;
            log.err("camera bounds invalid: origin ({d:.3},{d:.3}), view ({d:.3},{d:.3}), world ({d:.3},{d:.3})", .{
                camera.x,
                camera.y,
                camera.view_w,
                camera.view_h,
                camera.world_w,
                camera.world_h,
            });
        }

        const world = ctx.mouseWorld();
        const window_x = ((world.x - camera.x) * ctx.layout.dst_w / ctx.layout.view_w + ctx.layout.dst_x) / ctx.layout.pixel_density;
        const window_y = ((world.y - camera.y) * ctx.layout.dst_h / ctx.layout.view_h + ctx.layout.dst_y) / ctx.layout.pixel_density;
        const roundtrip_error = @max(@abs(window_x - ctx.input.mouse_x), @abs(window_y - ctx.input.mouse_y));
        self.conversion_checks += 1;
        self.max_conversion_error = @max(self.max_conversion_error, roundtrip_error);
        if (!std.math.isFinite(roundtrip_error) or roundtrip_error > 0.01) {
            self.conversion_failures += 1;
            log.err("window/world conversion round trip error {d:.5} points", .{roundtrip_error});
        }
    }

    pub fn draw(self: *Tb06, dc: *const engine.DrawContext) void {
        self.shake.update(dc.dt);
        const offset = self.shake.sample();
        const draw_camera = dc.cam.offset(offset[0], offset[1]);
        self.drawParallax(dc, draw_camera);
        self.drawWorld(dc, draw_camera);
        if (dc.show.camera) self.drawCameraDebug(dc, draw_camera);
    }

    fn drawParallax(self: *Tb06, dc: *const engine.DrawContext, cam: engine.Camera) void {
        const parallax = cam.scrolled(.{ .factor_x = 0.22, .factor_y = 0.22 });
        var x = @floor(parallax.x / 48) * 48;
        while (x < parallax.x + dc.view_w + 48) : (x += 48) {
            const sx = parallax.screenX(x);
            dc.batch.drawSprite(
                &self.texture,
                .{ .x = 0, .y = 0, .w = 4, .h = 4 },
                .{ .x = sx, .y = 0, .w = 1, .h = dc.view_h },
                .{ .tint = .{ 0.12, 0.18, 0.27 }, .alpha = 0.5 },
            );
        }
        var y = @floor(parallax.y / 48) * 48;
        while (y < parallax.y + dc.view_h + 48) : (y += 48) {
            const sy = parallax.screenY(y);
            dc.batch.drawSprite(
                &self.texture,
                .{ .x = 0, .y = 0, .w = 4, .h = 4 },
                .{ .x = 0, .y = sy, .w = dc.view_w, .h = 1 },
                .{ .tint = .{ 0.12, 0.18, 0.27 }, .alpha = 0.5 },
            );
        }
    }

    fn drawWorld(self: *Tb06, dc: *const engine.DrawContext, cam: engine.Camera) void {
        dc.batch.drawSprite(
            &self.texture,
            .{ .x = 0, .y = 0, .w = 4, .h = 4 },
            .{
                .x = cam.screenX(0),
                .y = cam.screenY(0),
                .w = world_w,
                .h = world_h,
            },
            .{ .tint = .{ 0.08, 0.11, 0.15 }, .alpha = 0.12 },
        );

        drawLine(dc, &self.texture, cam, .{ .x = 0, .y = 0 }, .{ .x = world_w, .y = 0 }, 3, .{ 0.32, 0.58, 0.8 });
        drawLine(dc, &self.texture, cam, .{ .x = 0, .y = world_h }, .{ .x = world_w, .y = world_h }, 3, .{ 0.32, 0.58, 0.8 });
        drawLine(dc, &self.texture, cam, .{ .x = 0, .y = 0 }, .{ .x = 0, .y = world_h }, 3, .{ 0.32, 0.58, 0.8 });
        drawLine(dc, &self.texture, cam, .{ .x = world_w, .y = 0 }, .{ .x = world_w, .y = world_h }, 3, .{ 0.32, 0.58, 0.8 });

        for (landmarks, 0..) |landmark, index| {
            const size: f32 = if (index == 4) 24 else target_size;
            const tint: [3]f32 = if (index == 4) .{ 0.95, 0.7, 0.22 } else .{ 0.32, 0.72, 0.92 };
            dc.batch.drawSprite(
                &self.texture,
                .{ .x = 0, .y = 0, .w = 4, .h = 4 },
                .{
                    .x = cam.screenX(landmark.x),
                    .y = cam.screenY(landmark.y),
                    .w = size,
                    .h = size,
                },
                .{ .tint = tint },
            );
        }

        const target = Point{
            .x = 40 + (world_w - 80) * (0.5 + 0.5 * @sin(self.elapsed * 0.23)),
            .y = 40 + (world_h - 80) * (0.5 + 0.5 * @sin(self.elapsed * 0.17 + 1.1)),
        };
        dc.batch.drawSprite(
            &self.texture,
            .{ .x = 0, .y = 0, .w = 4, .h = 4 },
            .{
                .x = cam.screenX(target.x - target_size / 2),
                .y = cam.screenY(target.y - target_size / 2),
                .w = target_size,
                .h = target_size,
            },
            .{ .tint = .{ 1, 0.3, 0.23 } },
        );
    }

    fn drawCameraDebug(self: *Tb06, dc: *const engine.DrawContext, cam: engine.Camera) void {
        const color = engine.diagnostics.Color{ .r = 0.2, .g = 0.85, .b = 0.95, .a = 1 };
        dc.debug.outline(0, 0, dc.view_w, dc.view_h, color);
        const world_left = cam.screenX(0);
        const world_top = cam.screenY(0);
        dc.debug.outline(world_left, world_top, world_w, world_h, .{ .r = 0.95, .g = 0.35, .b = 0.25, .a = 1 });
        if (self.constraints_enabled) {
            const half_w = dc.view_w * 0.14;
            const half_h = dc.view_h * 0.12;
            dc.debug.outline(
                dc.view_w / 2 - half_w,
                dc.view_h / 2 - half_h,
                half_w * 2,
                half_h * 2,
                .{ .r = 0.95, .g = 0.75, .b = 0.2, .a = 1 },
            );
        }
    }

    fn report(self: *Tb06, ctx: *engine.Context) void {
        self.report_written = true;
        const camera = ctx.camera.*;
        const frames = ctx.diagnostics.stats.of(.frame);
        log.info("TB-06 frames {d}, viewport {d:.1}x{d:.1}, drawable {d:.1}x{d:.1}, pixel density {d:.2}, integer scale {any}", .{
            ctx.diagnostics.snapshot.frames,
            ctx.layout.view_w,
            ctx.layout.view_h,
            ctx.layout.dst_w,
            ctx.layout.dst_h,
            ctx.layout.pixel_density,
            ctx.layout.pixel_perfect,
        });
        log.info("TB-06 camera ({d:.2},{d:.2}) zoom {d:.3}, conversion checks {d}, failures {d}, max error {d:.5} points, offscreen landmarks {d}, frame avg/p95 {d:.2}/{d:.2} ms", .{
            camera.x,
            camera.y,
            camera.zoom,
            self.conversion_checks,
            self.conversion_failures,
            self.max_conversion_error,
            self.offscreen_landmarks,
            frames.average() * 1000,
            frames.percentile(0.95) * 1000,
        });
        var json: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(
            &json,
            "{{\"testbed\":\"TB-06\",\"scenario\":\"camera-viewport\",\"result\":\"{s}\",\"frames\":{d},\"camera_update_checks\":{d},\"camera_x\":{d:.3},\"camera_y\":{d:.3},\"zoom\":{d:.3},\"view_w\":{d:.1},\"view_h\":{d:.1},\"drawable_w\":{d:.1},\"drawable_h\":{d:.1},\"pixel_density\":{d:.3},\"pixel_perfect\":{s},\"conversion_checks\":{d},\"conversion_failures\":{d},\"max_conversion_error_points\":{d:.6},\"offscreen_landmarks\":{d},\"shake_trauma\":{d:.3},\"frame_ms_avg\":{d:.3},\"frame_ms_p95\":{d:.3},\"post_effect\":\"vignette\",\"multiview\":\"unsupported\"}}\n",
            .{
                if (self.conversion_failures == 0) "pass" else "fail",
                ctx.diagnostics.snapshot.frames,
                self.update_checks,
                camera.x,
                camera.y,
                camera.zoom,
                ctx.layout.view_w,
                ctx.layout.view_h,
                ctx.layout.dst_w,
                ctx.layout.dst_h,
                ctx.layout.pixel_density,
                if (ctx.layout.pixel_perfect) "true" else "false",
                self.conversion_checks,
                self.conversion_failures,
                self.max_conversion_error,
                self.offscreen_landmarks,
                self.shake.trauma,
                frames.average() * 1000,
                frames.percentile(0.95) * 1000,
            },
        ) catch |err| {
            log.err("TB-06 metrics could not be formatted: {s}", .{@errorName(err)});
            return;
        };
        ctx.writeFile("TB-06-camera-viewport-results.json", text) catch |err| {
            log.err("TB-06 metrics could not be written: {s}", .{@errorName(err)});
        };
    }

    pub fn debugText(self: *const Tb06, out: *engine.diagnostics.Text) void {
        out.print("TB-06: +/- zoom, 0 reset, I fit/integer, Tab constraints, F follow, Space shake, F4 debug", .{});
        out.print("camera ({d:.1},{d:.1}) view {d:.1}x{d:.1} zoom {d:.2}", .{
            self.camera_x,
            self.camera_y,
            self.view_w,
            self.view_h,
            self.zoom,
        });
        out.print("viewport {d:.0}x{d:.0} drawable {d:.0}x{d:.0} DPI {d:.2}; conversion errors {d}", .{
            self.view_w,
            self.view_h,
            self.drawable_w,
            self.drawable_h,
            self.pixel_density,
            self.conversion_failures,
        });
    }

    pub fn deinitWithContext(self: *Tb06, _: *engine.Context) void {
        self.texture.deinit();
    }

    pub fn deinit(self: *Tb06) void {
        _ = self;
    }
};

fn validCameraAxis(origin: f32, view_size: f32, world_size: f32) bool {
    if (!(std.math.isFinite(origin) and std.math.isFinite(view_size) and std.math.isFinite(world_size)) or
        view_size <= 0 or world_size < 0) return false;
    if (world_size <= view_size) {
        return @abs(origin - (world_size - view_size) / 2) <= 0.01;
    }
    return origin >= -0.01 and origin + view_size <= world_size + 0.01;
}

fn drawLine(dc: *const engine.DrawContext, texture: *const engine.Texture, cam: engine.Camera, a: Point, b: Point, width: f32, tint: [3]f32) void {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const length = @sqrt(dx * dx + dy * dy);
    if (length <= 0) return;
    dc.batch.drawSprite(
        texture,
        .{ .x = 0, .y = 0, .w = 4, .h = 4 },
        .{
            .x = cam.screenX(a.x),
            .y = cam.screenY(a.y),
            .w = length,
            .h = width,
        },
        .{
            .tint = tint,
            .rotation = std.math.atan2(dy, dx),
            .origin = .{ 0, width / 2 },
        },
    );
}

pub fn main(init: std.process.Init.Minimal) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const args = init.args.toSlice(arena_state.allocator()) catch return error.InvalidArgument;
    var arg_index: usize = 1;
    while (arg_index < args.len) : (arg_index += 1) {
        const arg = args[arg_index];
        if (std.mem.eql(u8, arg, "--frames") and arg_index + 1 < args.len) {
            arg_index += 1;
            options.frames = try std.fmt.parseUnsigned(u64, args[arg_index], 10);
        } else if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("TB-06 options: --frames 180. Controls: +/- zoom, 0 reset, I fit/integer, Tab constraints, F follow, Space shake.\n", .{});
            return;
        } else {
            return error.InvalidArgument;
        }
    }
    try engine.run(engine.SceneHost(Tb06), config);
}
