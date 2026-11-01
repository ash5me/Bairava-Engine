//! Profiling zones for the Tracy profiler. A zone marks one scope in the frame, and each frame
//! ends with a frame mark. Tracy draws the zones as a timeline, and it measures each frame from
//! one mark to the next.
//!
//! Zones are compiled in only with `-Dtracy=true`. Without it these calls do nothing, so a normal
//! build carries no profiler code. To profile, start the Tracy profiler first, then run
//! `zig build run -Dtracy=true` and connect to it.
//!
//! Only this file imports ztracy, the Zig bindings for Tracy. Other code calls through here.

const std = @import("std");
const ztracy = @import("ztracy");

/// True when this build records zones. Code that exists only for the profiler can check it.
pub const enabled = ztracy.enabled;

/// An open zone. Call `End` when the scope ends, usually with `defer`:
///     const zone = profile.zone(@src());
///     defer zone.End();
pub const Zone = ztracy.ZoneCtx;

/// Opens a zone that Tracy names after the function it's in.
pub fn zone(comptime src: std.builtin.SourceLocation) Zone {
    return ztracy.Zone(src);
}

/// Opens a zone with a name of its own. Use it when the function name doesn't say what the zone
/// measures, or when one function has several zones.
pub fn zoneNamed(comptime src: std.builtin.SourceLocation, comptime name: [:0]const u8) Zone {
    return ztracy.ZoneN(src, name);
}

/// Marks the end of a frame. Tracy measures each frame from one mark to the next.
pub fn frameMark() void {
    ztracy.FrameMark();
}

/// Records `value` as a sample of the Tracy plot `name`. Tracy draws each plot as a graph over time, beside
/// the zones. Without `-Dtracy=true` this does nothing, and it references no Tracy symbol.
pub fn plot(comptime name: [:0]const u8, value: f32) void {
    if (comptime enabled) {
        tracyEmitPlot(name.ptr, value);
    }
}

/// Tracy's C entry point for one plot sample, the call its own `TracyPlot` macro makes. It is declared here
/// and referenced only in builds that record zones, so an ordinary build does not link Tracy.
extern fn ___tracy_emit_plot(name: [*:0]const u8, val: f64) void;

fn tracyEmitPlot(name: [*:0]const u8, value: f32) void {
    ___tracy_emit_plot(name, value);
}
