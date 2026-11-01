//! Development hot reload. The watcher notices when a watched file changes on disk, so the game can
//! reload it at a safe point. It decides whether a file changed, and nothing more: it never reads the
//! file and never touches a resource. The game reads the new bytes in `update`, builds the replacement,
//! and switches only when the replacement is valid, so a failed reload keeps what the game has.
//!
//! Rules:
//! - Only the kinds in `Kind` can be watched. Any other type is refused, so nothing is reloaded before
//!   its dependencies and destruction order are defined.
//! - A change is reported once. A new modification time must hold for two looks in a row before it is
//!   reported, so a file that is still being written is not read half-finished.
//! - Looks happen at most once per interval, and the watcher does nothing until the engine gives it a way
//!   to read modification times. The engine only polls in development builds.

const std = @import("std");
const validate = @import("validate.zig");
const dependency_graph = @import("dependency_graph.zig");

/// Capacity for every indexed asset plus a small set of explicit, non-indexed files.
pub const max_watched = dependency_graph.max_assets + 32;
/// Time between two looks at the file system, in nanoseconds.
pub const default_interval_ns: u64 = 250_000_000;

/// What a watched file holds, which decides what the game does when it changes.
pub const Kind = enum {
    /// The texture atlas index and its image. A reload builds a new atlas, then releases the old one.
    atlas,
    /// A sprite-animation definition, read by the animation loader.
    animation,
    /// A runtime output registered from the generated asset index.
    asset,
};

pub const WatchError = error{ Full, InvalidPath, Duplicate };
pub const WatchIndexError = WatchError || dependency_graph.Error;

/// Returns a file's last modification time in nanoseconds, or null when the file can't be examined.
pub const StampFn = *const fn (path: []const u8) ?i64;

const Entry = struct {
    path: []const u8,
    graph_index: ?usize = null,
    kind: Kind,
    /// The modification time the game last reloaded from. Null until the first look.
    stamp: ?i64 = null,
    /// A newer time seen once. It becomes a change only if the next look sees the same time.
    candidate: ?i64 = null,
    /// Set when a change has settled, and cleared by `take`.
    changed: bool = false,
};

pub const Watcher = struct {
    entries: [max_watched]Entry = undefined,
    count: usize = 0,
    graph: dependency_graph.Graph = .{},
    graph_loaded: bool = false,
    /// How a modification time is read. The engine sets it at startup, and nothing is polled without it.
    stat: ?StampFn = null,
    interval_ns: u64 = default_interval_ns,
    next_look_ns: u64 = 0,

    /// Adds a file to follow. The path is relative to the executable's folder, like every asset path.
    pub fn watch(self: *Watcher, path: []const u8, kind: Kind) WatchError!void {
        if (!validate.isSafePath(path)) return error.InvalidPath;
        for (self.entries[0..self.count]) |entry| {
            if (std.mem.eql(u8, self.entryPath(entry), path)) return error.Duplicate;
        }
        if (self.count == max_watched) return error.Full;
        self.entries[self.count] = .{ .path = path, .kind = kind };
        self.count += 1;
    }

    /// Loads the generated asset index and watches every runtime output path. The graph owns copies
    /// of names and paths, so the index buffer can be released immediately after this call.
    pub fn watchIndex(self: *Watcher, index_path: []const u8, text: []const u8) WatchIndexError!void {
        if (self.graph_loaded) return error.Duplicate;
        if (!validate.isSafePath(index_path)) return error.InvalidPath;
        var graph = try dependency_graph.Graph.parse(text);
        try graph.resolvePaths(index_path);
        if (graph.len > max_watched - self.count) return error.Full;
        for (0..graph.len) |index| {
            const path = graph.nodes[index].path.slice();
            for (self.entries[0..self.count]) |entry| {
                if (std.mem.eql(u8, self.entryPath(entry), path)) return error.Duplicate;
            }
            for (graph.nodes[0..index]) |previous| {
                if (std.mem.eql(u8, previous.path.slice(), path)) return error.Duplicate;
            }
        }

        self.graph = graph;
        self.graph_loaded = true;
        for (0..self.graph.len) |index| {
            self.entries[self.count] = .{ .path = "", .graph_index = index, .kind = .asset };
            self.count += 1;
        }
    }

    /// Looks at every watched file, if the interval has passed. The engine calls this once per frame,
    /// before the update steps, which is the safe point for reloading.
    pub fn poll(self: *Watcher, now_ns: u64) void {
        const look = self.stat orelse return;
        if (now_ns < self.next_look_ns) return;
        self.next_look_ns = now_ns + self.interval_ns;
        for (self.entries[0..self.count]) |*entry| {
            examine(entry, look(self.entryPath(entry.*)));
        }
    }

    /// True once after a watched file has changed. A second call for the same path returns false until
    /// the file changes again. An unwatched path always returns false.
    pub fn take(self: *Watcher, path: []const u8) bool {
        for (self.entries[0..self.count]) |*entry| {
            if (std.mem.eql(u8, self.entryPath(entry.*), path)) {
                const was = entry.changed;
                entry.changed = false;
                return was;
            }
        }
        return false;
    }

    /// Consumes settled changes to `name` or any transitive dependency of that asset.
    pub fn takeAssetChanged(self: *Watcher, name: []const u8) bool {
        if (!self.graph_loaded or self.graph.find(name) == null) return false;
        var affected = false;
        for (self.entries[0..self.count]) |*entry| {
            if (!entry.changed) continue;
            const changed_name = if (entry.graph_index) |index| self.graph.nodes[index].name.slice() else self.graph.nameAtPath(entry.path) orelse continue;
            if (self.graph.isAffected(name, changed_name)) {
                entry.changed = false;
                affected = true;
            }
        }
        return affected;
    }

    /// The kind a path was watched as, or null when it isn't watched.
    pub fn kindOf(self: *const Watcher, path: []const u8) ?Kind {
        for (self.entries[0..self.count]) |entry| {
            if (std.mem.eql(u8, self.entryPath(entry), path)) return entry.kind;
        }
        return null;
    }

    fn entryPath(self: *const Watcher, entry: Entry) []const u8 {
        if (entry.graph_index) |index| return self.graph.nodes[index].path.slice();
        return entry.path;
    }
};

