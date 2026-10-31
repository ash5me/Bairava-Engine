//! Logging and assertions for debugging.
//!
//! Logs go to stderr with a timestamp, a level, and a scope:
//!     [    1523ms] INFO  engine: window 960x540, native view 320x180, 60 update steps per second
//!
//! Once `openFile` succeeds, every message that reaches stderr also goes to the log file, through
//! log.c (see log_file.c). The file line has a wall-clock time in place of milliseconds since start:
//!     2026-10-29 07:31:02 INFO  engine: window 960x540, native view 320x180, 60 update steps per second
//!
//! Get a logger for one part of the code with `scoped`:
//!     const log = logging.scoped("game");
//!     log.info("level loaded", .{});
//!
//! Assertions check invariants. A failed assertion prints the caller's file and line, then
//! panics. They are checked in Debug and ReleaseSafe builds and compiled out in ReleaseFast and
//! ReleaseSmall. `fail` always panics, so use it where code should never run. Panics, including
//! these, are recorded in the log file by the panic handler in main.zig.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("../platform/sdl/sdl.zig").c;
const lf = @cImport(@cInclude("log_file.h"));

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

/// Longest message the log file takes, in bytes. A longer one is replaced by a short note.
const file_line_max = 2048;

/// True while the log file is open. Messages are written there only while it is.
var file_open = false;

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
    if (@intFromEnum(level) < @intFromEnum(min_level)) return;
    const ms = c.SDL_GetTicksNS() / 1_000_000;
    std.debug.print("[{d:>8}ms] {s} {s}: ", .{ ms, levelName(level), scope });
    std.debug.print(fmt ++ "\n", args);
    if (!file_open) return;
    var buf: [file_line_max]u8 = undefined;
    const text: [:0]const u8 = std.fmt.bufPrintZ(&buf, scope ++ ": " ++ fmt, args) catch "(message too long for the log file)";
    lf.log_file_write(@intFromEnum(level), text.ptr);
}

fn levelName(comptime level: Level) []const u8 {
    return switch (level) {
        .debug => "DEBUG",
        .info => "INFO ",
        .warn => "WARN ",
        .err => "ERROR",
    };
}
