//! Game-owned level metadata that does not belong in the engine's generic tilemap format.

const std = @import("std");

pub const SpawnError = error{ BadFormat, OutsideMap };
pub const Spawn = struct { col: u32, row: u32 };

/// Parses the single game-specific spawn cell and validates it against generic map dimensions.
pub fn parseSpawn(cols: u32, rows: u32, text: []const u8) SpawnError!Spawn {
    var spawn: ?Spawn = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (spawn != null) return error.BadFormat;
        var words = std.mem.tokenizeAny(u8, line, " \t");
        if (!std.mem.eql(u8, words.next() orelse return error.BadFormat, "spawn")) return error.BadFormat;
        const col = parseCoordinate(words.next()) orelse return error.BadFormat;
        const row = parseCoordinate(words.next()) orelse return error.BadFormat;
        if (words.next() != null) return error.BadFormat;
        if (col >= cols or row >= rows) return error.OutsideMap;
        spawn = .{ .col = col, .row = row };
    }
    return spawn orelse error.BadFormat;
}

fn parseCoordinate(value: ?[]const u8) ?u32 {
    const text = value orelse return null;
    return std.fmt.parseInt(u32, text, 10) catch null;
}

test "game spawn metadata parses independently and must fit map dimensions" {
    const cell = try parseSpawn(40, 24, "# game level metadata\nspawn 20 12\n");
    try std.testing.expectEqual(@as(u32, 20), cell.col);
    try std.testing.expectEqual(@as(u32, 12), cell.row);
    try std.testing.expectError(error.BadFormat, parseSpawn(40, 24, "spawn 20\n"));
    try std.testing.expectError(error.BadFormat, parseSpawn(40, 24, "spawn 1 1\nspawn 2 2\n"));
    try std.testing.expectError(error.OutsideMap, parseSpawn(40, 24, "spawn 40 0\n"));
}
