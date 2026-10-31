//! What the game passes to `run` at startup: the window, the native view, the timing, the zoom
//! limits, and the files the engine reads.

const view = @import("../renderer/view.zig");
const ScaleMode = view.ScaleMode;

/// Settings the game passes to `run`.
pub const Config = struct {
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
    /// Scale mode at startup. The game can change it later through `Context`.
    scale_mode: ScaleMode = .fit,
    /// Smallest and largest zoom the game may ask for. 1 is the normal view, so the bounds must
    /// include it. Below 1 the view shows more of the world, and above 1 it shows less, larger.
    zoom_min: f32,
    zoom_max: f32,
    /// How fast the camera eases to a new zoom, per second. Zero snaps.
    zoom_rate: f32,
    /// Font for the debug overlay: a TrueType file relative to the executable's folder, and its
    /// height in native pixels.
    debug_font_path: []const u8,
    debug_font_px: f32,
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
};
