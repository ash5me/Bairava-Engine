//! Asset cache: loads each registered asset once, hands out typed handles to it, and unloads
//! values nobody holds when asked.
//!
//! The cache is generic over the value type `T`. The caller supplies a `Loader` that turns a path
//! into a `T` and frees a `T` again, so tests use a fake loader and need no GPU.
//!
//! Storage is one slot per id the registry table can issue, allocated once in `init`. A handle is an
//! index and a generation (see handle.zig), so the cache never reallocates, never keeps a pointer
//! into itself, and no handle is invalidated by growth. Acquiring a value that isn't loaded
//! allocates nothing.
//!
//! Keys: an asset is identified by its name. The name maps to one id and one validated path, and the
//! cache's value type completes the key. Each `Cache(T)` holds only `T` values, so one name can't be
//! cached under two types.
//!
//! Lifetime: `acquire` and `retain` add a counted reference, and `release` drops one. A value with no
//! references stays loaded until `unloadUnused` or `deinit`, so a value needed again soon isn't
//! loaded twice. Unloading a value bumps its slot's generation, so every handle to the old load
//! becomes stale and is rejected.
//!
//! Failures: a load the loader rejects changes nothing and is counted in `Stats.failed_loads`. A
//! malformed or unregistered name is rejected before anything is loaded.
//!
//! Budget: `setBudget` caps the bytes the cache holds. A load that would go over the cap first unloads the
//! least recently used idle values. A referenced value is never unloaded to make room, so the cache can stay
//! over budget while everything it holds is in use. `Stats.over_budget` counts those times.
//!
//! Preloading: `request` marks an unloaded asset as wanted at a `Priority`, and `pump` loads wanted assets,
//! highest priority first, up to a limit per call. A preloaded value holds no reference, so it can be unloaded
//! if nothing acquires it. Loads are still synchronous. `pump` only spreads them across calls.
//!
//! The cache isn't thread-safe. The table it reads must outlive it and must not move after `init`,
//! because the cache keeps a pointer to it.

const std = @import("std");
const assets = @import("registry.zig");
const handle = @import("handle.zig");
const strings = @import("../memory/string.zig");

/// Why a handle can't be used. See handle.zig.
pub const LookupError = handle.LookupError;

/// How urgently a requested asset loads. `pump` loads higher priorities first. Slots store these values, so 0
/// means nothing has requested the asset.
pub const Priority = enum(u8) { low = 1, normal = 2, high = 3 };

/// What one `pump` did: how many requested values loaded, and how many failed to load.
pub const PumpResult = struct { loaded: usize = 0, failed: usize = 0 };

