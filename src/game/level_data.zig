//! Game-owned level metadata that does not belong in the engine's generic tilemap format. The file holds one
//! `spawn` line, the cell where the player starts, and any number of `place` lines. Each `place` names a prefab
//! from the prefab file and the cell to put one of its entities on:
//!
//!     spawn 20 12
//!     place coin 3 4
//!
//! `#` starts a comment, and blank lines are ignored. Any other line is an error, so a misspelled keyword cannot
//! be ignored silently. `zig build check-assets` checks the file against the map's size and the prefab file, and
//! the game checks it again when it loads.

const std = @import("std");
const prefab = @import("prefab.zig");

pub const ParseError = error{
    BadFormat,
    OutsideMap,
    UnknownPrefab,
    TooManyPlacements,
    OutOfMemory,
};

/// The cell where the player starts.
pub const Spawn = struct { col: u32, row: u32 };

/// One entity the level places: the prefab it is made from, and the cell it stands on.
pub const Placement = struct { prefab: prefab.Id, col: u32, row: u32 };

/// The most placements one level may hold. The cap keeps a bad file from taking all of memory.
pub const max_placements = 4096;

/// The parsed metadata. `placements` was allocated by the allocator given to `parse`, and `deinit` frees it.
pub const Data = struct {
    spawn: Spawn,
    placements: []Placement,

    pub fn deinit(self: Data, allocator: std.mem.Allocator) void {
        allocator.free(self.placements);
    }
};

/// The most words one line may hold. A `place` line has four.
const max_words = 4;

const Words = struct {
    items: [max_words][]const u8 = undefined,
    len: usize = 0,
};

/// Splits a line into words, or returns null when it holds more than `max_words`.
fn splitWords(line: []const u8) ?Words {
    var words: Words = .{};
    var tokens = std.mem.tokenizeAny(u8, line, " \t");
    while (tokens.next()) |word| {
        if (words.len == max_words) return null;
        words.items[words.len] = word;
        words.len += 1;
    }
    return words;
}

/// The words of one line, or null for a blank or comment line.
fn wordsOf(raw: []const u8) ParseError!?Words {
    const line = std.mem.trim(u8, raw, " \t\r");
    if (line.len == 0 or line[0] == '#') return null;
    const words = splitWords(line) orelse return error.BadFormat;
    return words;
}

/// Parses level metadata. `prefabs` is the registry that the placements name. The result owns its placements,
/// so the caller must call `deinit` on it.
pub fn parse(
    allocator: std.mem.Allocator,
    prefabs: *const prefab.Registry,
    cols: u32,
    rows: u32,
    text: []const u8,
) ParseError!Data {
    // The first pass counts the placements, so the second pass fills a slice of exactly that size.
    var count: usize = 0;
    var counting = std.mem.splitScalar(u8, text, '\n');
    while (counting.next()) |raw| {
        const words = (try wordsOf(raw)) orelse continue;
        if (std.mem.eql(u8, words.items[0], "place")) count += 1;
    }
    if (count > max_placements) return error.TooManyPlacements;

    const placements = try allocator.alloc(Placement, count);
    errdefer allocator.free(placements);

    var spawn: ?Spawn = null;
    var filled: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const words = (try wordsOf(raw)) orelse continue;
        const keyword = words.items[0];
        if (std.mem.eql(u8, keyword, "spawn")) {
            if (words.len != 3 or spawn != null) return error.BadFormat;
            spawn = try cellAt(words, 1, cols, rows);
        } else if (std.mem.eql(u8, keyword, "place")) {
            if (words.len != 4) return error.BadFormat;
            const id = prefabs.find(words.items[1]) orelse return error.UnknownPrefab;
            const cell = try cellAt(words, 2, cols, rows);
            placements[filled] = .{ .prefab = id, .col = cell.col, .row = cell.row };
            filled += 1;
        } else {
            return error.BadFormat;
        }
    }
    std.debug.assert(filled == count);
    const found = spawn orelse return error.BadFormat;
    return .{ .spawn = found, .placements = placements };
}

/// The cell named by the two words that start at `first`.
fn cellAt(words: Words, first: usize, cols: u32, rows: u32) ParseError!Spawn {
    const col = parseCoordinate(words.items[first]) orelse return error.BadFormat;
    const row = parseCoordinate(words.items[first + 1]) orelse return error.BadFormat;
    if (col >= cols or row >= rows) return error.OutsideMap;
    return .{ .col = col, .row = row };
}

fn parseCoordinate(text: []const u8) ?u32 {
    return std.fmt.parseInt(u32, text, 10) catch null;
}

test "spawn and place lines parse, and placements must name known prefabs inside the map" {
    const allocator = std.testing.allocator;
    const prefabs = try prefab.parse("prefab coin\ntile 39\n");

    const data = try parse(allocator, &prefabs, 40, 24, "# level metadata\nspawn 20 12\nplace coin 3 4\nplace coin 5 6\n");
    defer data.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 20), data.spawn.col);
    try std.testing.expectEqual(@as(u32, 12), data.spawn.row);
    try std.testing.expectEqual(@as(usize, 2), data.placements.len);
    try std.testing.expectEqual(@as(u32, 5), data.placements[1].col);
    try std.testing.expectEqual(@as(u32, 6), data.placements[1].row);
    try std.testing.expectEqual(@as(prefab.Id, 0), data.placements[1].prefab);
}

test "a level with no placements still has its spawn" {
    const allocator = std.testing.allocator;
    const prefabs = try prefab.parse("prefab coin\ntile 39\n");
    const data = try parse(allocator, &prefabs, 40, 24, "spawn 1 1\n");
    defer data.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), data.placements.len);
}

test "bad level metadata is refused with the reason" {
    const allocator = std.testing.allocator;
    const prefabs = try prefab.parse("prefab coin\ntile 39\n");
    try std.testing.expectError(error.BadFormat, parse(allocator, &prefabs, 40, 24, "place coin 1 1\n"));
    try std.testing.expectError(error.BadFormat, parse(allocator, &prefabs, 40, 24, "spawn 20\n"));
    try std.testing.expectError(error.BadFormat, parse(allocator, &prefabs, 40, 24, "spawn 1 1\nspawn 2 2\n"));
    try std.testing.expectError(error.BadFormat, parse(allocator, &prefabs, 40, 24, "spawn 1 1\nplace coin 1\n"));
    try std.testing.expectError(error.BadFormat, parse(allocator, &prefabs, 40, 24, "spawn 1 1\nspawnn 2 2\n"));
    try std.testing.expectError(error.UnknownPrefab, parse(allocator, &prefabs, 40, 24, "spawn 1 1\nplace crate 1 1\n"));
    try std.testing.expectError(error.OutsideMap, parse(allocator, &prefabs, 40, 24, "spawn 40 0\n"));
    try std.testing.expectError(error.OutsideMap, parse(allocator, &prefabs, 40, 24, "spawn 1 1\nplace coin 3 24\n"));
}
