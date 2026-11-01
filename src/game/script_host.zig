//! What gameplay scripts may read and call. The engine's script runtime knows nothing about the game, so this file is
//! the one place the two meet. A script sees only the names below. Values: `clicks`, `volume`, `zoom`, and `dt`.
//! Functions: `log(text)`, `set_volume(level)`, `zoom_by(factor)`, and `zoom_reset()`. Any other name is an error.
//! The rules for writing scripts are in docs/scripting.md.

const std = @import("std");
const engine = @import("bairava");

const script = engine.script;
const Call = script.Call;
const HostError = script.HostError;
const Value = script.Value;

const log = engine.log.scoped("script");

/// The state the bindings read and write. The game copies its values in before each call, and copies `volume` back
/// out after, so a script never holds a pointer into the game.
pub const Bridge = struct {
    ctx: *engine.Context,
    clicks: u32 = 0,
    volume: f32 = 0.5,
    dt: f32 = 0,
};

fn logMessage(_: *Bridge, call: Call) HostError!Value {
    const text = script.asString(call.args[0]) orelse return call.fail("log needs text");
    log.info("{s}", .{text});
    return script.nilValue();
}

fn setVolume(bridge: *Bridge, call: Call) HostError!Value {
    const level = script.asNumber(call.args[0]) orelse return call.fail("set_volume needs a number");
    bridge.volume = @floatCast(std.math.clamp(level, 0.0, 1.0));
    return script.nilValue();
}

fn zoomBy(bridge: *Bridge, call: Call) HostError!Value {
    const factor = script.asNumber(call.args[0]) orelse return call.fail("zoom_by needs a number");
    if (!(factor > 0)) return call.fail("zoom_by needs a factor above zero");
    bridge.ctx.zoomBy(@floatCast(factor));
    return script.nilValue();
}

fn zoomReset(bridge: *Bridge, _: Call) HostError!Value {
    bridge.ctx.resetZoom();
    return script.nilValue();
}

fn clicksValue(bridge: *Bridge) HostError!Value {
    return script.number(@floatFromInt(bridge.clicks));
}

fn volumeValue(bridge: *Bridge) HostError!Value {
    return script.number(bridge.volume);
}

fn zoomValue(bridge: *Bridge) HostError!Value {
    return script.number(bridge.ctx.zoom_target);
}

fn dtValue(bridge: *Bridge) HostError!Value {
    return script.number(bridge.dt);
}

/// Binds every name above into `vm`. The bindings point at `bridge`, which must outlive the VM.
pub fn bind(vm: *script.Vm, bridge: *Bridge) script.Error!void {
    const bindings = script.Bindings(Bridge);
    try bindings.function(vm, "log", 1, 1, bridge, logMessage);
    try bindings.function(vm, "set_volume", 1, 1, bridge, setVolume);
    try bindings.function(vm, "zoom_by", 1, 1, bridge, zoomBy);
    try bindings.function(vm, "zoom_reset", 0, 0, bridge, zoomReset);
    try bindings.value(vm, "clicks", bridge, clicksValue);
    try bindings.value(vm, "volume", bridge, volumeValue);
    try bindings.value(vm, "zoom", bridge, zoomValue);
    try bindings.value(vm, "dt", bridge, dtValue);
}
