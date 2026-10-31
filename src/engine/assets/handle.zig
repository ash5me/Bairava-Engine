//! Typed, stable references to cached assets.
//!
//! A `Handle(T)` names one loaded value of type `T`, so a texture handle can't be passed where a
//! sound handle is expected. A handle is two integers, never a pointer: `id` is the asset's id in
//! its registry table, which is also the cache slot that holds it, and `generation` counts how many
//! times that slot has been unloaded. Unloading bumps the generation, so a handle issued for an
//! earlier load no longer matches and is rejected as stale. Growing the cache never moves what a
//! handle names, because a handle holds no address.
//!
//! A handle is a counted reference, not a lease token. Each acquire or retain must be matched by one
//! release. Releasing through the handle's variable clears it, so the same variable can't release
//! twice. Two copies of one handle are not told apart: releasing both releases two references.

const std = @import("std");
const registry = @import("registry.zig");

/// Why a handle can't be used. `InvalidHandle` means it was never issued, or a release cleared it.
/// `StaleHandle` means it was issued, but the value it named has since been unloaded.
pub const LookupError = error{ InvalidHandle, StaleHandle };

/// A typed reference to a cached value of type `T`.
pub fn Handle(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The value type this handle names.
        pub const Value = T;

        /// The asset's id, which is also its cache slot.
        id: registry.AssetId,
        /// The slot's generation when the handle was issued. A slot's generation is never 0, so a
        /// handle with generation 0 matches nothing.
        generation: u32,

        /// The handle that names nothing. A release leaves it in the caller's variable.
        pub const invalid: Self = .{ .id = 0, .generation = 0 };
    };
}

/// The generation after `generation`. Generation 0 is skipped, because it marks an invalid handle,
/// so wrapping past the largest value starts again at 1.
pub fn nextGeneration(generation: u32) u32 {
    const next = generation +% 1;
    return if (next == 0) 1 else next;
}

test "handles to different value types are different types" {
    try std.testing.expect(Handle(u32) != Handle(f32));
    try std.testing.expect(Handle(u32).Value == u32);
}

test "the invalid handle has generation 0" {
    try std.testing.expectEqual(@as(u32, 0), Handle(u32).invalid.generation);
}

test "generations advance by one and never become 0" {
    try std.testing.expectEqual(@as(u32, 2), nextGeneration(1));
    try std.testing.expectEqual(@as(u32, 1), nextGeneration(std.math.maxInt(u32)));
}
