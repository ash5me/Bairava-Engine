//! The frame loop. `run` opens the engine, creates the game, and runs frames until the game sets
//! `running` to false or the window closes. Each frame measures its time, drains events, runs the
//! fixed-step updates, lays out the native view, draws the world into it, and presents it.
//!
//! Timing: `update` runs at a fixed rate, so game logic doesn't depend on the display. `draw` runs
//! once per frame and gets `alpha` to blend between the last two updates.

const std = @import("std");
const build_options = @import("build_options");
const platform = @import("../platform/platform.zig");
const application = @import("application.zig");
const allocator_types = @import("allocators.zig");
const context = @import("context.zig");
const event = @import("event.zig");
const fixed_timestep = @import("fixed_timestep.zig");
const lifecycle = @import("lifecycle.zig");
const startup = @import("startup.zig");
const logging = @import("../logging/log.zig");
const crash = @import("../logging/crash.zig");
const profile = @import("../profiling/profile.zig");
const debug_overlay = @import("../profiling/debug_overlay.zig");
const debug_geometry = @import("../renderer/debug_geometry.zig");
const gate = @import("../diagnostics/gate.zig");
const console_mod = @import("../diagnostics/console.zig");
const collector_mod = @import("../diagnostics/collector.zig");
const frame_stats = @import("../diagnostics/frame_stats.zig");
const renderer = @import("../renderer/renderer.zig");
const view = @import("../renderer/view.zig");
const sprite = @import("../renderer/sprite.zig");
const Rect = sprite.Rect;
const texture = @import("../renderer/texture.zig");
const ui = @import("../ui/ui.zig");

const Config = application.Config;
const DrawContext = context.DrawContext;
const elog = logging.scoped("engine");

/// How long to sleep when there is nothing to draw, in milliseconds. A minimized window has no
/// pixels to draw into, so the loop idles instead of spinning. The sleep is short enough that a
/// restored window shows up within a frame.
const idle_sleep_ms: u32 = 16;

const black = renderer.Color{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 };

/// The current time in nanoseconds, read only in development builds. A release build takes no
/// timings, so it doesn't read the clock for them.
fn clockIf() u64 {
    return if (gate.enabled) platform.clock.nowNs() else 0;
}

/// Seconds from `start_ns` to `end_ns`, or 0 when diagnostics are compiled out.
fn secondsBetween(start_ns: u64, end_ns: u64) f32 {
    if (!gate.enabled) return 0;
    return @as(f32, @floatFromInt(end_ns -| start_ns)) / 1_000_000_000.0;
}

/// Records this frame's samples for the overlay strips and for Tracy. Development builds only, since the
/// collector and the allocator counts are only kept there.
fn recordPlots(collector: *collector_mod.Collector, sprites: u32, draw_calls: u32, memory: collector_mod.Memory) void {
    const allocations = memory.allocationsThisFrame();
    const bytes = memory.bytesThisFrame();
    collector.plots.record(.sprites, @floatFromInt(sprites));
    collector.plots.record(.draw_calls, @floatFromInt(draw_calls));
    collector.plots.record(.allocations, @floatFromInt(allocations));
    collector.plots.record(.allocated_bytes, @floatFromInt(bytes));
    profile.plot("sprites", @floatFromInt(sprites));
    profile.plot("draw calls", @floatFromInt(draw_calls));
    profile.plot("allocations", @floatFromInt(allocations));
    profile.plot("allocated bytes", @floatFromInt(bytes));
}

/// The phase that took the longest in the frame that just ended, for a spike's record. The whole frame is not a
/// phase of its own, so it is left out. With gpu timing on, the GPU wait sits inside `present`, so `present` is
/// credited only with the time outside that wait. Otherwise a GPU-bound frame would be blamed on the window pass.
fn dominantPhase(stats: *const frame_stats.Stats) frame_stats.Phase {
    var best: frame_stats.Phase = .events;
    var best_seconds: f32 = -1;
    for (std.enums.values(frame_stats.Phase)) |phase| {
        if (phase == .frame) continue;
        var seconds = stats.of(phase).last();
        if (phase == .present) seconds = @max(@as(f32, 0), seconds - stats.of(.gpu).last());
        if (seconds > best_seconds) {
            best = phase;
            best_seconds = seconds;
        }
    }
    return best;
}

