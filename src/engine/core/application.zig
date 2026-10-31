<<<<<<< HEAD
//! Engine startup configuration passed to `run`: allocation, window, reference view, fixed timing,
//! engine presentation defaults, debug output, and engine settings-file paths.
//!
//! Gameplay tuning and content paths remain in the game layer. Values here may have safe engine
//! defaults; a game supplies explicit values only for presentation or behavior it owns.

const std = @import("std");
=======
//! What the game passes to `run` at startup: the window, the native view, the timing, the zoom
//! limits, and the files the engine reads.

>>>>>>> main
const view = @import("../renderer/view.zig");
const ScaleMode = view.ScaleMode;

/// Settings the game passes to `run`.
pub const Config = struct {
<<<<<<< HEAD
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
=======
    /// Window title.
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
>>>>>>> main
    /// Scale mode at startup. The game can change it later through `Context`.
    scale_mode: ScaleMode = .fit,
    /// Smallest and largest zoom the game may ask for. 1 is the normal view, so the bounds must
    /// include it. Below 1 the view shows more of the world, and above 1 it shows less, larger.
<<<<<<< HEAD
    zoom_min: f32 = 0.5,
    zoom_max: f32 = 4.0,
    /// How fast the camera eases to a new zoom, per second. Zero snaps.
    zoom_rate: f32 = 8.0,
    /// Font for the debug overlay: a TrueType file relative to the executable's folder, and its
    /// height in native pixels.
    debug_font_path: []const u8 = "assets/font.ttf",
    debug_font_px: f32 = 10.0,
=======
    zoom_min: f32,
    zoom_max: f32,
    /// How fast the camera eases to a new zoom, per second. Zero snaps.
    zoom_rate: f32,
    /// Font for the debug overlay: a TrueType file relative to the executable's folder, and its
    /// height in native pixels.
    debug_font_path: []const u8,
    debug_font_px: f32,
>>>>>>> main
    /// Name of the log file, written beside the executable. Each run replaces the file from the
    /// last run. Null logs to the terminal only.
    log_file: ?[:0]const u8 = null,
    /// Settings file, beside the executable. Its window settings override `window_w`, `window_h`,
    /// `fullscreen`, and `vsync`. A missing file keeps these values.
    settings_file: []const u8 = "settings.txt",
    /// Start full screen, unless the settings file says otherwise.
    fullscreen: bool = false,
    /// Wait for vsync, unless the settings file says otherwise.
    vsync: bool = true,
<<<<<<< HEAD

    pub const ValidationError = error{
        EmptyTitle,
        EmptySettingsFile,
        InvalidWindowSize,
        InvalidNativeViewSize,
        InvalidClearColor,
        InvalidUpdateRate,
        InvalidZoomBounds,
        InvalidZoomRate,
        InvalidDebugFont,
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
        if (!std.math.isFinite(self.zoom_min) or !std.math.isFinite(self.zoom_max) or
            self.zoom_min <= 0.0 or self.zoom_min > 1.0 or self.zoom_max < 1.0)
            return error.InvalidZoomBounds;
        if (!std.math.isFinite(self.zoom_rate) or self.zoom_rate < 0.0)
            return error.InvalidZoomRate;
        if (self.debug_font_path.len == 0 or
            !std.math.isFinite(self.debug_font_px) or self.debug_font_px <= 0.0)
            return error.InvalidDebugFont;
    }

    pub fn validationMessage(err: ValidationError) []const u8 {
        return switch (err) {
            error.EmptyTitle => "engine config title must not be empty",
            error.EmptySettingsFile => "engine config settings_file must not be empty",
            error.InvalidWindowSize => "engine config window_w and window_h must be between 64 and 8192 pixels",
            error.InvalidNativeViewSize => "engine config native_w and native_h must be greater than zero",
            error.InvalidClearColor => "engine config clear_rgb channels must be finite numbers between 0 and 1",
            error.InvalidUpdateRate => "engine config update_hz must be greater than zero",
            error.InvalidZoomBounds => "engine config zoom bounds must be finite, positive, and include zoom 1",
            error.InvalidZoomRate => "engine config zoom_rate must be a finite non-negative number",
            error.InvalidDebugFont => "engine config debug font path must not be empty and debug font px must be positive",
        };
    }
};

test "Config defaults are valid and can start a minimal consumer" {
    const config = Config{};
    try config.validate();
}

test "Config validation rejects invalid startup values" {
    var window = Config{ .window_w = 0 };
    try std.testing.expectError(error.InvalidWindowSize, window.validate());

    var native = Config{ .native_h = 0 };
    try std.testing.expectError(error.InvalidNativeViewSize, native.validate());

    var rate = Config{ .update_hz = 0 };
    try std.testing.expectError(error.InvalidUpdateRate, rate.validate());

    var bounds = Config{ .zoom_min = 2.0 };
    try std.testing.expectError(error.InvalidZoomBounds, bounds.validate());

    var clear = Config{ .clear_rgb = .{ 0.0, 1.1, 0.0 } };
    try std.testing.expectError(error.InvalidClearColor, clear.validate());
}
=======
};
>>>>>>> main