/// A cache of values of type `T`, loaded through a `Loader` that the caller supplies.
pub fn Cache(comptime T: type) type {
    return struct {
        const Self = @This();

        /// A typed reference to a value in this cache.
        pub const Handle = handle.Handle(T);

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
            /// Optional. Reports a loaded value's size in bytes, for `Stats.bytes`. Null counts every
            /// value as zero bytes.
            size: ?*const fn (value: *const T) usize = null,
        };

        /// Counters for logs and for checking the cache.
        pub const Stats = struct {
            /// Acquires that found their value already loaded.
            hits: u64 = 0,
            /// Acquires of a name that wasn't loaded. Some of these went on to fail; see `failed_loads`.
            misses: u64 = 0,
            /// Loads the loader rejected. Nothing was cached for these.
            failed_loads: u64 = 0,
            /// Values unloaded by `unloadUnused`, by the budget, or by `deinit`.
            unloads: u64 = 0,
            /// Times the cache was left over its budget, because every value it still held was referenced.
            over_budget: u64 = 0,
            /// Values loaded right now, referenced or not.
            loaded: usize = 0,
            /// Sum of the sizes that `Loader.size` reported for the loaded values.
            bytes: usize = 0,
        };

        /// One slot per id. A slot holds a value only while `loaded` is true.
        const Slot = struct {
            /// Identifies the current load. It advances every time the value is unloaded, and it is
            /// never 0, so the default handle matches nothing.
            generation: u32 = 1,
            loaded: bool = false,
            /// Counted references to this load. Zero means cached but unused.
            refs: u32 = 0,
            bytes: usize = 0,
            /// The request for this value as a `Priority`, or 0 when nothing has asked for it. A load clears it.
            pending: u8 = 0,
            /// The use clock's value when the value was last loaded or acquired. Budget eviction unloads the
            /// smallest value first, so the least recently used idle value goes first.
            last_use: u64 = 0,
            value: T = undefined,
        };

        allocator: std.mem.Allocator,
        table: *const assets.Table,
        loader: Loader,
        slots: []Slot,
        counts: Stats = .{},
        /// Most bytes the cache holds before it unloads idle values. Zero means no budget.
        budget_bytes: usize = 0,
        /// Advances on every load and acquire, and stamps each slot with its use order.
        clock: u64 = 0,

        /// Creates an empty cache over the names in `table`. Values load on their first acquire. The
        /// slots cover the table's whole capacity, so names registered later still have a slot.
        pub fn init(allocator: std.mem.Allocator, table: *const assets.Table, loader: Loader) std.mem.Allocator.Error!Self {
            const slots = try allocator.alloc(Slot, table.maxAssets());
            for (slots) |*slot| slot.* = .{};
            return .{ .allocator = allocator, .table = table, .loader = loader, .slots = slots };
        }

        /// Unloads every value, referenced or not, and frees the slots. A handle still held after this
        /// is invalid, so release handles before calling it.
        pub fn deinit(self: *Self) void {
            for (self.slots) |*slot| {
                if (slot.loaded) self.unloadSlot(slot);
            }
            self.allocator.free(self.slots);
            self.* = undefined;
        }

        /// Returns a counted reference to the asset `name`, loading it first if it isn't loaded. Each
        /// successful call needs one `release`. A malformed name fails with its validation error, and a
        /// name the table doesn't have fails with `error.UnknownAsset`. A rejected load returns the
        /// loader's error. A failed call changes nothing.
        pub fn acquire(self: *Self, name: []const u8) !Handle {
            const checked = try strings.Name.init(name);
            const id = self.table.find(checked.slice()) orelse return error.UnknownAsset;
            return self.acquireId(id);
        }

        fn acquireId(self: *Self, id: assets.AssetId) !Handle {
            if (id >= self.slots.len) return error.UnknownAsset;
            const slot = &self.slots[id];
            if (slot.loaded) {
                self.counts.hits += 1;
                slot.refs += 1;
                slot.last_use = self.touch();
                return .{ .id = id, .generation = slot.generation };
            }

            try self.loadSlot(id);
            slot.refs = 1;
            return .{ .id = id, .generation = slot.generation };
        }

        /// Adds one counted reference to a live handle, so a second holder can release its own
        /// reference. Fails if the handle is invalid or stale.
        pub fn retain(self: *Self, ref: Handle) LookupError!void {
            const slot = try slotFor(self.slots, ref);
            slot.refs += 1;
        }

        /// Drops one counted reference, and clears `ref` so the same variable can't release twice.
        /// Fails with `error.InvalidHandle` for a cleared or never-issued handle, and with
        /// `error.StaleHandle` for one whose value was unloaded. Both leave the cache unchanged.
        /// Releasing more often than the handle was acquired or retained is a bug in the caller, and
        /// it panics.
        pub fn release(self: *Self, ref: *Handle) LookupError!void {
            const slot = try slotFor(self.slots, ref.*);
            if (slot.refs == 0) {
                std.debug.panic("asset {d} was released more times than it was acquired", .{ref.id});
            }
            slot.refs -= 1;
            ref.* = Handle.invalid;
        }

        /// The value `ref` names. The pointer stays valid while the value is loaded, because the slots
        /// never move. Keep it only while the handle holds a reference.
        pub fn get(self: *const Self, ref: Handle) LookupError!*const T {
            const slot = try slotFor(self.slots, ref);
            return &slot.value;
        }

        /// Unloads every loaded value that has no references, and returns how many were unloaded.
        /// Referenced values stay loaded, and their handles stay valid.
        pub fn unloadUnused(self: *Self) usize {
            var unloaded: usize = 0;
            for (self.slots) |*slot| {
                if (slot.loaded and slot.refs == 0) {
                    self.unloadSlot(slot);
                    unloaded += 1;
                }
            }
            return unloaded;
        }

        /// Sets the byte budget. Zero removes it. Lowering it unloads idle values at once, least recently used first,
        /// until the cache fits or only referenced values are left.
        pub fn setBudget(self: *Self, bytes: usize) void {
            self.budget_bytes = bytes;
            self.enforceBudget(null);
        }

        /// Marks the asset `name` as wanted at `priority`, so a later `pump` loads it. A value that is already
        /// loaded needs nothing, so the request is ignored. Asking again keeps the higher priority. A malformed
        /// or unregistered name fails the way `acquire` does, and changes nothing.
        pub fn request(self: *Self, name: []const u8, priority: Priority) !void {
            const checked = try strings.Name.init(name);
            const id = self.table.find(checked.slice()) orelse return error.UnknownAsset;
            if (id >= self.slots.len) return error.UnknownAsset;
            const slot = &self.slots[id];
            if (slot.loaded) return;
            slot.pending = @max(slot.pending, @intFromEnum(priority));
        }

        /// Loads up to `max_loads` requested values, highest priority first, and the lower id first on a tie.
        /// A preloaded value holds no reference, so it stays cached only until something acquires it or
        /// `unloadUnused` runs. A request whose load fails is dropped, so a bad asset is not retried on every call.
        pub fn pump(self: *Self, max_loads: usize) PumpResult {
            var result = PumpResult{};
            while (result.loaded + result.failed < max_loads) {
                const id = self.nextRequest() orelse break;
                if (self.loadSlot(id)) |_| {
                    result.loaded += 1;
                } else |_| {
                    result.failed += 1;
                }
            }
            return result;
        }

        /// The requested, unloaded slot with the highest priority, or null when nothing is requested.
        fn nextRequest(self: *const Self) ?assets.AssetId {
            var best: ?assets.AssetId = null;
            for (self.slots, 0..) |slot, i| {
                if (slot.pending == 0 or slot.loaded) continue;
                if (best) |chosen| {
                    if (slot.pending <= self.slots[chosen].pending) continue;
                }
                best = @as(assets.AssetId, @intCast(i));
            }
            return best;
        }

        /// Loads slot `id` without taking a reference, and clears its request. A failed load is counted and
        /// returned, and changes nothing. A successful load may unload idle values to stay within the budget,
        /// but never the value it just loaded.
        fn loadSlot(self: *Self, id: assets.AssetId) !void {
            const slot = &self.slots[id];
            slot.pending = 0;
            self.counts.misses += 1;
            const path = self.table.pathOf(id) orelse return error.UnknownAsset;
            const value = self.loader.load(self.loader.context, path.slice()) catch |err| {
                self.counts.failed_loads += 1;
                return err;
            };
            slot.value = value;
            slot.loaded = true;
            slot.refs = 0;
            slot.bytes = if (self.loader.size) |measure| measure(&slot.value) else 0;
            slot.last_use = self.touch();
            self.counts.loaded += 1;
            self.counts.bytes += slot.bytes;
            self.enforceBudget(id);
        }

        /// Advances the use clock and returns the new value. Each slot records it when the slot is loaded or
        /// acquired, so the smallest recorded value belongs to the least recently used slot.
        fn touch(self: *Self) u64 {
            self.clock += 1;
            return self.clock;
        }

        /// Unloads idle values, least recently used first, until the cache is within its budget. `keep` names a
        /// value that must stay, such as the one just loaded. Referenced values are never unloaded, so when none
        /// is idle the cache can stay over budget, and that is counted in `over_budget`.
        fn enforceBudget(self: *Self, keep: ?assets.AssetId) void {
            if (self.budget_bytes == 0) return;
            while (self.counts.bytes > self.budget_bytes) {
                const victim = self.leastRecentlyUsedIdle(keep) orelse {
                    self.counts.over_budget += 1;
                    return;
                };
                self.unloadSlot(&self.slots[victim]);
            }
        }

        /// The loaded, unreferenced slot used least recently, other than `keep`. Null when there is none.
        fn leastRecentlyUsedIdle(self: *const Self, keep: ?assets.AssetId) ?assets.AssetId {
            var best: ?assets.AssetId = null;
            for (self.slots, 0..) |slot, i| {
                if (!slot.loaded or slot.refs != 0) continue;
                const id: assets.AssetId = @intCast(i);
                if (keep) |kept| {
                    if (kept == id) continue;
                }
                if (best) |chosen| {
                    if (slot.last_use >= self.slots[chosen].last_use) continue;
                }
                best = id;
            }
            return best;
        }

        /// The number of values loaded right now, referenced or not.
        pub fn count(self: *const Self) usize {
            return self.counts.loaded;
        }

        /// The current counters.
        pub fn stats(self: *const Self) Stats {
            return self.counts;
        }

        fn unloadSlot(self: *Self, slot: *Slot) void {
            self.loader.unload(self.loader.context, &slot.value);
            self.counts.unloads += 1;
            self.counts.loaded -= 1;
            self.counts.bytes -= slot.bytes;
            slot.loaded = false;
            slot.refs = 0;
            slot.bytes = 0;
            slot.generation = handle.nextGeneration(slot.generation);
        }

        fn slotFor(slots: []Slot, ref: Handle) LookupError!*Slot {
            if (ref.generation == 0 or ref.id >= slots.len) return error.InvalidHandle;
            const slot = &slots[ref.id];
            if (!slot.loaded or slot.generation != ref.generation) return error.StaleHandle;
            return slot;
        }
    };
}

