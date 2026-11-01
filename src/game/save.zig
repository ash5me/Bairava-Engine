//! Versioned JSON persistence for gameplay components. Parson owns the JSON tree and the
//! human-readable serialization; this module maps the game state to stable component paths.

const std = @import("std");
const parson = @cImport({
    @cInclude("parson.h");
});
const player = @import("player.zig");

/// Save-file representation kept independent of engine runtime types.
pub const SavedTransform = struct {
    position: [3]f32 = .{ 0.0, 0.0, 0.0 },
    rotation: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 },
    scale: [3]f32 = .{ 1.0, 1.0, 1.0 },
};

pub const current_version: u32 = 2;

pub const ScaleMode = enum { fit, integer };

pub const State = struct {
    player_transform: SavedTransform = .{},
    facing: player.Facing = .down,
    moving: bool = false,
    animation_time: f32 = 0,
    clicks: u32 = 0,
    volume: f32 = 0.5,
    level_matches: bool = true,
    scale_mode: ScaleMode = .fit,
    zoom_target: f32 = 1,
};

fn isValidState(state: State) bool {
    return isValidTransform(state.player_transform) and isFiniteF32(state.animation_time) and
        isFiniteF32(state.volume) and isFiniteF32(state.zoom_target) and
        state.animation_time >= 0 and state.animation_time <= 3600 and state.volume >= 0 and state.volume <= 1 and
        state.zoom_target > 0 and state.zoom_target <= 100 and state.level_matches;
}

fn isValidDefaultState(state: State) bool {
    return isValidTransform(state.player_transform) and isFiniteF32(state.animation_time) and
        isFiniteF32(state.volume) and isFiniteF32(state.zoom_target) and
        state.animation_time >= 0 and state.animation_time <= 3600 and state.volume >= 0 and state.volume <= 1 and
        state.zoom_target > 0 and state.zoom_target <= 100;
}

fn isValidTransform(value: SavedTransform) bool {
    for (value.position) |component| {
        if (!isFiniteF32(component) or @abs(component) > 1_000_000) return false;
    }
    for (value.scale) |component| {
        if (!isFiniteF32(component) or @abs(component) > 1_000) return false;
    }
    var rotation_length_squared: f32 = 0;
    for (value.rotation) |component| {
        if (!isFiniteF32(component) or @abs(component) > 1_000_000) return false;
        rotation_length_squared += component * component;
    }
    return rotation_length_squared > 1e-12 and isFiniteF32(rotation_length_squared);
}

fn parseScaleMode(text: []const u8) ?ScaleMode {
    if (std.ascii.eqlIgnoreCase(text, @tagName(ScaleMode.fit))) return .fit;
    if (std.ascii.eqlIgnoreCase(text, @tagName(ScaleMode.integer))) return .integer;
    return null;
}

fn parseFacing(text: []const u8) ?player.Facing {
    if (std.ascii.eqlIgnoreCase(text, @tagName(player.Facing.down))) return .down;
    if (std.ascii.eqlIgnoreCase(text, @tagName(player.Facing.right))) return .right;
    if (std.ascii.eqlIgnoreCase(text, @tagName(player.Facing.up))) return .up;
    if (std.ascii.eqlIgnoreCase(text, @tagName(player.Facing.left))) return .left;
    return null;
}

fn matchesLevelId(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "level1");
}

fn parseVersion(raw: f64) ?u32 {
    if (!std.math.isFinite(raw) or raw < 0 or raw > std.math.maxInt(u32) or raw != @floor(raw)) return null;
    return @intFromFloat(raw);
}

