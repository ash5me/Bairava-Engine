//! File access through SDL3. Every file call names a location, and the location decides which folder
//! a path resolves to. This is the only file that calls SDL's file functions, so grepping for them
//! finds every read and write the engine makes.
//!
//! `.packaged` holds shipped assets and is read-only. `.beside_executable` holds settings, the log,
//! and save data, and it is the only location that accepts writes.

const std = @import("std");

const c = @import("sdl.zig").c;
const types = @import("../types.zig");
const logging = @import("../../logging/log.zig");

const elog = logging.scoped("engine");

pub const Location = types.Location;
pub const FileError = types.FileError;
pub const max_full_path = types.max_full_path;

/// The folder the executable runs from, with a trailing separator. SDL owns the string until the
/// platform shuts down, so it stays valid for the run.
pub fn baseDir() []const u8 {
    const base_c = c.SDL_GetBasePath();
    if (base_c == null) std.debug.panic("SDL_GetBasePath failed: {s}", .{c.SDL_GetError()});
    return std.mem.span(base_c);
}

/// The full path for `path` at `location`, built in `buf`. It is valid for as long as `buf` is.
fn isSafeRelativePath(path: []const u8) bool {
    if (path.len == 0 or path.len > max_full_path) return false;
    if (path[0] == '/' or path[0] == '\\') return false;
    if (std.mem.indexOfScalar(u8, path, ':') != null) return false;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

pub fn absolutePath(location: Location, path: []const u8, buf: []u8) FileError![:0]const u8 {
    if (!isSafeRelativePath(path)) return error.ReadFailed;
    const folder: []const u8 = switch (location) {
        // Both locations resolve beside the executable today. The split is kept so that a user-data
        // location can be added later without changing any caller.
        .packaged, .beside_executable => baseDir(),
    };
    return std.fmt.bufPrintZ(buf, "{s}{s}", .{ folder, path }) catch error.PathTooLong;
}

/// Reads a whole file without logging. The caller owns the result and frees it with `allocator`. A path that
/// does not exist gives `error.NotFound`. SDL reports only that a path can't be examined, so a path that can't
/// be examined is also reported as missing. Any other failure gives `error.ReadFailed`.
///
/// Worker threads use this, because the logger is not safe to call from them. The caller logs the failure.
pub fn readQuiet(allocator: std.mem.Allocator, location: Location, path: []const u8) FileError![]u8 {
    var buf: [max_full_path]u8 = undefined;
    const full = try absolutePath(location, path, &buf);
    var info: c.SDL_PathInfo = undefined;
    if (!c.SDL_GetPathInfo(full.ptr, &info)) return error.NotFound;

    var size: usize = 0;
    const data = c.SDL_LoadFile(full.ptr, &size) orelse return error.ReadFailed;
    defer c.SDL_free(data);
    const bytes: [*]const u8 = @ptrCast(data);
    return allocator.dupe(u8, bytes[0..size]);
}

/// Reads a whole file, logging SDL's reason when the read fails. Main-thread callers use this. The result and
/// errors are the same as `readQuiet`.
pub fn read(allocator: std.mem.Allocator, location: Location, path: []const u8) FileError![]u8 {
    return readQuiet(allocator, location, path) catch |err| {
        if (err == error.ReadFailed) elog.err("could not read '{s}': {s}", .{ path, c.SDL_GetError() });
        return err;
    };
}

/// Writes a whole file by staging it under a temp name and replacing the destination once the file
/// is fully written. This keeps the previous version in place if the write fails partway through.
/// Only `.beside_executable` accepts writes. Any other location gives `error.ReadOnlyLocation`, and
/// the file is not touched.
pub fn write(location: Location, path: []const u8, bytes: []const u8) FileError!void {
    if (location != .beside_executable) return error.ReadOnlyLocation;
    var buf: [max_full_path]u8 = undefined;
    const full = try absolutePath(location, path, &buf);

    var temp_buf: [max_full_path]u8 = undefined;
    const temp = std.fmt.bufPrintZ(&temp_buf, "{s}.tmp", .{full}) catch return error.PathTooLong;
    if (!c.SDL_SaveFile(temp.ptr, bytes.ptr, bytes.len)) {
        _ = c.SDL_RemovePath(temp.ptr);
        elog.err("could not write '{s}': {s}", .{ path, c.SDL_GetError() });
        return error.WriteFailed;
    }
    if (!c.SDL_RenamePath(temp.ptr, full.ptr)) {
        _ = c.SDL_RemovePath(temp.ptr);
        elog.err("could not replace '{s}' atomically: {s}", .{ path, c.SDL_GetError() });
        return error.WriteFailed;
    }
}

/// The last modification time of a file in nanoseconds since the Unix epoch, or null when the path can't be
/// examined. SDL reports a missing file the same way, so both give null.
pub fn modifiedNs(location: Location, path: []const u8) ?i64 {
    var buf: [max_full_path]u8 = undefined;
    const full = absolutePath(location, path, &buf) catch return null;
    var info: c.SDL_PathInfo = undefined;
    if (!c.SDL_GetPathInfo(full.ptr, &info)) return null;
    return @as(i64, @intCast(info.modify_time));
}

test "a missing file has no modification time" {
    try std.testing.expectEqual(@as(?i64, null), modifiedNs(.packaged, "no-such-file-for-the-test.txt"));
}

test "packaged files are read only" {
    try std.testing.expectError(error.ReadOnlyLocation, write(.packaged, "step6_never_written.tmp", "x"));
}

test "a missing file reads as NotFound" {
    try std.testing.expectError(error.NotFound, read(std.testing.allocator, .packaged, "step6_no_such_file.tmp"));
}

test "a written file reads back with the same bytes, owned by the caller's allocator" {
    const name = "step6_files_test.tmp";
    const payload = "bairava step 6\n\x00\xff";
    try write(.beside_executable, name, payload);
    var buf: [max_full_path]u8 = undefined;
    const full = try absolutePath(.beside_executable, name, &buf);
    defer _ = c.SDL_RemovePath(full.ptr);

    // std.testing.allocator reports a leak if the caller does not free these bytes.
    const bytes = try read(std.testing.allocator, .beside_executable, name);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, payload, bytes);
}
