//! The engine: window, GPU device, the native-resolution pipeline, input, camera, and the
//! frame loop. Engine code never names a game type. A game plugs in by passing a type with
//! `init`, `update`, `draw`, and `deinit` to `run`. Game code should import only this file.
//!
//! Timing: `update` runs at a fixed rate, so game logic doesn't depend on the display. `draw`
//! runs once per frame and gets `alpha` to blend between the last two updates.

const std = @import("std");
const build_options = @import("build_options");

const c = @import("sdl.zig").c;
const image = @import("image.zig");
const Audio = @import("audio.zig").Audio;
const logging = @import("log.zig");
const Renderer = @import("renderer.zig").Renderer;

const elog = logging.scoped("engine");

pub const Camera = @import("camera.zig").Camera;
pub const Input = @import("input.zig").Input;
pub const Key = @import("input.zig").Key;
pub const Rect = @import("sprite.zig").Rect;
pub const SpriteBatch = @import("sprite.zig").SpriteBatch;
pub const Texture = @import("texture.zig").Texture;
/// Fits the native view to the window, and maps window, view, and world coordinates.
/// `Context.mouseWorld` uses the mapping.
pub const view = @import("view.zig");
/// Vector and matrix math, backed by cglm.
pub const math = @import("math.zig");
/// Validated fixed-capacity strings for names and paths.
pub const strings = @import("string.zig");
/// Hash map keyed by validated names.
pub const hash_map = @import("hash_map.zig");
/// Asset names, ids, and validated paths.
pub const assets = @import("assets.zig");
/// Texture atlas index: the rectangle of each sprite inside the atlas image.
pub const atlas = @import("atlas.zig");
/// Custom struct vectors in an array-of-structs or structure-of-arrays layout.
pub const vector = @import("vector.zig");
/// The entity world: component rows with generational handles, stored in a vector.
pub const entity = @import("entity.zig");
/// Tile maps: the map file format, layers, solid tiles, and box movement against them.
pub const tilemap = @import("tilemap.zig");
/// Sprite-sheet animation: clips that name a row of frames, and an animator that plays them.
pub const animation = @import("animation.zig");
/// Sound output through SDL3 audio streams: the playback device, sounds, and voices.
pub const audio = @import("audio.zig");

/// Text and widgets: fonts baked with stb_truetype, and the IMGUI widgets in src/engine/ui/.
pub const ui = @import("ui.zig");
/// Logging and assertions. Game code uses `engine.log.scoped("name")` and `engine.log.assert`.
pub const log = logging;

/// How the native view is fitted to the window. See `view.chooseFit`.
pub const ScaleMode = view.ScaleMode;

/// Settings the game passes to `run`.
pub const Config = struct {
    /// Window title. Play stats are appended to it.
    title: [:0]const u8,
    window_w: c_int,
    window_h: c_int,
    /// The reference view size, in native pixels. At zoom 1 the view fits the window on its
    /// limiting axis, so the view is exactly this size on that axis. The other axis shows more of
    /// the world when the window's shape differs.
    native_w: u32,
    native_h: u32,
    /// Background color behind the world, as RGB from 0 to 1.
    clear_rgb: [3]f32,
    /// Game `update` steps per second.
    update_hz: u32,
    /// Scale mode at startup. The game can change it later through `Context`.
    scale_mode: ScaleMode = .fit,
    /// Smallest and largest zoom the game may ask for. 1 is the normal view, so the bounds must
    /// include it. Below 1 the view shows more of the world, and above 1 it shows less, larger.
    zoom_min: f32,
    zoom_max: f32,
    /// How fast the camera eases to a new zoom, per second. Zero snaps.
    zoom_rate: f32,
};

