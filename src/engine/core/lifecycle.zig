//! Startup and shutdown of the engine's subsystems, in the order they depend on each other:
//! settings, SDL, the window, the GPU device, the native target and sprite batches, input, and audio.
//! `Session` owns all of them. It is built in place and never moved, because `Context` holds
//! pointers into it.

const std = @import("std");
const build_options = @import("build_options");
const c = @import("../platform/sdl/sdl.zig").c;
const platform = @import("../platform/platform.zig");
const audio = @import("../audio/audio.zig");
const logging = @import("../logging/log.zig");
const Input = @import("../input/input.zig").Input;
const Camera = @import("../renderer/camera.zig").Camera;
const SpriteBatch = @import("../renderer/sprite.zig").SpriteBatch;
const Texture = @import("../renderer/texture.zig").Texture;
const settings = @import("settings.zig");
const application = @import("application.zig");
const context = @import("context.zig");

const Config = application.Config;
const Context = context.Context;
const max_full_path = context.max_full_path;
const elog = logging.scoped("engine");

/// Everything the running engine owns. `start` opens it and `stop` releases it.
pub const Session = struct {
    /// Directory of the executable, with a trailing separator.
    base_path: []const u8,
    /// Text of the settings file. It is kept for the whole run, because the game reads from it.
    settings_bytes: ?[]u8 = null,
    window: *c.SDL_Window = undefined,
    gpu: platform.gpu.Gpu = undefined,
    /// The swapchain format. Targets and pipelines use it so they can be drawn into the window.
    format: c.SDL_GPUTextureFormat = undefined,
    /// The world target, sized to the view. The runtime rebuilds it when the view changes.
    target: Texture = undefined,
    world_batch: SpriteBatch = undefined,
    screen_batch: SpriteBatch = undefined,
    input: Input = .{},
    audio: audio.Audio = undefined,
    cam: Camera = undefined,
    ctx: Context = undefined,

    /// Opens everything, in dependency order. Panics on failures that leave the game unable to run.
    pub fn start(self: *Session, config: Config) void {
        self.settings_bytes = readSettings(self.base_path, config.settings_file);
        const settings_text: []const u8 = self.settings_bytes orelse "";
        const window_settings = loadWindowSettings(settings_text, .{
            .width = config.window_w,
            .height = config.window_h,
            .fullscreen = config.fullscreen,
            .vsync = config.vsync,
        });

        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
            std.debug.panic("SDL_Init failed: {s}", .{c.SDL_GetError()});
        }
        self.window = platform.window.create(config.title, window_settings.width, window_settings.height, window_settings.fullscreen);
        elog.info("window {d}x{d}, native view {d}x{d}, {d} update steps per second", .{
            window_settings.width, window_settings.height, config.native_w, config.native_h, config.update_hz,
        });

        self.gpu = platform.gpu.Gpu.init(self.window, build_options.gpu_debug);
        if (!self.gpu.setVsync(window_settings.vsync)) elog.warn("immediate present is not available on this display, so vsync stays on", .{});
        const vsync_label: []const u8 = if (window_settings.vsync) "on" else "off";
        elog.info("vsync {s}", .{vsync_label});

        self.format = self.gpu.swapchainFormat();
        const gpu_debug_label: []const u8 = if (build_options.gpu_debug) "on" else "off";
        elog.info("GPU device ready, validation {s}, swapchain format {d}", .{ gpu_debug_label, self.format });

        const native_wf: f32 = @floatFromInt(config.native_w);
        const native_hf: f32 = @floatFromInt(config.native_h);
        self.target = Texture.initTarget(self.gpu.device, config.native_w, config.native_h, self.format);
        self.world_batch = SpriteBatch.init(self.gpu.device, self.format);
        self.screen_batch = SpriteBatch.init(self.gpu.device, self.format);
        // Sound output. A missing device leaves it silent, so it never stops the game.
        self.audio = audio.Audio.init();
        // The game sets the world size every frame, so the camera starts without one.
        self.cam = Camera{ .view_w = native_wf, .view_h = native_hf, .world_w = 0, .world_h = 0 };
        // Before the first frame is drawn, assume the view fills the window at its native size.
        self.ctx = Context{
            .device = self.gpu.device,
            .input = &self.input,
            .scale_mode = config.scale_mode,
            .zoom_min = config.zoom_min,
            .zoom_max = config.zoom_max,
            .layout = .{ .dst_w = native_wf, .dst_h = native_hf, .view_w = native_wf, .view_h = native_hf },
            .camera = &self.cam,
            .base_path = self.base_path,
            .audio = &self.audio,
            .settings_text = settings_text,
        };
    }

    /// Releases everything `start` opened, in reverse order. The game must be released first.
    pub fn stop(self: *Session) void {
        self.audio.deinit();
        self.screen_batch.deinit();
        self.world_batch.deinit();
        self.target.deinit();
        // The device must go before the window, because it is still claimed for that window.
        self.gpu.deinit();
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
        if (self.settings_bytes) |bytes| std.heap.page_allocator.free(bytes);
    }
};

/// Opens the log file beside the executable when the game asks for one. Each run replaces the
/// file from the last run. Startup messages and startup failures are kept, so this runs first.
pub fn openLog(config: Config, base_path: []const u8) void {
    if (config.log_file) |name| {
        var path_buf: [max_full_path]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "{s}{s}", .{ base_path, name }) catch {
            std.debug.panic("log file path is longer than {d} bytes", .{max_full_path});
        };
        if (logging.openFile(path)) {
            elog.info("log file {s}", .{path});
        } else {
            elog.warn("could not open log file {s}, so logs go to the terminal only", .{path});
        }
    }
}

/// Reads the settings file in the executable's folder. Returns null when there is no file. The
/// caller frees the result with `std.heap.page_allocator`.
fn readSettings(base_path: []const u8, name: []const u8) ?[]u8 {
    var buf: [max_full_path]u8 = undefined;
    const path = std.fmt.bufPrintZ(&buf, "{s}{s}", .{ base_path, name }) catch {
        elog.warn("settings file name '{s}' is too long, so the defaults are used", .{name});
        return null;
    };
    var size: usize = 0;
    const data = c.SDL_LoadFile(path.ptr, &size) orelse {
        elog.info("no settings file at {s}, so the defaults are used", .{path});
        return null;
    };
    defer c.SDL_free(data);
    elog.info("settings file {s}", .{path});
    const bytes: [*]const u8 = @ptrCast(data);
    return std.heap.page_allocator.dupe(u8, bytes[0..size]) catch null;
}

/// Reads the window settings over `defaults`. A value that can't be read is logged, and its default is kept.
fn loadWindowSettings(text: []const u8, defaults: settings.Window) settings.Window {
    var window = defaults;
    var lines = settings.Lines.init(text);
    while (lines.next()) |line| {
        const value = line.value orelse continue;
        if (settings.applyWindowLine(&window, line.key, value) == .bad_value) {
            elog.warn("settings line {d}: '{s}' has a value that isn't valid, so the default is used", .{ line.number, line.key });
        }
    }
    return window;
}

