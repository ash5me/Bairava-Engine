//! Logging and assertions for debugging.
//!
//! Logs go to stderr with a timestamp, a level, and a scope:
//!     [    1523ms] INFO  engine: window 960x540, native view 320x180, 60 update steps per second
//!
//! Levels, from the least to the most severe, are trace, debug, info, warn, and error. `min_level`
//! drops the messages below it. Debug builds start at debug, and the other modes at info. The
//! `log_level` line of the settings file sets it at startup, and the default is kept when the value is
//! not a level name. See docs/logging.md.
//!
//! Once `openFile` succeeds, every message that reaches stderr also goes to the log file, through
//! log.c (see log_file.c). The file line has a wall-clock time in place of milliseconds since start:
//!     2026-10-29 07:31:02 INFO  engine: window 960x540, native view 320x180, 60 update steps per second
//!
//! Get a logger for one part of the code with `scoped`:
//!     const log = logging.scoped("game");
//!     log.info("level loaded", .{});
//!
//! Failures use one shape: the operation, the resource it was working on, and the error. `recovered` is for a
//! failure the caller continues past, and logs a warning that says what happens instead. `fatal` is for a
//! failure that stops the operation, and logs an error. Neither replaces the error: the caller still returns
//! the typed Zig error it got.
//!
//! Assertions check invariants. A failed assertion prints the caller's file and line, then panics. They are
//! checked in Debug and ReleaseSafe builds and compiled out in ReleaseFast and ReleaseSmall. `fail` always
//! panics, so use it where code should never run. Panics, including these, are recorded in the log file by
//! the panic handler in main.zig.

const std = @import("std");
const builtin = @import("builtin");
const lf = @cImport(@cInclude("log_file.h"));

pub const Level = enum(u8) {
    trace,
    debug,
    info,
    warn,
    err,
};

/// Messages below this level are dropped. Debug builds start at debug, and the other modes at info. The
/// settings file's `log_level` line changes it at startup.
pub var min_level: Level = if (builtin.mode == .Debug) .debug else .info;

/// True when assertions are checked. They are off only in the fastest release builds.
pub const asserts_enabled = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

/// Longest message the log file takes, in bytes. A longer one is replaced by a short note.
const file_line_max = 2048;

/// True while the log file is open. Messages are written there only while it is.
var file_open = false;

/// Where timestamps read the time, in nanoseconds. The platform sets it with `setClock` before the
/// first message, so this file never imports the platform layer. Until then, timestamps print as 0.
var clock_fn: ?*const fn () u64 = null;

/// Sets the clock that timestamps read. Pass null to go back to printing 0. `runtime.run` sets it
/// before the first log line.
pub fn setClock(source: ?*const fn () u64) void {
    clock_fn = source;
}

/// Milliseconds on the injected clock, or 0 when no clock is set.
pub fn timestampMs() u64 {
    const source = clock_fn orelse return 0;
    return source() / 1_000_000;
}

/// True when a message at `level` is written. Callers can check it before building an expensive message.
pub fn enabled(level: Level) bool {
    return @intFromEnum(level) >= @intFromEnum(min_level);
}

/// Reads a level name from a settings value: trace, debug, info, warn (or warning), or error, in any case.
/// Null for anything else, so the caller can say what was wrong.
pub fn parseLevel(text: []const u8) ?Level {
    if (std.ascii.eqlIgnoreCase(text, "trace")) return .trace;
    if (std.ascii.eqlIgnoreCase(text, "debug")) return .debug;
    if (std.ascii.eqlIgnoreCase(text, "info")) return .info;
    if (std.ascii.eqlIgnoreCase(text, "warn") or std.ascii.eqlIgnoreCase(text, "warning")) return .warn;
    if (std.ascii.eqlIgnoreCase(text, "error")) return .err;
    return null;
}