/// State the game reads and writes during `update`, plus the GPU access it needs in `init`.
pub const Context = struct {
    device: *c.SDL_GPUDevice,
    /// Held keys, presses, releases, and clicks for this update step.
    input: *const Input,
    /// Length of one update step in seconds. This is always the fixed step.
    dt: f32 = 0,
    /// Set to false to end the main loop.
    running: bool = true,
    /// How the native view is fitted to the window. The game may change this at any time.
    scale_mode: ScaleMode = .fit,
    /// The zoom the game is aiming for, where 1 is the normal view. The camera eases toward it each
    /// frame. Change it with `zoomBy` or `resetZoom`, which keep it within the bounds.
    zoom_target: f32 = 1.0,
    /// The zoom bounds from Config. `zoomBy` keeps `zoom_target` between them.
    zoom_min: f32,
    zoom_max: f32,
    /// Where the native view was drawn in the window, from the last frame. Mouse positions are
    /// mapped through this, so they match what the player saw.
    layout: view.Layout,
    /// The camera as the game last drew with it. Read it through `mouseWorld`.
    camera: *const Camera,
    /// Directory of the running executable, with a trailing separator. Asset paths are resolved
    /// against it, because the build installs assets beside the executable.
    base_path: []const u8,
    /// Sound output. Load sounds with `loadSound` and play them through this. It stays silent when
    /// no playback device could be opened.
    audio: *Audio,

    /// The mouse position in world pixels, as the player sees it. It is the cursor's place in the
    /// view drawn last frame, plus that frame's camera position. Use this in `update` rather than
    /// `input.mouse_x`, which is in window points.
    pub fn mouseWorld(self: *const Context) view.Point {
        return view.windowToWorld(self.layout, self.camera, .{ .x = self.input.mouse_x, .y = self.input.mouse_y });
    }

    /// Multiplies the zoom target by `factor`, within the zoom bounds. Use a factor above 1 to zoom
    /// in and one below 1 to zoom out. The camera eases to the new zoom over the next frames.
    pub fn zoomBy(self: *Context, factor: f32) void {
        self.zoom_target = Camera.zoomTarget(self.zoom_target, factor, self.zoom_min, self.zoom_max);
    }

    /// Aims the zoom back at the normal view.
    pub fn resetZoom(self: *Context) void {
        self.zoom_target = 1.0;
    }

    /// Loads an image and uploads it as a texture. `relative` is relative to the executable's
    /// folder, where the build installs the assets. Panics if the file is missing or can't be decoded.
    pub fn loadTexture(self: *const Context, relative: []const u8) Texture {
        var buf: [max_full_path]u8 = undefined;
        const path = std.fmt.bufPrintZ(&buf, "{s}{s}", .{ self.base_path, relative }) catch {
            std.debug.panic("asset path '{s}' is longer than {d} bytes", .{ relative, max_full_path });
        };
        var img = image.loadRgba8(path.ptr) catch |err| {
            std.debug.panic("failed to load {s}: {s}", .{ path, @errorName(err) });
        };
        defer img.deinit();
        elog.debug("loaded texture {s} ({d}x{d})", .{ path, img.width, img.height });
        return Texture.initRgba8(self.device, img.width, img.height, img.pixels);
    }

    /// Loads a WAV file and converts it to the device's format. `relative` is relative to the
    /// executable's folder, like `loadTexture`. It returns an error instead of panicking, because a
    /// missing sound shouldn't stop the game. The caller frees the sound with `Sound.deinit`.
    pub fn loadSound(self: *const Context, relative: []const u8) audio.Error!audio.Sound {
        var buf: [max_full_path]u8 = undefined;
        const path = std.fmt.bufPrintZ(&buf, "{s}{s}", .{ self.base_path, relative }) catch return error.LoadFailed;
        return self.audio.loadSound(path);
    }

    /// Reads a whole file. `relative` is relative to the executable's folder, like `loadTexture`.
    /// The caller owns the result and frees it with `std.heap.page_allocator`.
    pub fn readFile(self: *const Context, relative: []const u8) ![]u8 {
        var buf: [max_full_path]u8 = undefined;
        const path = std.fmt.bufPrintZ(&buf, "{s}{s}", .{ self.base_path, relative }) catch return error.PathTooLong;
        var size: usize = 0;
        const data = c.SDL_LoadFile(path.ptr, &size) orelse return error.FileNotFound;
        defer c.SDL_free(data);
        const bytes: [*]const u8 = @ptrCast(data);
        return std.heap.page_allocator.dupe(u8, bytes[0..size]);
    }
};

