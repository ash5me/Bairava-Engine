//! Runtime asset dependencies from the generated asset index. Edges point from an asset to the
//! assets it depends on; a changed node invalidates itself and all transitive dependents.

const std = @import("std");
const strings = @import("../memory/string.zig");

pub const max_assets = 256;
const dependency_words = (max_assets + 63) / 64;

pub const Error = error{
    InvalidIndex,
    TooManyAssets,
    DuplicateName,
    DuplicatePath,
    UnknownDependency,
};

const Node = struct {
    name: strings.Name,
    path: strings.Path,
    dependencies: [dependency_words]u64 = [_]u64{0} ** dependency_words,
};

pub const Graph = struct {
    nodes: [max_assets]Node = undefined,
    len: usize = 0,

    /// Parses the first five columns of `asset-index-v1`: name, type, output path, source,
    /// dependencies. Extra columns are metadata and ignored.
    pub fn parse(text: []const u8) Error!Graph {
        var graph = Graph{};
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            if (line[0] == '#') {
                if (std.mem.startsWith(u8, line, "# asset-index-")) {
                    if (!std.mem.eql(u8, line, "# asset-index-v1")) return error.InvalidIndex;
                }
                continue;
            }
            var fields = std.mem.tokenizeAny(u8, line, " \t");
            const name_text = fields.next() orelse return error.InvalidIndex;
            _ = fields.next() orelse return error.InvalidIndex;
            const path_text = fields.next() orelse return error.InvalidIndex;
            _ = fields.next() orelse return error.InvalidIndex;
            _ = fields.next() orelse return error.InvalidIndex;
            if (graph.len == max_assets) return error.TooManyAssets;
            const name = strings.Name.init(name_text) catch return error.InvalidIndex;
            if (path_text.len > strings.max_path_len) return error.InvalidIndex;
            var normalized_path: [strings.max_path_len]u8 = undefined;
            for (path_text, 0..) |character, index| {
                normalized_path[index] = if (character == '\\') '/' else character;
            }
            const path_slice = normalized_path[0..path_text.len];
            const path = strings.Path.init(path_slice) catch return error.InvalidIndex;
            if (graph.find(name_text) != null) return error.DuplicateName;
            for (graph.nodes[0..graph.len]) |node| {
                if (std.mem.eql(u8, node.path.slice(), path_slice)) return error.DuplicatePath;
            }
            graph.nodes[graph.len] = .{ .name = name, .path = path };
            graph.len += 1;
        }

        lines = std.mem.splitScalar(u8, text, '\n');
        var node_index: usize = 0;
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            var fields = std.mem.tokenizeAny(u8, line, " \t");
            _ = fields.next().?;
            _ = fields.next().?;
            _ = fields.next().?;
            _ = fields.next().?;
            const dependencies = fields.next().?;
            if (!std.mem.eql(u8, dependencies, "-")) {
                var names = std.mem.splitScalar(u8, dependencies, ',');
                while (names.next()) |dependency_name| {
                    const dependency = graph.find(dependency_name) orelse return error.UnknownDependency;
                    graph.nodes[node_index].dependencies[dependency / 64] |= @as(u64, 1) << @intCast(dependency % 64);
                }
            }
            node_index += 1;
        }
        return graph;
    }

    pub fn find(self: *const Graph, name: []const u8) ?usize {
        for (self.nodes[0..self.len], 0..) |node, index| {
            if (std.mem.eql(u8, node.name.slice(), name)) return index;
        }
        return null;
    }

    pub fn pathOf(self: *const Graph, name: []const u8) ?[]const u8 {
        const index = self.find(name) orelse return null;
        return self.nodes[index].path.slice();
    }

    /// Resolves output paths relative to the directory containing the generated index.
    pub fn resolvePaths(self: *Graph, index_path: []const u8) Error!void {
        const index = strings.Path.init(index_path) catch return error.InvalidIndex;
        const index_slice = index.slice();
        const directory_end = std.mem.lastIndexOfScalar(u8, index_slice, '/') orelse return;
        const directory = index_slice[0..directory_end];
        if (directory.len == 0) return error.InvalidIndex;

        for (self.nodes[0..self.len]) |*node| {
            const relative_path = node.path.slice();
            const resolved_len = directory.len + 1 + relative_path.len;
            if (resolved_len > strings.max_path_len) return error.InvalidIndex;
            var resolved: [strings.max_path_len]u8 = undefined;
            @memcpy(resolved[0..directory.len], directory);
            resolved[directory.len] = '/';
            @memcpy(resolved[directory.len + 1 .. resolved_len], relative_path);
            node.path = strings.Path.init(resolved[0..resolved_len]) catch return error.InvalidIndex;
        }
    }

    pub fn nameAtPath(self: *const Graph, path: []const u8) ?[]const u8 {
        for (self.nodes[0..self.len]) |node| {
            if (std.mem.eql(u8, node.path.slice(), path)) return node.name.slice();
        }
        return null;
    }

    /// True if `target` is `changed` or transitively depends on it.
    pub fn isAffected(self: *const Graph, target: []const u8, changed: []const u8) bool {
        const target_index = self.find(target) orelse return false;
        const changed_index = self.find(changed) orelse return false;
        if (target_index == changed_index) return true;

        var visited = [_]u64{0} ** dependency_words;
        var pending: [max_assets]usize = undefined;
        var pending_len: usize = 0;
        const root = self.nodes[target_index].dependencies;
        for (0..max_assets) |index| {
            if ((root[index / 64] & (@as(u64, 1) << @intCast(index % 64))) == 0) continue;
            visited[index / 64] |= @as(u64, 1) << @intCast(index % 64);
            pending[pending_len] = index;
            pending_len += 1;
        }

        while (pending_len > 0) {
            pending_len -= 1;
            const current = pending[pending_len];
            if (current == changed_index) return true;
            for (0..max_assets) |index| {
                if ((self.nodes[current].dependencies[index / 64] & (@as(u64, 1) << @intCast(index % 64))) == 0) continue;
                const next_mask = @as(u64, 1) << @intCast(index % 64);
                if ((visited[index / 64] & next_mask) == 0) {
                    visited[index / 64] |= next_mask;
                    pending[pending_len] = index;
                    pending_len += 1;
                }
            }
        }
        return false;
    }
};

