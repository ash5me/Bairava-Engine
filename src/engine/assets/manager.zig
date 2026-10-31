//! The asset manager: the registry of asset names, the cache of their values, and the loaders, in
//! one place. `Store(T)` is the piece the engine builds on. Names are registered, values load on
//! first use, and callers hold typed handles to them. The engine's texture store is `Store(Texture)`,
//! created in core/lifecycle.zig and used through the texture functions on core/context.zig.
//!
//! `Store` has no GPU code of its own. The caller supplies the loader, so the store can be tested
//! with a fake one. A store is set up in place (`init` takes a pointer), and it must not move after
//! that, because its cache keeps a pointer to the store's name table.

const std = @import("std");

pub const registry = @import("registry.zig");
pub const cache = @import("cache.zig");
pub const handle = @import("handle.zig");
pub const loaders = struct {
    pub const image = @import("loaders/image.zig");
    pub const atlas = @import("loaders/atlas.zig");
};

/// Registered names, a cache of `T` values, and the typed handles that name them.
pub fn Store(comptime T: type) type {
    return struct {
        const Self = @This();

        /// A typed reference to a value in this store.
        pub const Handle = handle.Handle(T);
        /// How the store loads and frees values. See cache.zig.
        pub const Loader = cache.Cache(T).Loader;
        /// Counters for the store. See cache.zig.
        pub const Stats = cache.Cache(T).Stats;

        table: registry.Table,
        cached: cache.Cache(T),

        /// Sets up the store in place. `capacity` is the most names it can register.
        pub fn init(self: *Self, allocator: std.mem.Allocator, capacity: u32, loader: Loader) !void {
            self.table = try registry.Table.init(allocator, capacity);
            errdefer self.table.deinit();
            self.cached = try cache.Cache(T).init(allocator, &self.table, loader);
        }

        /// Unloads every value and frees the names. Handles still held are invalid afterwards.
        pub fn deinit(self: *Self) void {
            self.cached.deinit();
            self.table.deinit();
            self.* = undefined;
        }

        /// Gives `name` to the asset at `path`. A name is registered once, before its first acquire.
        /// A full store returns `error.Full`, and a name that is taken returns `error.Duplicate`.
        pub fn register(self: *Self, name: []const u8, path: []const u8) registry.Table.Error!void {
            _ = try self.table.register(name, path);
        }

        /// Returns a counted reference to the value called `name`. See `cache.Cache.acquire`.
        pub fn acquire(self: *Self, name: []const u8) !Handle {
            return self.cached.acquire(name);
        }

        /// Adds one counted reference to a live handle. See `cache.Cache.retain`.
        pub fn retain(self: *Self, ref: Handle) handle.LookupError!void {
            return self.cached.retain(ref);
        }

        /// Drops one counted reference and clears `ref`. See `cache.Cache.release`.
        pub fn release(self: *Self, ref: *Handle) handle.LookupError!void {
            return self.cached.release(ref);
        }

        /// The value `ref` names. See `cache.Cache.get`.
        pub fn get(self: *const Self, ref: Handle) handle.LookupError!*const T {
            return self.cached.get(ref);
        }

        /// Unloads the values that no handle holds, and returns how many were unloaded.
        pub fn unloadUnused(self: *Self) usize {
            return self.cached.unloadUnused();
        }

        /// The store's counters.
        pub fn stats(self: *const Self) Stats {
            return self.cached.stats();
        }
    };
}

/// A loader for the store tests. Each load returns the number of loads so far. Paths that end in
/// `broken.png` fail to load.
const FakeLoader = struct {
    loads: u32 = 0,
    unloads: u32 = 0,

    fn load(context: *anyopaque, path: []const u8) anyerror!u32 {
        const self: *FakeLoader = @ptrCast(@alignCast(context));
        if (std.mem.endsWith(u8, path, "broken.png")) return error.DecodeFailed;
        self.loads += 1;
        return self.loads;
    }

    fn unload(context: *anyopaque, value: *u32) void {
        const self: *FakeLoader = @ptrCast(@alignCast(context));
        self.unloads += 1;
        value.* = 0;
    }
};

const TestStore = Store(u32);

fn initTestStore(store: *TestStore, source: *FakeLoader) !void {
    try store.init(std.testing.allocator, 4, .{
        .context = source,
        .load = &FakeLoader.load,
        .unload = &FakeLoader.unload,
    });
}

test "a store registers names and shares one value per name" {
    var source = FakeLoader{};
    var store: TestStore = undefined;
    try initTestStore(&store, &source);
    defer store.deinit();

    try store.register("tile", "assets/tile.png");
    try store.register("warrior", "assets/warrior.png");

    var a = try store.acquire("tile");
    var b = try store.acquire("tile");
    try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(@as(u32, 1), source.loads);
    try std.testing.expectEqual(@as(u32, 1), (try store.get(a)).*);

    try store.release(&a);
    try store.release(&b);
}

test "a store rejects duplicate names, and reports names it doesn't have" {
    var source = FakeLoader{};
    var store: TestStore = undefined;
    try initTestStore(&store, &source);
    defer store.deinit();

    try store.register("tile", "assets/tile.png");
    try std.testing.expectError(error.Duplicate, store.register("tile", "assets/other.png"));
    try std.testing.expectError(error.UnknownAsset, store.acquire("missing"));
    try std.testing.expectEqual(@as(u32, 0), source.loads);
}

test "a load the loader rejects is returned to the caller, and nothing stays loaded" {
    var source = FakeLoader{};
    var store: TestStore = undefined;
    try initTestStore(&store, &source);
    defer store.deinit();

    try store.register("broken", "assets/broken.png");
    try std.testing.expectError(error.DecodeFailed, store.acquire("broken"));
    try std.testing.expectEqual(@as(usize, 0), store.stats().loaded);
    try std.testing.expectEqual(@as(u64, 1), store.stats().failed_loads);
}

test "unloadUnused through the store frees only unreferenced values" {
    var source = FakeLoader{};
    var store: TestStore = undefined;
    try initTestStore(&store, &source);
    defer store.deinit();

    try store.register("tile", "assets/tile.png");
    try store.register("warrior", "assets/warrior.png");

    var idle = try store.acquire("tile");
    var held = try store.acquire("warrior");
    try store.release(&idle);

    try std.testing.expectEqual(@as(usize, 1), store.unloadUnused());
    try std.testing.expectEqual(@as(u32, 2), (try store.get(held)).*);
    try store.release(&held);
}

test "deinit unloads values that are still held" {
    var source = FakeLoader{};
    var store: TestStore = undefined;
    try initTestStore(&store, &source);

    try store.register("tile", "assets/tile.png");
    _ = try store.acquire("tile");
    store.deinit();
    try std.testing.expectEqual(@as(u32, 1), source.unloads);
}

test "stores for different value types have different handle types" {
    try std.testing.expect(Store(u32).Handle != Store(f32).Handle);
}
