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

/// What a `FontStore` points at. Only this file names it.
const State = struct {
    allocator: std.mem.Allocator,
    resources: font_resource.Resources,
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
    const state = try allocator.create(State);
    state.* = .{ .allocator = allocator, .resources = font_resource.Resources.init(allocator) };
    return @ptrCast(state);
}

/// The number of fonts stored.
pub fn count(store: *const FontStore) usize {
    return stateOfConst(store).resources.count();
}

/// Stores a bitmap font under a new handle. The store takes ownership. If the insert fails, the store releases the font
/// before it returns the error, so the caller has nothing left to clean up.
pub fn insertBfnt(store: *FontStore, font_value: font_mod.Font) InsertError!FontHandle {
    var resource = font_resource.FontResource{ .bfnt_coverage = font_value };
    return stateOf(store).resources.insert(resource) catch |err| {
        resource.deinit();
        return err;
    };
}

/// Releases every font, then frees the store. Call it once no handle is in use, and before the GPU device is released.
pub fn destroy(store: *FontStore) void {
    const state = stateOf(store);
    const allocator = state.allocator;
    state.resources.deinitWith(&font_resource.FontResource.deinit);
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
    return .{ .texture = fixtures.texture(1, 1), .baked = .{ .white = .{ .x = 0, .y = 0, .w = 1, .h = 1 } } };
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
