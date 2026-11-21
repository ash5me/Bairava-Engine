const std = @import("std");
const engine = @import("bairava");
const script_host = @import("game_script_host");

test "game script bindings expose only the supported host API" {
    var context: engine.Context = undefined;
    context.zoom_min = 0.5;
    context.zoom_max = 2.0;
    context.zoom_target = 1.0;
    var bridge = script_host.Bridge{
        .ctx = &context,
        .clicks = 7,
        .volume = 0.25,
        .dt = 1.0 / 60.0,
    };

    var vm = try engine.script.Vm.init(1000);
    defer vm.deinit();
    try script_host.bind(&vm, &bridge);
    try vm.load("test_game_host.bs",
        \\fn inspect() { return clicks + volume + dt; }
        \\fn set_zoom() { zoom_by(1.5); return zoom; }
        \\fn reset_zoom() { zoom_reset(); return zoom; }
        \\fn apply_volume() { set_volume(1.5); return volume; }
        \\fn bad_volume() { set_volume("loud"); }
        \\fn bad_zoom() { zoom_by(0); }
        \\fn bad_log() { log(3); }
        \\fn missing_binding() { not_exposed(); }
    );

    const inspection = (try vm.call("inspect", &.{})).?;
    try std.testing.expectApproxEqAbs(@as(f64, 7.25 + 1.0 / 60.0), engine.script.asNumber(inspection).?, 1e-6);
    const zoomed = (try vm.call("set_zoom", &.{})).?;
    try std.testing.expectEqual(@as(?f64, 1.5), engine.script.asNumber(zoomed));
    const reset_zoom = (try vm.call("reset_zoom", &.{})).?;
    try std.testing.expectEqual(@as(?f64, 1.0), engine.script.asNumber(reset_zoom));
    const volume = (try vm.call("apply_volume", &.{})).?;
    try std.testing.expectEqual(@as(?f64, 1), engine.script.asNumber(volume));
    try std.testing.expectEqual(@as(f32, 1), bridge.volume);

    try std.testing.expectError(error.CallFailed, vm.call("bad_volume", &.{}));
    try std.testing.expect(std.mem.indexOf(u8, vm.errorText(), "set_volume needs a number") != null);
    try std.testing.expectError(error.CallFailed, vm.call("bad_zoom", &.{}));
    try std.testing.expect(std.mem.indexOf(u8, vm.errorText(), "factor above zero") != null);
    try std.testing.expectError(error.CallFailed, vm.call("bad_log", &.{}));
    try std.testing.expect(std.mem.indexOf(u8, vm.errorText(), "log needs text") != null);
    try std.testing.expectError(error.CallFailed, vm.call("missing_binding", &.{}));
    try std.testing.expect(std.mem.indexOf(u8, vm.errorText(), "unknown function 'not_exposed'") != null);

    const after_errors = (try vm.call("inspect", &.{})).?;
    try std.testing.expectApproxEqAbs(@as(f64, 7 + 1 + 1.0 / 60.0), engine.script.asNumber(after_errors).?, 1e-6);
}

test "game script VM can be shut down while its bridge remains alive" {
    var context: engine.Context = undefined;
    context.zoom_min = 0.5;
    context.zoom_max = 2.0;
    context.zoom_target = 1.0;
    var bridge = script_host.Bridge{ .ctx = &context };

    var vm = try engine.script.Vm.init(1000);
    try script_host.bind(&vm, &bridge);
    try vm.load("active.bs", "fn on_update() { set_volume(0.75); }\n");
    try std.testing.expect((try vm.call("on_update", &.{})) != null);
    vm.deinit();
    try std.testing.expectEqual(@as(f32, 0.75), bridge.volume);
}