/// A logger for one scope. `scope` names the part of the code, such as "engine" or "game".
pub fn scoped(comptime scope: []const u8) type {
    return struct {
        pub fn trace(comptime fmt: []const u8, args: anytype) void {
            write(.trace, scope, fmt, args);
        }

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

/// Reports a failure the caller continues past: the operation, the resource, the error, and what happens
/// instead. Logged at warning level, because nothing stops.
pub fn recovered(comptime scope: []const u8, operation: []const u8, resource: []const u8, err_value: anyerror, instead: []const u8) void {
    scoped(scope).warn("{s} failed for '{s}': {s}; {s}", .{ operation, resource, @errorName(err_value), instead });
}

/// Reports a failure that stops the operation: the operation, the resource, and the error. Logged at error
/// level. The caller returns the same error afterwards.
pub fn fatal(comptime scope: []const u8, operation: []const u8, resource: []const u8, err_value: anyerror) void {
    scoped(scope).err("{s} failed for '{s}': {s}", .{ operation, resource, @errorName(err_value) });
}

/// Starts writing messages to the file at `path`. The file is replaced, so each run starts a new
/// log. Returns false if the file can't be opened, and the game then logs to the terminal only.
pub fn openFile(path: [:0]const u8) bool {
    if (lf.log_file_open(path.ptr) != 0) return false;
    file_open = true;
    return true;
}

/// Stops writing to the log file and closes it. Later messages go to the terminal only.
pub fn closeFile() void {
    if (!file_open) return;
    lf.log_file_close();
    file_open = false;
}

/// Records a panic's message in the log file. The panic handler in main.zig calls this before Zig
/// prints the message and the stack trace to the terminal.
pub fn recordPanic(msg: []const u8) void {
    if (!file_open) return;
    var buf: [file_line_max]u8 = undefined;
    const text: [:0]const u8 = std.fmt.bufPrintZ(&buf, "panic: {s}", .{msg}) catch "panic: (message too long for the log file)";
    lf.log_file_write(@intFromEnum(Level.err), text.ptr);
}

/// Checks an invariant. If `ok` is false, the message names the caller's location and panics.
/// Does nothing when assertions are compiled out.
pub fn assert(ok: bool, src: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
    if (!asserts_enabled or ok) return;
    fail(src, "assertion failed: " ++ fmt, args);
}

/// Panics with the caller's location and the message. Unlike `assert`, this panics in every build
/// mode, so use it only where code should never run.
pub fn fail(src: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) noreturn {
    // The location and the message go out as one panic message, so the log file gets one line for both.
    var buf: [file_line_max]u8 = undefined;
    const message: []const u8 = std.fmt.bufPrint(&buf, fmt, args) catch "(message too long)";
    std.debug.panic("{s}:{d}:{d}: in {s}: {s}", .{ src.file, src.line, src.column, src.fn_name, message });
}

fn write(comptime level: Level, comptime scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (!enabled(level)) return;
    const ms = timestampMs();
    std.debug.print("[{d:>8}ms] {s} {s}: ", .{ ms, levelName(level), scope });
    std.debug.print(fmt ++ "\n", args);
    if (!file_open) return;
    var buf: [file_line_max]u8 = undefined;
    const text: [:0]const u8 = std.fmt.bufPrintZ(&buf, scope ++ ": " ++ fmt, args) catch "(message too long for the log file)";
    lf.log_file_write(@intFromEnum(level), text.ptr);
}

fn levelName(comptime level: Level) []const u8 {
    return switch (level) {
        .trace => "TRACE",
        .debug => "DEBUG",
        .info => "INFO ",
        .warn => "WARN ",
        .err => "ERROR",
    };
}

test "timestamps print as 0 before a clock is injected" {
    setClock(null);
    try std.testing.expectEqual(@as(u64, 0), timestampMs());
}

test "timestamps read the injected clock in milliseconds" {
    const fake = struct {
        fn now() u64 {
            return 2_500_000_000;
        }
    };
    setClock(&fake.now);
    defer setClock(null);
    try std.testing.expectEqual(@as(u64, 2500), timestampMs());
}

test "parseLevel reads each level name in any case, and refuses other words" {
    try std.testing.expectEqual(@as(?Level, .trace), parseLevel("TRACE"));
    try std.testing.expectEqual(@as(?Level, .debug), parseLevel("Debug"));
    try std.testing.expectEqual(@as(?Level, .info), parseLevel("info"));
    try std.testing.expectEqual(@as(?Level, .warn), parseLevel("warning"));
    try std.testing.expectEqual(@as(?Level, .err), parseLevel("error"));
    try std.testing.expectEqual(@as(?Level, null), parseLevel("loud"));
    try std.testing.expectEqual(@as(?Level, null), parseLevel(""));
}

test "enabled drops the levels below min_level, and keeps the rest" {
    const saved = min_level;
    defer min_level = saved;

    min_level = .warn;
    try std.testing.expect(!enabled(.trace));
    try std.testing.expect(!enabled(.debug));
    try std.testing.expect(!enabled(.info));
    try std.testing.expect(enabled(.warn));
    try std.testing.expect(enabled(.err));

    min_level = .trace;
    try std.testing.expect(enabled(.trace));
}