test "index graph resolves runtime paths and transitive dependencies" {
    const text =
        \\# asset-index-v1
        \\source image assets/source.png source.png -
        \\map file assets/map.txt map.txt source
        \\spawn file assets/spawn.txt spawn.txt map
        \\unrelated file assets/other.txt other.txt -
        \\
    ;
    const graph = try Graph.parse(text);
    try std.testing.expectEqualStrings("assets/map.txt", graph.pathOf("map").?);
    try std.testing.expect(graph.isAffected("source", "source"));
    try std.testing.expect(graph.isAffected("spawn", "map"));
    try std.testing.expect(graph.isAffected("spawn", "source"));
    try std.testing.expect(!graph.isAffected("unrelated", "source"));
    try std.testing.expect(!graph.isAffected("missing", "source"));
}

test "index graph normalizes Windows output paths" {
    const graph = try Graph.parse(
        \\# asset-index-v1
        \\map file assets\maps\level.txt level.txt -
    );
    try std.testing.expectEqualStrings("assets/maps/level.txt", graph.pathOf("map").?);
}

test "index graph resolves outputs beside its index file" {
    var graph = try Graph.parse(
        \\# asset-index-v1
        \\map file maps/level.txt level.txt -
    );
    try graph.resolvePaths("assets/asset-index.txt");
    try std.testing.expectEqualStrings("assets/maps/level.txt", graph.pathOf("map").?);
}

test "index graph rejects invalid dependencies and duplicate assets" {
    try std.testing.expectError(error.UnknownDependency, Graph.parse(
        \\map file assets/map.txt map.txt missing
    ));
    try std.testing.expectError(error.DuplicateName, Graph.parse(
        \\map file assets/a.txt a.txt -
        \\map file assets/b.txt b.txt -
    ));
    try std.testing.expectError(error.DuplicatePath, Graph.parse(
        \\map file assets/a.txt a.txt -
        \\other file assets/a.txt other.txt -
    ));
    try std.testing.expectError(error.InvalidIndex, Graph.parse(
        \\# asset-index-v2
        \\map file assets/a.txt a.txt -
    ));
}
