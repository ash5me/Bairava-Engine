//! Asset cache: loads each asset once, shares it between users, and unloads unused assets on
//! request.
//!
//! Assets are looked up by name. `assets.zig` maps each registered name to its validated path, and
//! the cache keeps loaded values in a `hash_map.StringMap` keyed by that name. Names are
//! fixed-capacity and stored inline, so an insert doesn't allocate for its key. Each entry is its
//! own heap allocation, so a `Ref` stays valid until its entry is unloaded, even as the index grows.
//!
//! Users hold counted references. `acquire` adds one, and `Entry.release` drops one. An entry with
//! no references stays cached until `unloadUnused` or `deinit` frees it, so a value needed again
//! soon isn't loaded twice.
//!
//! The cache is generic, so tests use a fake loader and need no GPU. Nothing in this file imports
//! SDL or the logger. The cache isn't thread-safe. The `assets.Table` it reads must outlive it.

const std = @import("std");
const assets = @import("assets.zig");
const hash_map = @import("hash_map.zig");
const strings = @import("string.zig");

/// A cache of values of type `T`, loaded through a `Loader` that the caller supplies.
pub fn Cache(comptime T: type) type {
    return struct {
        const Self = @This();

        /// How the cache loads and frees values. The cache stores these pointers, so `context` must
        /// stay valid for as long as the cache does.
        pub const Loader = struct {
            /// Passed to `load` and `unload` unchanged.
            context: *anyopaque,
            /// Loads the asset at `path`, which is relative to the executable's folder. The cache owns
            /// the value it returns.
            load: *const fn (context: *anyopaque, path: []const u8) anyerror!T,
            /// Frees a value that `load` returned. Called once for each loaded value.
            unload: *const fn (context: *anyopaque, value: *T) void,
        };

        /// One loaded value and its reference count.
        pub const Entry = struct {
            name: strings.Name,
            /// How many users hold this entry. Zero means it is cached but unused.
            refs: u32,
            value: T,
            prev: ?*Entry,
            next: ?*Entry,

            /// Drops one reference. Call it once for each successful `acquire`.
            pub fn release(self: *Entry) void {
                if (self.refs == 0) {
                    std.debug.panic("asset '{s}' was released more times than it was acquired", .{self.name.slice()});
                }
                self.refs -= 1;
            }
        };

        /// A counted reference to a cached value. Read the value through `.value`, and release it
        /// with `Entry.release`.
        pub const Ref = *Entry;

        allocator: std.mem.Allocator,
        table: *const assets.Table,
        loader: Loader,
        /// Loaded entries by name. The values are pointers to heap entries, so growing the index
        /// never moves an entry that a `Ref` points to.
        index: hash_map.StringMap(*Entry),
        /// Every entry, newest first. Walking the list visits each entry once, and unlinking an
        /// entry during the walk doesn't break it, because the next entry is read first.
        head: ?*Entry = null,

        /// Creates an empty cache over the names in `table`. Values load on their first `acquire`.
        pub fn init(allocator: std.mem.Allocator, table: *const assets.Table, loader: Loader) std.mem.Allocator.Error!Self {
            const index = try hash_map.StringMap(*Entry).init(allocator, 0);
            return .{ .allocator = allocator, .table = table, .loader = loader, .index = index };
        }

        /// Frees every value and the index, whether or not it is still referenced. Release references
        /// before calling this, because any `Ref` still held is invalid afterward.
        pub fn deinit(self: *Self) void {
            var cursor = self.head;
            while (cursor) |entry| {
                cursor = entry.next;
                self.loader.unload(self.loader.context, &entry.value);
                self.allocator.destroy(entry);
            }
            self.index.deinit();
            self.* = undefined;
        }

        /// Returns a reference to the asset `name`, loading it first if the cache doesn't hold it
        /// yet. Each successful call adds one reference, so each call needs a matching
        /// `Entry.release`. Fails with `error.UnknownAsset` if the table has no such name, and with
        /// the name's validation error if the name is malformed. A failed call changes nothing.
        pub fn acquire(self: *Self, name: []const u8) !Ref {
            const key = try strings.Name.init(name);
            if (self.index.get(key.slice())) |found| {
                found.refs += 1;
                return found;
            }

            const id = self.table.find(key.slice()) orelse return error.UnknownAsset;
            const path = self.table.pathOf(id) orelse return error.UnknownAsset;

            var value = try self.loader.load(self.loader.context, path.slice());
            errdefer self.loader.unload(self.loader.context, &value);

            const entry = try self.allocator.create(Entry);
            errdefer self.allocator.destroy(entry);
            entry.* = .{ .name = key, .refs = 1, .value = value, .prev = null, .next = null };

            try self.index.insert(key.slice(), entry);
            self.linkFront(entry);
            return entry;
        }

        /// Unloads every entry with no references and returns how many were unloaded. Referenced
        /// entries stay loaded. An unreferenced entry has no `Ref` pointing at it, so unloading it
        /// can't leave one dangling.
        pub fn unloadUnused(self: *Self) usize {
            var unloaded: usize = 0;
            var cursor = self.head;
            while (cursor) |entry| {
                cursor = entry.next;
                if (entry.refs != 0) continue;
                self.unloadEntry(entry);
                unloaded += 1;
            }
            return unloaded;
        }

        /// The number of cached entries, referenced or not.
        pub fn count(self: *const Self) usize {
            return self.index.count();
        }

        fn unloadEntry(self: *Self, entry: *Entry) void {
            _ = self.index.remove(entry.name.slice());
            self.unlink(entry);
            self.loader.unload(self.loader.context, &entry.value);
            self.allocator.destroy(entry);
        }

        fn linkFront(self: *Self, entry: *Entry) void {
            entry.prev = null;
            entry.next = self.head;
            if (self.head) |first| first.prev = entry;
            self.head = entry;
        }

        fn unlink(self: *Self, entry: *Entry) void {
            if (entry.prev) |prev| prev.next = entry.next else self.head = entry.next;
            if (entry.next) |next| next.prev = entry.prev;
        }
    };
}

