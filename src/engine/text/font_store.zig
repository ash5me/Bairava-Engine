//! The session's font store, and the engine code that fills it.
//!
//! Game-facing code reaches fonts through a `*FontStore`: `Context.fonts`, `Canvas.fonts`, and `Ui` hold one. Game code
//! gives the store a `FontHandle` and gets back widths, heights, quad lists, or C widget state. No
//! method on `FontStore` takes or returns the registry, a font resource, or a provider type, so none of those is
//! reachable from game-facing code (plan D-21). `FontStore` is opaque: its state is the private `State` struct in this
//! file, and no other file can read it.
//!
//! The functions below the type belong to the engine. The session creates and destroys the store, and
//! `Context.loadFont` inserts fonts into it. `bairava.zig` does not re-export any of them.
//!
//! Lifetime follows font_registry.zig. A font keeps its address until it is removed, and C widget callbacks keep only
//! the store and handle, so measurement and drawing always dispatch through the active provider.

const std = @import("std");
const c = @import("../ui/c.zig").c;
const font_registry = @import("font_registry.zig");
const font_resource = @import("font_resource.zig");
const font_mod = @import("font.zig");
const runtime_font = @import("runtime_font.zig");
const shaper = @import("shaper.zig");
const bitmap_mapper = @import("bitmap_mapper.zig");
const bfnt_measure = @import("bfnt_measure.zig");
const text_layout = @import("layout.zig");
const shaped_layout = @import("shaped_layout.zig");
const glyph_records = @import("glyph_records.zig");
const glyph_cache = @import("glyph_cache.zig");
const glyph_atlas = @import("../renderer/glyph_atlas.zig");
const platform = @import("../platform/platform.zig");
const Texture = @import("../renderer/texture.zig").Texture;

pub const FontHandle = font_registry.FontHandle;
pub const InsertError = font_registry.InsertError;
pub const LayoutError = shaped_layout.LayoutError;
pub const DrawError = error{ RuntimeDrawingUnavailable, LayoutFontMismatch, QuadListFull } || glyph_records.Error || LayoutError;
pub const UnloadError = font_registry.LookupError || std.mem.Allocator.Error;

/// The fonts the store holds, counted by how they are drawn. Plain numbers, so game code reads them without any engine type.
pub const Stats = struct {
    /// Every font stored.
    fonts: usize,
    /// Fonts drawn from a prebaked `.bfnt` coverage atlas.
    bfnt_coverage: usize,
    /// Fonts baked into an offline MSDF atlas with a coverage fallback.
    msdf: usize,
    /// Fonts drawn from hand-authored bitmap coverage pages.
    bitmap: usize,
    /// Fonts rasterized at runtime from a TrueType face.
    runtime_coverage: usize,
};

/// How one font's glyphs reach the screen. Plain values, for the debug overlay and for logs.
pub const Description = struct {
    source: Source,
    mode: Mode,

    pub const Source = enum { bfnt_prebaked, msdf_outline, bitmap, runtime_outline };
    pub const Mode = enum { prebaked_coverage, msdf, bitmap_coverage, gray_coverage };
};

/// Plain text-path counters for profiling. Timings cover HarfBuzz calls; cache and upload counters are cumulative.
pub const ProfileStats = struct {
    shape_calls: u64 = 0,
    shape_nanoseconds: u64 = 0,
    measure_calls: u64 = 0,
    measure_nanoseconds: u64 = 0,
    glyph_cache_hits: u64 = 0,
    glyph_cache_misses: u64 = 0,
    glyphs_rasterized: u64 = 0,
    atlas_pages: u32 = 0,
    atlas_cpu_bytes: u64 = 0,
    atlas_gpu_upload_bytes: u64 = 0,
    atlas_gpu_upload_regions: u64 = 0,
    retired_fonts: usize = 0,
};

/// Releases one font when the store lets go of it. `create` uses `FontResource.deinit`. Tests pass a counting function, so
/// the store's ownership can be checked without a GPU object behind the font.
pub const Release = *const fn (*font_resource.FontResource) void;

/// What a `FontStore` points at. Only this file names it.
const State = struct {
    allocator: std.mem.Allocator,
    resources: font_resource.Resources,
    release: Release,
    atlas: ?*glyph_atlas.Atlas = null,
    retired: std.ArrayList(*font_resource.FontResource) = .empty,
    profile_clock: ?*const fn () u64 = null,
};

