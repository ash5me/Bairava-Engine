//! Crash reports. The frame loop records the frame, the scene, and the held keys and mouse position with a few
//! stores each frame, so a report can say what the run was doing. The panic handler in main.zig calls `report`,
//! which logs the panic line as before and writes the message and that context to a file beside the executable.
//! The recording costs the same in every build and allocates nothing. Pure code, apart from the file write, which
//! goes through log_file.c.

const std = @import("std");
const log = @import("log.zig");
const input = @import("../input/input.zig");

comptime {
    if (std.enums.values(input.Key).len > 64) @compileError("the crash report's key mask needs more than 64 bits");
}

/// Longest path kept for the report file, in bytes, including room for its terminator.
pub const max_path = 1024;
/// Most bytes a report takes. The fields are capped below so a report always fits.
const report_capacity = 2048;
const max_message = 1024;
const max_scene = 256;
const max_keys_text = 256;

/// What the run was doing when it was last recorded.
pub const Context = struct {
    frame: u64 = 0,
    scene: []const u8 = "none",
    /// One bit per key, in the order of `input.Key`. A set bit means the key was held.
    held_keys: u64 = 0,
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
};

var current: Context = .{};
var path_buf: [max_path]u8 = undefined;
var path_len: usize = 0;
/// Set once a report starts, so a panic while reporting cannot start another report.
var reporting = false;

/// Records what the next report will say. The frame loop calls this once per frame.
pub fn note(frame: u64, scene: []const u8, held_keys: u64, mouse_x: f32, mouse_y: f32) void {
    current = .{
        .frame = frame,
        .scene = scene,
        .held_keys = held_keys,
        .mouse_x = mouse_x,
        .mouse_y = mouse_y,
    };
}

/// Sets the file that reports are written to. Returns false when the path is empty or too long, and then no
/// report file is written. The run calls this at startup.
pub fn setReportPath(path: []const u8) bool {
    if (path.len == 0 or path.len >= max_path) {
        path_len = 0;
        return false;
    }
    @memcpy(path_buf[0..path.len], path);
    path_len = path.len;
    return true;
}

/// Removes a report left by an earlier run, so an old report is not mistaken for a new crash.
pub fn clearOldReport() void {
    const path = reportPath() orelse return;
    log.removeCrashFile(path);
}

/// Writes the report for a panic: the message and the context from `note`. The panic handler calls this before
/// Zig prints the stack trace to the terminal. A panic while a report is underway does nothing.
pub fn report(msg: []const u8) void {
    if (reporting) return;
    reporting = true;
    log.recordPanic(msg);
    const path = reportPath() orelse return;
    var text_buf: [report_capacity + 1]u8 = undefined;
    const text = formatReport(text_buf[0..report_capacity], msg, current);
    text_buf[text.len] = 0;
    _ = log.writeCrashFile(path, text_buf[0..text.len :0]);
}

/// Builds the report text in `buf` and returns the part it used. Long fields are cut, so the text fits.
pub fn formatReport(buf: []u8, msg: []const u8, context: Context) []const u8 {
    var keys_buf: [max_keys_text]u8 = undefined;
    const message = msg[0..@min(msg.len, max_message)];
    const scene = context.scene[0..@min(context.scene.len, max_scene)];
    return std.fmt.bufPrint(buf, "crash report\npanic: {s}\nframe: {d}\nscene: {s}\nmouse: {d:.0}, {d:.0} (window points)\nheld keys: {s}\n", .{
        message,
        context.frame,
        scene,
        context.mouse_x,
        context.mouse_y,
        keyNames(&keys_buf, context.held_keys),
    }) catch buf[0..0];
}

/// The names of the keys whose bits are set, joined by ", ", or "none". Stops at the buffer's end.
fn keyNames(buf: []u8, mask: u64) []const u8 {
    var len: usize = 0;
    for (std.enums.values(input.Key)) |key| {
        const bit: u6 = @intCast(@intFromEnum(key));
        if (((mask >> bit) & 1) == 0) continue;
        const name = @tagName(key);
        const separator: usize = if (len == 0) 0 else 2;
        if (len + separator + name.len > buf.len) break;
        if (separator == 2) {
            buf[len] = ',';
            buf[len + 1] = ' ';
            len += 2;
        }
        @memcpy(buf[len..][0..name.len], name);
        len += name.len;
    }
    if (len == 0) return "none";
    return buf[0..len];
}

fn reportPath() ?[:0]const u8 {
    if (path_len == 0) return null;
    path_buf[path_len] = 0;
    return path_buf[0..path_len :0];
}

test "a crash report names the panic, the frame, the scene, the mouse, and the held keys" {
    var buf: [report_capacity]u8 = undefined;
    // Bit 5 is `w` and bit 15 is `space` in input.Key.
    const held = (@as(u64, 1) << 5) | (@as(u64, 1) << 15);
    const text = formatReport(&buf, "index out of bounds", .{
        .frame = 1234,
        .scene = "game.Game",
        .held_keys = held,
        .mouse_x = 12,
        .mouse_y = 80,
    });
    try std.testing.expect(std.mem.indexOf(u8, text, "panic: index out of bounds\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "frame: 1234\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "scene: game.Game\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "mouse: 12, 80 (window points)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "held keys: w, space\n") != null);
}

test "a report with no keys held says none, and an oversized panic message is cut" {
    var buf: [report_capacity]u8 = undefined;
    const long = [_]u8{'x'} ** 2000;
    const text = formatReport(&buf, &long, .{});
    try std.testing.expect(std.mem.indexOf(u8, text, "held keys: none\n") != null);
    try std.testing.expect(text.len <= report_capacity);
}

test "a report path must be non-empty and short enough to keep" {
    const long = [_]u8{'a'} ** max_path;
    try std.testing.expect(!setReportPath(""));
    try std.testing.expect(!setReportPath(&long));
    try std.testing.expect(setReportPath("Semkootru.crash.txt"));
    path_len = 0;
}