/// A loader for tests. It counts loads and unloads, records the last path it was asked for, can be
/// told to fail the next load, and reports every value as 100 bytes.
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

    fn size(value: *const u32) usize {
        _ = value;
        return 100;
    }
};

const Cached = Cache(u32);

fn fakeCache(allocator: std.mem.Allocator, table: *const assets.Table, source: *FakeSource) std.mem.Allocator.Error!Cached {
    return Cached.init(allocator, table, .{
        .context = source,
        .load = &FakeSource.load,
        .unload = &FakeSource.unload,
        .size = &FakeSource.size,
    });
}

fn registerTestAssets(table: *assets.Table) !void {
    _ = try table.register("tile", "assets/tile.png");
    _ = try table.register("warrior", "assets/warrior_16x32.png");
    _ = try table.register("ui/button", "assets/ui/button.png");
}

test "the first acquire loads and later acquires share the same value" {
    var table = try assets.Table.init(std.testing.allocator, 8);
    defer table.deinit();
    try registerTestAssets(&table);

    var source = FakeSource{};
    var cache = try fakeCache(std.testing.allocator, &table, &source);
    defer cache.deinit();

    var first = try cache.acquire("tile");
    var second = try cache.acquire("tile");
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(u32, 1), source.loads);
    try std.testing.expectEqual(@as(u32, 1), (try cache.get(first)).*);
    try std.testing.expectEqual(@as(u32, 2), cache.slots[first.id].refs);
    try std.testing.expectEqual(@as(usize, 1), cache.count());

    try cache.release(&first);
    try cache.release(&second);
}

