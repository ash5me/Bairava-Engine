//! Engine startup configuration passed to `run`: allocation, window, reference view, fixed timing,
//! engine presentation defaults, debug output, and engine settings-file paths.
//!
//! Gameplay tuning and content paths remain in the game layer. Values here may have safe engine
//! defaults; a game supplies explicit values only for presentation or behavior it owns.

const std = @import("std");
const view = @import("../renderer/view.zig");
const render_types = @import("../renderer/render_types.zig");
const ScaleMode = view.ScaleMode;

/// Rendering implementation used by the engine. SDL_GPU is the feature-complete default;
/// SDL2D can be selected at startup or switched at runtime with the configured hotkey.
pub const Renderer = enum { sdl_gpu, sdl2d };

/// Settings the game passes to `run`.
pub const Config = struct {
    /// Parent allocator for all memory owned during this run. The runtime creates narrower
    /// engine, game, asset, and frame arenas from it. Defaults to the process page allocator.
    allocator: std.mem.Allocator = std.heap.page_allocator,
    /// Window title.
    title: [:0]const u8 = "Bairava",
    window_w: c_int = 1280,
    window_h: c_int = 720,
    /// The reference view size, in native pixels. At zoom 1 the view fits the window on its
    /// limiting axis, so the view is exactly this size on that axis. The other axis shows more of
    /// the world when the window's shape differs.
    native_w: u32 = 320,
    native_h: u32 = 180,
    /// Background color behind the world, as RGB from 0 to 1.
    clear_rgb: [3]f32 = .{ 0.1, 0.1, 0.1 },
    /// Game `update` steps per second.
    update_hz: u32 = 60,
    /// Scale mode at startup. The game can change it later through `Context`.
    scale_mode: ScaleMode = .fit,
    /// Active renderer at startup. The engine recreates presentation state when switching
    /// between backends; game draw code remains backend-independent.
    renderer: Renderer = .sdl_gpu,
    /// Smallest and largest zoom the game may ask for. 1 is the normal view, so the bounds must
    /// include it. Below 1 the view shows more of the world, and above 1 it shows less, larger.
    zoom_min: f32 = 0.5,
    zoom_max: f32 = 4.0,
    /// How fast the camera eases to a new zoom, per second. Zero snaps.
    zoom_rate: f32 = 8.0,
    /// Font for the debug overlay: a prebaked `.bfnt` file relative to the executable's folder, baked at exactly
    /// `debug_font_px`. A missing or mismatched file turns the overlay off.
    debug_font_path: []const u8 = "assets/default_font_10px.bfnt",
    debug_font_px: f32 = 10.0,
    /// Name of the log file, written beside the executable. Each run replaces the file from the
    /// last run. Null logs to the terminal only.
    log_file: ?[:0]const u8 = null,
    /// Name of the crash report, written beside the executable when the game panics. Each run clears the report
    /// from the last run. Null writes no report; the log still records the panic.
    crash_file: ?[:0]const u8 = null,
    /// Settings file, beside the executable. Its window settings override `window_w`, `window_h`,
    /// `fullscreen`, and `vsync`. A missing file keeps these values.
    settings_file: []const u8 = "settings.txt",
    /// Start full screen, unless the settings file says otherwise.
    fullscreen: bool = false,
    /// Wait for vsync, unless the settings file says otherwise.
    vsync: bool = true,
    /// Post-processing effects, run in order over the finished world before it is shown. Empty by default, which
    /// presents the world unchanged. A chain holds at most `render_types.max_post_effects` effects.
    post_effects: []const render_types.Effect = &.{},
    /// Strengths the post-processing effects use, each from 0 to 1. The defaults keep the effects' original look.
    post_params: render_types.PostParams = render_types.default_post_params,
    /// Most bytes the texture cache may hold, counted at four bytes per texel. Idle textures are unloaded, least
    /// recently used first, to stay within it. Zero means no budget.
    texture_budget_bytes: usize = 0,
    /// Most decoded/compressed texture payload bytes held while background decodes await upload. Zero removes the cap.
    /// Files that exceed the whole budget fail; loads deferred because other textures currently use the budget retry.
    texture_staging_budget_bytes: usize = 128 * 1024 * 1024,
    /// Requested textures the runtime loads each frame, between frames. Zero turns preloading off.
    texture_loads_per_frame: usize = 2,
    /// Measures the GPU's share of each frame by waiting for the GPU to finish it. Development builds only. The wait
    /// stalls the CPU every frame, so frame times in this mode add the CPU and GPU work together. That makes them a
    /// cost, not a rate to play at. The result is the `gpu` phase, shown on the overlay and in Tracy.
    gpu_timing: bool = false,
    /// Worker threads for background work, such as decoding requested textures before they are needed. Zero runs that
    /// work on the main thread instead, which is deterministic. With workers, `allocator` must be safe to use from several
    /// threads. The page allocator, the default, is.
    worker_threads: u32 = 2,
    /// The most worker threads a config may ask for.
    pub const max_worker_threads: u32 = 32;

    pub const ValidationError = error{
        EmptyTitle,
        EmptySettingsFile,
        InvalidWindowSize,
        InvalidNativeViewSize,
        InvalidClearColor,
        InvalidUpdateRate,
        TooManyWorkerThreads,
        InvalidZoomBounds,
        InvalidZoomRate,
        InvalidDebugFont,
        TooManyPostEffects,
        InvalidPostParams,
    };

    /// Validates all engine-owned startup values before any platform resource is created.
    /// Game code and the runtime call this first so configuration failures are error values,
    /// not assertions or crashes from backend initialization.
    pub fn validate(self: Config) ValidationError!void {
        if (self.title.len == 0) return error.EmptyTitle;
        if (self.settings_file.len == 0) return error.EmptySettingsFile;
        if (self.window_w < 64 or self.window_w > 8192 or
            self.window_h < 64 or self.window_h > 8192)
            return error.InvalidWindowSize;
        if (self.native_w == 0 or self.native_h == 0)
            return error.InvalidNativeViewSize;
        for (self.clear_rgb) |channel| {
            if (!std.math.isFinite(channel) or channel < 0.0 or channel > 1.0)
                return error.InvalidClearColor;
        }
        if (self.update_hz == 0) return error.InvalidUpdateRate;
        if (self.worker_threads > max_worker_threads) return error.TooManyWorkerThreads;
        if (!std.math.isFinite(self.zoom_min) or !std.math.isFinite(self.zoom_max) or
            self.zoom_min <= 0.0 or self.zoom_min > 1.0 or self.zoom_max < 1.0)
            return error.InvalidZoomBounds;
        if (!std.math.isFinite(self.zoom_rate) or self.zoom_rate < 0.0)
            return error.InvalidZoomRate;
        if (self.debug_font_path.len == 0 or
            !std.math.isFinite(self.debug_font_px) or self.debug_font_px <= 0.0)
            return error.InvalidDebugFont;
        if (self.post_effects.len > render_types.max_post_effects) return error.TooManyPostEffects;
        for ([_]f32{ self.post_params.vignette, self.post_params.scanline_dim, self.post_params.grayscale }) |value| {
            if (!std.math.isFinite(value) or value < 0.0 or value > 1.0) return error.InvalidPostParams;
        }
    }

    pub fn validationMessage(err: ValidationError) []const u8 {
        return switch (err) {
            error.EmptyTitle => "engine config title must not be empty",
            error.EmptySettingsFile => "engine config settings_file must not be empty",
            error.InvalidWindowSize => "engine config window_w and window_h must be between 64 and 8192 pixels",
            error.InvalidNativeViewSize => "engine config native_w and native_h must be greater than zero",
            error.InvalidClearColor => "engine config clear_rgb channels must be finite numbers between 0 and 1",
            error.InvalidUpdateRate => "engine config update_hz must be greater than zero",
            error.TooManyWorkerThreads => "engine config worker_threads must be at most 32",
            error.InvalidZoomBounds => "engine config zoom bounds must be finite, positive, and include zoom 1",
            error.InvalidZoomRate => "engine config zoom_rate must be a finite non-negative number",
            error.InvalidDebugFont => "engine config debug font path must not be empty and debug font px must be positive",
            error.TooManyPostEffects => "engine config post_effects holds more effects than one chain allows",
            error.InvalidPostParams => "engine config post_params values must be finite numbers from 0 to 1",
        };
    }
};

