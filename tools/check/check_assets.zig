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
const max_manifest_assets = 256;
/// The manifest name of the game's prefab file. Level metadata must depend on it.
const prefab_asset_name = "game_prefabs";

const ManifestAsset = struct {
    name: []const u8,
    kind: []const u8,
    source: []const u8,
    dependencies: []const u8,
    map_size: ?MapSize = null,
};

const MapSize = struct {
    cols: u32,
    rows: u32,
};

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

fn collectManifestAssets(text: []const u8, assets: *[max_manifest_assets]ManifestAsset) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t\r");
        const name = fields.next() orelse continue;
        const kind = fields.next() orelse continue;
        const source = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const dependencies = fields.next() orelse continue;
        if (count == assets.len) break;
        assets[count] = .{
            .name = name,
            .kind = kind,
            .source = source,
            .dependencies = dependencies,
        };
        count += 1;
    }
    return count;
}

fn isExtension(path: []const u8, extension: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
    return dot >= slash and std.ascii.eqlIgnoreCase(path[dot + 1 ..], extension);
}

fn dependencyMapSize(asset: *const ManifestAsset, assets: []const ManifestAsset) ?MapSize {
    if (std.mem.eql(u8, asset.dependencies, "-")) return null;
    var dependencies = std.mem.splitScalar(u8, asset.dependencies, ',');
    while (dependencies.next()) |name| {
        for (assets) |dependency| {
            if (std.mem.eql(u8, dependency.name, name) and std.mem.eql(u8, dependency.kind, "map")) {
                return dependency.map_size;
            }
        }
    }
    return null;
}

/// The source path of the `file` asset that `asset` depends on under the name `wanted`, or null when none does.
fn dependencySource(asset: *const ManifestAsset, assets: []const ManifestAsset, wanted: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, asset.dependencies, "-")) return null;
    var dependencies = std.mem.splitScalar(u8, asset.dependencies, ',');
    while (dependencies.next()) |name| {
        if (!std.mem.eql(u8, name, wanted)) continue;
        for (assets) |dependency| {
            if (std.mem.eql(u8, dependency.name, name) and std.mem.eql(u8, dependency.kind, "file")) return dependency.source;
        }
    }
    return null;
}

fn dependencyImageName(asset: *const ManifestAsset, assets: []const ManifestAsset) ?[]const u8 {
    if (std.mem.eql(u8, asset.dependencies, "-")) return null;
    var dependencies = std.mem.splitScalar(u8, asset.dependencies, ',');
    while (dependencies.next()) |name| {
        for (assets) |dependency| {
            if (std.mem.eql(u8, dependency.name, name) and std.mem.eql(u8, dependency.kind, "image")) {
                return dependency.name;
            }
        }
    }
    return null;
}

fn checkAssetContent(
    allocator: std.mem.Allocator,
    manifest_text: []const u8,
    atlas_index_text: ?[]const u8,
    report: *check.validate.Report,
) void {
    var assets: [max_manifest_assets]ManifestAsset = undefined;
    const asset_count = collectManifestAssets(manifest_text, &assets);
    const project_assets = assets[0..asset_count];

    for (project_assets) |*asset| {
        if (!std.mem.eql(u8, asset.kind, "map")) continue;
        if (!check.validate.isSafePath(asset.source)) continue;
        const text = readFile(allocator, asset.source) orelse {
            report.add(asset.source, 0, "file could not be read");
            continue;
        };
        defer allocator.free(text);
        var map = check.tilemap.TileMap.parse(allocator, text) catch |err| {
            report.add(asset.source, 0, @errorName(err));
            continue;
        };
        asset.map_size = .{ .cols = map.cols, .rows = map.rows };
        map.deinit(allocator);
    }

    for (project_assets) |*asset| {
        if (!std.mem.eql(u8, asset.kind, "file")) continue;
        if (!check.validate.isSafePath(asset.source)) continue;

        if (std.mem.eql(u8, asset.name, prefab_asset_name)) {
            const text = readFile(allocator, asset.source) orelse {
                report.add(asset.source, 0, "file could not be read");
                continue;
            };
            defer allocator.free(text);
            _ = check.prefab.parse(text) catch |err| {
                report.add(asset.source, 0, @errorName(err));
                continue;
            };
        } else if (isExtension(asset.source, "spawn")) {
            const dimensions = dependencyMapSize(asset, project_assets) orelse {
                report.add(asset.source, 0, "spawn metadata must depend on a valid map asset");
                continue;
            };
            const prefab_source = dependencySource(asset, project_assets, prefab_asset_name) orelse {
                report.add(asset.source, 0, "spawn metadata must depend on the " ++ prefab_asset_name ++ " asset");
                continue;
            };
            const prefab_text = readFile(allocator, prefab_source) orelse {
                report.add(asset.source, 0, "prefab file could not be read");
                continue;
            };
            defer allocator.free(prefab_text);
            // A broken prefab file is reported on its own line of this loop, so here it only stops the placement check.
            const registry = check.prefab.parse(prefab_text) catch continue;
            const text = readFile(allocator, asset.source) orelse {
                report.add(asset.source, 0, "file could not be read");
                continue;
            };
            defer allocator.free(text);
            const data = check.level_data.parse(allocator, &registry, dimensions.cols, dimensions.rows, text) catch |err| {
                report.add(asset.source, 0, @errorName(err));
                continue;
            };
            data.deinit(allocator);
        } else if (isExtension(asset.source, "anim")) {
            const image_name = dependencyImageName(asset, project_assets) orelse {
                report.add(asset.source, 0, "animation asset must depend on its atlas image asset");
                continue;
            };
            const text = readFile(allocator, asset.source) orelse {
                report.add(asset.source, 0, "file could not be read");
                continue;
            };
            defer allocator.free(text);

            var dimensions = check.validate.ImageSize{
                .w = std.math.maxInt(u32),
                .h = std.math.maxInt(u32),
            };
            if (atlas_index_text) |index_text| {
                dimensions = check.validate.atlasSpriteSize(index_text, image_name) orelse {
                    report.add(asset.source, 0, "animation image dependency is missing from the built atlas");
                    continue;
                };
            }
            var library = check.animation.Library.parse(allocator, text, dimensions.w, dimensions.h) catch |err| {
                report.add(asset.source, 0, @errorName(err));
                continue;
            };
            library.deinit();
        }
    }
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var marker: u8 = 0;
    const files = check.validate.Files{ .context = &marker, .exists = &fileExists };
    var report = check.validate.Report{};

    const manifest_path = "assets/asset_manifest.txt";
    var manifest_text: ?[]u8 = null;
    defer if (manifest_text) |text| allocator.free(text);
    if (readFile(allocator, manifest_path)) |text| {
        manifest_text = text;
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
    const atlas_index_text = readFile(allocator, index_path);
    defer if (atlas_index_text) |text| allocator.free(text);
    if (atlas_index_text) |index_text| {
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
    if (manifest_text) |text| {
        checkAssetContent(allocator, text, atlas_index_text, &report);
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