test "each name loads the path it was registered with" {
    var table = try assets.Table.init(std.testing.allocator, 8);
    defer table.deinit();
    try registerTestAssets(&table);

    var source = FakeSource{};
    var cache = try fakeCache(std.testing.allocator, &table, &source);
    defer cache.deinit();

    var tile = try cache.acquire("tile");
    try std.testing.expectEqualStrings("assets/tile.png", source.last_path);
    var warrior = try cache.acquire("warrior");
    try std.testing.expectEqualStrings("assets/warrior_16x32.png", source.last_path);

    try std.testing.expect(tile.id != warrior.id);
    try std.testing.expectEqual(@as(u32, 2), source.loads);
    try std.testing.expectEqual(@as(u32, 2), (try cache.get(warrior)).*);
    try cache.release(&tile);
    try cache.release(&warrior);
}

test "a released asset stays cached until unloadUnused, and a handle kept past its unload is stale" {
    var table = try assets.Table.init(std.testing.allocator, 8);
    defer table.deinit();
    try registerTestAssets(&table);

    var source = FakeSource{};
    var cache = try fakeCache(std.testing.allocator, &table, &source);
    defer cache.deinit();

    var first = try cache.acquire("tile");
    const kept = first;
    try cache.release(&first);

    // Released but still cached, so this is a hit and loads nothing.
    var again = try cache.acquire("tile");
    try std.testing.expectEqual(@as(u32, 1), source.loads);
    try cache.release(&again);

    try std.testing.expectEqual(@as(usize, 1), cache.unloadUnused());
    try std.testing.expectEqual(@as(u32, 1), source.unloads);
    try std.testing.expectEqual(@as(usize, 0), cache.count());
    try std.testing.expectError(error.StaleHandle, cache.get(kept));

    // The next acquire loads again, under a new generation.
    var reloaded = try cache.acquire("tile");
    try std.testing.expectEqual(@as(u32, 2), source.loads);
    try std.testing.expect(reloaded.generation != kept.generation);
    try cache.release(&reloaded);
}