/// Serialize a snapshot into pretty, editable JSON. The caller owns the returned bytes.
pub fn serialize(allocator: std.mem.Allocator, state: State) ![]u8 {
    if (!isValidState(state)) {
        return error.InvalidSave;
    }

    const root_value = parson.json_value_init_object() orelse return error.OutOfMemory;
    defer parson.json_value_free(root_value);
    const root = parson.json_value_get_object(root_value) orelse return error.SerializeFailed;

    try setNumber(root, "save_version", @floatFromInt(current_version));
    const saved_transform = state.player_transform;
    try setNumber(root, "components.player.transform.position.x", @floatCast(saved_transform.position[0]));
    try setNumber(root, "components.player.transform.position.y", @floatCast(saved_transform.position[1]));
    try setNumber(root, "components.player.transform.position.z", @floatCast(saved_transform.position[2]));
    const rotation = normalizedRotation(saved_transform.rotation);
    try setNumber(root, "components.player.transform.rotation.x", @floatCast(rotation[0]));
    try setNumber(root, "components.player.transform.rotation.y", @floatCast(rotation[1]));
    try setNumber(root, "components.player.transform.rotation.z", @floatCast(rotation[2]));
    try setNumber(root, "components.player.transform.rotation.w", @floatCast(rotation[3]));
    try setNumber(root, "components.player.transform.scale.x", @floatCast(saved_transform.scale[0]));
    try setNumber(root, "components.player.transform.scale.y", @floatCast(saved_transform.scale[1]));
    try setNumber(root, "components.player.transform.scale.z", @floatCast(saved_transform.scale[2]));
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
pub fn deserialize(allocator: std.mem.Allocator, text: []const u8, defaults: State) !State {
    if (!isValidDefaultState(defaults)) return error.InvalidSave;
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidSave;
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidSave;
    const ztext = try allocator.dupeZ(u8, text);
    defer allocator.free(ztext);
    const root_value = parson.json_parse_string(ztext.ptr) orelse return error.InvalidSave;
    defer parson.json_value_free(root_value);
    if (parson.json_value_get_type(root_value) != parson.JSONObject) return error.InvalidSave;
    const root = parson.json_value_get_object(root_value) orelse return error.InvalidSave;

    const version = parseVersion(numberAt(root, "save_version") orelse return error.InvalidSave) orelse return error.InvalidSave;
    if (version < 1) return error.InvalidSave;
    if (version > current_version) return error.UnsupportedVersion;

    var state = defaults;
    const position_x = numberAt(root, "components.player.transform.position.x") orelse numberAt(root, "components.player.transform.x");
    const position_y = numberAt(root, "components.player.transform.position.y") orelse numberAt(root, "components.player.transform.y");
    if (position_x) |x| {
        if (position_y) |y| {
            const z = numberAt(root, "components.player.transform.position.z") orelse @as(f64, state.player_transform.position[2]);
            if (std.math.isFinite(x) and std.math.isFinite(y) and std.math.isFinite(z) and
                @abs(x) <= 1_000_000 and @abs(y) <= 1_000_000 and @abs(z) <= 1_000_000)
            {
                state.player_transform.position = .{ @floatCast(x), @floatCast(y), @floatCast(z) };
            }
        }
    }

    const rotation_paths = .{
        numberAt(root, "components.player.transform.rotation.x"),
        numberAt(root, "components.player.transform.rotation.y"),
        numberAt(root, "components.player.transform.rotation.z"),
        numberAt(root, "components.player.transform.rotation.w"),
    };
    if (rotation_paths[0]) |x| {
        if (rotation_paths[1]) |y| {
            if (rotation_paths[2]) |z| {
                if (rotation_paths[3]) |w| {
                    if (std.math.isFinite(x) and std.math.isFinite(y) and std.math.isFinite(z) and std.math.isFinite(w) and
                        @abs(x) <= 1_000_000 and @abs(y) <= 1_000_000 and @abs(z) <= 1_000_000 and @abs(w) <= 1_000_000)
                    {
                        const rotation: [4]f32 = .{ @floatCast(x), @floatCast(y), @floatCast(z), @floatCast(w) };
                        if (rotationLengthSquared(rotation) > 1e-12) {
                            state.player_transform.rotation = normalizedRotation(rotation);
                        }
                    }
                }
            }
        }
    }

    const scale_paths = .{
        numberAt(root, "components.player.transform.scale.x"),
        numberAt(root, "components.player.transform.scale.y"),
        numberAt(root, "components.player.transform.scale.z"),
    };
    if (scale_paths[0]) |x| {
        if (scale_paths[1]) |y| {
            if (scale_paths[2]) |z| {
                if (std.math.isFinite(x) and std.math.isFinite(y) and std.math.isFinite(z) and
                    @abs(x) <= 1_000 and @abs(y) <= 1_000 and @abs(z) <= 1_000)
                {
                    state.player_transform.scale = .{ @floatCast(x), @floatCast(y), @floatCast(z) };
                }
            }
        }
    }

    if (stringAt(root, "components.player.facing.direction")) |name| {
        if (parseFacing(name)) |facing| state.facing = facing;
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
        state.level_matches = matchesLevelId(level_id);
    }
    if (stringAt(root, "components.display.scale_mode")) |mode| {
        if (parseScaleMode(mode)) |parsed_mode| state.scale_mode = parsed_mode;
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
    if (parson.json_object_dotget_value(object, path)) |value| return value;

    const text = std.mem.span(path);
    var flat_buf: [256]u8 = undefined;
    if (text.len < flat_buf.len) {
        @memcpy(flat_buf[0..text.len], text);
        flat_buf[text.len] = 0;
        if (parson.json_object_get_value(object, @ptrCast(&flat_buf))) |value| return value;
    }

    var cursor: usize = 0;
    var current_obj = object;
    while (true) {
        const dot = std.mem.indexOfScalarPos(u8, text, cursor, '.');
        const key_text = if (dot) |index| text[cursor..index] else text[cursor..];
        if (key_text.len == 0) return null;

        var key_buf: [128]u8 = undefined;
        if (key_text.len >= key_buf.len) return null;
        @memcpy(key_buf[0..key_text.len], key_text);
        key_buf[key_text.len] = 0;

        const value = parson.json_object_get_value(current_obj, @ptrCast(&key_buf)) orelse return null;
        if (dot) |_| {
            current_obj = parson.json_value_get_object(value) orelse return null;
            cursor = dot.? + 1;
            continue;
        }
        return value;
    }
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

fn isFiniteF32(value: f32) bool {
    return std.math.isFinite(value);
}

fn rotationLengthSquared(rotation: [4]f32) f32 {
    var length_squared: f32 = 0;
    for (rotation) |component| length_squared += component * component;
    return length_squared;
}

fn normalizedRotation(rotation: [4]f32) [4]f32 {
    const inverse_length = 1.0 / @sqrt(rotationLengthSquared(rotation));
    return .{
        rotation[0] * inverse_length,
        rotation[1] * inverse_length,
        rotation[2] * inverse_length,
        rotation[3] * inverse_length,
    };
}

test "save round-trips valid gameplay state and rejects invalid floats" {
    const defaults = State{};
    const state = State{
        .player_transform = .{
            .position = .{ 42.5, -12.25, 3.0 },
            .rotation = .{ 0.0, 0.0, @sin(0.25), @cos(0.25) },
            .scale = .{ 2.0, 3.0, 1.0 },
        },
        .facing = .left,
        .moving = true,
        .animation_time = 1.5,
        .clicks = 9,
        .volume = 0.75,
        .scale_mode = .integer,
        .zoom_target = 2.0,
    };

    const json = try serialize(std.testing.allocator, state);
    defer std.testing.allocator.free(json);

    const loaded = try deserialize(std.testing.allocator, json, defaults);
    try std.testing.expectEqual(state.player_transform.position, loaded.player_transform.position);
    try std.testing.expectEqual(state.player_transform.rotation, loaded.player_transform.rotation);
    try std.testing.expectEqual(state.player_transform.scale, loaded.player_transform.scale);
    try std.testing.expectEqual(state.facing, loaded.facing);
    try std.testing.expectEqual(state.moving, loaded.moving);
    try std.testing.expectEqual(state.animation_time, loaded.animation_time);
    try std.testing.expectEqual(state.clicks, loaded.clicks);
    try std.testing.expectEqual(state.volume, loaded.volume);
    try std.testing.expectEqual(state.scale_mode, loaded.scale_mode);
    try std.testing.expectEqual(state.zoom_target, loaded.zoom_target);

    try std.testing.expectError(error.InvalidSave, serialize(std.testing.allocator, .{ .player_transform = .{ .position = .{ std.math.nan(f32), 0, 0 } } }));
}

test "save rejects unsupported versions and malformed payloads" {
    const defaults = State{};
    const bad_version = "{\n  \"save_version\": 99\n}\n";
    try std.testing.expectError(error.UnsupportedVersion, deserialize(std.testing.allocator, bad_version, defaults));

    const huge_version = "{\n  \"save_version\": 4294967296\n}\n";
    try std.testing.expectError(error.InvalidSave, deserialize(std.testing.allocator, huge_version, defaults));

    const zero_version = "{\n  \"save_version\": 0\n}\n";
    try std.testing.expectError(error.InvalidSave, deserialize(std.testing.allocator, zero_version, defaults));

    const negative_version = "{\n  \"save_version\": -1\n}\n";
    try std.testing.expectError(error.InvalidSave, deserialize(std.testing.allocator, negative_version, defaults));

    const malformed = "{\n  \"save_version\": \"1\"\n}\n";
    try std.testing.expectError(error.InvalidSave, deserialize(std.testing.allocator, malformed, defaults));

    const blank = "   \n\t\r  ";
    try std.testing.expectError(error.InvalidSave, deserialize(std.testing.allocator, blank, defaults));
}

test "save rejects invalid default state and keeps malformed loaded values on their defaults" {
    const valid_save = "{\n  \"save_version\": 1,\n  \"components.game.progress.volume\": 1.0\n}\n";
    try std.testing.expectError(error.InvalidSave, deserialize(std.testing.allocator, valid_save, .{ .volume = 2.0 }));

    const loaded = try deserialize(std.testing.allocator, "{\n  \"save_version\": 1,\n  \"components.game.progress.volume\": 2.0\n}\n", .{ .volume = 0.25 });
    try std.testing.expectEqual(@as(f32, 0.25), loaded.volume);
    try std.testing.expectError(error.InvalidSave, serialize(std.testing.allocator, .{ .level_matches = false }));
}

test "version one position paths remain readable and new transform values default" {
    const loaded = try deserialize(std.testing.allocator,
        "{\"save_version\":1,\"components\":{\"player\":{\"transform\":{\"x\":12,\"y\":34}}}}",
        State{},
    );
    try std.testing.expectEqual(@as(f32, 12), loaded.player_transform.position[0]);
    try std.testing.expectEqual(@as(f32, 34), loaded.player_transform.position[1]);
    try std.testing.expectEqual(@as(f32, 0), loaded.player_transform.position[2]);
    try std.testing.expectEqual(@as(f32, 1), loaded.player_transform.scale[0]);
}

test "save keeps defaults for unknown enum strings and mismatched level ids" {
    const loaded_scale = try deserialize(std.testing.allocator,
        "{\n  \"save_version\": 1,\n  \"components.display.scale_mode\": \"BOGUS\"\n}\n",
        .{ .scale_mode = .integer },
    );
    try std.testing.expectEqual(ScaleMode.integer, loaded_scale.scale_mode);

    const loaded_level = try deserialize(std.testing.allocator,
        "{\n  \"save_version\": 1,\n  \"components.world.level.id\": \"LEVEL2\"\n}\n",
        .{ .level_matches = true },
    );
    try std.testing.expectEqual(false, loaded_level.level_matches);

    const parsed_case = try deserialize(std.testing.allocator,
        "{\n  \"save_version\": 1,\n  \"components.display.scale_mode\": \"INTEGER\",\n  \"components.world.level.id\": \"LEVEL1\"\n}\n",
        .{ .scale_mode = .fit, .level_matches = false },
    );
    try std.testing.expectEqual(ScaleMode.integer, parsed_case.scale_mode);
    try std.testing.expectEqual(true, parsed_case.level_matches);

    const facing = try deserialize(std.testing.allocator,
        "{\n  \"save_version\": 1,\n  \"components.player.facing.direction\": \"LEFT\"\n}\n",
        .{ .facing = .right },
    );
    try std.testing.expectEqual(player.Facing.left, facing.facing);

    try std.testing.expectError(error.InvalidSave, deserialize(std.testing.allocator, "{\n  \"save_version\": 1.5\n}\n", State{}));
}