/// What the game needs to queue sprites for one frame.
pub const DrawContext = struct {
    /// Sprites are queued here. The engine uploads and draws them.
    batch: *SpriteBatch,
    /// The view camera. The game sets its world size, then calls `follow`.
    cam: *Camera,
    /// Native view size in pixels. The camera's view has this size.
    view_w: f32,
    view_h: f32,
    /// Blend factor between the last two updates. 0 is the previous update, and 1 is the latest.
    alpha: f32,
    /// Seconds since the previous frame, capped like the update loop's frame time. Smoothing that
    /// should not depend on the frame rate uses it.
    dt: f32,
};

/// Longest frame time the loop will use. A longer stall is cut short, so the game slows down
/// rather than racing to catch up.
const max_dt: f32 = 0.1;
/// How often the window title is refreshed, in seconds.
const title_interval: f32 = 0.5;
/// How long to sleep when there is nothing to draw, in milliseconds. A minimized window has no
/// pixels to draw into, so the loop idles instead of spinning. The sleep is short enough that a
/// restored window shows up within a frame, and SDL keeps queuing events while the loop sleeps.
const idle_sleep_ms: u32 = 16;
/// Longest full asset path the loader builds, in bytes. A longer path panics with a clear message.
const max_full_path = 1024;

const black = c.SDL_FColor{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 };

