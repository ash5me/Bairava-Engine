//! What the engine publishes about the running frame, and the switches that control what is shown.
//! The runtime fills a `Snapshot` each frame from the systems it owns, the game adds its own lines
//! to `text` and its debug shapes to `debug`, and the overlay reads all of it. An overlay never
//! reaches into a subsystem's private state: it reads only what was published here.

const std = @import("std");
const frame_stats = @import("frame_stats.zig");
const plot_series = @import("plots.zig");
const spike_log = @import("spike_log.zig");
const text = @import("text.zig");
const debug_draw = @import("debug_draw.zig");
const allocator_types = @import("../core/allocators.zig");

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
    /// What the change waiting for the next safe point does: a scene's name for a switch, `push <name>`, or
    /// `pop`. Null when none is pending.
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

/// Requested allocations measured at each arena-facing allocator. High-water marks are lifetime
/// peaks; frame live counts reset with the frame arena.
pub const Memory = allocator_types.Stats;

/// A short list of names, such as the held keys or the actions they resolve to. The names are kept
/// as one joined line, so the overlay and the console can show them without allocating. A name that
/// does not fit is counted in `omitted` instead, so a full list is visible rather than silent.
pub const NameList = struct {
    /// Bytes kept for the joined text, names and their separators.
    pub const capacity = 72;

    bytes: [capacity]u8 = undefined,
    len: usize = 0,
    /// Names kept.
    count: usize = 0,
    /// Names that did not fit.
    omitted: u32 = 0,

    pub fn add(self: *NameList, name: []const u8) void {
        const separator: usize = if (self.count == 0) 0 else 2;
        if (self.len + separator + name.len > capacity) {
            self.omitted += 1;
            return;
        }
        if (separator == 2) {
            self.bytes[self.len] = ',';
            self.bytes[self.len + 1] = ' ';
            self.len += 2;
        }
        @memcpy(self.bytes[self.len..][0..name.len], name);
        self.len += name.len;
        self.count += 1;
    }

    /// The names kept, joined by ", ".
    pub fn text(self: *const NameList) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// Audio state, copied from the audio module each frame for the console's `audio` command. Plain
/// values only, so this file stays free of the audio code.
pub const AudioState = struct {
    /// Voices listed in full. `voices_busy` counts all of them.
    pub const max_listed = 3;

    /// True when a playback device is open. Without one, nothing plays.
    device_open: bool = false,
    /// The device's mix format, when a device is open.
    sample_rate: u32 = 0,
    channels: u8 = 0,
    /// Voices in use, the most that can play at once, and the master gain.
    voices_busy: u32 = 0,
    voices_max: u32 = 0,
    master_gain: f32 = 1,
    /// The first busy voices, in slot order.
    listed: [max_listed]AudioVoice = [_]AudioVoice{.{}} ** max_listed,
    listed_count: u8 = 0,
};

/// One busy voice: whether it loops, its own gain, and the size of the sound it plays.
pub const AudioVoice = struct {
    looping: bool = false,
    gain: f32 = 0,
    sound_bytes: usize = 0,
};

pub const max_inspected_entities = 16;
pub const max_inspected_components = 4;
pub const entity_name_capacity = 32;
pub const component_name_capacity = 24;
pub const component_value_capacity = 64;

pub const ComponentInput = struct {
    name: []const u8,
    value: []const u8,
};

/// Caller-owned data copied into the diagnostics snapshot; no game storage is retained.
pub const EntityInput = struct {
    id: u32,
    name: []const u8,
    components: []const ComponentInput,
};

pub const ComponentSnapshot = struct {
    name: [component_name_capacity]u8 = undefined,
    name_len: u8 = 0,
    value: [component_value_capacity]u8 = undefined,
    value_len: u8 = 0,

    pub fn nameText(self: *const ComponentSnapshot) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn valueText(self: *const ComponentSnapshot) []const u8 {
        return self.value[0..self.value_len];
    }
};

pub const EntitySnapshot = struct {
    id: u32,
    name: [entity_name_capacity]u8 = undefined,
    name_len: u8 = 0,
    components: [max_inspected_components]ComponentSnapshot = undefined,
    component_count: u8 = 0,

    pub fn nameText(self: *const EntitySnapshot) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn componentSlice(self: *const EntitySnapshot) []const ComponentSnapshot {
        return self.components[0..self.component_count];
    }
};

pub const Inspection = struct {
    entities: [max_inspected_entities]EntitySnapshot = undefined,
    count: u8 = 0,
    omitted: u32 = 0,

    pub fn entitySlice(self: *const Inspection) []const EntitySnapshot {
        return self.entities[0..self.count];
    }
};

pub const EntityPublishError = error{
    TooManyEntities,
    TooManyComponents,
    TextTooLong,
    EmptyName,
    DuplicateEntity,
    DuplicateComponent,
    CountMismatch,
};

/// Input state, from the input module.
pub const Input = struct {
    held: u32 = 0,
    pressed: u32 = 0,
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    /// The keys held now, by name, and the actions they resolve to through the game's bindings.
    keys: NameList = .{},
    actions: NameList = .{},
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
    memory: Memory = .{},
    input: Input = .{},
    world: World = .{},
    audio: AudioState = .{},
    inspection: Inspection = .{},
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
    /// Per-frame values the overlay draws as strips and Tracy plots over time. See plots.zig.
    plots: plot_series.Plots = .{},
    /// Frames that ran past two budgets, kept for the overlay. See spike_log.zig.
    spikes: spike_log.SpikeLog = .{},

    /// Copies entity/component values into bounded storage for read-only inspection. Neither the
    /// caller's slices nor pointers into game state are retained.
    pub fn publishEntities(self: *Collector, total_count: u32, inputs: []const EntityInput) EntityPublishError!void {
        if (inputs.len > max_inspected_entities) return error.TooManyEntities;
        if (inputs.len > total_count) return error.CountMismatch;

        for (inputs, 0..) |entity, index| {
            if (entity.name.len == 0) return error.EmptyName;
            if (entity.name.len > entity_name_capacity) return error.TextTooLong;
            if (entity.components.len > max_inspected_components) return error.TooManyComponents;
            for (inputs[0..index]) |previous| {
                if (previous.id == entity.id) return error.DuplicateEntity;
            }
            for (entity.components, 0..) |component, component_index| {
                if (component.name.len == 0) return error.EmptyName;
                if (component.name.len > component_name_capacity or component.value.len > component_value_capacity) {
                    return error.TextTooLong;
                }
                for (entity.components[0..component_index]) |previous| {
                    if (std.mem.eql(u8, previous.name, component.name)) return error.DuplicateComponent;
                }
            }
        }

        var inspection = Inspection{ .omitted = total_count - @as(u32, @intCast(inputs.len)) };
        for (inputs, 0..) |entity, index| {
            var snapshot = EntitySnapshot{ .id = entity.id, .name_len = @intCast(entity.name.len) };
            @memcpy(snapshot.name[0..entity.name.len], entity.name);
            snapshot.component_count = @intCast(entity.components.len);
            for (entity.components, 0..) |component, component_index| {
                var copied = ComponentSnapshot{
                    .name_len = @intCast(component.name.len),
                    .value_len = @intCast(component.value.len),
                };
                @memcpy(copied.name[0..component.name.len], component.name);
                @memcpy(copied.value[0..component.value.len], component.value);
                snapshot.components[component_index] = copied;
            }
            inspection.entities[index] = snapshot;
        }

        inspection.count = @intCast(inputs.len);
        self.snapshot.world.entities = total_count;
        self.snapshot.inspection = inspection;
    }

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

test "entity snapshots copy bounded component values and report omitted entities" {
    var collector = Collector{};
    var name = [_]u8{ 'p', 'l', 'a', 'y', 'e', 'r' };
    var position = [_]u8{ 'x', '=', '1' };
    const components = [_]ComponentInput{.{ .name = "transform", .value = &position }};
    const entities = [_]EntityInput{.{ .id = 7, .name = &name, .components = &components }};
    try collector.publishEntities(3, &entities);

    name[0] = 'X';
    position[2] = '9';
    try std.testing.expectEqual(@as(u32, 3), collector.snapshot.world.entities);
    try std.testing.expectEqual(@as(u32, 2), collector.snapshot.inspection.omitted);
    try std.testing.expectEqualStrings("player", collector.snapshot.inspection.entities[0].nameText());
    try std.testing.expectEqualStrings("x=1", collector.snapshot.inspection.entities[0].components[0].valueText());
}

test "invalid entity snapshots are rejected without replacing the prior snapshot" {
    var collector = Collector{};
    const valid = [_]EntityInput{.{ .id = 1, .name = "player", .components = &.{} }};
    try collector.publishEntities(1, &valid);
    const duplicate = [_]EntityInput{
        .{ .id = 2, .name = "first", .components = &.{} },
        .{ .id = 2, .name = "second", .components = &.{} },
    };
    try std.testing.expectError(error.DuplicateEntity, collector.publishEntities(2, &duplicate));
    try std.testing.expectEqual(@as(u32, 1), collector.snapshot.world.entities);
    try std.testing.expectEqual(@as(u32, 1), collector.snapshot.inspection.entities[0].id);
}

test "a name list joins its names and counts the ones that do not fit" {
    var names = NameList{};
    names.add("w");
    names.add("space");
    try std.testing.expectEqualStrings("w, space", names.text());
    try std.testing.expectEqual(@as(usize, 2), names.count);

    var i: usize = 0;
    while (i < 20) : (i += 1) names.add("keypad_minus");
    // Four more names fit under the capacity, and the other sixteen are counted as omitted.
    try std.testing.expectEqual(@as(usize, 6), names.count);
    try std.testing.expectEqual(@as(u32, 16), names.omitted);
    try std.testing.expect(names.text().len <= NameList.capacity);
}
