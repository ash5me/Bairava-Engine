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
    output: []const u8,
    dependencies: []const u8,
    line: u32,
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

fn pathExists(path: []const u8) bool {
    var context: u8 = 0;
    return fileExists(&context, path);
}

fn collectManifestAssets(text: []const u8, assets: *[max_manifest_assets]ManifestAsset) usize {
    var count: usize = 0;
    var line_number: u32 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        line_number += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t\r");
        const name = fields.next() orelse continue;
        const kind = fields.next() orelse continue;
        const source = fields.next() orelse continue;
        const output = fields.next() orelse continue;
        const dependencies = fields.next() orelse continue;
        if (count == assets.len) break;
        assets[count] = .{
            .name = name,
            .kind = kind,
            .source = source,
            .output = output,
            .dependencies = dependencies,
            .line = line_number,
        };
        count += 1;
    }
    return count;
}

fn basename(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

fn folder(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
    return path[0..slash];
}

fn sameFolder(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, folder(left), folder(right));
}

fn safePageName(name: []const u8) bool {
    return name.len != 0 and
        !std.mem.eql(u8, name, ".") and
        !std.mem.eql(u8, name, "..") and
        std.mem.indexOfAny(u8, name, "/\\:") == null;
}

fn descriptorPageFileIsQuoted(text: []const u8, wanted_id: u32, wanted_file: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "page ") and !std.mem.startsWith(u8, line, "page\t")) continue;
        const id_key = std.mem.indexOf(u8, line, "id=") orelse continue;
        const id_start = id_key + 3;
        var id_end = id_start;
        while (id_end < line.len and line[id_end] >= '0' and line[id_end] <= '9') : (id_end += 1) {}
        const id = std.fmt.parseInt(u32, line[id_start..id_end], 10) catch continue;
        if (id != wanted_id) continue;
        const file_key = std.mem.indexOf(u8, line, "file=") orelse return false;
        const value_start = file_key + 5;
        if (value_start >= line.len or line[value_start] != '"') return false;
        const value_end = std.mem.indexOfScalarPos(u8, line, value_start + 1, '"') orelse return false;
        return std.mem.eql(u8, line[value_start + 1 .. value_end], wanted_file);
    }
    return false;
}

fn assetNamed(assets: []const ManifestAsset, name: []const u8) ?*const ManifestAsset {
    for (assets) |*asset| {
        if (std.mem.eql(u8, asset.name, name)) return asset;
    }
    return null;
}

fn dependencyNamed(asset: *const ManifestAsset, assets: []const ManifestAsset, name: []const u8) ?*const ManifestAsset {
    if (std.mem.eql(u8, asset.dependencies, "-")) return null;
    var dependencies = std.mem.splitScalar(u8, asset.dependencies, ',');
    while (dependencies.next()) |dependency| {
        if (std.mem.eql(u8, dependency, name)) return assetNamed(assets, name);
    }
    return null;
}

fn pngGray8Size(bytes: []const u8) ?check.validate.ImageSize {
    const size = check.validate.pngSize(bytes) orelse return null;
    if (bytes.len < 26 or std.mem.readInt(u32, bytes[8..12], .big) != 13 or bytes[24] != 8 or bytes[25] != 0) return null;
    return size;
}

fn packagedAssetPath(allocator: std.mem.Allocator, output: []const u8) ?[]u8 {
    return std.fmt.allocPrint(allocator, "zig-out/bin/assets/{s}", .{output}) catch null;
}