/// Opens the window and runs `Game` until it sets `running` to false or the window closes.
pub fn run(comptime Game: type, config: Config) void {
    logging.assert(config.update_hz > 0, @src(), "update rate must be positive, got {d}", .{config.update_hz});
    logging.assert(config.zoom_min > 0 and config.zoom_min <= 1.0 and config.zoom_max >= 1.0, @src(), "zoom bounds {d} to {d} must be positive and include 1", .{ config.zoom_min, config.zoom_max });
    const fixed_dt: f32 = 1.0 / @as(f32, @floatFromInt(config.update_hz));

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.debug.panic("SDL_Init failed: {s}", .{c.SDL_GetError()});
    }
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow(config.title.ptr, config.window_w, config.window_h, c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY) orelse {
        std.debug.panic("SDL_CreateWindow failed: {s}", .{c.SDL_GetError()});
    };
    defer c.SDL_DestroyWindow(window);
    elog.info("window {d}x{d}, native view {d}x{d}, {d} update steps per second", .{
        config.window_w, config.window_h, config.native_w, config.native_h, config.update_hz,
    });

    var gpu = Renderer.init(window, build_options.gpu_debug);
    defer gpu.deinit();

    const format = gpu.swapchainFormat();
    const gpu_debug_label: []const u8 = if (build_options.gpu_debug) "on" else "off";
    elog.info("GPU device ready, validation {s}, swapchain format {d}", .{ gpu_debug_label, format });

    const native_wf: f32 = @floatFromInt(config.native_w);
    const native_hf: f32 = @floatFromInt(config.native_h);
    const clear = c.SDL_FColor{
        .r = config.clear_rgb[0],
        .g = config.clear_rgb[1],
        .b = config.clear_rgb[2],
        .a = 1.0,
    };

    // The world is drawn into this target at the view's native size, then stretched to the window.
    // It's rebuilt whenever the view size changes.
    var target = Texture.initTarget(gpu.device, config.native_w, config.native_h, format);
    defer target.deinit();

    var world_batch = SpriteBatch.init(gpu.device, format);
    defer world_batch.deinit();
    var screen_batch = SpriteBatch.init(gpu.device, format);
    defer screen_batch.deinit();

    var input_state = Input.init();

    // Sound output. A missing device leaves it silent, so it never stops the game.
    var audio_out = Audio.init();
    defer audio_out.deinit();
    // The game sets the world size every frame, so the camera starts without one.
    var cam = Camera{ .view_w = native_wf, .view_h = native_hf, .world_w = 0, .world_h = 0 };

    // Find the executable's folder once. SDL3 owns the returned string, so it stays valid for the run.
    const base_c = c.SDL_GetBasePath();
    if (base_c == null) std.debug.panic("SDL_GetBasePath failed: {s}", .{c.SDL_GetError()});
    const base_path = std.mem.span(base_c);

    // Before the first frame is drawn, assume the view fills the window at its native size.
    var ctx = Context{
        .device = gpu.device,
        .input = &input_state,
        .scale_mode = config.scale_mode,
        .zoom_min = config.zoom_min,
        .zoom_max = config.zoom_max,
        .layout = .{ .dst_w = native_wf, .dst_h = native_hf, .view_w = native_wf, .view_h = native_hf },
        .camera = &cam,
        .base_path = base_path,
        .audio = &audio_out,
    };
    var game = Game.init(&ctx);
    defer game.deinit();
    var last_mode = ctx.scale_mode;

    var last_ns = c.SDL_GetTicksNS();
    var accumulator: f32 = 0;
    var title_timer: f32 = 0;
    var frames: u32 = 0;
    var total_frames: u64 = 0;
    var title_buf: [160:0]u8 = undefined;

    while (ctx.running) {
        // Frame timing: seconds since the last frame, capped at max_dt.
        const now_ns = c.SDL_GetTicksNS();
        const frame_dt = @min(@as(f32, @floatFromInt(now_ns - last_ns)) / 1_000_000_000.0, max_dt);
        last_ns = now_ns;

        // Events: quit requests, F11 fullscreen, and key and mouse state. Presses and clicks wait
        // in Input until an update step takes them.
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            if (event.type == c.SDL_EVENT_QUIT) {
                elog.info("quit requested by the window", .{});
                ctx.running = false;
            }
            if (event.type == c.SDL_EVENT_KEY_DOWN and event.key.key == c.SDLK_F11 and !event.key.repeat) {
                const fullscreen = (c.SDL_GetWindowFlags(window) & c.SDL_WINDOW_FULLSCREEN) != 0;
                _ = c.SDL_SetWindowFullscreen(window, !fullscreen);
            }
            input_state.handleEvent(&event);
        }

        // Fixed-timestep updates. Run whole steps while the accumulated time covers one, so game
        // logic advances at the same rate on any display. Stop early if the game quits.
        accumulator += frame_dt;
        var steps: u32 = 0;
        while (accumulator >= fixed_dt and ctx.running) {
            input_state.latch();
            ctx.dt = fixed_dt;
            game.update(&ctx);
            accumulator -= fixed_dt;
            steps += 1;
        }
        if (steps > 4) {
            elog.debug("{d} update steps in one frame, so the frame took {d:.1} ms", .{ steps, frame_dt * 1000.0 });
        }
        // Free finished voices and keep looping voices fed. Once per frame is enough, because a
        // looping voice queues a full copy of its sound ahead of time.
        audio_out.update();
        if (ctx.scale_mode != last_mode) {
            elog.info("scale mode: {s}", .{@tagName(ctx.scale_mode)});
            last_mode = ctx.scale_mode;
        }

        // The leftover time as a fraction of a step. Drawing blends between the last two updates by this amount.
        const alpha = @min(accumulator / fixed_dt, 1.0);
        logging.assert(alpha >= 0.0 and alpha <= 1.0, @src(), "blend factor {d} is outside 0 to 1", .{alpha});

        // Window size in pixels, which is also the swapchain size on high-DPI displays.
        var pw: c_int = 0;
        var ph: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(window, &pw, &ph);
        if (pw <= 0 or ph <= 0) {
            // Minimized: there is nothing to draw into, so sleep rather than spin. Events stay
            // queued in SDL until the next poll.
            c.SDL_Delay(idle_sleep_ms);
            continue;
        }
        const win_wf: f32 = @floatFromInt(pw);
        const win_hf: f32 = @floatFromInt(ph);

        // Ease the camera's zoom toward the zoom the game asked for. This runs before the view is
        // sized, so this frame is drawn at the zoom it has reached.
        cam.approachZoom(ctx.zoom_target, frame_dt, config.zoom_rate);

        // Choose the scale and the view size for this zoom. The fallback rules for integer mode live
        // in view.chooseFit.
        const fit = view.chooseFit(win_wf, win_hf, native_wf, native_hf, ctx.scale_mode, cam.zoom);
        const mode_label: []const u8 = if (fit.pixel_perfect) "integer" else "fit";
        const view_w = fit.view_w;
        const view_h = fit.view_h;
        const view_wf: f32 = @floatFromInt(view_w);
        const view_hf: f32 = @floatFromInt(view_h);
        logging.assert(view_w >= 1 and view_h >= 1, @src(), "view {d}x{d} is empty", .{ view_w, view_h });

        if (target.width != view_w or target.height != view_h) {
            // Wait first, because the old target may still be in use by the GPU.
            _ = c.SDL_WaitForGPUIdle(gpu.device);
            target.deinit();
            target = Texture.initTarget(gpu.device, view_w, view_h, format);
            elog.debug("native target is now {d}x{d} at {d:.2} scale ({s})", .{ view_w, view_h, fit.scale, mode_label });
        }

        cam.view_w = view_wf;
        cam.view_h = view_hf;

        // Acquire the frame after the layout is known.
        // A minimized window can report a nonzero size yet get no swapchain, so this path idles too.
        const frame = gpu.beginFrame() orelse {
            c.SDL_Delay(idle_sleep_ms);
            continue;
        };

        // Pass 1: the game queues its sprites, and they're drawn into the view-sized target.
        world_batch.begin(view_wf, view_hf);
        const draw_ctx = DrawContext{
            .batch = &world_batch,
            .cam = &cam,
            .view_w = view_wf,
            .view_h = view_hf,
            .alpha = alpha,
            .dt = frame_dt,
        };
        game.draw(&draw_ctx);
        world_batch.upload(frame.cmd);
        const world_pass = Renderer.beginPass(frame.cmd, target.texture, clear);
        world_batch.draw(world_pass);
        Renderer.endPass(world_pass);

        // Pass 2: stretch the target onto the window. Fit mode covers the whole window. Integer
        // mode covers a centered whole-number multiple of the view, and the edges stay black.
        var dst_rect = Rect{ .x = 0, .y = 0, .w = win_wf, .h = win_hf };
        if (fit.pixel_perfect) {
            const content_w = view_wf * fit.scale;
            const content_h = view_hf * fit.scale;
            dst_rect = Rect{
                .x = @floor((win_wf - content_w) / 2.0),
                .y = @floor((win_hf - content_h) / 2.0),
                .w = content_w,
                .h = content_h,
            };
        }
        // Record where the view landed, so the next update maps mouse positions with the same rectangle.
        ctx.layout = .{
            .pixel_density = c.SDL_GetWindowPixelDensity(window),
            .dst_x = dst_rect.x,
            .dst_y = dst_rect.y,
            .dst_w = dst_rect.w,
            .dst_h = dst_rect.h,
            .view_w = view_wf,
            .view_h = view_hf,
        };
        const view_rect = Rect{ .x = 0, .y = 0, .w = view_wf, .h = view_hf };
        screen_batch.begin(win_wf, win_hf);
        screen_batch.drawSprite(&target, view_rect, dst_rect, .{});
        screen_batch.upload(frame.cmd);
        const screen_pass = Renderer.beginPass(frame.cmd, frame.swapchain, black);
        screen_batch.draw(screen_pass);
        Renderer.endPass(screen_pass);

        Renderer.endFrame(frame);

        // Window title: FPS, sprite count, draw calls, scale, scale mode, zoom, and view size, refreshed a few times a second.
        frames += 1;
        total_frames += 1;
        title_timer += frame_dt;
        if (title_timer >= title_interval) {
            const fps = @as(f32, @floatFromInt(frames)) / title_timer;
            const title = std.fmt.bufPrintZ(&title_buf, "{s} | {d:.0} fps | {d} sprites | {d} draw calls | {d:.0}% {s} | zoom {d:.2}x | view {d}x{d}", .{
                config.title, fps, world_batch.sprite_count, world_batch.draw_calls + screen_batch.draw_calls, fit.scale * 100.0, mode_label, cam.zoom, view_w, view_h,
            }) catch null;
            if (title) |t| _ = c.SDL_SetWindowTitle(window, t.ptr);
            frames = 0;
            title_timer = 0;
        }
    }
    elog.info("main loop ended after {d} frames", .{total_frames});
}
