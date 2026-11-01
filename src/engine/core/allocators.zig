//! Allocator scopes owned by one `engine.run` call. The caller supplies the parent allocator;
//! runtime and game-facing services use narrower lifetime arenas with request-level accounting.

const std = @import("std");

pub const ContextAllocators = struct {
    /// Persistent allocations owned by the current game instance.
    game: std.mem.Allocator,
    /// Loaded asset data whose lifetime is the current run.
    asset: std.mem.Allocator,
    /// Temporary data valid only until the next outer frame begins.
    frame: std.mem.Allocator,
};

pub const ScopeStats = struct {
    allocation_count: u64 = 0,
    free_count: u64 = 0,
    failed_allocations: u64 = 0,
    live_allocations: usize = 0,
    live_bytes: usize = 0,
    high_water_bytes: usize = 0,
    arena_capacity_bytes: usize = 0,
    /// Allocations and bytes requested since the current frame began. Unlike the counts above, these
    /// restart each frame, so they show what one frame costs.
    allocations_this_frame: u64 = 0,
    bytes_this_frame: usize = 0,
};

pub const Stats = struct {
    engine: ScopeStats = .{},
    game: ScopeStats = .{},
    asset: ScopeStats = .{},
    frame: ScopeStats = .{},

    /// Allocations requested so far this frame, across every scope.
    pub fn allocationsThisFrame(self: Stats) u64 {
        return self.engine.allocations_this_frame + self.game.allocations_this_frame +
            self.asset.allocations_this_frame + self.frame.allocations_this_frame;
    }

    /// Bytes requested so far this frame, across every scope.
    pub fn bytesThisFrame(self: Stats) usize {
        return self.engine.bytes_this_frame + self.game.bytes_this_frame +
            self.asset.bytes_this_frame + self.frame.bytes_this_frame;
    }
};