fn checkBitmapFontContent(
    allocator: std.mem.Allocator,
    asset: *const ManifestAsset,
    assets: []const ManifestAsset,
    used_coverage: []bool,
    report: *check.validate.Report,
) void {
    for (assets) |dependency| {
        if (dependencyNamed(asset, assets, dependency.name) != null and !std.mem.eql(u8, dependency.kind, "coverage")) {
            report.add(asset.source, asset.line, "bitmap_font dependencies must name coverage assets");
        }
    }

    const descriptor_text = readFile(allocator, asset.source) orelse {
        report.add(asset.source, asset.line, "bitmap font descriptor could not be read");
        return;
    };
    defer allocator.free(descriptor_text);

    var diagnostic: check.bmfont.Diagnostic = .{};
    var font = check.bmfont.parse(allocator, descriptor_text, .{}, &diagnostic) catch {
        check.bmfont_check.checkDescriptor(allocator, asset.source, descriptor_text, &.{}, report);
        return;
    };
    defer font.deinit();

    var page_images = allocator.alloc(?check.validate.ImageSize, font.pages.len) catch {
        report.add(asset.source, asset.line, "out of memory while checking bitmap font pages");
        return;
    };
    defer allocator.free(page_images);
    @memset(page_images, null);
    var matched_dependencies = allocator.alloc(bool, assets.len) catch {
        report.add(asset.source, asset.line, "out of memory while checking bitmap font dependencies");
        return;
    };
    defer allocator.free(matched_dependencies);
    @memset(matched_dependencies, false);

    for (font.pages, 0..) |page, page_index| {
        if (!safePageName(page.file) or !descriptorPageFileIsQuoted(descriptor_text, page.id, page.file)) {
            report.add(asset.source, asset.line, "bitmap font page file must be a non-empty quoted basename");
            continue;
        }

        var matched_index: ?usize = null;
        for (assets, 0..) |dependency, dependency_index| {
            if (dependencyNamed(asset, assets, dependency.name) == null) continue;
            if (!std.mem.eql(u8, dependency.kind, "coverage")) continue;
            if (std.mem.eql(u8, basename(dependency.source), page.file)) {
                if (matched_index != null) {
                    report.add(asset.source, asset.line, "a bitmap font page must match exactly one coverage source");
                    matched_index = null;
                    break;
                }
                matched_index = dependency_index;
            }
        }
        const dependency_index = matched_index orelse {
            report.add(asset.source, asset.line, "bitmap font page does not match a coverage dependency by PNG basename");
            continue;
        };
        const coverage = &assets[dependency_index];
        matched_dependencies[dependency_index] = true;
        if (!sameFolder(asset.source, coverage.source)) {
            report.add(asset.source, asset.line, "bitmap font and coverage sources must share a folder");
        }
        if (!sameFolder(asset.output, coverage.output)) {
            report.add(asset.source, asset.line, "bitmap font and coverage outputs must share a folder");
        }
        if (dependency_index < used_coverage.len) used_coverage[dependency_index] = true;

        const png_bytes = readFile(allocator, coverage.source) orelse {
            report.add(coverage.source, asset.line, "coverage PNG could not be read");
            continue;
        };
        defer allocator.free(png_bytes);
        page_images[page_index] = pngGray8Size(png_bytes);
        if (page_images[page_index] == null) report.add(coverage.source, asset.line, "coverage source must be an 8-bit grayscale PNG");

        const expected = std.math.mul(usize, @intCast(font.scale_w), @intCast(font.scale_h)) catch {
            report.add(asset.source, asset.line, "bitmap font atlas byte length overflows");
            continue;
        };
        if (packagedAssetPath(allocator, coverage.output)) |r8_path| {
            defer allocator.free(r8_path);
            if (pathExists(r8_path)) {
                const r8_bytes = readFile(allocator, r8_path) orelse {
                    report.add(r8_path, 0, "coverage output could not be read");
                    continue;
                };
                defer allocator.free(r8_bytes);
                if (r8_bytes.len != expected) report.add(r8_path, 0, "coverage output must contain exactly scaleW * scaleH bytes");
            }
        } else {
            report.add(coverage.output, 0, "coverage output path could not be built");
        }
    }

    check.bmfont_check.checkDescriptor(allocator, asset.source, descriptor_text, page_images, report);
    for (assets, 0..) |dependency, dependency_index| {
        if (dependencyNamed(asset, assets, dependency.name) == null) continue;
        if (std.mem.eql(u8, dependency.kind, "coverage") and !matched_dependencies[dependency_index]) {
            report.add(asset.source, asset.line, "every bitmap_font coverage dependency must be used by one page");
        }
    }

    if (packagedAssetPath(allocator, asset.output)) |packed_path| {
        defer allocator.free(packed_path);
        if (!pathExists(packed_path)) return;
        const packed_text = readFile(allocator, packed_path) orelse {
            report.add(packed_path, 0, "packaged bitmap font descriptor could not be read");
            return;
        };
        defer allocator.free(packed_text);
        var packed_font = check.bmfont.parse(allocator, packed_text, .{}, null) catch {
            report.add(packed_path, 0, "packaged bitmap font descriptor is invalid");
            return;
        };
        defer packed_font.deinit();
        for (packed_font.pages) |page| {
            if (!safePageName(page.file) or !std.mem.endsWith(u8, page.file, ".r8")) {
                report.add(packed_path, 0, "packaged bitmap font page file must name an r8 basename");
                continue;
            }
            var matches: usize = 0;
            for (assets) |dependency| {
                if (dependencyNamed(asset, assets, dependency.name) == null or !std.mem.eql(u8, dependency.kind, "coverage")) continue;
                if (std.mem.eql(u8, basename(dependency.output), page.file)) matches += 1;
            }
            if (matches != 1) report.add(packed_path, 0, "packaged bitmap font page does not match exactly one coverage output");
        }
    } else {
        report.add(asset.output, 0, "bitmap font output path could not be built");
    }
}

fn checkBitmapFontAssets(allocator: std.mem.Allocator, assets: []const ManifestAsset, report: *check.validate.Report) void {
    const used_coverage = allocator.alloc(bool, assets.len) catch {
        report.add("assets/asset_manifest.txt", 0, "out of memory while checking coverage usage");
        return;
    };
    defer allocator.free(used_coverage);
    @memset(used_coverage, false);

    for (assets) |*asset| {
        if (!std.mem.eql(u8, asset.kind, "bitmap_font")) continue;
        checkBitmapFontContent(allocator, asset, assets, used_coverage, report);
    }
    for (assets, 0..) |asset, index| {
        if (std.mem.eql(u8, asset.kind, "coverage") and !used_coverage[index]) {
            report.add(asset.source, asset.line, "every coverage asset must be used by a bitmap_font page");
        }
    }
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
    checkBitmapFontAssets(allocator, project_assets, report);
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
