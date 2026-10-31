//! The asset manager: one place for the asset table, the cache, and the loaders. The game still
//! loads through `Context` (core/context.zig), which calls the loaders directly. Connecting the
//! cache to GPU textures is the next step on the roadmap, and this file is where it will go.

pub const registry = @import("registry.zig");
pub const cache = @import("cache.zig");
pub const loaders = struct {
    pub const image = @import("loaders/image.zig");
    pub const atlas = @import("loaders/atlas.zig");
};
