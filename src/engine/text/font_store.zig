//! The session's font store, and the engine code that fills it.
//!
//! Game-facing code reaches fonts through a `*FontStore`: `Context.fonts`, `Canvas.fonts`, and `Ui` hold one. Game code
//! gives the store a `FontHandle` and gets back widths, heights, quad lists, texture pointers, or C widget state. No
//! method on `FontStore` takes or returns the registry, a font resource, or a provider type, so none of those is
//! reachable from game-facing code (plan D-21). `FontStore` is opaque: its state is the private `State` struct in this
//! file, and no other file can read it.
//!
//! The functions below the type belong to the engine. The session creates and destroys the store, and
//! `Context.loadFont` inserts fonts into it. `bairava.zig` does not re-export any of them.
//!
//! Lifetime follows font_registry.zig. A font keeps its address until it is removed, so the C widget state can point at
//! its metrics. A lookup panics on a handle that names no drawable font, because that is a bug in the caller.

const std = @import("std");
const c = @import("../ui/c.zig").c;
const font_registry = @import("font_registry.zig");
const font_resource = @import("font_resource.zig");
const font_mod = @import("font.zig");
const Texture = @import("../renderer/texture.zig").Texture;

pub const FontHandle = font_registry.FontHandle;
pub const InsertError = font_registry.InsertError;

/// Releases one font when the store lets go of it. `create` uses `FontResource.deinit`. Tests pass a counting function, so
/// the store's ownership can be checked without a GPU object behind the font.
pub const Release = *const fn (*font_resource.FontResource) void;

/// What a `FontStore` points at. Only this file names it.
const State = struct {
    allocator: std.mem.Allocator,
    resources: font_resource.Resources,
    release: Release,
};

/// The session's fonts, as game-facing code sees them. Opaque, so its state is reachable only from this file.
pub const FontStore = opaque {
    /// The natural line height of the font `handle` names, in pixels.
    pub fn lineHeight(self: *FontStore, handle: FontHandle) f32 {
        return @floatFromInt(bfntFont(stateOf(self), handle).baked.line_height);
    }

    /// The width of `str` in pixels, in the font `handle` names.
    pub fn textWidth(self: *FontStore, handle: FontHandle, str: []const u8) f32 {
        return c.ui_font_text_width(&bfntFont(stateOf(self), handle).baked, str.ptr, str.len);
    }

    /// Adds `str` to `list` with its top-left corner at (x, y), in pixels, in the font `handle` names.
    pub fn drawText(self: *FontStore, handle: FontHandle, list: *c.ui_quad_list, x: f32, y: f32, str: []const u8, color: c.ui_color) void {
        c.ui_font_draw_text(&bfntFont(stateOf(self), handle).baked, list, x, y, str.ptr, str.len, color);
    }

    /// The atlas texture that the glyphs of `handle`'s font sample. Solid fills never sample it.
    pub fn glyphTexture(self: *FontStore, handle: FontHandle) *const Texture {
        return &bfntFont(stateOf(self), handle).texture;
    }

    /// Panics unless `handle` names a font the UI can draw. Canvas creation calls this, so a bad handle fails there.
    pub fn check(self: *FontStore, handle: FontHandle) void {
        _ = bfntFont(stateOf(self), handle);
    }

    /// Points the C widget state at the font's metrics. The font keeps its address until it is removed, so the pointer
    /// stays valid for as long as the widgets use it.
    pub fn initWidgets(self: *FontStore, handle: FontHandle, ctx: *c.ui_context) void {
        c.ui_init(ctx, &bfntFont(stateOf(self), handle).baked);
    }
};

/// Creates an empty store. The session calls this once, before any font is loaded.
pub fn create(allocator: std.mem.Allocator) std.mem.Allocator.Error!*FontStore {
    return createWithRelease(allocator, &font_resource.FontResource.deinit);
}

/// As `create`, but `release` runs on each font the store lets go of, in place of `FontResource.deinit`. Only tests pass
/// another function, so they can count releases of a font that has no GPU object behind it.
pub fn createWithRelease(allocator: std.mem.Allocator, release: Release) std.mem.Allocator.Error!*FontStore {
    const state = try allocator.create(State);
    state.* = .{ .allocator = allocator, .resources = font_resource.Resources.init(allocator), .release = release };
    return @ptrCast(state);
}