/// One look at one file. `seen` is the time just read, or null when the file could not be examined. A
/// missing file keeps its state, so a file that is briefly absent during a rebuild is not a change.
fn examine(entry: *Entry, seen: ?i64) void {
    const now = seen orelse return;
    const stamp = entry.stamp orelse {
        entry.stamp = now;
        return;
    };
    if (now == stamp) {
        entry.candidate = null;
        return;
    }
    if (entry.candidate) |pending| {
        if (pending == now) {
            entry.stamp = now;
            entry.candidate = null;
            entry.changed = true;
            return;
        }
    }
    entry.candidate = now;
}

// ---- Tests -----------------------------------------------------------------------------------------------

/// The time the fake file system reports. A test sets it, and null means the file is missing.
var fake_stamp: ?i64 = null;

fn fakeStat(path: []const u8) ?i64 {
    _ = path;
    return fake_stamp;
}

test "a change is reported once, and only after the new time holds for two looks" {
    var watcher = Watcher{ .stat = &fakeStat, .interval_ns = 0 };
    try watcher.watch("assets/atlas.txt", .atlas);

    fake_stamp = 100;
    watcher.poll(1); // The first look records the time, so nothing has changed yet.
    try std.testing.expect(!watcher.take("assets/atlas.txt"));

    fake_stamp = 200;
    watcher.poll(2); // A new time, seen once: not reported yet.
    try std.testing.expect(!watcher.take("assets/atlas.txt"));

    watcher.poll(3); // The same new time on a second look: reported.
    try std.testing.expect(watcher.take("assets/atlas.txt"));
    try std.testing.expect(!watcher.take("assets/atlas.txt"));

    watcher.poll(4); // Nothing else changed, so nothing more is reported.
    try std.testing.expect(!watcher.take("assets/atlas.txt"));
}

test "a file that keeps changing while it is written is not reported until it settles" {
    var watcher = Watcher{ .stat = &fakeStat, .interval_ns = 0 };
    try watcher.watch("assets/atlas.txt", .atlas);

    fake_stamp = 100;
    watcher.poll(1);
    fake_stamp = 200;
    watcher.poll(2);
    fake_stamp = 300; // Still changing, so the candidate moves on.
    watcher.poll(3);
    try std.testing.expect(!watcher.take("assets/atlas.txt"));

    watcher.poll(4); // Finally the same time twice.
    try std.testing.expect(watcher.take("assets/atlas.txt"));
}

