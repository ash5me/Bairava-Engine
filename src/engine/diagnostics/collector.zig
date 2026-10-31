//! What the engine publishes about the running frame, and the switches that control what is shown.
//! The runtime fills a `Snapshot` each frame from the systems it owns, the game adds its own lines
//! to `text` and its debug shapes to `debug`, and the overlay reads all of it. An overlay never
//! reaches into a subsystem's private state: it reads only what was published here.

const std = @import("std");
const frame_stats = @import("frame_stats.zig");
const text = @import("text.zig");
const debug_draw = @import("debug_draw.zig");

pub const Text = text.Text;
pub const Draw = debug_draw.Draw;
pub const Color = debug_draw.Color;

/// Which debug geometry is drawn. F4 turns all of them on or off together, and the console sets each
/// one on its own.
pub const Geometry = struct {
    /// Solid tiles and the box the player collides with.
    collision: bool = false,
    /// The grid of tile boundaries.
    tiles: bool = false,
    /// The world's edges, as the camera sees them.
    camera: bool = false,
    /// Positions of entities, where a game draws them.
    entities: bool = false,

    /// True when any kind of geometry is on.
    pub fn any(self: Geometry) bool {
        return self.collision or self.tiles or self.camera or self.entities;
    }

    /// Turns every kind on, or every kind off.
    pub fn setAll(self: *Geometry, on: bool) void {
        self.collision = on;
        self.tiles = on;
        self.camera = on;
        self.entities = on;
    }
};

/// Which game-owned tile layers are currently visible. These are inspection controls, not geometry.
pub const Layers = struct {
    ground: bool = true,
    decoration: bool = true,
    foreground: bool = true,
};

/// The active scene and whether a switch is waiting, from the scene host.
pub const Scene = struct {
    name: []const u8 = "none",
    /// The name of the scene a switch will open at the next safe point, or null when none is pending.
    pending: ?[]const u8 = null,
    /// Scenes opened so far, counting the first.
    switches: u32 = 0,
};

/// Asset counters, from the texture store.
pub const Assets = struct {
    loaded: usize = 0,
    hits: u64 = 0,
    misses: u64 = 0,
    failed: u64 = 0,
    /// Estimated bytes of the loaded textures. See `Loader.size` in assets/cache.zig.
    bytes: usize = 0,
};

/// Input state, from the input module.
pub const Input = struct {
    held: u32 = 0,
    pressed: u32 = 0,
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
};

/// What the world drew, and how the view is laid out.
pub const World = struct {
    /// Sprites queued this frame, before the overlay adds its own.
    sprites: u32 = 0,
    /// Draw calls made in the last frame. This frame's are not known until its batches are drawn.
    draw_calls: u32 = 0,
    /// Entities in the current world, when the game publishes the count.
    entities: u32 = 0,
    /// Collision-query calls since startup, when the game publishes the count.
    collision_queries: u64 = 0,
    zoom: f32 = 1,
    cam_x: f32 = 0,
    cam_y: f32 = 0,
    view_w: u32 = 0,
    view_h: u32 = 0,
    /// "fit" or "integer", and the window pixels per view pixel.
    mode: []const u8 = "fit",
    scale: f32 = 1,
    map_cols: u32 = 0,
    map_rows: u32 = 0,
    selected_col: i32 = -1,
    selected_row: i32 = -1,
    selected_tile: ?u8 = null,
    selected_solid: bool = false,
};

pub const Snapshot = struct {
    scene: Scene = .{},
    assets: Assets = .{},
    input: Input = .{},
    world: World = .{},
    /// Loop iterations since the run started.
    frames: u64 = 0,
};

/// The overlay's state. The runtime owns one, and the session keeps it for the run.
pub const Collector = struct {
    stats: frame_stats.Stats = .{},
    snapshot: Snapshot = .{},
    /// Lines the game adds each frame through its `debugText`.
    text: Text = .{},
    /// Debug shapes for this frame, in view pixels.
    debug: Draw = .{},
    geometry: Geometry = .{},
    layers: Layers = .{},

    /// Turns all debug geometry on, or all of it off when any is on.
    pub fn toggleGeometry(self: *Collector) void {
        self.geometry.setAll(!self.geometry.any());
    }
};

test "geometry toggles on and off as a whole" {
    var geometry = Geometry{};
    try std.testing.expect(!geometry.any());
    geometry.setAll(true);
    try std.testing.expect(geometry.collision and geometry.tiles and geometry.camera and geometry.entities);
    geometry.setAll(false);
    try std.testing.expect(!geometry.any());
}

test "a collector toggles all geometry with one call" {
    var collector = Collector{};
    collector.toggleGeometry();
    try std.testing.expect(collector.geometry.any());
    collector.toggleGeometry();
    try std.testing.expect(!collector.geometry.any());
}