test "unloadUnused keeps referenced assets, and their handles stay valid" {
    var table = try assets.Table.init(std.testing.allocator, 8);
    defer table.deinit();
    try registerTestAssets(&table);

    var source = FakeSource{};
    var cache = try fakeCache(std.testing.allocator, &table, &source);
    defer cache.deinit();

    var held = try cache.acquire("tile");
    var idle = try cache.acquire("warrior");
    try cache.release(&idle);

    try std.testing.expectEqual(@as(usize, 1), cache.unloadUnused());
    try std.testing.expectEqual(@as(usize, 1), cache.count());
    try std.testing.expectEqual(@as(u32, 1), source.unloads);

    // The held value is still loaded, so its handle works and this acquire is a hit.
    var again = try cache.acquire("tile");
    try std.testing.expectEqual(held, again);
    try std.testing.expectEqual(@as(u32, 2), source.loads);
    try std.testing.expectEqual(@as(u32, 1), (try cache.get(held)).*);

    try cache.release(&again);
    try cache.release(&held);
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
    try std.testing.expectEqual(@as(u64, 1), cache.stats().failed_loads);

    // The failure cached nothing, so the next success is load number one.
    var ok = try cache.acquire("tile");
    try std.testing.expectEqual(@as(u32, 1), (try cache.get(ok)).*);
    try cache.release(&ok);
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
    try std.testing.expectEqual(@as(u64, 0), cache.stats().misses);
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

test "a stale handle is rejected, and releasing it leaves the new holder's reference alone" {
    var table = try assets.Table.init(std.testing.allocator, 8);
    defer table.deinit();
    try registerTestAssets(&table);

    var source = FakeSource{};
    var cache = try fakeCache(std.testing.allocator, &table, &source);
    defer cache.deinit();

    var first = try cache.acquire("tile");
    var stale = first;
    try cache.release(&first);
    try std.testing.expectEqual(@as(usize, 1), cache.unloadUnused());

    var newcomer = try cache.acquire("tile");
    try std.testing.expectError(error.StaleHandle, cache.release(&stale));
    try std.testing.expectEqual(@as(u32, 1), cache.slots[newcomer.id].refs);
    try std.testing.expect(stale.generation != newcomer.generation);

    try cache.release(&newcomer);
    try std.testing.expectEqual(@as(u32, 0), cache.slots[newcomer.id].refs);
}

test "a released handle is cleared, so releasing it again is caught" {
    var table = try assets.Table.init(std.testing.allocator, 8);
    defer table.deinit();
    try registerTestAssets(&table);

    var source = FakeSource{};
    var cache = try fakeCache(std.testing.allocator, &table, &source);
    defer cache.deinit();

    var h = try cache.acquire("tile");
    try cache.release(&h);
    try std.testing.expectEqual(Cached.Handle.invalid, h);
    try std.testing.expectError(error.InvalidHandle, cache.release(&h));
    try std.testing.expectError(error.InvalidHandle, cache.get(Cached.Handle.invalid));
}

test "retain adds a reference, so a value stays loaded until every holder releases it" {
    var table = try assets.Table.init(std.testing.allocator, 8);
    defer table.deinit();
    try registerTestAssets(&table);

    var source = FakeSource{};
    var cache = try fakeCache(std.testing.allocator, &table, &source);
    defer cache.deinit();

    var a = try cache.acquire("tile");
    try cache.retain(a);
    var b = a;

    try std.testing.expectEqual(@as(usize, 0), cache.unloadUnused());
    try cache.release(&a);
    try std.testing.expectEqual(@as(usize, 0), cache.unloadUnused());
    try cache.release(&b);
    try std.testing.expectEqual(@as(usize, 1), cache.unloadUnused());
}

test "stats count hits, misses, loaded values, and their estimated bytes" {
    var table = try assets.Table.init(std.testing.allocator, 8);
    defer table.deinit();
    try registerTestAssets(&table);

    var source = FakeSource{};
    var cache = try fakeCache(std.testing.allocator, &table, &source);
    defer cache.deinit();

    var a = try cache.acquire("tile");
    var b = try cache.acquire("tile");
    var c = try cache.acquire("warrior");
    try std.testing.expectError(error.UnknownAsset, cache.acquire("missing"));

    const s = cache.stats();
    try std.testing.expectEqual(@as(u64, 1), s.hits);
    try std.testing.expectEqual(@as(u64, 2), s.misses);
    try std.testing.expectEqual(@as(usize, 2), s.loaded);
    try std.testing.expectEqual(@as(usize, 200), s.bytes);

    try cache.release(&a);
    try cache.release(&b);
    try cache.release(&c);
    try std.testing.expectEqual(@as(usize, 2), cache.unloadUnused());

    const after = cache.stats();
    try std.testing.expectEqual(@as(u64, 2), after.unloads);
    try std.testing.expectEqual(@as(usize, 0), after.bytes);
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
    var handles: [300]Cached.Handle = undefined;
    for (0..300) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "frame{d:0>3}", .{i});
        const path = try std.fmt.bufPrint(&path_buf, "assets/frame{d:0>3}.png", .{i});
        _ = try table.register(name, path);
        names[i] = try strings.Name.init(name);
        handles[i] = try cache.acquire(name);
    }

    for (handles, 0..) |h, i| {
        try std.testing.expectEqual(@as(u32, @intCast(i + 1)), (try cache.get(h)).*);
    }
    try std.testing.expectEqual(@as(usize, 300), cache.count());

    // Release the even half and unload it. Removing those values must not disturb the odd half,
    // which is still referenced.
    for (&handles, 0..) |*h, i| {
        if (i % 2 == 0) try cache.release(h);
    }
    try std.testing.expectEqual(@as(usize, 150), cache.unloadUnused());
    try std.testing.expectEqual(@as(usize, 150), cache.count());

    // The held half is still a hit, so it doesn't reload.
    for (handles, 0..) |h, i| {
        if (i % 2 == 0) continue;
        var again = try cache.acquire(names[i].slice());
        try std.testing.expectEqual(h, again);
        try cache.release(&again);
    }
    try std.testing.expectEqual(@as(u32, 300), source.loads);

    // The released half loads again on its next acquire.
    for (names, 0..) |name, i| {
        if (i % 2 != 0) continue;
        var reloaded = try cache.acquire(name.slice());
        try cache.release(&reloaded);
    }
    try std.testing.expectEqual(@as(u32, 450), source.loads);
    try std.testing.expectEqual(@as(usize, 300), cache.count());

    // Release the odd half, then unload everything. Every load has now been matched by an unload.
    for (&handles, 0..) |*h, i| {
        if (i % 2 != 0) try cache.release(h);
    }
    try std.testing.expectEqual(@as(usize, 300), cache.unloadUnused());
    try std.testing.expectEqual(@as(usize, 0), cache.count());
    try std.testing.expectEqual(source.loads, source.unloads);
}