/// A loader for tests. It counts loads and unloads, records the last path it was asked for, and
/// can be told to fail the next load.
const FakeSource = struct {
    loads: u32 = 0,
    unloads: u32 = 0,
    fail_next: bool = false,
    last_path: []const u8 = "",

    /// Each successful load returns the number of loads so far, so a value identifies which load
    /// produced it.
    fn load(context: *anyopaque, path: []const u8) anyerror!u32 {
        const self: *FakeSource = @ptrCast(@alignCast(context));
        if (self.fail_next) {
            self.fail_next = false;
            return error.DecodeFailed;
        }
        self.loads += 1;
        self.last_path = path;
        return self.loads;
    }

    fn unload(context: *anyopaque, value: *u32) void {
        const self: *FakeSource = @ptrCast(@alignCast(context));
        self.unloads += 1;
        value.* = 0;
    }
};

const Cached = Cache(u32);

fn fakeCache(allocator: std.mem.Allocator, table: *const assets.Table, source: *FakeSource) std.mem.Allocator.Error!Cached {
    return Cached.init(allocator, table, .{
        .context = source,
        .load = &FakeSource.load,
        .unload = &FakeSource.unload,
    });
}

fn registerTestAssets(table: *assets.Table) !void {
    _ = try table.register("tile", "assets/tile.png");
    _ = try table.register("warrior", "assets/warrior_16x32.png");
    _ = try table.register("ui/button", "assets/ui/button.png");
}

test "the first acquire loads and later acquires share the same entry" {
    var table = try assets.Table.init(std.testing.allocator, 8);
    defer table.deinit();
    try registerTestAssets(&table);

    var source = FakeSource{};
    var cache = try fakeCache(std.testing.allocator, &table, &source);
    defer cache.deinit();

    const first = try cache.acquire("tile");
    const second = try cache.acquire("tile");
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(u32, 1), source.loads);
    try std.testing.expectEqual(@as(u32, 2), first.refs);
    try std.testing.expectEqual(@as(u32, 1), first.value);
    try std.testing.expectEqual(@as(usize, 1), cache.count());

    first.release();
    second.release();
}

test "each name loads the path it was registered with" {
    var table = try assets.Table.init(std.testing.allocator, 8);
    defer table.deinit();
    try registerTestAssets(&table);

    var source = FakeSource{};
    var cache = try fakeCache(std.testing.allocator, &table, &source);
    defer cache.deinit();

    const tile = try cache.acquire("tile");
    try std.testing.expectEqualStrings("assets/tile.png", source.last_path);
    const warrior = try cache.acquire("warrior");
    try std.testing.expectEqualStrings("assets/warrior_16x32.png", source.last_path);

    try std.testing.expect(tile != warrior);
    try std.testing.expectEqual(@as(u32, 2), source.loads);
    try std.testing.expectEqual(@as(u32, 2), warrior.value);
    try std.testing.expectEqual(@as(usize, 2), cache.count());

    tile.release();
    warrior.release();
}

test "a released asset stays cached until unloadUnused removes it" {
    var table = try assets.Table.init(std.testing.allocator, 8);
    defer table.deinit();
    try registerTestAssets(&table);

    var source = FakeSource{};
    var cache = try fakeCache(std.testing.allocator, &table, &source);
    defer cache.deinit();

    const first = try cache.acquire("tile");
    first.release();

    // Released but still cached, so this is a hit and loads nothing.
    const again = try cache.acquire("tile");
    try std.testing.expectEqual(@as(u32, 1), source.loads);
    again.release();

    try std.testing.expectEqual(@as(usize, 1), cache.unloadUnused());
    try std.testing.expectEqual(@as(u32, 1), source.unloads);
    try std.testing.expectEqual(@as(usize, 0), cache.count());

    // After it was unloaded, the next acquire loads it again.
    const reloaded = try cache.acquire("tile");
    try std.testing.expectEqual(@as(u32, 2), source.loads);
    reloaded.release();
}

