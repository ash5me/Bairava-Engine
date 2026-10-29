//! Versioned JSON persistence for gameplay components. Parson owns the JSON tree and the
//! human-readable serialization; this module maps the game state to stable component paths.

const std = @import("std");
const parson = @cImport({
    @cInclude("parson.h");
});
const player = @import("player.zig");

pub const current_version: f64 = 1;

pub const ScaleMode = enum { fit, integer };

pub const State = struct {
    player_x: f32 = 0,
    player_y: f32 = 0,
    facing: player.Facing = .down,
    moving: bool = false,
    animation_time: f32 = 0,
    clicks: u32 = 0,
    volume: f32 = 0.5,
    level_matches: bool = true,
    scale_mode: ScaleMode = .fit,
    zoom_target: f32 = 1,
};

/// Serialize a snapshot into pretty, editable JSON. The caller owns the returned bytes.
pub fn serialize(allocator: std.mem.Allocator, state: State) ![]u8 {
    const root_value = parson.json_value_init_object() orelse return error.OutOfMemory;
    defer parson.json_value_free(root_value);
    const root = parson.json_value_get_object(root_value) orelse return error.SerializeFailed;

    try setNumber(root, "save_version", current_version);
    try setNumber(root, "components.player.transform.x", @floatCast(state.player_x));
    try setNumber(root, "components.player.transform.y", @floatCast(state.player_y));
    try setString(root, "components.player.facing.direction", @tagName(state.facing));
    try setBoolean(root, "components.player.animation.moving", state.moving);
    try setNumber(root, "components.player.animation.elapsed_seconds", @floatCast(state.animation_time));
    try setNumber(root, "components.game.progress.clicks", @floatFromInt(state.clicks));
    try setNumber(root, "components.game.progress.volume", @floatCast(state.volume));
    try setString(root, "components.world.level.id", "level1");
    try setString(root, "components.display.scale_mode", @tagName(state.scale_mode));
    try setNumber(root, "components.display.zoom_target", @floatCast(state.zoom_target));

    const json = parson.json_serialize_to_string_pretty(root_value) orelse return error.SerializeFailed;
    defer parson.json_free_serialized_string(json);
    return try allocator.dupe(u8, std.mem.span(json));
}

/// Decode a save over the current defaults. Missing or malformed component values keep their
/// defaults, which lets older saves omit fields added by later versions. Unknown future versions
/// are rejected so they are not accidentally interpreted as an older format.
pub fn deserialize(text: []const u8, defaults: State) !State {
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidSave;
    const ztext = try std.heap.page_allocator.dupeZ(u8, text);
    defer std.heap.page_allocator.free(ztext);
    const root_value = parson.json_parse_string(ztext.ptr) orelse return error.InvalidSave;
    defer parson.json_value_free(root_value);
    if (parson.json_value_get_type(root_value) != parson.JSONObject) return error.InvalidSave;
    const root = parson.json_value_get_object(root_value) orelse return error.InvalidSave;

    const version = numberAt(root, "save_version") orelse return error.InvalidSave;
    if (!std.math.isFinite(version) or version < 0 or @floor(version) != version) return error.InvalidSave;
    if (version > current_version) return error.UnsupportedVersion;

    var state = defaults;
    if (numberAt(root, "components.player.transform.x")) |x| {
        if (numberAt(root, "components.player.transform.y")) |y| {
            if (std.math.isFinite(x) and std.math.isFinite(y) and @abs(x) <= 1_000_000 and @abs(y) <= 1_000_000) {
                state.player_x = @floatCast(x);
                state.player_y = @floatCast(y);
            }
        }
    }

    if (stringAt(root, "components.player.facing.direction")) |name| {
        if (std.meta.stringToEnum(player.Facing, name)) |facing| state.facing = facing;
    }

    if (booleanAt(root, "components.player.animation.moving")) |moving| state.moving = moving;
    if (numberAt(root, "components.player.animation.elapsed_seconds")) |elapsed| {
        if (std.math.isFinite(elapsed) and elapsed >= 0 and elapsed <= 3600) state.animation_time = @floatCast(elapsed);
    }

    if (numberAt(root, "components.game.progress.clicks")) |clicks| {
        if (std.math.isFinite(clicks) and clicks >= 0 and clicks <= std.math.maxInt(u32) and @floor(clicks) == clicks) {
            state.clicks = @intFromFloat(clicks);
        }
    }
    if (numberAt(root, "components.game.progress.volume")) |volume| {
        if (std.math.isFinite(volume) and volume >= 0 and volume <= 1) state.volume = @floatCast(volume);
    }

    if (stringAt(root, "components.world.level.id")) |level_id| {
        state.level_matches = std.mem.eql(u8, level_id, "level1");
    }
    if (stringAt(root, "components.display.scale_mode")) |mode| {
        if (std.mem.eql(u8, mode, "fit")) state.scale_mode = .fit else if (std.mem.eql(u8, mode, "integer")) state.scale_mode = .integer;
    }
    if (numberAt(root, "components.display.zoom_target")) |zoom| {
        if (std.math.isFinite(zoom) and zoom > 0 and zoom <= 100) state.zoom_target = @floatCast(zoom);
    }
    return state;
}

fn setNumber(object: *parson.JSON_Object, path: [*:0]const u8, value: f64) !void {
    if (parson.json_object_dotset_number(object, path, value) != parson.JSONSuccess) return error.SerializeFailed;
}

fn setString(object: *parson.JSON_Object, path: [*:0]const u8, value: [*:0]const u8) !void {
    if (parson.json_object_dotset_string(object, path, value) != parson.JSONSuccess) return error.SerializeFailed;
}

fn setBoolean(object: *parson.JSON_Object, path: [*:0]const u8, value: bool) !void {
    if (parson.json_object_dotset_boolean(object, path, @intFromBool(value)) != parson.JSONSuccess) return error.SerializeFailed;
}

fn valueAt(object: *const parson.JSON_Object, path: [*:0]const u8) ?*parson.JSON_Value {
    return parson.json_object_dotget_value(object, path);
}

fn numberAt(object: *const parson.JSON_Object, path: [*:0]const u8) ?f64 {
    const value = valueAt(object, path) orelse return null;
    if (parson.json_value_get_type(value) != parson.JSONNumber) return null;
    return parson.json_value_get_number(value);
}

fn stringAt(object: *const parson.JSON_Object, path: [*:0]const u8) ?[]const u8 {
    const value = valueAt(object, path) orelse return null;
    if (parson.json_value_get_type(value) != parson.JSONString) return null;
    const string = parson.json_value_get_string(value) orelse return null;
    return std.mem.span(string);
}

fn booleanAt(object: *const parson.JSON_Object, path: [*:0]const u8) ?bool {
    const value = valueAt(object, path) orelse return null;
    if (parson.json_value_get_type(value) != parson.JSONBoolean) return null;
    return parson.json_value_get_boolean(value) != 0;
}