test "a budget unloads the least recently used idle value before a load that would exceed it" {
    var table = try assets.Table.init(std.testing.allocator, 8);
    defer table.deinit();
    try registerTestAssets(&table);

    var source = FakeSource{};
    var cache = try fakeCache(std.testing.allocator, &table, &source);
    defer cache.deinit();
    // Each FakeSource value is 100 bytes, so two fit in the budget and a third does not.
    cache.setBudget(250);

    var tile = try cache.acquire("tile");
    const tile_kept = tile;
    try cache.release(&tile);
    var warrior = try cache.acquire("warrior");
    try cache.release(&warrior);

    // Use the warrior again, so the tile is now the least recently used idle value.
    var warrior_again = try cache.acquire("warrior");
    try cache.release(&warrior_again);

    var button = try cache.acquire("ui/button");
    try std.testing.expectEqual(@as(usize, 2), cache.count());
    try std.testing.expectEqual(@as(usize, 200), cache.stats().bytes);
    try std.testing.expectEqual(@as(u64, 1), cache.stats().unloads);
    try std.testing.expectEqual(@as(u64, 0), cache.stats().over_budget);
    try std.testing.expectError(error.StaleHandle, cache.get(tile_kept));
    try cache.release(&button);
}

test "a budget never unloads a referenced value, and counts the loads that stay over it" {
    var table = try assets.Table.init(std.testing.allocator, 8);
    defer table.deinit();
    try registerTestAssets(&table);

    var source = FakeSource{};
    var cache = try fakeCache(std.testing.allocator, &table, &source);
    defer cache.deinit();
    cache.setBudget(150);

    var tile = try cache.acquire("tile");
    var warrior = try cache.acquire("warrior");
    try std.testing.expectEqual(@as(usize, 2), cache.count());
    try std.testing.expectEqual(@as(u64, 1), cache.stats().over_budget);
    try std.testing.expectEqual(@as(u64, 0), cache.stats().unloads);
    try cache.release(&tile);
    try cache.release(&warrior);
}

