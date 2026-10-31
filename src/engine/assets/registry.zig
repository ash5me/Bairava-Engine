//! Asset identity. A `Table` maps each asset's name to a small integer id and to its validated
//! path.
//!
//! Code uses names once, when it registers or looks up an asset, and then uses ids. An id is an
//! index into a fixed array, so the hot path does no string work. Names are unique, so an id
//! always refers to the same asset. This module doesn't load files. It answers "which asset is
//! this, and where is it", and leaves loading to the caller.
//!
//! Nothing in this file imports SDL or the logger.

const std = @import("std");
const strings = @import("../memory/string.zig");
const hash_map = @import("../memory/hash_map.zig");

pub const Name = strings.Name;
pub const Path = strings.Path;

/// Index of a registered asset. Ids are assigned in registration order, starting at 0.
pub const AssetId = u32;

pub const Table = struct {
    pub const Error = std.mem.Allocator.Error || strings.Error || error{
        /// The name is already registered. The table is unchanged.
        Duplicate,
        /// The table has no room for another asset. The table is unchanged.
        Full,
    };

    pub const Entry = struct {
        name: Name,
        path: Path,
    };

    allocator: std.mem.Allocator,
    /// Fixed-size storage. Entries are written in order, and the first `len` are registered.
    /// The array never grows, so a `*const Path` from `pathOf` stays valid until `deinit`.
    entries: []Entry,
    len: AssetId = 0,
    index: hash_map.StringMap(AssetId),

    /// Creates a table that can hold up to `capacity` assets.
    pub fn init(allocator: std.mem.Allocator, capacity: u32) std.mem.Allocator.Error!Table {
        const entries = try allocator.alloc(Entry, capacity);
        errdefer allocator.free(entries);
        const index = try hash_map.StringMap(AssetId).init(allocator, capacity);
        return .{ .allocator = allocator, .entries = entries, .index = index };
    }

    pub fn deinit(self: *Table) void {
        self.index.deinit();
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    /// Registers the asset `name` at `path` and returns its id. Both are validated before
    /// anything is stored, so a rejected call changes nothing.
    pub fn register(self: *Table, name: []const u8, path: []const u8) Error!AssetId {
        const checked_name = try Name.init(name);
        const checked_path = try Path.init(path);
        if (self.len == self.entries.len) return error.Full;
        if (self.index.contains(checked_name.slice())) return error.Duplicate;

        const id = self.len;
        try self.index.insert(checked_name.slice(), id);
        self.entries[id] = .{ .name = checked_name, .path = checked_path };
        self.len += 1;
        return id;
    }

    /// The id registered under `name`, or null if no asset has that name.
    pub fn find(self: *const Table, name: []const u8) ?AssetId {
        return self.index.get(name);
    }

    /// The number of registered assets.
    pub fn count(self: *const Table) AssetId {
        return self.len;
    }

    /// The name of asset `id`, or null if `id` wasn't issued by this table.
    pub fn nameOf(self: *const Table, id: AssetId) ?[]const u8 {
        const found = self.entry(id) orelse return null;
        return found.name.slice();
    }

    /// The path of asset `id`, or null if `id` wasn't issued by this table.
    pub fn pathOf(self: *const Table, id: AssetId) ?*const Path {
        const found = self.entry(id) orelse return null;
        return &found.path;
    }

    fn entry(self: *const Table, id: AssetId) ?*const Entry {
        if (id >= self.len) return null;
        return &self.entries[id];
    }
};

test "register assigns ids in order and find returns them" {
    var table = try Table.init(std.testing.allocator, 4);
    defer table.deinit();

    const tile = try table.register("tile", "assets/tile.png");
    const warrior = try table.register("warrior", "assets/warrior_16x32.png");
    try std.testing.expectEqual(@as(AssetId, 0), tile);
    try std.testing.expectEqual(@as(AssetId, 1), warrior);
    try std.testing.expectEqual(@as(?AssetId, tile), table.find("tile"));
    try std.testing.expectEqual(@as(?AssetId, warrior), table.find("warrior"));
    try std.testing.expectEqual(@as(?AssetId, null), table.find("missing"));
    try std.testing.expectEqual(@as(AssetId, 2), table.count());
}

test "nameOf and pathOf return what was registered" {
    var table = try Table.init(std.testing.allocator, 2);
    defer table.deinit();

    const id = try table.register("ui/button", "assets/ui/button.png");
    try std.testing.expectEqualStrings("ui/button", table.nameOf(id).?);
    try std.testing.expectEqualStrings("assets/ui/button.png", std.mem.span(table.pathOf(id).?.cstr()));
}

test "ids that were never issued are reported as missing" {
    var table = try Table.init(std.testing.allocator, 2);
    defer table.deinit();

    _ = try table.register("tile", "assets/tile.png");
    try std.testing.expectEqual(@as(?[]const u8, null), table.nameOf(1));
    try std.testing.expectEqual(@as(?*const Path, null), table.pathOf(1));
    try std.testing.expectEqual(@as(?[]const u8, null), table.nameOf(std.math.maxInt(AssetId)));
}

test "a duplicate name is rejected and the original asset is kept" {
    var table = try Table.init(std.testing.allocator, 4);
    defer table.deinit();

    const original = try table.register("tile", "assets/tile.png");
    try std.testing.expectError(error.Duplicate, table.register("tile", "assets/other.png"));
    try std.testing.expectEqual(@as(?AssetId, original), table.find("tile"));
    try std.testing.expectEqualStrings("assets/tile.png", std.mem.span(table.pathOf(original).?.cstr()));
    try std.testing.expectEqual(@as(AssetId, 1), table.count());
}

test "invalid names and paths are rejected and nothing is registered" {
    var table = try Table.init(std.testing.allocator, 4);
    defer table.deinit();

    try std.testing.expectError(error.BadCharacter, table.register("Tile", "assets/tile.png"));
    try std.testing.expectError(error.Absolute, table.register("tile", "/assets/tile.png"));
    try std.testing.expectError(error.BadSegment, table.register("tile", "assets/../tile.png"));
    try std.testing.expectError(error.Empty, table.register("", "assets/tile.png"));
    try std.testing.expectEqual(@as(AssetId, 0), table.count());
    try std.testing.expectEqual(@as(?AssetId, null), table.find("tile"));
}

test "a full table rejects new assets and keeps the existing ones" {
    var table = try Table.init(std.testing.allocator, 2);
    defer table.deinit();

    _ = try table.register("a", "assets/a.png");
    _ = try table.register("b", "assets/b.png");
    try std.testing.expectError(error.Full, table.register("c", "assets/c.png"));
    try std.testing.expectEqual(@as(AssetId, 2), table.count());
    try std.testing.expectEqual(@as(?AssetId, 1), table.find("b"));
    try std.testing.expectEqual(@as(?AssetId, null), table.find("c"));
}

test "path pointers stay valid while more assets are registered" {
    var table = try Table.init(std.testing.allocator, 8);
    defer table.deinit();

    const first = try table.register("first", "assets/first.png");
    const before = table.pathOf(first).?;
    var name_buf: [16]u8 = undefined;
    for (1..8) |i| {
        const name = std.fmt.bufPrint(&name_buf, "extra{d}", .{i}) catch unreachable;
        _ = try table.register(name, "assets/extra.png");
    }
    try std.testing.expectEqual(before, table.pathOf(first).?);
    try std.testing.expectEqualStrings("assets/first.png", before.slice());
}