test "a missing file keeps its state, so a rebuild that removes it briefly is not a change" {
    var watcher = Watcher{ .stat = &fakeStat, .interval_ns = 0 };
    try watcher.watch("assets/atlas.txt", .atlas);

    fake_stamp = 100;
    watcher.poll(1);
    fake_stamp = null;
    watcher.poll(2);
    fake_stamp = 100;
    watcher.poll(3);
    try std.testing.expect(!watcher.take("assets/atlas.txt"));
}

test "polling waits for the interval between looks" {
    var watcher = Watcher{ .stat = &fakeStat, .interval_ns = 1000 };
    try watcher.watch("assets/atlas.txt", .atlas);

    fake_stamp = 100;
    watcher.poll(0);
    fake_stamp = 200;
    watcher.poll(500); // Too soon to look.
    watcher.poll(1000); // A look: the new time is a candidate.
    try std.testing.expect(!watcher.take("assets/atlas.txt"));
    watcher.poll(2000); // The second look confirms it.
    try std.testing.expect(watcher.take("assets/atlas.txt"));
}

test "a watcher with no way to read times does nothing" {
    var watcher = Watcher{};
    try watcher.watch("assets/atlas.txt", .atlas);
    watcher.poll(0);
    try std.testing.expect(!watcher.take("assets/atlas.txt"));
}

test "unsafe paths, duplicates, and a full list are refused" {
    var watcher = Watcher{};
    try std.testing.expectError(error.InvalidPath, watcher.watch("../secret.txt", .atlas));
    try std.testing.expectError(error.InvalidPath, watcher.watch("/etc/atlas.txt", .atlas));
    try watcher.watch("assets/atlas.txt", .atlas);
    try std.testing.expectError(error.Duplicate, watcher.watch("assets/atlas.txt", .animation));
    try std.testing.expectEqual(Kind.atlas, watcher.kindOf("assets/atlas.txt").?);

    var names: [max_watched][24]u8 = undefined;
    var i: usize = 1;
    while (i < max_watched) : (i += 1) {
        const path = try std.fmt.bufPrint(&names[i], "assets/f{d}.txt", .{i});
        try watcher.watch(path, .animation);
    }
    try std.testing.expectError(error.Full, watcher.watch("assets/one_more.txt", .animation));
}

var graph_source_stamp: i64 = 100;

fn graphFakeStat(path: []const u8) ?i64 {
    if (std.mem.eql(u8, path, "assets/source.png")) return graph_source_stamp;
    return 100;
}

test "indexed changes invalidate transitive dependents once" {
    const index =
        \\# asset-index-v1
        \\source image source.png source.png -
        \\map file map.txt map.txt source
        \\spawn file spawn.txt spawn.txt map
        \\other file other.txt other.txt -
        \\
    ;
    var watcher = Watcher{ .stat = &graphFakeStat, .interval_ns = 0 };
    try watcher.watchIndex("assets/asset-index.txt", index);
    try std.testing.expectEqual(Kind.asset, watcher.kindOf("assets/source.png").?);

    graph_source_stamp = 100;
    watcher.poll(1);
    graph_source_stamp = 200;
    watcher.poll(2);
    watcher.poll(3);

    try std.testing.expect(watcher.takeAssetChanged("spawn"));
    try std.testing.expect(!watcher.takeAssetChanged("spawn"));
    try std.testing.expect(!watcher.takeAssetChanged("other"));
}

test "asset index registration rejects duplicate watched paths and capacity overflow" {
    var watcher = Watcher{};
    try watcher.watch("assets/source.png", .atlas);
    try std.testing.expectError(error.Duplicate, watcher.watchIndex("assets/asset-index.txt",
        \\source image source.png source.png -
    ));

    var full = Watcher{};
    var paths: [max_watched][24]u8 = undefined;
    for (0..max_watched) |i| {
        const path = try std.fmt.bufPrint(&paths[i], "assets/f{d}.txt", .{i});
        try full.watch(path, .asset);
    }
    try std.testing.expectError(error.Full, full.watchIndex("assets/asset-index.txt",
        \\asset file assets/extra.txt extra.txt -
    ));
}
