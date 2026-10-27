//! Logging and assertions for debugging.
//!
//! Logs go to stderr with a timestamp, a level, and a scope:
//!     [    1523ms] INFO  engine: window 960x540, native view 320x180, 60 update steps per second
//!
//! Get a logger for one part of the code with `scoped`:
//!     const log = logging.scoped("game");
//!     log.info("level loaded", .{});
//!
//! Assertions check invariants. A failed assertion prints the caller's file and line, then
//! panics. They are checked in Debug and ReleaseSafe builds and compiled out in ReleaseFast and
//! ReleaseSmall. `fail` always panics, so use it where code should never run.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("sdl.zig").c;

pub const Level = enum(u8) {
    debug,
    info,
    warn,
    err,
};

/// Messages below this level are dropped. Debug builds show everything. Other builds show info and up.
pub var min_level: Level = if (builtin.mode == .Debug) .debug else .info;

/// True when assertions are checked. They are off only in the fastest release builds.
pub const asserts_enabled = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

/// A logger for one scope. `scope` names the part of the code, such as "engine" or "game".
pub fn scoped(comptime scope: []const u8) type {
    return struct {
        pub fn debug(comptime fmt: []const u8, args: anytype) void {
            write(.debug, scope, fmt, args);
        }

        pub fn info(comptime fmt: []const u8, args: anytype) void {
            write(.info, scope, fmt, args);
        }

        pub fn warn(comptime fmt: []const u8, args: anytype) void {
            write(.warn, scope, fmt, args);
        }

        pub fn err(comptime fmt: []const u8, args: anytype) void {
            write(.err, scope, fmt, args);
        }
    };
}

/// Checks an invariant. If `ok` is false, prints the caller's location and the message, then
/// panics. Does nothing when assertions are compiled out.
pub fn assert(ok: bool, src: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
    if (!asserts_enabled or ok) return;
    fail(src, "assertion failed: " ++ fmt, args);
}

/// Prints the caller's location and the message, then panics. Unlike `assert`, this panics in
/// every build mode, so use it only where code should never run.
pub fn fail(src: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("{s}:{d}:{d}: in {s}\n", .{ src.file, src.line, src.column, src.fn_name });
    std.debug.panic(fmt, args);
}

fn write(comptime level: Level, scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(level) < @intFromEnum(min_level)) return;
    const ms = c.SDL_GetTicksNS() / 1_000_000;
    std.debug.print("[{d:>8}ms] {s} {s}: ", .{ ms, levelName(level), scope });
    std.debug.print(fmt ++ "\n", args);
}

fn levelName(comptime level: Level) []const u8 {
    return switch (level) {
        .debug => "DEBUG",
        .info => "INFO ",
        .warn => "WARN ",
        .err => "ERROR",
    };
}
