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
const logging = @import("log.zig");
const Renderer = @import("renderer.zig").Renderer;

const elog = logging.scoped("engine");

pub const Camera = @import("camera.zig").Camera;
pub const Input = @import("input.zig").Input;
pub const Key = @import("input.zig").Key;
pub const Rect = @import("sprite.zig").Rect;
pub const SpriteBatch = @import("sprite.zig").SpriteBatch;
pub const Texture = @import("texture.zig").Texture;
/// Vector and matrix math, backed by cglm.
pub const math = @import("math.zig");
/// Validated fixed-capacity strings for names and paths.
pub const strings = @import("string.zig");
/// Hash map keyed by validated names.
pub const hash_map = @import("hash_map.zig");
/// Asset names, ids, and validated paths.
pub const assets = @import("assets.zig");
/// Logging and assertions. Game code uses `engine.log.scoped("name")` and `engine.log.assert`.
pub const log = logging;

/// How the native view is fitted to the window.
pub const ScaleMode = enum {
    /// Fill the window exactly. The view grows or shrinks with the window, and some native
    /// pixels cover one more screen pixel than others.
    fit,
    /// Use a whole-number multiple of the view, so every native pixel is the same size. The
    /// result is centered, and any leftover edge pixels are black.
    integer,
};

/// Settings the game passes to `run`.
pub const Config = struct {
    /// Window title. Play stats are appended to it.
    title: [:0]const u8,
    window_w: c_int,
    window_h: c_int,
    /// The smallest view the game is designed for, in native pixels. Larger windows show
    /// more of the world instead of bigger pixels.
    native_w: u32,
    native_h: u32,
    /// Background color behind the world, as RGB from 0 to 1.
    clear_rgb: [3]f32,
    /// Game `update` steps per second.
    update_hz: u32,
    /// Scale mode at startup. The game can change it later through `Context`.
    scale_mode: ScaleMode = .fit,
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

    /// Loads an image and uploads it as a texture. Panics if the file is missing or can't be
    /// decoded. Paths are relative to the working directory.
    pub fn loadTexture(self: *const Context, path: [*:0]const u8) Texture {
        var img = image.loadRgba8(path) catch |err| {
            std.debug.panic("failed to load {s}: {s}", .{ path, @errorName(err) });
        };
        defer img.deinit();
        elog.debug("loaded texture {s} ({d}x{d})", .{ path, img.width, img.height });
        return Texture.initRgba8(self.device, img.width, img.height, img.pixels);
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
};

/// Longest frame time the loop will use. A longer stall is cut short, so the game slows down
/// rather than racing to catch up.
const max_dt: f32 = 0.1;
/// How often the window title is refreshed, in seconds.
const title_interval: f32 = 0.5;

const white = [3]f32{ 1.0, 1.0, 1.0 };
const black = c.SDL_FColor{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 };

/// The scale at which the native view fits the window on its limiting axis.
fn fitScale(win_w: f32, win_h: f32, native_w: f32, native_h: f32) f32 {
    return @min(win_w / native_w, win_h / native_h);
}

/// Opens the window and runs `Game` until it sets `running` to false or the window closes.
pub fn run(comptime Game: type, config: Config) void {
    logging.assert(config.update_hz > 0, @src(), "update rate must be positive, got {d}", .{config.update_hz});
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
    // The game sets the world size every frame, so the camera starts without one.
    var cam = Camera{ .view_w = native_wf, .view_h = native_hf, .world_w = 0, .world_h = 0 };

    var ctx = Context{ .device = gpu.device, .input = &input_state, .scale_mode = config.scale_mode };
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
        if (pw <= 0 or ph <= 0) continue;
        const win_wf: f32 = @floatFromInt(pw);
        const win_hf: f32 = @floatFromInt(ph);

        // Choose the scale. Integer mode needs the window to hold at least one native view, so the
        // view never shrinks below its native size. Smaller windows fall back to fit.
        const fit = fitScale(win_wf, win_hf, native_wf, native_hf);
        const pixel_perfect = ctx.scale_mode == .integer and fit >= 1.0;
        const scale: f32 = if (pixel_perfect) @floor(fit) else fit;
        const mode_label: []const u8 = if (pixel_perfect) "integer" else "fit";

        // The view is the part of the world the window shows. The 0.01 keeps float rounding
        // from dropping a whole native pixel.
        const view_w: u32 = @intFromFloat(@floor(win_wf / scale + 0.01));
        const view_h: u32 = @intFromFloat(@floor(win_hf / scale + 0.01));
        const view_wf: f32 = @floatFromInt(view_w);
        const view_hf: f32 = @floatFromInt(view_h);
        logging.assert(view_w >= config.native_w and view_h >= config.native_h, @src(), "view {d}x{d} is smaller than the native view {d}x{d}", .{
            view_w, view_h, config.native_w, config.native_h,
        });

        if (target.width != view_w or target.height != view_h) {
            // Wait first, because the old target may still be in use by the GPU.
            _ = c.SDL_WaitForGPUIdle(gpu.device);
            target.deinit();
            target = Texture.initTarget(gpu.device, view_w, view_h, format);
            elog.debug("native target is now {d}x{d} at {d:.2} scale ({s})", .{ view_w, view_h, scale, mode_label });
        }

        cam.view_w = view_wf;
        cam.view_h = view_hf;

        // Acquire the frame after the layout is known.
        const frame = gpu.beginFrame() orelse continue;

        // Pass 1: the game queues its sprites, and they're drawn into the view-sized target.
        world_batch.begin(view_wf, view_hf);
        const draw_ctx = DrawContext{
            .batch = &world_batch,
            .cam = &cam,
            .view_w = view_wf,
            .view_h = view_hf,
            .alpha = alpha,
        };
        game.draw(&draw_ctx);
        world_batch.upload(frame.cmd);
        const world_pass = Renderer.beginPass(frame.cmd, target.texture, clear);
        world_batch.draw(world_pass);
        Renderer.endPass(world_pass);

        // Pass 2: stretch the target onto the window. Fit mode covers the whole window. Integer
        // mode covers a centered whole-number multiple of the view, and the edges stay black.
        var dst_rect = Rect{ .x = 0, .y = 0, .w = win_wf, .h = win_hf };
        if (pixel_perfect) {
            const content_w = view_wf * scale;
            const content_h = view_hf * scale;
            dst_rect = Rect{
                .x = @floor((win_wf - content_w) / 2.0),
                .y = @floor((win_hf - content_h) / 2.0),
                .w = content_w,
                .h = content_h,
            };
        }
        const view_rect = Rect{ .x = 0, .y = 0, .w = view_wf, .h = view_hf };
        screen_batch.begin(win_wf, win_hf);
        screen_batch.drawSprite(&target, view_rect, dst_rect, white);
        screen_batch.upload(frame.cmd);
        const screen_pass = Renderer.beginPass(frame.cmd, frame.swapchain, black);
        screen_batch.draw(screen_pass);
        Renderer.endPass(screen_pass);

        Renderer.endFrame(frame);

        // Window title: FPS, sprite count, draw calls, scale, scale mode, and view size, refreshed a few times a second.
        frames += 1;
        total_frames += 1;
        title_timer += frame_dt;
        if (title_timer >= title_interval) {
            const fps = @as(f32, @floatFromInt(frames)) / title_timer;
            const title = std.fmt.bufPrintZ(&title_buf, "{s} | {d:.0} fps | {d} sprites | {d} draw calls | {d:.0}% {s} | view {d}x{d}", .{
                config.title, fps, world_batch.sprite_count, world_batch.draw_calls + screen_batch.draw_calls, scale * 100.0, mode_label, view_w, view_h,
            }) catch null;
            if (title) |t| _ = c.SDL_SetWindowTitle(window, t.ptr);
            frames = 0;
            title_timer = 0;
        }
    }
    elog.info("main loop ended after {d} frames", .{total_frames});
}
