//! Smoke test for the vendored HarfBuzz build. It checks that the library links and runs and reports
//! the pinned version. Shaping tests come with the shaping layer.

const std = @import("std");

const hb = @cImport({
    @cInclude("hb.h");
});

test "HarfBuzz links and reports its pinned version" {
    const version = std.mem.span(hb.hb_version_string());
    try std.testing.expectEqualStrings("15.1.0", version);
}
