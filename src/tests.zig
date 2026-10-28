//! Test root for `zig build test`. It lists the modules that don't need SDL, a GPU, or the asset
//! files, so the tests run on any machine that can build the project.

test {
    _ = @import("engine/string.zig");
    _ = @import("engine/hash_map.zig");
    _ = @import("engine/assets.zig");
    _ = @import("engine/math.zig");
    _ = @import("engine/view.zig");
}