/// The number of fonts stored.
pub fn count(store: *const FontStore) usize {
    return stateOfConst(store).resources.count();
}

/// Stores a bitmap font under a new handle. The store takes ownership. If the insert fails, the store releases the font
/// before it returns the error, so the caller has nothing left to clean up.
pub fn insertBfnt(store: *FontStore, font_value: font_mod.Font) InsertError!FontHandle {
    const state = stateOf(store);
    var resource = font_resource.FontResource{ .bfnt_coverage = font_value };
    return state.resources.insert(resource) catch |err| {
        // Nothing was stored, so the new font is still ours to release. This is the only release on the failure path.
        state.release(&resource);
        return err;
    };
}

/// Releases every font, then frees the store. Call it once no handle is in use, and before the GPU device is released.
pub fn destroy(store: *FontStore) void {
    const state = stateOf(store);
    const allocator = state.allocator;
    state.resources.deinitWith(state.release);
    allocator.destroy(state);
}

/// Frees the store without releasing its fonts. Tests use this for fonts that have no GPU object to release.
pub fn discard(store: *FontStore) void {
    const state = stateOf(store);
    const allocator = state.allocator;
    state.resources.deinit();
    allocator.destroy(state);
}

fn stateOf(store: *FontStore) *State {
    return @ptrCast(@alignCast(store));
}

fn stateOfConst(store: *const FontStore) *const State {
    return @ptrCast(@alignCast(store));
}