const TrackedAllocator = struct {
    backing: std.mem.Allocator = undefined,
    allocation_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    free_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    failed_allocations: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    live_allocations: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    live_bytes: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    high_water_bytes: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    frame_allocations: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    frame_bytes: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(self: *TrackedAllocator, backing: std.mem.Allocator) std.mem.Allocator {
        self.backing = backing;
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn recordAllocation(self: *TrackedAllocator, size: usize) void {
        _ = self.allocation_count.fetchAdd(1, .monotonic);
        _ = self.frame_allocations.fetchAdd(1, .monotonic);
        _ = self.frame_bytes.fetchAdd(size, .monotonic);
        _ = self.live_allocations.fetchAdd(1, .monotonic);
        const live = self.live_bytes.fetchAdd(size, .monotonic) + size;
        _ = self.high_water_bytes.fetchMax(live, .monotonic);
    }

    fn recordRelease(self: *TrackedAllocator, size: usize) void {
        _ = self.free_count.fetchAdd(1, .monotonic);
        _ = self.live_allocations.fetchSub(1, .monotonic);
        _ = self.live_bytes.fetchSub(size, .monotonic);
    }

    fn recordFailure(self: *TrackedAllocator) void {
        _ = self.failed_allocations.fetchAdd(1, .monotonic);
    }

    fn recordResize(self: *TrackedAllocator, old_size: usize, new_size: usize) void {
        if (new_size >= old_size) {
            const live = self.live_bytes.fetchAdd(new_size - old_size, .monotonic) + (new_size - old_size);
            _ = self.high_water_bytes.fetchMax(live, .monotonic);
        } else {
            _ = self.live_bytes.fetchSub(old_size - new_size, .monotonic);
        }
    }

    fn snapshot(self: *const TrackedAllocator) ScopeStats {
        return .{
            .allocation_count = self.allocation_count.load(.monotonic),
            .free_count = self.free_count.load(.monotonic),
            .failed_allocations = self.failed_allocations.load(.monotonic),
            .live_allocations = self.live_allocations.load(.monotonic),
            .live_bytes = self.live_bytes.load(.monotonic),
            .high_water_bytes = self.high_water_bytes.load(.monotonic),
            .allocations_this_frame = self.frame_allocations.load(.monotonic),
            .bytes_this_frame = self.frame_bytes.load(.monotonic),
        };
    }

    fn resetLive(self: *TrackedAllocator) void {
        self.live_allocations.store(0, .monotonic);
        self.live_bytes.store(0, .monotonic);
    }

    fn resetFrameCounts(self: *TrackedAllocator) void {
        self.frame_allocations.store(0, .monotonic);
        self.frame_bytes.store(0, .monotonic);
    }

    fn alloc(context: *anyopaque, size: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TrackedAllocator = @ptrCast(@alignCast(context));
        const result = self.backing.rawAlloc(size, alignment, ret_addr) orelse {
            self.recordFailure();
            return null;
        };
        self.recordAllocation(size);
        return result;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_size: usize, ret_addr: usize) bool {
        const self: *TrackedAllocator = @ptrCast(@alignCast(context));
        if (!self.backing.rawResize(memory, alignment, new_size, ret_addr)) return false;
        self.recordResize(memory.len, new_size);
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_size: usize, ret_addr: usize) ?[*]u8 {
        const self: *TrackedAllocator = @ptrCast(@alignCast(context));
        const result = self.backing.rawRemap(memory, alignment, new_size, ret_addr) orelse return null;
        self.recordResize(memory.len, new_size);
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *TrackedAllocator = @ptrCast(@alignCast(context));
        self.backing.rawFree(memory, alignment, ret_addr);
        self.recordRelease(memory.len);
    }
};

pub const RuntimeAllocators = struct {
    engine_arena: std.heap.ArenaAllocator,
    game_arena: std.heap.ArenaAllocator,
    asset_arena: std.heap.ArenaAllocator,
    frame_arena: std.heap.ArenaAllocator,
    engine_tracker: TrackedAllocator,
    game_tracker: TrackedAllocator,
    asset_tracker: TrackedAllocator,
    frame_tracker: TrackedAllocator,
    tracking_enabled: bool,

    pub fn init(parent: std.mem.Allocator, tracking_enabled: bool) RuntimeAllocators {
        var self: RuntimeAllocators = undefined;
        self.engine_arena = std.heap.ArenaAllocator.init(parent);
        self.game_arena = std.heap.ArenaAllocator.init(parent);
        self.asset_arena = std.heap.ArenaAllocator.init(parent);
        self.frame_arena = std.heap.ArenaAllocator.init(parent);
        self.engine_tracker = .{};
        self.game_tracker = .{};
        self.asset_tracker = .{};
        self.frame_tracker = .{};
        self.tracking_enabled = tracking_enabled;
        return self;
    }

    pub fn deinit(self: *RuntimeAllocators) void {
        self.frame_arena.deinit();
        self.asset_arena.deinit();
        self.game_arena.deinit();
        self.engine_arena.deinit();
    }

    pub fn engineAllocator(self: *RuntimeAllocators) std.mem.Allocator {
        return if (self.tracking_enabled)
            self.engine_tracker.allocator(self.engine_arena.allocator())
        else
            self.engine_arena.allocator();
    }

    pub fn context(self: *RuntimeAllocators) ContextAllocators {
        return .{
            .game = if (self.tracking_enabled) self.game_tracker.allocator(self.game_arena.allocator()) else self.game_arena.allocator(),
            .asset = if (self.tracking_enabled) self.asset_tracker.allocator(self.asset_arena.allocator()) else self.asset_arena.allocator(),
            .frame = if (self.tracking_enabled) self.frame_tracker.allocator(self.frame_arena.allocator()) else self.frame_arena.allocator(),
        };
    }

    pub fn stats(self: *const RuntimeAllocators) Stats {
        return .{
            .engine = scopeStats(self.engine_tracker.snapshot(), self.engine_arena),
            .game = scopeStats(self.game_tracker.snapshot(), self.game_arena),
            .asset = scopeStats(self.asset_tracker.snapshot(), self.asset_arena),
            .frame = scopeStats(self.frame_tracker.snapshot(), self.frame_arena),
        };
    }

    pub fn resetFrame(self: *RuntimeAllocators) void {
        _ = self.frame_arena.reset(.free_all);
        self.frame_tracker.resetLive();
        self.engine_tracker.resetFrameCounts();
        self.game_tracker.resetFrameCounts();
        self.asset_tracker.resetFrameCounts();
        self.frame_tracker.resetFrameCounts();
    }
};

fn scopeStats(stats: ScopeStats, arena: std.heap.ArenaAllocator) ScopeStats {
    var result = stats;
    result.arena_capacity_bytes = arena.queryCapacity();
    return result;
}

test "tracked arenas record allocation counts, live bytes, and high-water marks" {
    var roles = RuntimeAllocators.init(std.testing.allocator, true);
    defer roles.deinit();

    const allocators = roles.context();
    const game_bytes = try allocators.game.alloc(u8, 32);
    const asset_bytes = try allocators.asset.alloc(u8, 64);
    const frame_bytes = try allocators.frame.alloc(u8, 16);
    @memset(game_bytes, 1);
    @memset(asset_bytes, 2);
    @memset(frame_bytes, 3);

    const before_reset = roles.stats();
    try std.testing.expectEqual(@as(u64, 1), before_reset.game.allocation_count);
    try std.testing.expectEqual(@as(usize, 32), before_reset.game.live_bytes);
    try std.testing.expectEqual(@as(usize, 64), before_reset.asset.high_water_bytes);
    try std.testing.expect(before_reset.asset.arena_capacity_bytes >= 64);
    try std.testing.expectEqual(@as(usize, 16), before_reset.frame.live_bytes);

    roles.resetFrame();
    const after_reset = roles.stats();
    try std.testing.expectEqual(@as(usize, 0), after_reset.frame.live_bytes);
    try std.testing.expectEqual(@as(usize, 0), after_reset.frame.live_allocations);
    try std.testing.expectEqual(@as(usize, 16), after_reset.frame.high_water_bytes);

    const next_frame_bytes = try roles.context().frame.alloc(u8, 8);
    @memset(next_frame_bytes, 4);
    try std.testing.expectEqual(@as(usize, 32), game_bytes.len);
    try std.testing.expectEqual(@as(usize, 64), asset_bytes.len);
}

test "tracked frees release live bytes and preserve peak usage" {
    var roles = RuntimeAllocators.init(std.testing.allocator, true);
    defer roles.deinit();

    const allocator = roles.context().game;
    const bytes = try allocator.alloc(u8, 48);
    const larger = try allocator.realloc(bytes, 96);
    const smaller = try allocator.realloc(larger, 24);
    allocator.free(smaller);

    const stats = roles.stats().game;
    try std.testing.expect(stats.allocation_count >= 1);
    try std.testing.expectEqual(stats.allocation_count, stats.free_count);
    try std.testing.expectEqual(@as(usize, 0), stats.live_allocations);
    try std.testing.expectEqual(@as(usize, 0), stats.live_bytes);
    try std.testing.expect(stats.high_water_bytes >= 96);
}

test "per-frame counts restart each frame, while lifetime totals keep counting" {
    var roles = RuntimeAllocators.init(std.testing.allocator, true);
    defer roles.deinit();

    const allocators = roles.context();
    _ = try allocators.game.alloc(u8, 32);
    _ = try allocators.asset.alloc(u8, 64);
    const busy = roles.stats();
    try std.testing.expectEqual(@as(u64, 2), busy.allocationsThisFrame());
    try std.testing.expectEqual(@as(usize, 96), busy.bytesThisFrame());

    roles.resetFrame();
    try std.testing.expectEqual(@as(u64, 0), roles.stats().allocationsThisFrame());
    try std.testing.expectEqual(@as(usize, 0), roles.stats().bytesThisFrame());

    _ = try allocators.frame.alloc(u8, 8);
    const next = roles.stats();
    try std.testing.expectEqual(@as(u64, 1), next.allocationsThisFrame());
    try std.testing.expectEqual(@as(usize, 8), next.bytesThisFrame());
    try std.testing.expectEqual(@as(u64, 1), next.game.allocation_count);
}

test "untracked arenas preserve the normal allocator path" {
    var roles = RuntimeAllocators.init(std.testing.allocator, false);
    defer roles.deinit();

    const bytes = try roles.context().asset.alloc(u8, 24);
    roles.context().asset.free(bytes);
    const stats = roles.stats().asset;
    try std.testing.expectEqual(@as(u64, 0), stats.allocation_count);
    try std.testing.expectEqual(@as(usize, 0), stats.live_bytes);
    try std.testing.expect(stats.arena_capacity_bytes >= 24);
}

test "tracked arenas count failed allocation requests" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var roles = RuntimeAllocators.init(failing.allocator(), true);
    defer roles.deinit();

    try std.testing.expectError(error.OutOfMemory, roles.context().asset.alloc(u8, 32));
    try std.testing.expectEqual(@as(u64, 1), roles.stats().asset.failed_allocations);
    try std.testing.expectEqual(@as(u64, 0), roles.stats().asset.allocation_count);
}