/// The session's fonts, as game-facing code sees them. Opaque, so its state is reachable only from this file.
pub const FontStore = opaque {
    /// The natural line height of the font `handle` names, in pixels.
    pub fn lineHeight(self: *FontStore, handle: FontHandle) f32 {
        return resourceOf(stateOf(self), handle).metrics().line_height;
    }

    /// The width of `str` in pixels, in the font `handle` names.
    pub fn textWidth(self: *FontStore, handle: FontHandle, str: []const u8) f32 {
        return switch (resourceOf(stateOf(self), handle).*) {
            .bfnt_coverage => |*font_value| bfnt_measure.width(&font_value.baked, str, 1.0),
            .msdf => |*font_value| msdfShaper(font_value).measure(str, .{}) catch |err|
                std.debug.panic("could not measure MSDF font text: {s}", .{@errorName(err)}),
            .bitmap => |*font_value| bitmapWidth(&font_value.descriptor, str),
            .runtime_coverage => |*font_value| runtimeShaper(font_value).measure(str, .{}) catch |err|
                std.debug.panic("could not measure outline font text: {s}", .{@errorName(err)}),
        };
    }

    /// Adds `str` to `list` with its top-left corner at (x, y), in pixels, in the font `handle` names. Runtime glyphs
    /// use the session atlas; the runtime flushes it before either renderer path submits the batch.
    pub fn drawText(self: *FontStore, handle: FontHandle, list: *c.ui_quad_list, x: f32, y: f32, str: []const u8, color: c.ui_color) DrawError!void {
        switch (resourceOf(stateOf(self), handle).*) {
            .bfnt_coverage => |*font_value| drawBfntText(font_value, list, x, y, str, color),
            .msdf => |*font_value| try drawMsdfText(stateOf(self), handle, font_value, list, x, y, str, color),
            .bitmap => |*font_value| try drawBitmapText(&font_value.descriptor, list, x, y, str, color),
            .runtime_coverage => |*font_value| try drawRuntimeText(
                stateOf(self),
                handle,
                font_value,
                list,
                x,
                y,
                str,
                color,
            ),
        }
    }

    /// Panics unless `handle` names a loaded font. Canvas creation calls this, so a bad handle fails there.
    pub fn check(self: *FontStore, handle: FontHandle) void {
        _ = resourceOf(stateOf(self), handle);
    }

    /// Counts the fonts the store holds, by how they are drawn.
    pub fn stats(self: *FontStore) Stats {
        return statsOf(stateOf(self));
    }

    /// How the font `handle` names is drawn: its source, and the mode its glyphs use. Panics on a handle that names no
    /// loaded font, as the other lookups do.
    pub fn describe(self: *FontStore, handle: FontHandle) Description {
        return describeOf(stateOf(self), handle);
    }

    /// Returns plain timing, cache, atlas, and retirement counters for the text path.
    pub fn profileStats(self: *FontStore) ProfileStats {
        return profileStatsOf(stateOf(self));
    }

    /// Connects C widget layout to the same provider-based measurement and draw path as Canvas text.
    pub fn initWidgets(self: *FontStore, handle: FontHandle, ctx: *c.ui_context) void {
        c.ui_init(
            ctx,
            self.lineHeight(handle),
            @ptrCast(self),
            handle.id,
            &widgetTextWidth,
            &widgetDrawText,
        );
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

/// Creates the production store with the session-owned runtime glyph atlas.
pub fn createWithAtlas(allocator: std.mem.Allocator, atlas: *glyph_atlas.Atlas) std.mem.Allocator.Error!*FontStore {
    const state = try allocator.create(State);
    state.* = .{
        .allocator = allocator,
        .resources = font_resource.Resources.init(allocator),
        .release = &font_resource.FontResource.deinit,
        .atlas = atlas,
    };
    return @ptrCast(state);
}

/// The number of fonts stored.
pub fn count(store: *const FontStore) usize {
    return stateOfConst(store).resources.count();
}

/// Lays out text through the selected provider. Runtime outline fonts use shaped, cluster-safe breaks; static providers
/// keep the existing codepoint/metric layout.
pub fn layoutTextOf(
    store: *FontStore,
    handle: FontHandle,
    allocator: std.mem.Allocator,
    text: []const u8,
    max_width: f32,
    alignment: text_layout.Alignment,
) LayoutError!text_layout.Layout {
    const state = stateOf(store);
    const resource = resourceOf(state, handle);
    switch (resource.*) {
        .runtime_coverage => |*font_value| return shaped_layout.layout(
            allocator,
            runtimeShaper(font_value),
            text,
            max_width,
            resource.metrics().line_height,
            alignment,
            .{},
        ),
        .msdf => |*font_value| return shaped_layout.layout(
            allocator,
            msdfShaper(font_value),
            text,
            max_width,
            resource.metrics().line_height,
            alignment,
            .{},
        ),
        .bfnt_coverage, .bitmap => {
            const measure_context = LayoutMeasureContext{ .store = store, .handle = handle };
            return text_layout.layout(
                allocator,
                text,
                max_width,
                resource.metrics().line_height,
                alignment,
                measure_context,
                measureForLayout,
            );
        },
    }
}

/// Submits the already-shaped records in a runtime text layout. The layout must have come from this same font handle.
pub fn drawShapedLayoutOf(
    store: *FontStore,
    handle: FontHandle,
    list: *c.ui_quad_list,
    x: f32,
    y: f32,
    layout: *const shaped_layout.Layout,
    color: c.ui_color,
) DrawError!void {
    const state = stateOf(store);
    const resource = resourceOf(state, handle);
    if (shaped_layout.fontIdOf(layout) != handle.id) return error.LayoutFontMismatch;
    switch (resource.*) {
        .runtime_coverage => |*font_value| try appendRuntimeRecords(state, handle, font_value, list, layout, x, y, color),
        .msdf => |*font_value| try appendMsdfRecords(font_value, list, layout, x, y, color),
        .bfnt_coverage, .bitmap => return error.LayoutFontMismatch,
    }
}

/// The single BFNT atlas texture. Solid fills never sample it. This remains BFNT-only; bitmap fonts have multiple pages.
/// Engine-only because it names a renderer type.
pub fn glyphTextureOf(store: *FontStore, handle: FontHandle) *const Texture {
    return &bfntFont(stateOf(store), handle).texture;
}

/// Resolves one page for the engine's common sprite submission path. No page or texture getter is exposed on FontStore.
pub fn glyphTextureForPageOf(store: *FontStore, handle: FontHandle, page: u32) *const Texture {
    const resource = resourceOf(stateOf(store), handle);
    return switch (resource.*) {
        .bfnt_coverage => |*font_value| if (page == 0) &font_value.texture else std.debug.panic("BFNT font has no page {d}", .{page}),
        .msdf => |*font_value| if (page == 0) &font_value.msdf_texture else std.debug.panic("MSDF font has no page {d}", .{page}),
        .bitmap => |*font_value| if (page < font_value.pages.len)
            &font_value.pages[@intCast(page)]
        else
            std.debug.panic("bitmap font has no page {d}", .{page}),
        .runtime_coverage => |*font_value| blk: {
            const atlas = stateOf(store).atlas orelse std.debug.panic("runtime glyph atlas is unavailable", .{});
            _ = font_value;
            break :blk atlas.pageTexture(page);
        },
    };
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

/// Stores a baked MSDF font and initializes its reusable shaper after the resource reaches a stable registry address.
pub fn insertMsdf(store: *FontStore, font_value: font_resource.MsdfFont) InsertError!FontHandle {
    const state = stateOf(store);
    var resource = font_resource.FontResource{ .msdf = font_value };
    const handle = state.resources.insert(resource) catch |err| {
        state.release(&resource);
        return err;
    };
    const stored = state.resources.get(handle) catch unreachable;
    const msdf = &stored.msdf;
    msdf.shaper = shaper.Shaper.init(&msdf.face) catch |err| {
        var failed = state.resources.remove(handle) catch unreachable;
        state.release(&failed);
        return err;
    };
    msdf.shaper.?.font_id = handle.id;
    msdf.shaper.?.setProfileClock(state.profile_clock);
    msdf.msdf_texture.sdl2d_fallback = &msdf.coverage_texture;
    return handle;
}

/// Stores a normalized bitmap font and its uploaded pages. The store releases both descriptor allocations and textures.
pub fn insertBitmap(store: *FontStore, font_value: font_resource.BitmapFont) InsertError!FontHandle {
    const state = stateOf(store);
    var resource = font_resource.FontResource{ .bitmap = font_value };
    return state.resources.insert(resource) catch |err| {
        state.release(&resource);
        return err;
    };
}

/// Stores a runtime TrueType face under a new handle. The store takes ownership on entry. The shaper is created once
/// after the resource reaches its stable registry allocation, because it borrows the face at that address.
pub fn insertRuntime(store: *FontStore, face: runtime_font.RuntimeFont) InsertError!FontHandle {
    const state = stateOf(store);
    var resource = font_resource.FontResource{ .runtime_coverage = .{ .face = face } };
    const handle = state.resources.insert(resource) catch |err| {
        state.release(&resource);
        return err;
    };

    const stored = state.resources.get(handle) catch unreachable;
    const runtime = &stored.runtime_coverage;
    runtime.shaper = shaper.Shaper.init(&runtime.face) catch |err| {
        var failed = state.resources.remove(handle) catch unreachable;
        state.release(&failed);
        return err;
    };
    runtime.shaper.?.font_id = handle.id;
    runtime.shaper.?.setProfileClock(state.profile_clock);
    return handle;
}

/// Releases every font, then frees the store. Call it once no handle is in use, and before the GPU device is released.
pub fn destroy(store: *FontStore) void {
    const state = stateOf(store);
    const allocator = state.allocator;
    state.resources.deinitWith(state.release);
    for (state.retired.items) |resource| {
        state.release(resource);
        allocator.destroy(resource);
    }
    state.retired.deinit(allocator);
    allocator.destroy(state);
}

/// Rebuilds stored provider textures from retained CPU data. The caller must wait for GPU idle first.
pub fn recreateGpuResources(store: *FontStore, device: *platform.gpu.Device) void {
    const state = stateOf(store);
    for (state.resources.entries.items) |entry| {
        entry.value.recreateGpuResources(state.allocator, device);
    }
}

/// Sets the monotonic timer used to accumulate shaping durations without coupling the text package to a platform clock.
pub fn setProfileClock(store: *FontStore, clock_ns: ?*const fn () u64) void {
    const state = stateOf(store);
    state.profile_clock = clock_ns;
    for (state.resources.entries.items) |entry| {
        switch (entry.value.*) {
            .runtime_coverage => |*font_value| if (font_value.shaper) |*value| value.setProfileClock(clock_ns),
            .msdf => |*font_value| if (font_value.shaper) |*value| value.setProfileClock(clock_ns),
            .bfnt_coverage, .bitmap => {},
        }
    }
}

/// Releases resources retired by `unload`. Call only after GPU idle, when no queued draw can retain their texture pointers.
pub fn collectRetiredAfterGpuIdle(store: *FontStore) usize {
    const state = stateOf(store);
    const retired_count = state.retired.items.len;
    for (state.retired.items) |resource| {
        state.release(resource);
        state.allocator.destroy(resource);
    }
    state.retired.clearRetainingCapacity();
    return retired_count;
}

/// Number of unloaded fonts waiting for an idle-safe release.
pub fn retiredCount(store: *const FontStore) usize {
    return stateOfConst(store).retired.items.len;
}

/// Invalidates a font handle immediately and defers releasing its resource until the next GPU-idle collection.
/// This keeps any texture pointers already queued in the current frame valid.
pub fn unload(store: *FontStore, handle: FontHandle) UnloadError!void {
    const state = stateOf(store);
    try state.retired.ensureUnusedCapacity(state.allocator, 1);
    const resource = try state.resources.detach(handle);
    state.retired.appendAssumeCapacity(resource);
    if (state.atlas) |atlas| _ = atlas.cache.removeFont(handle.id);
}

/// Frees the store without releasing its fonts. Tests use this for fonts that have no GPU object to release.
pub fn discard(store: *FontStore) void {
    const state = stateOf(store);
    const allocator = state.allocator;
    state.resources.deinit();
    for (state.retired.items) |resource| allocator.destroy(resource);
    state.retired.deinit(allocator);
    allocator.destroy(state);
}

fn stateOf(store: *FontStore) *State {
    return @ptrCast(@alignCast(store));
}

fn stateOfConst(store: *const FontStore) *const State {
    return @ptrCast(@alignCast(store));
}

fn resourceOf(state: *State, handle: FontHandle) *font_resource.FontResource {
    return state.resources.get(handle) catch |err| std.debug.panic("UI font handle {d} does not name a loaded font: {s}", .{ handle.id, @errorName(err) });
}

fn runtimeShaper(font_value: *font_resource.RuntimeCoverage) *shaper.Shaper {
    return if (font_value.shaper) |*value| value else unreachable;
}

fn msdfShaper(font_value: *font_resource.MsdfFont) *shaper.Shaper {
    return if (font_value.shaper) |*value| value else unreachable;
}

const LayoutMeasureContext = struct {
    store: *FontStore,
    handle: FontHandle,
};

fn measureForLayout(context: LayoutMeasureContext, text: []const u8) f32 {
    return context.store.textWidth(context.handle, text);
}

fn widgetTextWidth(context: ?*anyopaque, font_id: u64, text: [*c]const u8, len: usize) callconv(.c) f32 {
    const store: *FontStore = @ptrCast(@alignCast(context orelse unreachable));
    return store.textWidth(.{ .id = font_id }, text[0..len]);
}

fn widgetDrawText(
    context: ?*anyopaque,
    font_id: u64,
    list: [*c]c.ui_quad_list,
    x: f32,
    y: f32,
    text: [*c]const u8,
    len: usize,
    color: c.ui_color,
) callconv(.c) void {
    const store: *FontStore = @ptrCast(@alignCast(context orelse unreachable));
    store.drawText(.{ .id = font_id }, list, x, y, text[0..len], color) catch |err|
        std.debug.panic("could not draw widget text with font {d}: {s}", .{ font_id, @errorName(err) });
}

fn drawBfntText(font_value: *font_mod.Font, list: *c.ui_quad_list, x: f32, y: f32, str: []const u8, color: c.ui_color) void {
    c.ui_font_draw_text(&font_value.baked, list, x, y, str.ptr, str.len, color);
}

fn drawRuntimeText(
    state: *State,
    handle: FontHandle,
    font_value: *font_resource.RuntimeCoverage,
    list: *c.ui_quad_list,
    x: f32,
    y: f32,
    str: []const u8,
    color: c.ui_color,
) DrawError!void {
    if (state.atlas == null) return error.RuntimeDrawingUnavailable;
    var layout = try shaped_layout.layout(
        state.allocator,
        runtimeShaper(font_value),
        str,
        std.math.floatMax(f32),
        resourceOf(state, handle).metrics().line_height,
        .left,
        .{},
    );
    defer layout.deinit();

    try appendRuntimeRecords(state, handle, font_value, list, &layout, x, y, color);
}

fn drawMsdfText(
    state: *State,
    handle: FontHandle,
    font_value: *font_resource.MsdfFont,
    list: *c.ui_quad_list,
    x: f32,
    y: f32,
    str: []const u8,
    color: c.ui_color,
) DrawError!void {
    var layout = try shaped_layout.layout(
        state.allocator,
        msdfShaper(font_value),
        str,
        std.math.floatMax(f32),
        resourceOf(state, handle).metrics().line_height,
        .left,
        .{},
    );
    defer layout.deinit();
    try appendMsdfRecords(font_value, list, &layout, x, y, color);
}

fn appendMsdfRecords(
    font_value: *font_resource.MsdfFont,
    list: *c.ui_quad_list,
    layout: *const shaped_layout.Layout,
    x: f32,
    y: f32,
    color: c.ui_color,
) DrawError!void {
    const ascent: f32 = @floatFromInt(font_value.baked.ascent);
    for (layout.lines, 0..) |line, line_index| {
        const baseline = @round(y + @as(f32, @floatFromInt(line_index)) * layout.line_height) + ascent;
        var pen = x + line.x_offset;
        for (shaped_layout.glyphsOf(layout, line_index)) |glyph| {
            const glyph_id = if (glyph.glyph_id != 0 and glyph.glyph_id < font_value.face.glyph_count)
                glyph.glyph_id
            else
                font_value.baked.fallback_glyph_id;
            const record = font_value.baked.glyphs[glyph_id];
            const width: f32 = @floatFromInt(record.x1 - record.x0);
            const height: f32 = @floatFromInt(record.y1 - record.y0);
            if (width > 0 and height > 0) {
                if (list.count >= c.UI_MAX_QUADS) {
                    return error.QuadListFull;
                } else {
                    list.items[@intCast(list.count)] = .{
                        .dst = .{
                            .x = @round(pen + glyph.x_offset + record.xoff),
                            .y = baseline + @round(glyph.y_offset + record.yoff),
                            .w = width,
                            .h = height,
                        },
                        .src = .{
                            .x = @floatFromInt(record.x0),
                            .y = @floatFromInt(record.y0),
                            .w = width,
                            .h = height,
                        },
                        .color = color,
                        .page = 0,
                        .solid = 0,
                    };
                    list.count += 1;
                }
            }
            pen += glyph.x_advance;
        }
    }
}

fn appendRuntimeRecords(
    state: *State,
    handle: FontHandle,
    font_value: *font_resource.RuntimeCoverage,
    list: *c.ui_quad_list,
    layout: *const shaped_layout.Layout,
    x: f32,
    y: f32,
    color: c.ui_color,
) DrawError!void {
    const atlas = state.atlas orelse return error.RuntimeDrawingUnavailable;
    var records: std.ArrayList(glyph_records.Record) = .empty;
    defer records.deinit(state.allocator);
    try glyph_records.build(
        state.allocator,
        &records,
        &atlas.cache,
        &font_value.face,
        layout,
        x,
        y,
        .{ .font_id = handle.id, .fallback_glyph_id = font_value.face.fallback_glyph_id },
    );
    for (records.items) |record| {
        if (list.count >= c.UI_MAX_QUADS) {
            return error.QuadListFull;
        }
        list.items[@intCast(list.count)] = .{
            .dst = .{ .x = record.dst_x, .y = record.dst_y, .w = record.dst_w, .h = record.dst_h },
            .src = .{
                .x = @floatFromInt(record.src_x),
                .y = @floatFromInt(record.src_y),
                .w = @floatFromInt(record.src_w),
                .h = @floatFromInt(record.src_h),
            },
            .color = color,
            .page = record.page,
            .solid = 0,
        };
        list.count += 1;
    }
}

fn bitmapWidth(font_value: *const @import("bmfont.zig").Font, str: []const u8) f32 {
    var mapper = bitmap_mapper.Mapper.init(font_value, str);
    return mapper.width();
}

fn drawBitmapText(font_value: *const @import("bmfont.zig").Font, list: *c.ui_quad_list, x: f32, y: f32, str: []const u8, color: c.ui_color) DrawError!void {
    var mapper = bitmap_mapper.Mapper.init(font_value, str);
    while (mapper.next()) |mapped| {
        const glyph = mapped.glyph;
        if (glyph.width == 0 or glyph.height == 0) continue;
        if (list.count >= c.UI_MAX_QUADS) {
            return error.QuadListFull;
        }
        list.items[@intCast(list.count)] = .{
            .dst = .{
                .x = @round(x + mapped.pen + @as(f32, @floatFromInt(glyph.x_offset))),
                .y = @round(y + @as(f32, @floatFromInt(glyph.y_offset))),
                .w = @floatFromInt(glyph.width),
                .h = @floatFromInt(glyph.height),
            },
            .src = .{
                .x = @floatFromInt(glyph.x),
                .y = @floatFromInt(glyph.y),
                .w = @floatFromInt(glyph.width),
                .h = @floatFromInt(glyph.height),
            },
            .color = color,
            .page = glyph.page,
            .solid = 0,
        };
        list.count += 1;
    }
}

fn bfntFont(state: *State, handle: FontHandle) *font_mod.Font {
    const resource = resourceOf(state, handle);
    return switch (resource.*) {
        .bfnt_coverage => |*font_value| font_value,
        .msdf => std.debug.panic("font handle {d} is an MSDF font and has no BFNT atlas", .{handle.id}),
        .bitmap => std.debug.panic("font handle {d} is a bitmap font and has no BFNT atlas", .{handle.id}),
        .runtime_coverage => std.debug.panic("font handle {d} is an outline font and has no BFNT atlas", .{handle.id}),
    };
}

fn statsOf(state: *const State) Stats {
    var result = Stats{ .fonts = state.resources.count(), .bfnt_coverage = 0, .msdf = 0, .bitmap = 0, .runtime_coverage = 0 };
    for (state.resources.entries.items) |entry| {
        switch (entry.value.*) {
            .bfnt_coverage => {
                result.bfnt_coverage += 1;
            },
            .msdf => {
                result.msdf += 1;
            },
            .bitmap => {
                result.bitmap += 1;
            },
            .runtime_coverage => {
                result.runtime_coverage += 1;
            },
        }
    }
    return result;
}

fn profileStatsOf(state: *const State) ProfileStats {
    var result = ProfileStats{ .retired_fonts = state.retired.items.len };
    for (state.resources.entries.items) |entry| {
        switch (entry.value.*) {
            .runtime_coverage => |*font_value| addShaperStats(&result, font_value.shaper),
            .msdf => |*font_value| addShaperStats(&result, font_value.shaper),
            .bfnt_coverage, .bitmap => {},
        }
    }
    if (state.atlas) |atlas| {
        const cache_stats = atlas.cache.snapshot();
        const flush_stats = atlas.flushStats();
        result.glyph_cache_hits = cache_stats.hits;
        result.glyph_cache_misses = cache_stats.misses;
        result.glyphs_rasterized = cache_stats.rasterized;
        result.atlas_pages = cache_stats.pages_in_use;
        result.atlas_cpu_bytes = cache_stats.allocated_bytes;
        result.atlas_gpu_upload_bytes = flush_stats.gpu_upload_bytes;
        result.atlas_gpu_upload_regions = flush_stats.gpu_regions;
    }
    return result;
}

fn addShaperStats(result: *ProfileStats, value: ?shaper.Shaper) void {
    const profile = if (value) |*font_shaper| font_shaper.profile else return;
    result.shape_calls += profile.shape_calls;
    result.shape_nanoseconds += profile.shape_nanoseconds;
    result.measure_calls += profile.measure_calls;
    result.measure_nanoseconds += profile.measure_nanoseconds;
}

fn describeOf(state: *State, handle: FontHandle) Description {
    const resource = state.resources.peek(handle) catch |err| std.debug.panic("UI font handle {d} does not name a loaded font: {s}", .{ handle.id, @errorName(err) });
    return switch (resource.*) {
        .bfnt_coverage => .{ .source = .bfnt_prebaked, .mode = .prebaked_coverage },
        .msdf => .{ .source = .msdf_outline, .mode = .msdf },
        .bitmap => .{ .source = .bitmap, .mode = .bitmap_coverage },
        .runtime_coverage => .{ .source = .runtime_outline, .mode = .gray_coverage },
    };
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const bmfont = @import("bmfont.zig");

/// A font with empty metrics, except for a 1x1 white block at the origin. Its texture comes from the test fixtures: a
/// texture with no GPU object, so `discard` can free the store without releasing anything.
fn emptyFont() font_mod.Font {
    const fixtures = @import("../testing/fixtures.zig");
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
    const atlas = glyphTextureOf(store, handle);
    try testing.expectEqual(@as(*const Texture, &bfntFont(stateOf(store), handle).texture), atlas);
}

test "every FontStore method the engine uses is compiled by the test build" {
    // Taking each address makes this binary analyze and emit the method. Ui tests exercise the C callback bridge.
    _ = &FontStore.lineHeight;
    _ = &FontStore.textWidth;
    _ = &FontStore.drawText;
    _ = &glyphTextureOf;
    _ = &FontStore.check;
    _ = &count;
    _ = &destroy;
}

test "an empty store reports no fonts" {
    const store = try create(testing.allocator);
    defer discard(store);
    const stats = store.stats();
    try testing.expectEqual(@as(usize, 0), stats.fonts);
    try testing.expectEqual(@as(usize, 0), stats.bfnt_coverage);
    try testing.expectEqual(@as(usize, 0), stats.msdf);
    try testing.expectEqual(@as(usize, 0), stats.bitmap);
    try testing.expectEqual(@as(usize, 0), stats.runtime_coverage);
}

test "a stored bfnt font is counted as prebaked, and drawn with prebaked coverage" {
    const store = try create(testing.allocator);
    defer discard(store);
    const handle = try insertBfnt(store, emptyFont());
    _ = try insertBfnt(store, emptyFont());
    const stats = store.stats();
    try testing.expectEqual(@as(usize, 2), stats.fonts);
    try testing.expectEqual(@as(usize, 2), stats.bfnt_coverage);
    try testing.expectEqual(@as(usize, 0), stats.runtime_coverage);
    const described = store.describe(handle);
    try testing.expectEqual(Description.Source.bfnt_prebaked, described.source);
    try testing.expectEqual(Description.Mode.prebaked_coverage, described.mode);
}

const bitmap_fixture =
    \\info face="Fixture" size=8 padding=0,0,0,0
    \\common lineHeight=8 base=7 scaleW=16 scaleH=8 pages=2
    \\page id=0 file="page.r8"
    \\page id=1 file="page2.r8"
    \\chars count=4
    \\char id=32 x=0 y=0 width=0 height=0 xoffset=0 yoffset=0 xadvance=4 page=0 chnl=15
    \\char id=63 x=0 y=0 width=8 height=8 xoffset=0 yoffset=0 xadvance=8 page=0 chnl=15
    \\char id=65 x=8 y=0 width=8 height=8 xoffset=-1 yoffset=2 xadvance=8 page=0 chnl=15
    \\char id=66 x=0 y=0 width=8 height=8 xoffset=0 yoffset=0 xadvance=8 page=1 chnl=15
    \\kernings count=1
    \\kerning first=65 second=65 amount=-1
;

fn bitmapFixture() !font_resource.BitmapFont {
    const fixtures = @import("../testing/fixtures.zig");
    const descriptor = try bmfont.parse(testing.allocator, bitmap_fixture, .{}, null);
    const pages = try testing.allocator.alloc(Texture, 2);
    pages[0] = fixtures.texture(16, 8);
    pages[1] = fixtures.texture(16, 8);
    const page_pixels = try testing.allocator.alloc([]u8, 2);
    page_pixels[0] = try testing.allocator.alloc(u8, 16 * 8);
    page_pixels[1] = try testing.allocator.alloc(u8, 16 * 8);
    @memset(page_pixels[0], 0);
    @memset(page_pixels[1], 0);
    return .{ .allocator = testing.allocator, .descriptor = descriptor, .pages = pages, .page_pixels = page_pixels };
}

test "bitmap text shares measurement and quad submission with authored offsets, fallback, and kerning" {
    const store = try countingStore(testing.allocator);
    const handle = try insertBitmap(store, try bitmapFixture());
    defer destroy(store);

    store.check(handle);
    try testing.expectEqual(@as(f32, 8), store.lineHeight(handle));
    try testing.expectEqual(@as(f32, 15), store.textWidth(handle, "AA"));
    try testing.expectEqual(@as(f32, 16), store.textWidth(handle, "AZ"));
    try testing.expectEqual(@as(usize, 1), store.stats().bitmap);
    try testing.expectEqual(Description.Source.bitmap, store.describe(handle).source);
    try testing.expectEqual(Description.Mode.bitmap_coverage, store.describe(handle).mode);

    var list = std.mem.zeroes(c.ui_quad_list);
    try store.drawText(handle, &list, 10.4, 20.6, "AA", .{ .r = 1, .g = 1, .b = 1, .a = 1 });
    try testing.expectEqual(@as(c_int, 2), list.count);
    try testing.expectEqual(@as(u32, 0), list.items[0].page);
    try testing.expectEqual(@as(f32, 8), list.items[0].src.x);
    try testing.expectEqual(@as(f32, 8), list.items[0].src.w);
    try testing.expectEqual(@as(f32, 9), list.items[0].dst.x);
    try testing.expectEqual(@as(f32, 23), list.items[0].dst.y);
    try testing.expectEqual(@as(f32, 16), list.items[1].dst.x);
    try testing.expectEqual(@as(*const Texture, &resourceOf(stateOf(store), handle).bitmap.pages[0]), glyphTextureForPageOf(store, handle, 0));

    list.count = 0;
    try store.drawText(handle, &list, 0, 0, "AB", .{ .r = 1, .g = 1, .b = 1, .a = 1 });
    try testing.expectEqual(@as(u32, 0), list.items[0].page);
    try testing.expectEqual(@as(u32, 1), list.items[1].page);
    try testing.expectEqual(@as(*const Texture, &resourceOf(stateOf(store), handle).bitmap.pages[1]), glyphTextureForPageOf(store, handle, 1));

    var widget_context = std.mem.zeroes(c.ui_context);
    store.initWidgets(handle, &widget_context);
    const widget_width = widget_context.text_width.?(
        widget_context.font_context,
        widget_context.font_id,
        "AA",
        2,
    );
    try testing.expectEqual(store.textWidth(handle, "AA"), widget_width);
    var widget_list = std.mem.zeroes(c.ui_quad_list);
    widget_context.draw_text.?(
        widget_context.font_context,
        widget_context.font_id,
        &widget_list,
        0,
        0,
        "AB",
        2,
        .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    );
    try testing.expectEqual(@as(c_int, 2), widget_list.count);
    try testing.expectEqual(@as(u32, 0), widget_list.items[0].page);
    try testing.expectEqual(@as(u32, 1), widget_list.items[1].page);
}

test "runtime fonts share metrics and measurement, and pass check without enabling drawing" {
    const store = try create(testing.allocator);
    defer destroy(store);
    const handle = try insertRuntime(store, try runtimeFixture());

    store.check(handle);
    const resource = resourceOf(stateOf(store), handle);
    try testing.expectEqual(resource.metrics().line_height, store.lineHeight(handle));
    try testing.expectEqual(@as(usize, 1), store.stats().runtime_coverage);
    try testing.expectEqual(Description.Source.runtime_outline, store.describe(handle).source);

    const expected = try runtimeShaper(&resource.runtime_coverage).measure("AV", .{});
    try testing.expectEqual(expected, store.textWidth(handle, "AV"));
    try testing.expectEqual(handle.id, runtimeShaper(&resource.runtime_coverage).font_id);
    const profile = store.profileStats();
    try testing.expectEqual(@as(u64, 2), profile.measure_calls);
    try testing.expectEqual(@as(u64, 0), profile.shape_calls);

    var list = std.mem.zeroes(c.ui_quad_list);
    try testing.expectError(error.RuntimeDrawingUnavailable, store.drawText(handle, &list, 0, 0, "A", .{
        .r = 1,
        .g = 1,
        .b = 1,
        .a = 1,
    }));
    try testing.expectEqual(@as(c_int, 0), list.count);
}

test "destroy releases an inserted runtime face and its shaper exactly once" {
    const store = try countingStore(testing.allocator);
    _ = try insertRuntime(store, try runtimeFixture());
    try testing.expectEqual(@as(usize, 0), released_count);
    destroy(store);
    try testing.expectEqual(@as(usize, 1), releasesOf(16));
}

test "a runtime insert that fails to allocate releases the face once" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    const store = try countingStore(failing.allocator());
    try testing.expectError(error.OutOfMemory, insertRuntime(store, try runtimeFixture()));
    try testing.expectEqual(@as(usize, 1), releasesOf(16));
    try testing.expectEqual(@as(usize, 0), count(store));
    destroy(store);
    try testing.expectEqual(@as(usize, 1), released_count);
}

test "a runtime insert at id exhaustion releases its face and keeps stored fonts" {
    const store = try countingStore(testing.allocator);
    _ = try insertBfnt(store, markedFont(61));
    stateOf(store).resources.next_id = std.math.maxInt(font_registry.FontId);
    try testing.expectError(error.FontIdExhausted, insertRuntime(store, try runtimeFixture()));
    try testing.expectEqual(@as(usize, 1), releasesOf(16));
    try testing.expectEqual(@as(usize, 1), count(store));
    destroy(store);
    try testing.expectEqual(@as(usize, 1), releasesOf(61));
    try testing.expectEqual(@as(usize, 2), released_count);
}

// ---- ownership: who releases a font, and when ------------------------------------------------------------------------
//
// These tests count releases with `recordRelease`, a stand-in for `FontResource.deinit`. A font's marker is its line
// height, so each release can be matched to the font it came from.

/// Markers of the fonts released so far, in release order.
var released_markers: [8]c_int = undefined;
var released_count: usize = 0;

fn recordRelease(resource: *font_resource.FontResource) void {
    var needs_provider_deinit = false;
    switch (resource.*) {
        .bfnt_coverage => |f| {
            released_markers[released_count] = f.baked.line_height;
            released_count += 1;
        },
        .msdf => @panic("the release-count test holds only bfnt fonts"),
        .bitmap => |*f| {
            released_markers[released_count] = f.descriptor.size;
            released_count += 1;
            f.descriptor.deinit();
            f.allocator.free(f.pages);
            for (f.page_pixels) |pixels| f.allocator.free(pixels);
            f.allocator.free(f.page_pixels);
            resource.* = undefined;
            return;
        },
        .runtime_coverage => |f| {
            released_markers[released_count] = @intFromFloat(f.face.pixel_height);
            released_count += 1;
            needs_provider_deinit = true;
        },
    }
    if (needs_provider_deinit) {
        resource.deinit();
    } else {
        resource.* = undefined;
    }
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

fn runtimeFixture() !runtime_font.RuntimeFont {
    const blob = runtime_font.hb.hb_blob_create_from_file_or_fail("assets/font.ttf") orelse return error.FixtureMissing;
    defer runtime_font.hb.hb_blob_destroy(blob);
    var len: c_uint = 0;
    const data = runtime_font.hb.hb_blob_get_data(blob, &len);
    if (data == null or len == 0) return error.FixtureMissing;
    const ptr: [*]const u8 = @ptrCast(data);
    return runtime_font.RuntimeFont.init(testing.allocator, ptr[0..@as(usize, len)], 16);
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

test "unloading invalidates the handle and idle collection releases it exactly once" {
    const store = try countingStore(testing.allocator);
    const handle = try insertBfnt(store, markedFont(33));
    const stored = try stateOf(store).resources.get(handle);

    try unload(store, handle);
    try testing.expectEqual(@as(usize, 0), released_count);
    try testing.expectEqual(@as(c_int, 33), stored.bfnt_coverage.baked.line_height);
    try testing.expectError(error.StaleHandle, stateOf(store).resources.get(handle));

    try testing.expectEqual(@as(usize, 1), collectRetiredAfterGpuIdle(store));
    try testing.expectEqual(@as(usize, 1), released_count);
    try testing.expectEqual(@as(usize, 1), releasesOf(33));
    destroy(store);
    try testing.expectEqual(@as(usize, 1), released_count);
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
