const std = @import("std");
const bairava = @import("bairava");

test "configure the engine and define a typed action map" {
    const config = bairava.Config{
        .title = "Example",
        .native_w = 320,
        .native_h = 180,
    };
    try config.validate();

    const Action = enum { jump };
    const defaults = bairava.ActionDefaults(Action).init(.{
        .jump = &.{.{ .key = .space }},
    });
    const actions = bairava.ActionMap(Action).fromDefaults(defaults);
    try std.testing.expectEqual(@as(usize, 1), actions.bindingsOf(.jump).len);
}
