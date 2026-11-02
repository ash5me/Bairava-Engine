//! Prefabs: named entity templates. The game's prefab file lists them, and a level places them by name.
//! Each placement spawns one entity that draws the prefab's tile, so a template can be placed many times
//! without repeating its data.
//!
//! The file has one statement per line. `#` starts a comment, and blank lines are ignored:
//!
//!     prefab coin
//!     tile 39
//!
//! `prefab <name>` starts a template. A name uses lowercase letters, digits, and `_`, and is at most 32
//! bytes. `tile <id>` names the tile the template draws: an index into the level's tileset, counted left to
//! right and then down, the same as the tile layers. Each template needs exactly one `tile` line. Any other
//! line is an error, so a misspelled keyword cannot be ignored silently.

const std = @import("std");

/// The most templates one file may define. The registry is a fixed array, so it needs no allocator.
pub const max_prefabs = 64;
/// The longest name a template may have.
pub const max_name_len = 32;

/// Index of a template in its registry.
pub const Id = u16;

pub const ParseError = error{
    BadFormat,
    BadName,
    DuplicatePrefab,
    UnknownKey,
    MissingTile,
    TooManyPrefabs,
};

/// One template: its name, and the tile it draws.
pub const Prefab = struct {
    name_buf: [max_name_len]u8 = undefined,
    name_len: usize = 0,
    tile: u32 = 0,
    has_tile: bool = false,

    pub fn name(self: *const Prefab) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

/// Every template a file defines, in the order the file lists them.
pub const Registry = struct {
    items: [max_prefabs]Prefab = [_]Prefab{.{}} ** max_prefabs,
    count: usize = 0,

    pub fn get(self: *const Registry, id: Id) *const Prefab {
        return &self.items[id];
    }

    /// The index of the template called `wanted`, or null when there is none.
    pub fn find(self: *const Registry, wanted: []const u8) ?Id {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (std.mem.eql(u8, self.items[i].name(), wanted)) return @as(Id, @intCast(i));
        }
        return null;
    }

    /// True when every template draws a tile that a tileset of `tile_count` tiles has.
    pub fn tilesFit(self: *const Registry, tile_count: u32) bool {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.items[i].tile >= tile_count) return false;
        }
        return true;
    }
};

/// Parses a prefab file. The result is a full registry, or the first error found.
pub fn parse(text: []const u8) ParseError!Registry {
    var registry: Registry = .{};
    var current: ?usize = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        var words: [3][]const u8 = undefined;
        var count: usize = 0;
        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        while (tokens.next()) |word| {
            if (count == words.len) return error.BadFormat;
            words[count] = word;
            count += 1;
        }
        if (count != 2) return error.BadFormat;

        const keyword = words[0];
        const value = words[1];
        if (std.mem.eql(u8, keyword, "prefab")) {
            if (!validName(value)) return error.BadName;
            if (registry.find(value) != null) return error.DuplicatePrefab;
            if (registry.count == max_prefabs) return error.TooManyPrefabs;
            const index = registry.count;
            const slot = &registry.items[index];
            @memcpy(slot.name_buf[0..value.len], value);
            slot.name_len = value.len;
            registry.count += 1;
            current = index;
        } else if (std.mem.eql(u8, keyword, "tile")) {
            const index = current orelse return error.BadFormat;
            const slot = &registry.items[index];
            if (slot.has_tile) return error.BadFormat;
            slot.tile = std.fmt.parseInt(u32, value, 10) catch return error.BadFormat;
            slot.has_tile = true;
        } else {
            return error.UnknownKey;
        }
    }

    var i: usize = 0;
    while (i < registry.count) : (i += 1) {
        if (!registry.items[i].has_tile) return error.MissingTile;
    }
    return registry;
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_len) return false;
    for (name) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '_';
        if (!ok) return false;
    }
    return true;
}

test "a prefab file parses its templates and their tiles" {
    const registry = try parse("# coins and crates\nprefab coin\ntile 39\n\nprefab crate_2\n  tile 9\n");
    try std.testing.expectEqual(@as(usize, 2), registry.count);
    const coin = registry.find("coin") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 39), registry.get(coin).tile);
    const crate = registry.find("crate_2") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("crate_2", registry.get(crate).name());
    try std.testing.expect(registry.find("missing") == null);
}

test "a registry checks its tiles against the tileset size" {
    const registry = try parse("prefab coin\ntile 9\n");
    try std.testing.expect(registry.tilesFit(10));
    try std.testing.expect(!registry.tilesFit(9));
}

test "a prefab file that breaks a rule is refused with the reason" {
    try std.testing.expectError(error.DuplicatePrefab, parse("prefab a\ntile 1\nprefab a\ntile 2\n"));
    try std.testing.expectError(error.MissingTile, parse("prefab a\n"));
    try std.testing.expectError(error.UnknownKey, parse("prefab a\nsprite tile\n"));
    try std.testing.expectError(error.BadFormat, parse("tile 1\n"));
    try std.testing.expectError(error.BadFormat, parse("prefab a\ntile 1\ntile 2\n"));
    try std.testing.expectError(error.BadFormat, parse("prefab a\ntile x\n"));
    try std.testing.expectError(error.BadFormat, parse("prefab a b\ntile 1\n"));
    try std.testing.expectError(error.BadName, parse("prefab Coin\ntile 1\n"));
    try std.testing.expectError(error.BadName, parse("prefab a_name_that_is_far_too_long_for_one_prefab\ntile 1\n"));
}

test "a file with more templates than the registry holds is refused" {
    var text: [(max_prefabs + 1) * 20]u8 = undefined;
    var len: usize = 0;
    for (0..max_prefabs + 1) |i| {
        const piece = try std.fmt.bufPrint(text[len..], "prefab p{d}\ntile 0\n", .{i});
        len += piece.len;
    }
    try std.testing.expectError(error.TooManyPrefabs, parse(text[0..len]));
}
