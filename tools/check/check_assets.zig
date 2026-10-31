//! `zig build check-assets`: validates the project's asset manifest and sprite list, and the installed
//! atlas index when `zig-out/bin/assets` has one. It prints each problem as `path:line: reason` and
//! fails the build when there is any. It opens no window and needs no GPU.
//!
//! The tool runs with the project root as its folder, and it reads files through C stdio, so it needs
//! no file API beyond what the C library gives.

const std = @import("std");
const check = @import("asset_check");

const File = opaque {};

extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*File;
extern "c" fn fclose(file: *File) c_int;
extern "c" fn fseek(file: *File, offset: c_long, origin: c_int) c_int;
extern "c" fn ftell(file: *File) c_long;
extern "c" fn fread(buffer: [*]u8, size: usize, count: usize, file: *File) usize;

const seek_set: c_int = 0;
const seek_end: c_int = 2;

/// Reads a whole file. Returns null when it can't be opened or read. The caller frees the bytes.
fn readFile(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    var path_buf: [1024]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return null;
    const file = fopen(path_z.ptr, "rb") orelse return null;
    defer _ = fclose(file);
    if (fseek(file, 0, seek_end) != 0) return null;
    const length = ftell(file);
    if (length < 0) return null;
    if (fseek(file, 0, seek_set) != 0) return null;
    const size: usize = @intCast(length);
    const bytes = allocator.alloc(u8, size) catch return null;
    if (size > 0 and fread(bytes.ptr, 1, size, file) != size) {
        allocator.free(bytes);
        return null;
    }
    return bytes;
}

/// Answers whether a project file exists, by trying to open it.
fn fileExists(context: *anyopaque, path: []const u8) bool {
    _ = context;
    var path_buf: [1024]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return false;
    const file = fopen(path_z.ptr, "rb") orelse return false;
    _ = fclose(file);
    return true;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var marker: u8 = 0;
    const files = check.validate.Files{ .context = &marker, .exists = &fileExists };
    var report = check.validate.Report{};

    const manifest_path = "assets/asset_manifest.txt";
    if (readFile(allocator, manifest_path)) |text| {
        defer allocator.free(text);
        check.validate.checkManifest(manifest_path, text, files, &report);
    } else {
        report.add(manifest_path, 0, "file could not be read");
    }

    const sprites_path = "assets/sprites.txt";
    if (readFile(allocator, sprites_path)) |text| {
        defer allocator.free(text);
        check.validate.checkSprites(sprites_path, text, files, &report);
    } else {
        report.add(sprites_path, 0, "file could not be read");
    }

    // The installed atlas is checked when the build has produced one. Before the first build it is absent,
    // and that is not a problem with the project.
    const index_path = "zig-out/bin/assets/atlas.txt";
    const image_path = "zig-out/bin/assets/atlas.png";
    if (readFile(allocator, index_path)) |index_text| {
        defer allocator.free(index_text);
        var image_size: ?check.validate.ImageSize = null;
        if (readFile(allocator, image_path)) |png| {
            defer allocator.free(png);
            image_size = check.validate.pngSize(png);
            if (image_size == null) report.add(image_path, 0, "file is not a png with a size");
        } else {
            report.add(image_path, 0, "installed atlas image is missing");
        }
        check.validate.checkAtlasIndex(index_path, index_text, image_size, &report);
    }

    if (report.ok()) {
        std.debug.print("asset check: all checks passed\n", .{});
        return;
    }
    for (report.slice()) |issue| {
        if (issue.line == 0) {
            std.debug.print("{s}: {s}\n", .{ issue.path, issue.message });
        } else {
            std.debug.print("{s}:{d}: {s}\n", .{ issue.path, issue.line, issue.message });
        }
    }
    if (report.overflow > 0) std.debug.print("... and {d} more\n", .{report.overflow});
    std.debug.print("asset check: {d} problem(s) found\n", .{report.count + report.overflow});
    return error.AssetCheckFailed;
}