test "unloadUnused keeps referenced assets, and they stay findable" {
    var table = try assets.Table.init(std.testing.allocator, 8);
    defer table.deinit();
    try registerTestAssets(&table);

    var source = FakeSource{};
    var cache = try fakeCache(std.testing.allocator, &table, &source);
    defer cache.deinit();

    const held = try cache.acquire("tile");
    const idle = try cache.acquire("warrior");
    idle.release();

    try std.testing.expectEqual(@as(usize, 1), cache.unloadUnused());
    try std.testing.expectEqual(@as(usize, 1), cache.count());
    try std.testing.expectEqual(@as(u32, 1), source.unloads);

    // The held entry is still in the index, so this is a hit and not a reload.
    const again = try cache.acquire("tile");
    try std.testing.expectEqual(held, again);
    try std.testing.expectEqual(@as(u32, 2), source.loads);

    again.release();
    held.release();
}

test "a failed load leaves the cache unchanged" {
    var table = try assets.Table.init(std.testing.allocator, 8);
    defer table.deinit();
    try registerTestAssets(&table);

    var source = FakeSource{ .fail_next = true };
    var cache = try fakeCache(std.testing.allocator, &table, &source);
    defer cache.deinit();

    try std.testing.expectError(error.DecodeFailed, cache.acquire("tile"));
    try std.testing.expectEqual(@as(usize, 0), cache.count());
    try std.testing.expectEqual(@as(u32, 0), source.loads);

    // The failure didn't count as a load, so the next success is load number one.
    const ok = try cache.acquire("tile");
    try std.testing.expectEqual(@as(u32, 1), ok.value);
    ok.release();
}

test "unknown and malformed names are rejected before anything is loaded" {
    var table = try assets.Table.init(std.testing.allocator, 8);
    defer table.deinit();
    try registerTestAssets(&table);

    var source = FakeSource{};
    var cache = try fakeCache(std.testing.allocator, &table, &source);
    defer cache.deinit();

    try std.testing.expectError(error.UnknownAsset, cache.acquire("missing"));
    try std.testing.expectError(error.BadCharacter, cache.acquire("Tile"));
    try std.testing.expectError(error.Empty, cache.acquire(""));
    try std.testing.expectEqual(@as(u32, 0), source.loads);
    try std.testing.expectEqual(@as(usize, 0), cache.count());
}

test "deinit unloads every value, including referenced ones" {
    var table = try assets.Table.init(std.testing.allocator, 8);
    defer table.deinit();
    try registerTestAssets(&table);

    var source = FakeSource{};
    var cache = try fakeCache(std.testing.allocator, &table, &source);

    _ = try cache.acquire("tile");
    _ = try cache.acquire("warrior");
    cache.deinit();
    try std.testing.expectEqual(@as(u32, 2), source.unloads);
}

test "many assets: bulk unload keeps the rest reachable" {
    var table = try assets.Table.init(std.testing.allocator, 300);
    defer table.deinit();

    var source = FakeSource{};
    var cache = try fakeCache(std.testing.allocator, &table, &source);
    defer cache.deinit();

    var name_buf: [16]u8 = undefined;
    var path_buf: [32]u8 = undefined;
    var names: [300]strings.Name = undefined;
    var refs: [300]Cached.Ref = undefined;
    for (0..300) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "frame{d:0>3}", .{i});
        const path = try std.fmt.bufPrint(&path_buf, "assets/frame{d:0>3}.png", .{i});
        _ = try table.register(name, path);
        names[i] = try strings.Name.init(name);
        refs[i] = try cache.acquire(name);
    }

    for (refs, 0..) |ref, i| {
        try std.testing.expectEqual(@as(u32, @intCast(i + 1)), ref.value);
    }
    try std.testing.expectEqual(@as(usize, 300), cache.count());

    // Release the even half and unload it. Removing those index entries must not disturb the odd
    // half, which is still referenced.
    for (refs, 0..) |ref, i| {
        if (i % 2 == 0) ref.release();
    }
    try std.testing.expectEqual(@as(usize, 150), cache.unloadUnused());
    try std.testing.expectEqual(@as(usize, 150), cache.count());

    // The held half is still a hit, so it doesn't reload.
    for (refs, 0..) |ref, i| {
        if (i % 2 == 0) continue;
        const again = try cache.acquire(names[i].slice());
        try std.testing.expectEqual(ref, again);
        again.release();
    }
    try std.testing.expectEqual(@as(u32, 300), source.loads);

    // The released half loads again on its next acquire.
    for (names, 0..) |name, i| {
        if (i % 2 != 0) continue;
        const reloaded = try cache.acquire(name.slice());
        reloaded.release();
    }
    try std.testing.expectEqual(@as(u32, 450), source.loads);
    try std.testing.expectEqual(@as(usize, 300), cache.count());

    // Release the rest, then unload everything. Every load has now been matched by an unload.
    for (refs, 0..) |ref, i| {
        if (i % 2 != 0) ref.release();
    }
    try std.testing.expectEqual(@as(usize, 300), cache.unloadUnused());
    try std.testing.expectEqual(@as(usize, 0), cache.count());
    try std.testing.expectEqual(source.loads, source.unloads);
}