fn bfntFont(state: *State, handle: FontHandle) *font_mod.Font {
    const resource = state.resources.get(handle) catch |err| std.debug.panic("UI font handle {d} does not name a loaded font: {s}", .{ handle.id, @errorName(err) });
    return switch (resource.*) {
        .bfnt_coverage => |*font_value| font_value,
        .runtime_coverage => std.debug.panic("UI font handle {d} is an outline font, which the UI cannot draw yet", .{handle.id}),
    };
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

/// A font with empty metrics, except for a 1x1 white block at the origin. Its texture comes from the test fixtures: a
/// texture with no GPU object, so `discard` can free the store without releasing anything.
fn emptyFont() font_mod.Font {
    const fixtures = @import("../test_fixtures.zig");
    // A C struct literal must name every field, so start from zeros and set the one that matters here.
    var baked = std.mem.zeroes(c.ui_font);
    baked.white = .{ .x = 0, .y = 0, .w = 1, .h = 1 };
    return .{ .texture = fixtures.texture(1, 1), .baked = baked };
}

test "a stored font keeps its address while more fonts are stored" {
    const store = try create(testing.allocator);
    defer discard(store);
    const handle = try insertBfnt(store, emptyFont());
    const before = bfntFont(stateOf(store), handle);
    var i: u32 = 0;
    while (i < 64) : (i += 1) _ = try insertBfnt(store, emptyFont());
    try testing.expect(before == bfntFont(stateOf(store), handle));
}

test "a stored font answers its line height and atlas without the C text path" {
    const store = try create(testing.allocator);
    defer discard(store);
    var font_value = emptyFont();
    font_value.baked.line_height = 12;
    const handle = try insertBfnt(store, font_value);
    store.check(handle);
    try testing.expectEqual(@as(f32, 12), store.lineHeight(handle));
    const atlas = store.glyphTexture(handle);
    try testing.expectEqual(@as(*const Texture, &bfntFont(stateOf(store), handle).texture), atlas);
}

test "every FontStore method the engine uses is compiled by the test build" {
    // Taking each address makes this binary analyze and emit the method. initWidgets is left out on purpose: its C call
    // is in imgui.c, which this test binary does not link. The engine build compiles it through Ui.init.
    _ = &FontStore.lineHeight;
    _ = &FontStore.textWidth;
    _ = &FontStore.drawText;
    _ = &FontStore.glyphTexture;
    _ = &FontStore.check;
    _ = &count;
    _ = &destroy;
}

// ---- ownership: who releases a font, and when ------------------------------------------------------------------------
//
// These tests count releases with `recordRelease`, a stand-in for `FontResource.deinit`. A font's marker is its line
// height, so each release can be matched to the font it came from.

/// Markers of the fonts released so far, in release order.
var released_markers: [8]c_int = undefined;
var released_count: usize = 0;

fn recordRelease(resource: *font_resource.FontResource) void {
    switch (resource.*) {
        .bfnt_coverage => |f| {
            released_markers[released_count] = f.baked.line_height;
            released_count += 1;
        },
        .runtime_coverage => @panic("the store test holds only bfnt fonts"),
    }
    resource.* = undefined;
}

/// How many releases carried `marker`.
fn releasesOf(marker: c_int) usize {
    var n: usize = 0;
    for (released_markers[0..released_count]) |m| {
        if (m == marker) n += 1;
    }
    return n;
}

fn countingStore(allocator: std.mem.Allocator) !*FontStore {
    released_count = 0;
    return createWithRelease(allocator, &recordRelease);
}

fn markedFont(marker: c_int) font_mod.Font {
    var font_value = emptyFont();
    font_value.baked.line_height = marker;
    return font_value;
}

test "the store owns a font once it is inserted, so the insert releases nothing" {
    const store = try countingStore(testing.allocator);
    const handle = try insertBfnt(store, markedFont(11));
    try testing.expectEqual(@as(usize, 0), released_count);
    try testing.expectEqual(@as(usize, 1), count(store));
    try testing.expectEqual(@as(f32, 11), store.lineHeight(handle));
    destroy(store);
    try testing.expectEqual(@as(usize, 1), releasesOf(11));
}

test "destroy releases each stored font exactly once, and nothing before it" {
    const store = try countingStore(testing.allocator);
    _ = try insertBfnt(store, markedFont(21));
    _ = try insertBfnt(store, markedFont(22));
    _ = try insertBfnt(store, markedFont(23));
    try testing.expectEqual(@as(usize, 0), released_count);
    destroy(store);
    try testing.expectEqual(@as(usize, 3), released_count);
    try testing.expectEqual(@as(usize, 1), releasesOf(21));
    try testing.expectEqual(@as(usize, 1), releasesOf(22));
    try testing.expectEqual(@as(usize, 1), releasesOf(23));
}

test "an insert that fails to allocate releases the new font once, and stores nothing" {
    // Allocation 0 is the store's own State, which must succeed. Allocation 1 is the registry's slot for the new font,
    // and it fails. The new font is then the only thing that can leak, so it must be released here.
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    const store = try countingStore(failing.allocator());
    try testing.expectError(error.OutOfMemory, insertBfnt(store, markedFont(31)));
    try testing.expectEqual(@as(usize, 1), released_count);
    try testing.expectEqual(@as(usize, 1), releasesOf(31));
    try testing.expectEqual(@as(usize, 0), count(store));
    destroy(store);
    try testing.expectEqual(@as(usize, 1), released_count);
}

test "an insert that runs out of font ids releases the new font, and keeps the fonts it had" {
    const store = try countingStore(testing.allocator);
    _ = try insertBfnt(store, markedFont(41));
    // The next id to issue is the last one. The id is refused before anything is allocated, which is a second failure
    // path with no allocation to fail, so it needs its own check.
    stateOf(store).resources.next_id = std.math.maxInt(font_registry.FontId);
    try testing.expectError(error.FontIdExhausted, insertBfnt(store, markedFont(42)));
    try testing.expectEqual(@as(usize, 1), released_count);
    try testing.expectEqual(@as(usize, 1), releasesOf(42));
    try testing.expectEqual(@as(usize, 1), count(store));
    destroy(store);
    try testing.expectEqual(@as(usize, 2), released_count);
    try testing.expectEqual(@as(usize, 1), releasesOf(41));
}

test "discard frees the store without releasing its fonts" {
    const store = try countingStore(testing.allocator);
    _ = try insertBfnt(store, markedFont(51));
    discard(store);
    try testing.expectEqual(@as(usize, 0), released_count);
}