test "Config defaults are valid and can start a minimal consumer" {
    const config = Config{};
    try config.validate();
}

test "Config validation rejects invalid startup values" {
    const window = Config{ .window_w = 0 };
    try std.testing.expectError(error.InvalidWindowSize, window.validate());

    const native = Config{ .native_h = 0 };
    try std.testing.expectError(error.InvalidNativeViewSize, native.validate());

    const rate = Config{ .update_hz = 0 };
    try std.testing.expectError(error.InvalidUpdateRate, rate.validate());

    const bounds = Config{ .zoom_min = 2.0 };
    try std.testing.expectError(error.InvalidZoomBounds, bounds.validate());

    const clear = Config{ .clear_rgb = .{ 0.0, 1.1, 0.0 } };
    try std.testing.expectError(error.InvalidClearColor, clear.validate());
}

test "Config validation rejects a post-processing chain longer than one chain allows" {
    const too_many = [_]render_types.Effect{.grayscale} ** (render_types.max_post_effects + 1);
    const config = Config{ .post_effects = &too_many };
    try std.testing.expectError(error.TooManyPostEffects, config.validate());
}

test "Config validation rejects post settings outside 0 to 1, and values that are not numbers" {
    const too_strong = Config{ .post_params = .{ .vignette = 1.5, .scanline_dim = 0.8, .grayscale = 1, .padding = 0 } };
    try std.testing.expectError(error.InvalidPostParams, too_strong.validate());
    const not_a_number = Config{ .post_params = .{ .vignette = 0.25, .scanline_dim = std.math.nan(f32), .grayscale = 1, .padding = 0 } };
    try std.testing.expectError(error.InvalidPostParams, not_a_number.validate());
}

test "Config validation rejects more worker threads than the engine allows" {
    const too_many = Config{ .worker_threads = Config.max_worker_threads + 1 };
    try std.testing.expectError(error.TooManyWorkerThreads, too_many.validate());
    const none = Config{ .worker_threads = 0 };
    try none.validate();
}
