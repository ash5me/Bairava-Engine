//! Allocator scopes owned by one `engine.run` call. The caller supplies the parent allocator;
//! runtime and game-facing services use narrower lifetime allocators from these arenas.

const std = @import("std");

pub const ContextAllocators = struct {
    /// Persistent allocations owned by the current game instance.
    game: std.mem.Allocator,
    /// Loaded asset data whose lifetime is the current run.
    asset: std.mem.Allocator,
    /// Temporary data valid only until the next outer frame begins.
    frame: std.mem.Allocator,
};

pub const RuntimeAllocators = struct {
    engine_arena: std.heap.ArenaAllocator,
    game_arena: std.heap.ArenaAllocator,
    asset_arena: std.heap.ArenaAllocator,
    frame_arena: std.heap.ArenaAllocator,

    pub fn init(parent: std.mem.Allocator) RuntimeAllocators {
        return .{
            .engine_arena = std.heap.ArenaAllocator.init(parent),
            .game_arena = std.heap.ArenaAllocator.init(parent),
            .asset_arena = std.heap.ArenaAllocator.init(parent),
            .frame_arena = std.heap.ArenaAllocator.init(parent),
        };
    }

    pub fn deinit(self: *RuntimeAllocators) void {
        self.frame_arena.deinit();
        self.asset_arena.deinit();
        self.game_arena.deinit();
        self.engine_arena.deinit();
    }

    pub fn engineAllocator(self: *RuntimeAllocators) std.mem.Allocator {
        return self.engine_arena.allocator();
    }

    pub fn context(self: *RuntimeAllocators) ContextAllocators {
        return .{
            .game = self.game_arena.allocator(),
            .asset = self.asset_arena.allocator(),
            .frame = self.frame_arena.allocator(),
        };
    }

    pub fn resetFrame(self: *RuntimeAllocators) void {
        _ = self.frame_arena.reset(.free_all);
    }
};

test "runtime allocator roles use separate arenas and release with their parent" {
    var roles = RuntimeAllocators.init(std.testing.allocator);
    defer roles.deinit();

    const game_bytes = try roles.context().game.alloc(u8, 32);
    const asset_bytes = try roles.context().asset.alloc(u8, 64);
    const frame_bytes = try roles.context().frame.alloc(u8, 16);
    @memset(game_bytes, 1);
    @memset(asset_bytes, 2);
    @memset(frame_bytes, 3);

    roles.resetFrame();
    const next_frame_bytes = try roles.context().frame.alloc(u8, 8);
    @memset(next_frame_bytes, 4);
    try std.testing.expectEqual(@as(usize, 32), game_bytes.len);
    try std.testing.expectEqual(@as(usize, 64), asset_bytes.len);
}