/// Loads the overlay's font. A missing font turns the overlay off rather than stopping the game.
fn loadOverlayFont(ctx: *const context.Context, config: Config) ?ui.Font {
    return ctx.loadFont(config.debug_font_path, config.debug_font_px) catch |err| {
        logging.recovered("engine", "loading the debug overlay font", config.debug_font_path, err, "the overlay is off");
        return null;
    };
}

/// Opens the window and runs `Game` until it sets `running` to false or the window closes.
///
/// Returns an error when the config is invalid, when the engine can't start, or when the game's
/// `init` fails. Each failure is logged, and everything opened before it is released first. A
/// clean run returns normally.
pub fn run(comptime Game: type, config: Config) !void {
    config.validate() catch |err| {
        elog.err("{s}", .{Config.validationMessage(err)});
        return err;
    };

    // The logger reads the platform clock, so it is set before the first log line. Its timestamps
    // then share a clock with the frame timing below.
    logging.setClock(platform.clock.nowNs);

    // The log file sits beside the executable, which the platform resolves.
    lifecycle.openLog(config);
    defer logging.closeFile();
    elog.info("build profile {s}", .{build_options.profile});
    elog.info("profiling zones {s}", .{if (profile.enabled) "on (Tracy)" else "off"});
    elog.info("development tools {s}", .{if (gate.enabled) "on" else "off"});
    elog.info("gpu timing {s}", .{if (gate.enabled and config.gpu_timing) "on (each frame waits for the GPU)" else "off"});

    var timestep = fixed_timestep.Accumulator.init(config.update_hz);

    var allocators = allocator_types.RuntimeAllocators.init(config.allocator, gate.enabled);
    defer {
        if (gate.enabled) {
            const memory = allocators.stats();
            elog.info("arena shutdown outstanding allocations: engine {d}/{d} B, game {d}/{d} B, asset {d}/{d} B, frame {d}/{d} B", .{
                memory.engine.live_allocations, memory.engine.live_bytes,
                memory.game.live_allocations,   memory.game.live_bytes,
                memory.asset.live_allocations,  memory.asset.live_bytes,
                memory.frame.live_allocations,  memory.frame.live_bytes,
            });
        }
        allocators.deinit();
    }

    var session = lifecycle.Session{};
    session.start(config, &allocators) catch |err| {
        var summary: [256]u8 = undefined;
        elog.err("{s}", .{startup.failureSummary(&summary, session.stage, @errorName(err))});
        return err;
    };
    defer session.stop();
    const ctx = &session.ctx;

    var game = Game.init(ctx) catch |err| {
        elog.err("game initialization failed: {s}", .{@errorName(err)});
        return err;
    };
    defer game.deinit();

    // The overlay bakes its own copy of the debug font, loaded from the same files as the game's fonts.
    // Release builds have no overlay, so they load no font for it.
    const debug_font: ?ui.Font = if (gate.enabled) loadOverlayFont(ctx, config) else null;
    var overlay = debug_overlay.Overlay.init(allocators.engineAllocator(), debug_font);
    defer overlay.deinit();
    const collector = &session.collector;
    var dev_console = console_mod.Console{};
    defer if (dev_console.visible and !platform.window.stopTextInput(session.window)) {
        elog.warn("could not stop text input during shutdown", .{});
    };

    const native_wf: f32 = @floatFromInt(config.native_w);
    const native_hf: f32 = @floatFromInt(config.native_h);
    const clear = renderer.Color{
        .r = config.clear_rgb[0],
        .g = config.clear_rgb[1],
        .b = config.clear_rgb[2],
        .a = 1.0,
    };

    var last_mode = ctx.scale_mode;
    var last_ns = platform.clock.nowNs();
    var total_frames: u64 = 0;
    var simulation_tick: u64 = 0;
    var last_draw_calls: u32 = 0;

    while (ctx.running) {
        allocators.resetFrame();
        // Each Tracy frame runs from one mark to the next, so idle frames show in the profile too.
        profile.frameMark();
        const frame_zone = profile.zoneNamed(@src(), "frame");
        defer frame_zone.End();

        // Frame timing: seconds since the last frame, capped by the fixed-step accumulator.
        const now_ns = platform.clock.nowNs();
        // The overlay graphs the raw time, so a long stall shows in full. The update loop uses the capped time.
        const frame_seconds = @as(f32, @floatFromInt(now_ns - last_ns)) / 1_000_000_000.0;
        const frame_dt = timestep.addFrameTime(frame_seconds);
        last_ns = now_ns;
        if (gate.enabled) {
            collector.stats.record(.frame, frame_seconds);
            // The phases recorded so far belong to the frame that just ended, so a spike names that frame's largest phase.
            collector.spikes.observe(total_frames, frame_seconds, dominantPhase(&collector.stats));
        }

        // Events, then the held keys as of this pump. Presses and clicks wait in Input for an update.
        const events_start = clockIf();
        {
            const zone = profile.zoneNamed(@src(), "events");
            defer zone.End();
            const pumped = try event.pump(session.window, &session.input, &dev_console, collector, &overlay.visible, &session.game_events);
            if (pumped.quit) ctx.running = false;
            if (pumped.toggle_overlay) overlay.toggle();
            if (gate.enabled and pumped.toggle_geometry) collector.toggleGeometry();
            session.input.sampleHeld(platform.events.isHeld);
        }
        if (gate.enabled) collector.stats.record(.events, secondsBetween(events_start, clockIf()));
        // What this frame starts with. A crash report written if the frame panics reads it.
        crash.note(total_frames, if (comptime @hasDecl(@TypeOf(game), "sceneInfo")) game.sceneInfo().name else "none", session.input.heldMask(), session.input.mouse_x, session.input.mouse_y);
        // Hot reload looks at watched files here, before the updates, so a reload never runs during an update.
        if (gate.enabled) {
            const asset_start = clockIf();
            session.reloads.poll(now_ns);
            collector.stats.record(.asset, secondsBetween(asset_start, clockIf()));
        }

        // Requested textures decode on worker threads and are uploaded here, between frames, so a texture never appears
        // partway through an update. At most `texture_loads_per_frame` uploads happen per frame, which bounds the GPU work.
        if (config.texture_loads_per_frame > 0) {
            const zone = profile.zoneNamed(@src(), "texture stream");
            defer zone.End();
            _ = session.streamer.pump(ctx, session.textures, config.texture_loads_per_frame);
        }

        // Fixed-timestep updates. Run whole steps while the accumulated time covers one, so game
        // logic advances at the same rate on any display. Stop early if the game quits.
        var steps: u32 = 0;
        var update_seconds: f32 = 0;
        while (timestep.hasStep() and ctx.running) {
            session.input.latch();
            ctx.dt = timestep.fixed_dt;
            ctx.simulation_tick = simulation_tick;
            const update_start = clockIf();
            {
                const zone = profile.zoneNamed(@src(), "update");
                defer zone.End();
                game.update(ctx);
            }
            simulation_tick +%= 1;
            update_seconds += secondsBetween(update_start, clockIf());
            timestep.consumeStep();
            steps += 1;
        }
        if (gate.enabled) collector.stats.record(.update, update_seconds);
        if (steps > 4) {
            elog.debug("{d} update steps in one frame, so the frame took {d:.1} ms", .{ steps, frame_dt * 1000.0 });
        }
        // Free finished voices, keep voices fed, and move positional voices to the listener. Once per frame is
        // enough: a looping voice keeps a full copy of its sound queued, and a positional voice keeps a tenth of a
        // second queued, so a frame shorter than that cannot starve either.
        const audio_start = clockIf();
        {
            const zone = profile.zoneNamed(@src(), "audio");
            defer zone.End();
            session.audio.update();
        }
        if (gate.enabled) collector.stats.record(.audio, secondsBetween(audio_start, clockIf()));
        if (ctx.scale_mode != last_mode) {
            elog.info("scale mode: {s}", .{@tagName(ctx.scale_mode)});
            last_mode = ctx.scale_mode;
        }

        // The leftover time as a fraction of a step. Drawing blends between the last two updates by this amount.
        const alpha = timestep.interpolationAlpha();
        logging.assert(alpha >= 0.0 and alpha <= 1.0, @src(), "blend factor {d} is outside 0 to 1", .{alpha});

        // Window size in pixels, which is also the swapchain size on high-DPI displays.
        const px = platform.window.pixelSize(session.window);
        if (px.w <= 0 or px.h <= 0) {
            // Minimized: there is nothing to draw into, so sleep rather than spin. Events stay
            // queued in SDL until the next pump.
            platform.clock.sleepMs(idle_sleep_ms);
            continue;
        }
        const win_wf: f32 = @floatFromInt(px.w);
        const win_hf: f32 = @floatFromInt(px.h);

        // Ease the camera's zoom toward the zoom the game asked for. This runs before the view is
        // sized, so this frame is drawn at the zoom it has reached.
        session.cam.approachZoom(ctx.zoom_target, frame_dt, config.zoom_rate);

        // Choose the scale and the view size for this zoom. The fallback rules for integer mode live
        // in view.chooseFit.
        const fit = view.chooseFit(win_wf, win_hf, native_wf, native_hf, ctx.scale_mode, session.cam.zoom);
        const mode_label: []const u8 = if (fit.pixel_perfect) "integer" else "fit";
        const view_w = fit.view_w;
        const view_h = fit.view_h;
        const view_wf: f32 = @floatFromInt(view_w);
        const view_hf: f32 = @floatFromInt(view_h);
        logging.assert(view_w >= 1 and view_h >= 1, @src(), "view {d}x{d} is empty", .{ view_w, view_h });

        if (session.target.width != view_w or session.target.height != view_h) {
            const zone = profile.zoneNamed(@src(), "rebuild target");
            defer zone.End();
            // Wait first, because the old target may still be in use by the GPU.
            platform.gpu.waitIdle(session.gpu.device);
            session.target.deinit();
            session.target = texture.createTarget(allocators.engineAllocator(), session.gpu.device, view_w, view_h, session.format);
            session.post_chain.resize(view_w, view_h);
            elog.debug("native target is now {d}x{d} at {d:.2} scale ({s})", .{ view_w, view_h, fit.scale, mode_label });
        }

        session.cam.view_w = view_wf;
        session.cam.view_h = view_hf;

        // Acquire the frame after the layout is known. A minimized window can report a nonzero size
        // yet get no swapchain, so this path idles too.
        const frame = session.gpu.beginFrame() orelse {
            platform.clock.sleepMs(idle_sleep_ms);
            continue;
        };

        // Pass 1: the game queues its sprites, and they're drawn into the view-sized target.
        const draw_start = clockIf();
        session.world_batch.begin(view_wf, view_hf);
        collector.debug.clear();
        const draw_ctx = DrawContext{
            .batch = &session.world_batch,
            .cam = &session.cam,
            .view_w = view_wf,
            .view_h = view_hf,
            .alpha = alpha,
            .dt = frame_dt,
            .debug = &collector.debug,
            .show = collector.geometry,
            .layers = collector.layers,
        };
        {
            const zone = profile.zoneNamed(@src(), "game draw");
            defer zone.End();
            game.draw(&draw_ctx);
        }
        if (gate.enabled and collector.geometry.camera) debug_geometry.cameraBounds(&collector.debug, &session.cam);

        // The published snapshot and the game's lines, for the overlay. Built only in development builds.
        if (gate.enabled) {
            collector.text.clear();
            if (comptime @hasDecl(@TypeOf(game), "debugText")) game.debugText(&collector.text);
            if (comptime @hasDecl(@TypeOf(game), "sceneInfo")) {
                const info = game.sceneInfo();
                collector.snapshot.scene = .{
                    .name = info.name,
                    .pending = info.pending,
                    .switches = info.switches,
                    .depth = info.depth,
                    .stack = info.stack,
                };
            }
            const textures = ctx.textureStats();
            collector.snapshot.assets = .{
                .loaded = textures.loaded,
                .hits = textures.hits,
                .misses = textures.misses,
                .failed = textures.failed_loads,
                .bytes = textures.bytes,
            };
            collector.snapshot.memory = allocators.stats();
            recordPlots(collector, session.world_batch.sprite_count, last_draw_calls, collector.snapshot.memory);
            // Held keys by name, and the actions the game's bindings resolve from them. A game that does not
            // declare `debugActions` lists no actions.
            var held_keys = collector_mod.NameList{};
            session.input.addHeldNames(&held_keys);
            var held_actions = collector_mod.NameList{};
            if (comptime @hasDecl(@TypeOf(game), "debugActions")) game.debugActions(&session.input, &held_actions);
            collector.snapshot.input = .{
                .held = session.input.heldCount(),
                .pressed = session.input.pressedCount(),
                .mouse_x = session.input.mouse_x,
                .mouse_y = session.input.mouse_y,
                .keys = held_keys,
                .actions = held_actions,
            };
            session.audio.describe(&collector.snapshot.audio);
            const previous_world = collector.snapshot.world;
            collector.snapshot.world = .{
                .sprites = session.world_batch.sprite_count,
                .draw_calls = last_draw_calls,
                .entities = previous_world.entities,
                .collision_queries = previous_world.collision_queries,
                .zoom = session.cam.zoom,
                .cam_x = session.cam.x,
                .cam_y = session.cam.y,
                .view_w = view_w,
                .view_h = view_h,
                .mode = mode_label,
                .scale = fit.scale,
                .map_cols = previous_world.map_cols,
                .map_rows = previous_world.map_rows,
                .selected_col = previous_world.selected_col,
                .selected_row = previous_world.selected_row,
                .selected_tile = previous_world.selected_tile,
                .selected_solid = previous_world.selected_solid,
            };
            collector.snapshot.frames = total_frames;
            // The overlay goes above the game in the same native view. Its draw-call count is from the
            // last frame, since this frame's batches are not drawn until below.
            const overlay_zone = profile.zoneNamed(@src(), "debug overlay");
            defer overlay_zone.End();
            overlay.draw(&session.world_batch, view_wf, view_hf, collector, &dev_console);
        }
        sprite.upload(&session.world_batch, frame.cmd);
        const world_pass = renderer.beginPass(frame.cmd, texture.backendTexture(&session.target), clear);
        sprite.draw(&session.world_batch, world_pass);
        renderer.endPass(world_pass);
        if (gate.enabled) collector.stats.record(.draw, secondsBetween(draw_start, clockIf()));

        // Post-processing: each effect reads the image before it. With no effects, the world target is presented as it is.
        var presented: *const texture.Texture = &session.target;
        if (session.post_chain.enabled()) {
            const zone = profile.zoneNamed(@src(), "post");
            defer zone.End();
            presented = session.post_chain.run(frame.cmd, &session.target);
        }

        // Pass 2: stretch the target onto the window. Fit mode covers the whole window. Integer
        // mode covers a centered whole-number multiple of the view, and the edges stay black.
        const present_start = clockIf();
        {
            const zone = profile.zoneNamed(@src(), "present");
            defer zone.End();
            const layout = view.layoutForFit(win_wf, win_hf, fit);
            const dst_rect = Rect{ .x = layout.dst_x, .y = layout.dst_y, .w = layout.dst_w, .h = layout.dst_h };
            // Record where the view landed, so the next update maps mouse positions with the same rectangle.
            ctx.layout = .{
                .pixel_density = platform.window.pixelDensity(session.window),
                .dst_x = layout.dst_x,
                .dst_y = layout.dst_y,
                .dst_w = layout.dst_w,
                .dst_h = layout.dst_h,
                .view_w = layout.view_w,
                .view_h = layout.view_h,
            };
            const view_rect = Rect{ .x = 0, .y = 0, .w = view_wf, .h = view_hf };
            session.screen_batch.begin(win_wf, win_hf);
            session.screen_batch.drawSprite(presented, view_rect, dst_rect, .{});
            sprite.upload(&session.screen_batch, frame.cmd);
            const screen_pass = renderer.beginPass(frame.cmd, frame.swapchain, black);
            sprite.draw(&session.screen_batch, screen_pass);
            renderer.endPass(screen_pass);
        }

        // With gpu timing on, the frame waits for the GPU to finish, and that wait is the gpu phase. Without it, the
        // frame is submitted and the CPU moves on.
        if (gate.enabled and config.gpu_timing) {
            const gpu_start = clockIf();
            session.gpu.submitAndWait(frame);
            const gpu_seconds = secondsBetween(gpu_start, clockIf());
            collector.stats.record(.gpu, gpu_seconds);
            profile.plot("gpu ms", gpu_seconds * 1000.0);
        } else {
            platform.gpu.Gpu.endFrame(frame);
        }
        if (gate.enabled) collector.stats.record(.present, secondsBetween(present_start, clockIf()));

        // The window title stays as configured. The frame stats are in the debug overlay (F3).
        last_draw_calls = session.world_batch.draw_calls + session.screen_batch.draw_calls;
        total_frames += 1;
    }
    elog.info("main loop ended after {d} frames", .{total_frames});
}