test "requests load highest priority first, and a preloaded value holds no reference" {
    var table = try assets.Table.init(std.testing.allocator, 8);
    defer table.deinit();
    try registerTestAssets(&table);

    var source = FakeSource{};
    var cache = try fakeCache(std.testing.allocator, &table, &source);
    defer cache.deinit();

    const tile_id = table.find("tile").?;
    const warrior_id = table.find("warrior").?;
    const button_id = table.find("ui/button").?;

    try cache.request("tile", .low);
    try cache.request("warrior", .high);
    try cache.request("ui/button", .normal);
    // A lower request does not lower a pending higher one.
    try cache.request("warrior", .low);

    const first = cache.pump(2);
    try std.testing.expectEqual(@as(usize, 2), first.loaded);
    try std.testing.expectEqual(@as(usize, 0), first.failed);
    try std.testing.expect(cache.slots[warrior_id].loaded);
    try std.testing.expect(cache.slots[button_id].loaded);
    try std.testing.expect(!cache.slots[tile_id].loaded);

    // Nothing holds a preloaded value, so it is idle and unloadUnused can free it.
    try std.testing.expectEqual(@as(u32, 0), cache.slots[warrior_id].refs);

    const second = cache.pump(5);
    try std.testing.expectEqual(@as(usize, 1), second.loaded);
    try std.testing.expectEqual(@as(usize, 0), cache.pump(5).loaded);
    try std.testing.expectEqual(@as(u32, 3), source.loads);

    // Acquiring a preloaded value is a hit, so it loads nothing.
    var warrior = try cache.acquire("warrior");
    try std.testing.expectEqual(@as(u32, 3), source.loads);
    try cache.release(&warrior);
    try std.testing.expectEqual(@as(usize, 3), cache.unloadUnused());
}

test "a request for an unknown name is refused, and a request for a loaded value does nothing" {
    var table = try assets.Table.init(std.testing.allocator, 8);
    defer table.deinit();
    try registerTestAssets(&table);

    var source = FakeSource{};
    var cache = try fakeCache(std.testing.allocator, &table, &source);
    defer cache.deinit();

    try std.testing.expectError(error.UnknownAsset, cache.request("missing", .high));
    try std.testing.expectEqual(@as(usize, 0), cache.pump(10).loaded);

    var tile = try cache.acquire("tile");
    try cache.request("tile", .high);
    try std.testing.expectEqual(@as(usize, 0), cache.pump(10).loaded);
    try std.testing.expectEqual(@as(u32, 1), source.loads);
    try cache.release(&tile);
}

test "a preload that fails is dropped, so the next pump does not retry it" {
    var table = try assets.Table.init(std.testing.allocator, 8);
    defer table.deinit();
    try registerTestAssets(&table);

    var source = FakeSource{ .fail_next = true };
    var cache = try fakeCache(std.testing.allocator, &table, &source);
    defer cache.deinit();

    try cache.request("tile", .normal);
    const first = cache.pump(4);
    try std.testing.expectEqual(@as(usize, 0), first.loaded);
    try std.testing.expectEqual(@as(usize, 1), first.failed);
    try std.testing.expectEqual(@as(usize, 0), cache.pump(4).failed);
    try std.testing.expectEqual(@as(u64, 1), cache.stats().failed_loads);
    try std.testing.expectEqual(@as(usize, 0), cache.count());
}
