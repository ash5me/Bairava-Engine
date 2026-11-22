//! Text and widgets, bridged from the C code in src/engine/ui/. The C side builds quads in pixels.
//! Glyph quads sample the font atlas, and solid fills sample the batch's white texture. This file queues each quad
//! as a sprite. BFNT, runtime outline, and authored bitmap fonts all reach the same quad list.
//!
//! The C headers are private to this file, text/font.zig, and text/font_store.zig. Everything else reaches the UI
//! through `Canvas` (text and rectangles) and `Ui` (widgets), which take and return Zig types.

const std = @import("std");
const c = @import("c.zig").c;
const input = @import("../input/input.zig");
const action = @import("../input/action.zig");
const sprite = @import("../renderer/sprite.zig");
const view = @import("../renderer/view.zig");
const text_layout = @import("../text/layout.zig");
const font_registry = @import("../text/font_registry.zig");
const font_store = @import("../text/font_store.zig");
const font_mod = @import("../text/font.zig");
const Texture = @import("../renderer/texture.zig").Texture;

/// What game code holds in place of a font. The font itself lives in the session's font store.
pub const FontHandle = font_registry.FontHandle;
/// The session's fonts. Game code reaches them with a `FontHandle`, through the methods of this type.
pub const FontStore = font_store.FontStore;
pub const FontProfileStats = font_store.ProfileStats;
pub const TextAlignment = text_layout.Alignment;
pub const TextLayout = text_layout.Layout;
pub const TextOptions = font_store.TextOptions;

/// An RGBA color, each channel from 0 to 1.
pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

/// Where a UI panel is anchored inside the logical viewport.
pub const Anchor = enum {
    top_left,
    top_center,
    top_right,
    middle_left,
    center,
    middle_right,
    bottom_left,
    bottom_center,
    bottom_right,
};

/// A drawable rectangle in view pixels. `Ui.anchorBounds` resolves a panel's x/y and size from a
/// logical viewport and a target panel size.
pub const Bounds = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

/// Resolves an anchored panel inside the logical viewport. `margin_x` and `margin_y` are extra
/// padding from the chosen edge before the panel is placed. Invalid viewport values fall back to a
/// 1x1 view, so the UI never crashes when the window is transiently zero-sized or empty.
pub fn anchorBounds(view_w: f32, view_h: f32, width: f32, height: f32, anchor: Anchor, margin_x: f32, margin_y: f32) Bounds {
    const safe_view_w = if (std.math.isFinite(view_w) and view_w > 0) view_w else 1.0;
    const safe_view_h = if (std.math.isFinite(view_h) and view_h > 0) view_h else 1.0;
    const safe_w = if (std.math.isFinite(width) and width > 0) width else 1.0;
    const safe_h = if (std.math.isFinite(height) and height > 0) height else 1.0;
    const x = switch (anchor) {
        .top_left, .middle_left, .bottom_left => margin_x,
        .top_center, .center, .bottom_center => (safe_view_w - safe_w) / 2.0 + margin_x,
        .top_right, .middle_right, .bottom_right => safe_view_w - safe_w - margin_x,
    };
    const y = switch (anchor) {
        .top_left, .top_center, .top_right => margin_y,
        .middle_left, .center, .middle_right => (safe_view_h - safe_h) / 2.0 + margin_y,
        .bottom_left, .bottom_center, .bottom_right => safe_view_h - safe_h - margin_y,
    };
    return .{ .x = x, .y = y, .w = safe_w, .h = safe_h };
}

/// A handle to a font in the session's font store, and a quad list on the heap, with text and rectangle helpers. The
/// debug overlay draws with one directly, and `Ui` builds one for its widgets. The font is not owned here: the store
/// owns it and releases it at shutdown, after every Canvas has been deinitialized.
pub const Canvas = struct {
    allocator: std.mem.Allocator,
    /// The store the font lives in. It is a mutable pointer because the C text functions take a non-const font.
    fonts: *FontStore,
    font: FontHandle,
    list: *c.ui_quad_list,

    /// Keeps `font` as a handle; all wrapper memory uses `allocator`. Panics if the handle does not name a font this
    /// path can draw, because that is a bug in the code that made it.
    pub fn create(allocator: std.mem.Allocator, fonts: *FontStore, font: FontHandle) Canvas {
        fonts.check(font);
        const list = allocator.create(c.ui_quad_list) catch @panic("out of memory");
        list.count = 0;
        list.dropped = 0;
        return .{ .allocator = allocator, .fonts = fonts, .font = font, .list = list };
    }

    /// Frees the quad list. The font stays in the store.
    pub fn deinit(self: *Canvas) void {
        self.allocator.destroy(self.list);
    }

    /// Empties the quad list, ready for a new frame.
    pub fn clear(self: *Canvas) void {
        self.list.count = 0;
        self.list.dropped = 0;
    }

    /// The natural line height of this font, in pixels.
    pub fn lineHeight(self: *const Canvas) f32 {
        return self.fonts.lineHeight(self.font);
    }

    /// The width of `str` in pixels, in this font.
    pub fn textWidth(self: *const Canvas, str: []const u8) f32 {
        return self.fonts.textWidth(self.font, str);
    }

    /// The width of `str` in pixels, shaped with the supplied script and language when supported by this font.
    pub fn textWidthWithOptions(self: *const Canvas, str: []const u8, options: TextOptions) f32 {
        return self.fonts.textWidthWithOptions(self.font, str, options);
    }

    /// Builds a wrapped, aligned text block. Line slices borrow `str`; release the result with
    /// `TextLayout.deinit` and the allocator used here.
    pub fn layoutText(self: *const Canvas, allocator: std.mem.Allocator, str: []const u8, max_width: f32, alignment: TextAlignment) text_layout.LayoutError!TextLayout {
        return self.layoutTextWithOptions(allocator, str, max_width, alignment, .{});
    }

    /// Builds a wrapped, aligned text block using the supplied script and language for shaping.
    pub fn layoutTextWithOptions(
        self: *const Canvas,
        allocator: std.mem.Allocator,
        str: []const u8,
        max_width: f32,
        alignment: TextAlignment,
        options: TextOptions,
    ) text_layout.LayoutError!TextLayout {
        return font_store.layoutTextWithOptionsOf(
            self.fonts,
            self.font,
            allocator,
            str,
            max_width,
            alignment,
            options,
        );
    }

    /// Adds each line of a previously measured text block at `(x, y)`.
    pub fn drawTextLayout(self: *Canvas, x: f32, y: f32, layout: *const TextLayout, color: Color) void {
        if (self.fonts.describe(self.font).source == .runtime_outline) {
            font_store.drawShapedLayoutOf(self.fonts, self.font, self.list, x, y, layout, toC(color)) catch |err|
                std.debug.panic("could not draw text layout with font {d}: {s}", .{ self.font.id, @errorName(err) });
            return;
        }
        for (layout.lines, 0..) |line, index| {
            self.text(
                x + line.x_offset,
                y + @as(f32, @floatFromInt(index)) * layout.line_height,
                line.text,
                color,
            );
        }
    }

    /// Adds `str` with its top-left corner at (x, y), in pixels.
    pub fn text(self: *Canvas, x: f32, y: f32, str: []const u8, color: Color) void {
        self.fonts.drawText(self.font, self.list, x, y, str, toC(color)) catch |err|
            std.debug.panic("could not draw text with font {d}: {s}", .{ self.font.id, @errorName(err) });
    }

    /// Adds `str` with its top-left corner at (x, y), using the supplied script and language for shaping.
    pub fn textWithOptions(self: *Canvas, x: f32, y: f32, str: []const u8, options: TextOptions, color: Color) void {
        self.fonts.drawTextWithOptions(self.font, self.list, x, y, str, options, toC(color)) catch |err|
            std.debug.panic("could not draw text with font {d}: {s}", .{ self.font.id, @errorName(err) });
    }

    /// Adds a solid rectangle. It draws from the batch's white texture when it is queued (see `queueQuads`), so it
    /// does not depend on the font's white block. Like `ui_quad_push`, quads past the list's capacity are counted in
    /// `dropped` and not drawn.
    pub fn rect(self: *Canvas, x: f32, y: f32, w: f32, h: f32, color: Color) void {
        const list = self.list;
        if (list.count >= c.UI_MAX_QUADS) {
            list.dropped += 1;
            return;
        }
        list.items[@intCast(list.count)] = .{
            .dst = .{ .x = x, .y = y, .w = w, .h = h },
            .src = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .color = toC(color),
            .page = 0,
            .solid = 1,
        };
        list.count += 1;
    }

    /// Queues the quads as sprites at depth `z`.
    pub fn queue(self: *Canvas, batch: *sprite.SpriteBatch, z: i32) void {
        queueQuads(batch, self.fonts, self.font, self.list, z);
    }
};

/// Immediate-mode widgets. The C side keeps the layout and the widget state, and this wrapper hands
/// it Zig values. Labels are copied into a buffer for the length of each call, because the C side
/// hashes them and draws them during the call and keeps no pointer to them.
pub const Ui = struct {
    allocator: std.mem.Allocator,
    canvas: Canvas,
    ctx: *c.ui_context,

    /// Keeps `font` as a handle into `fonts`; wrapper memory uses `allocator`. C widget labels call back into the store
    /// for provider-based measurement and drawing.
    pub fn init(allocator: std.mem.Allocator, fonts: *FontStore, font: FontHandle) Ui {
        const canvas = Canvas.create(allocator, fonts, font);
        const ctx = allocator.create(c.ui_context) catch @panic("out of memory");
        fonts.initWidgets(font, ctx);
        return .{ .allocator = allocator, .canvas = canvas, .ctx = ctx };
    }

    pub fn deinit(self: *Ui) void {
        self.allocator.destroy(self.ctx);
        self.canvas.deinit();
    }

    /// Starts the frame's widgets in the column (x, y, width), in view pixels. The pointer comes
    /// from `in_state` in window points, so it is mapped through `layout` first. Keybind rows take
    /// their control from `in_state` too: the first bindable control pressed this frame, and Escape
    /// as the cancel.
    pub fn begin(self: *Ui, in_state: *const input.Input, layout: view.Layout, x: f32, y: f32, width: f32) void {
        const safe_layout: view.Layout = if (std.math.isFinite(layout.pixel_density) and layout.pixel_density > 0 and
            std.math.isFinite(layout.dst_x) and std.math.isFinite(layout.dst_y) and
            std.math.isFinite(layout.dst_w) and std.math.isFinite(layout.dst_h) and
            std.math.isFinite(layout.view_w) and std.math.isFinite(layout.view_h) and
            layout.dst_w > 0 and layout.dst_h > 0 and layout.view_w > 0 and layout.view_h > 0)
            layout
        else
            .{
                .pixel_density = 1.0,
                .dst_x = 0.0,
                .dst_y = 0.0,
                .dst_w = 1.0,
                .dst_h = 1.0,
                .view_w = 1.0,
                .view_h = 1.0,
            };
        const pointer = view.windowToView(safe_layout, .{
            .x = if (std.math.isFinite(in_state.mouse_x)) in_state.mouse_x else 0,
            .y = if (std.math.isFinite(in_state.mouse_y)) in_state.mouse_y else 0,
        });
        const snapped_pointer = if (safe_layout.pixel_perfect) view.Point{
            .x = @round(pointer.x),
            .y = @round(pointer.y),
        } else pointer;
        const snapped_x = if (safe_layout.pixel_perfect) @round(if (std.math.isFinite(x)) x else 0) else if (std.math.isFinite(x)) x else 0;
        const snapped_y = if (safe_layout.pixel_perfect) @round(if (std.math.isFinite(y)) y else 0) else if (std.math.isFinite(y)) y else 0;
        const snapped_width = if (safe_layout.pixel_perfect) @round(if (std.math.isFinite(width) and width > 0) width else 1) else if (std.math.isFinite(width) and width > 0) width else 1;
        const frame = c.ui_input{
            .mouse_x = snapped_pointer.x,
            .mouse_y = snapped_pointer.y,
            .mouse_down = @intFromBool(in_state.mouseDown(.left)),
            .mouse_pressed = @intFromBool(in_state.mousePressed(.left)),
            .mouse_released = @intFromBool(in_state.mouseReleased(.left)),
            .control = @intCast(action.pressedCode(in_state)),
            .cancel = @intFromBool(in_state.wasPressed(.escape)),
        };
        c.ui_begin(self.ctx, &frame, snapped_x, snapped_y, snapped_width);
    }

    /// Ends the frame's widgets. Call `queue` after this to draw them.
    pub fn end(self: *Ui) void {
        c.ui_end(self.ctx);
    }

    /// Cancels keybind capture immediately, for example when the menu that owns the row is closed.
    pub fn cancelListening(self: *Ui) void {
        c.ui_cancel_listening(self.ctx);
    }

    /// Removes all widgets queued by the previous frame without drawing anything.
    pub fn clear(self: *Ui) void {
        c.ui_clear(self.ctx);
    }

    /// A line of text in the column.
    pub fn label(self: *Ui, str: []const u8) void {
        var buf: CString = undefined;
        c.ui_label(self.ctx, cstring(&buf, str));
    }

    /// A button. Returns true on the frame it is clicked.
    pub fn button(self: *Ui, str: []const u8) bool {
        var buf: CString = undefined;
        return c.ui_button(self.ctx, cstring(&buf, str)) != 0;
    }

    /// A slider over [lo, hi]. Returns true on a frame where the value changes.
    pub fn slider(self: *Ui, str: []const u8, value: *f32, lo: f32, hi: f32) bool {
        var buf: CString = undefined;
        return c.ui_slider(self.ctx, cstring(&buf, str), value, lo, hi) != 0;
    }

    /// A row that rebinds one action, showing `value` (its current bindings) at the right. Clicking
    /// it waits for the next key, mouse button other than the left, or gamepad control, and returns
    /// that binding on the frame it is pressed. Escape cancels the wait. Returns null on every other frame.
    pub fn keybind(self: *Ui, str: []const u8, value: []const u8) ?action.Binding {
        var label_buf: CString = undefined;
        var value_buf: CString = undefined;
        const code = c.ui_keybind(self.ctx, cstring(&label_buf, str), cstring(&value_buf, value));
        return action.bindingOf(@intCast(code));
    }

    /// True while a keybind row waits for a control. The game holds its actions then, so the key that
    /// picks a binding does not also act.
    pub fn listening(self: *const Ui) bool {
        return self.ctx.listening != 0;
    }

    /// Queues this frame's widgets as sprites at depth `z`.
    pub fn queue(self: *Ui, batch: *sprite.SpriteBatch, z: i32) void {
        queueQuads(batch, self.canvas.fonts, self.canvas.font, &self.ctx.list, z);
    }
};

/// Room for one label, not counting its terminating zero.
const label_capacity = 256;
const CString = [label_capacity + 1]u8;

/// Copies `str` into `buf` and terminates it. Panics when it does not fit, since a label that long
/// is a bug in the code that wrote it.
fn cstring(buf: *CString, str: []const u8) [*:0]const u8 {
    if (str.len > label_capacity) {
        std.debug.panic("UI text is {d} bytes, past the limit of {d}", .{ str.len, label_capacity });
    }
    @memcpy(buf[0..str.len], str);
    buf[str.len] = 0;
    return buf[0..str.len :0].ptr;
}

fn toC(color: Color) c.ui_color {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
}

/// Queues each quad in `list` as one sprite on `batch`. A solid quad draws from the batch's white texture, and its
/// `src` is ignored. A batch without a white texture draws no fills, so a fill never reads the font's atlas. A glyph
/// quad's `src` is its texel rectangle in the font's atlas, so the font is looked up only when a glyph is drawn. `dst`
/// is the pixel rectangle, and the color's RGB and alpha become the sprite's tint and alpha. `z` puts the UI above or
/// below other sprites.
fn queueQuads(batch: *sprite.SpriteBatch, fonts: *FontStore, handle: FontHandle, list: *const c.ui_quad_list, z: i32) void {
    const count: usize = @intCast(list.count);
    var atlas: ?*const Texture = null;
    var atlas_page: ?u32 = null;
    for (list.items[0..count]) |q| {
        const snap = @floor(q.dst.x + 0.5);
        const snap_y = @floor(q.dst.y + 0.5);
        const snap_w = @max(1.0, @floor(q.dst.w + 0.5));
        const snap_h = @max(1.0, @floor(q.dst.h + 0.5));
        if (q.solid != 0) {
            const white = batch.white orelse continue;
            batch.drawSprite(
                white,
                .{ .x = 0, .y = 0, .w = @floatFromInt(white.width), .h = @floatFromInt(white.height) },
                .{ .x = snap, .y = snap_y, .w = snap_w, .h = snap_h },
                .{ .tint = .{ q.color.r, q.color.g, q.color.b }, .alpha = q.color.a, .z = z },
            );
            continue;
        }
        const glyph_atlas = if (atlas_page != null and atlas_page.? == q.page) atlas.? else blk: {
            atlas = font_store.glyphTextureForPageOf(fonts, handle, q.page);
            atlas_page = q.page;
            break :blk atlas.?;
        };
        batch.drawSprite(
            glyph_atlas,
            .{ .x = q.src.x, .y = q.src.y, .w = q.src.w, .h = q.src.h },
            .{ .x = snap, .y = snap_y, .w = snap_w, .h = snap_h },
            .{ .tint = .{ q.color.r, q.color.g, q.color.b }, .alpha = q.color.a, .z = z },
        );
    }
}

test "ui anchorBounds places panels relative to the viewport" {
    const panel = anchorBounds(320, 180, 120, 60, .top_right, 8, 6);
    try std.testing.expectEqual(@as(f32, 192.0), panel.x);
    try std.testing.expectEqual(@as(f32, 6.0), panel.y);
    try std.testing.expectEqual(@as(f32, 120.0), panel.w);
    try std.testing.expectEqual(@as(f32, 60.0), panel.h);

    const centered = anchorBounds(320, 180, 80, 40, .center, 0, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 120.0), centered.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 70.0), centered.y, 1e-4);
}

test "Canvas keeps runtime glyph clusters across wrapping and widgets measure through the provider" {
    const font_test_support = @import("../text/font_test_support.zig");
    const shaped_layout = @import("../text/shaped_layout.zig");
    const allocator = std.testing.allocator;
    const store = try font_store.create(allocator);
    defer font_store.destroy(store);
    const handle = try font_store.insertRuntime(store, try font_test_support.runtimeOutlineFixture(allocator));

    var canvas = Canvas.create(allocator, store, handle);
    defer canvas.deinit();

    const text = "A\u{0305}A\u{0305}";
    const cluster_width = canvas.textWidth(text[0..3]);
    const full_width = canvas.textWidth(text);
    try std.testing.expect(full_width > cluster_width);
    var layout = try canvas.layoutText(allocator, text, (cluster_width + full_width) / 2, .left);
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 2), layout.lines.len);
    try std.testing.expectEqualStrings(text[0..3], layout.lines[0].text);
    try std.testing.expectEqualStrings(text[3..], layout.lines[1].text);
    try std.testing.expectEqual(handle.id, shaped_layout.fontIdOf(&layout).?);
    for (shaped_layout.glyphsOf(&layout, 0)) |glyph| try std.testing.expectEqual(@as(u32, 0), glyph.cluster);
    for (shaped_layout.glyphsOf(&layout, 1)) |glyph| try std.testing.expectEqual(@as(u32, 3), glyph.cluster);

    var widgets = Ui.init(allocator, store, handle);
    defer widgets.deinit();
    const widget_width = widgets.ctx.text_width.?(
        widgets.ctx.font_context,
        widgets.ctx.font_id,
        "AV",
        2,
    );
    try std.testing.expectEqual(canvas.textWidth("AV"), widget_width);
    try std.testing.expect(widgets.ctx.draw_text != null);
}

test "Canvas Tamil options agree across measurement, wrapping, and drawing" {
    const runtime_font = @import("../text/runtime_font.zig");
    const glyph_atlas = @import("../renderer/glyph_atlas.zig");
    const glyph_cache = @import("../text/glyph_cache.zig");
    const allocator = std.testing.allocator;
    const blob = runtime_font.hb.hb_blob_create_from_file_or_fail("tests/fixtures/NotoSansTamil.ttf") orelse
        return error.FixtureMissing;
    defer runtime_font.hb.hb_blob_destroy(blob);
    var len: c_uint = 0;
    const data = runtime_font.hb.hb_blob_get_data(blob, &len);
    if (data == null or len == 0) return error.FixtureMissing;
    const bytes: [*]const u8 = @ptrCast(data);
    var atlas = glyph_atlas.Atlas{
        .allocator = allocator,
        .cache = try glyph_cache.Cache.init(allocator, .{}),
        .pages = &.{},
    };
    defer atlas.deinit();
    const fonts = try font_store.createWithAtlas(allocator, &atlas);
    defer font_store.destroy(fonts);
    const handle = try font_store.insertRuntime(
        fonts,
        try runtime_font.RuntimeFont.init(allocator, bytes[0..@as(usize, len)], 16),
    );
    var canvas = Canvas.create(allocator, fonts, handle);
    defer canvas.deinit();

    const tamil: TextOptions = .{ .script = "Taml", .language = "ta" };
    const conjunct = "\u{0B95}\u{0BCD}\u{0BB7}";
    const width = canvas.textWidthWithOptions(conjunct, tamil);
    try std.testing.expect(width > 0);

    var layout = try canvas.layoutTextWithOptions(allocator, conjunct, width + 1, .left, tamil);
    defer layout.deinit();
    const shaped_layout = @import("../text/shaped_layout.zig");
    const conjunct_glyphs = shaped_layout.glyphsOf(&layout, 0);
    try std.testing.expectEqual(@as(usize, 1), conjunct_glyphs.len);
    try std.testing.expectApproxEqAbs(width, layout.lines[0].width, 1e-4);

    const wrapped = "\u{0BA4}\u{0BAE}\u{0BBF}\u{0BB4}\u{0BCD} " ++ conjunct;
    const word = wrapped[0..15];
    var word_layout = try canvas.layoutTextWithOptions(allocator, wrapped, canvas.textWidthWithOptions(word, tamil), .left, tamil);
    defer word_layout.deinit();
    try std.testing.expectEqual(@as(usize, 2), word_layout.lines.len);
    try std.testing.expectEqual(@as(usize, 1), shaped_layout.glyphsOf(&word_layout, 1).len);

    const white = Color{ .r = 1, .g = 1, .b = 1, .a = 1 };
    canvas.textWithOptions(0, 0, conjunct, tamil, white);
    try std.testing.expectEqual(@as(c_int, 1), canvas.list.count);
    canvas.clear();
    canvas.text(0, 0, conjunct, white);
    try std.testing.expectEqual(@as(c_int, 3), canvas.list.count);
}

/// A font with empty metrics, except for a 1x1 white block at the origin. Its texture comes from the test fixtures, with no GPU object.
fn emptyFont() font_mod.Font {
    const fixtures = @import("../testing/fixtures.zig");
    // A C struct literal must name every field, so start from zeros and set the one that matters here.
    var baked = std.mem.zeroes(c.ui_font);
    baked.white = .{ .x = 0, .y = 0, .w = 1, .h = 1 };
    return .{ .texture = fixtures.texture(1, 1), .baked = baked };
}

/// Stores a font with a 2x2 white block at the origin and a 64x64 fixture texture, for the Canvas tests. The tests call
/// `discard` on their store, not `destroy`, because the fixture texture has no GPU object to release.
fn insertFixtureFont(fonts: *FontStore) !FontHandle {
    const fixtures = @import("../testing/fixtures.zig");
    var font = font_mod.Font{ .baked = std.mem.zeroes(c.ui_font), .texture = fixtures.texture(64, 64) };
    font.baked.white = .{ .x = 0, .y = 0, .w = 2, .h = 2 };
    return font_store.insertBfnt(fonts, font);
}

test "ui begin substitutes a safe layout and origin when input is invalid" {
    const fonts = try font_store.create(std.testing.allocator);
    defer font_store.discard(fonts);
    const font = try font_store.insertBfnt(fonts, emptyFont());
    var ui = Ui.init(std.testing.allocator, fonts, font);
    defer ui.deinit();

    var input_state = input.Input{};
    input_state.mouse_x = std.math.nan(f32);
    input_state.mouse_y = std.math.inf(f32);
    ui.begin(&input_state, .{
        .pixel_density = 0,
        .dst_w = 0,
        .dst_h = 0,
        .view_w = 0,
        .view_h = 0,
    }, std.math.nan(f32), std.math.inf(f32), 0);
}

test "ui begin passes Escape as the cancel, and the key pressed as its control" {
    const fonts = try font_store.create(std.testing.allocator);
    defer font_store.discard(fonts);
    const font = try font_store.insertBfnt(fonts, emptyFont());
    var ui = Ui.init(std.testing.allocator, fonts, font);
    defer ui.deinit();

    var input_state = input.Input{};
    input_state.keyDown(.escape);
    input_state.latch();
    ui.begin(&input_state, .{
        .pixel_density = 1,
        .dst_x = 0,
        .dst_y = 0,
        .dst_w = 320,
        .dst_h = 180,
        .view_w = 320,
        .view_h = 180,
    }, 0, 0, 100);
    const escape_code: u32 = action.codeOf(.{ .key = .escape });
    try std.testing.expectEqual(@as(c_int, 1), ui.ctx.in.cancel);
    try std.testing.expectEqual(escape_code, @as(u32, @intCast(ui.ctx.in.control)));
    ui.end();
    try std.testing.expect(!ui.listening());
}

test "a solid rectangle draws from the batch's white texture, not the font atlas" {
    const allocator = std.testing.allocator;
    const fixtures = @import("../testing/fixtures.zig");

    const fonts = try font_store.create(allocator);
    defer font_store.discard(fonts);
    const handle = try insertFixtureFont(fonts);
    const list = try allocator.create(c.ui_quad_list);
    defer allocator.destroy(list);
    list.count = 0;
    list.dropped = 0;
    var canvas = Canvas{ .allocator = allocator, .fonts = fonts, .font = handle, .list = list };
    canvas.rect(10, 10, 20, 5, .{ .r = 1, .g = 0, .b = 0, .a = 1 });

    var no_vertices: [0]sprite.Vertex = .{};
    var no_batches: [0]sprite.Batch = .{};
    var batch = fixtures.batch(&no_vertices, &no_batches);
    defer fixtures.freeBatch(&batch);
    const white = fixtures.texture(2, 2);
    batch.white = &white;
    batch.begin(320, 180);
    canvas.queue(&batch, 0);
    batch.prepare();

    try std.testing.expectEqual(@as(u32, 1), batch.batch_count);
    try std.testing.expectEqual(@as(*const Texture, &white), batch.batches[0].texture);
    // The white texture is 2x2 and entirely covered, so the whole texture maps onto the quad.
    try std.testing.expectEqual(@as(f32, 0), batch.vertices[0].uv[0]);
    try std.testing.expectEqual(@as(f32, 1), batch.vertices[2].uv[0]);
    try std.testing.expectEqual(@as(f32, 1), batch.vertices[2].uv[1]);
}

test "a glyph keeps the font atlas, and a fill after it starts a run on the white texture" {
    const allocator = std.testing.allocator;
    const fixtures = @import("../testing/fixtures.zig");

    const fonts = try font_store.create(allocator);
    defer font_store.discard(fonts);
    const handle = try insertFixtureFont(fonts);
    const atlas = font_store.glyphTextureOf(fonts, handle);
    const list = try allocator.create(c.ui_quad_list);
    defer allocator.destroy(list);
    list.count = 0;
    list.dropped = 0;
    // A glyph quad, as the C side pushes one: solid is 0, and src is a texel rectangle of the atlas.
    list.items[0] = std.mem.zeroes(c.ui_quad);
    list.items[0].dst = .{ .x = 0, .y = 0, .w = 8, .h = 8 };
    list.items[0].src = .{ .x = 4, .y = 4, .w = 8, .h = 8 };
    list.items[0].color = .{ .r = 1, .g = 1, .b = 1, .a = 1 };
    list.items[0].solid = 0;
    list.count = 1;
    var canvas = Canvas{ .allocator = allocator, .fonts = fonts, .font = handle, .list = list };
    canvas.rect(10, 10, 20, 5, .{ .r = 1, .g = 0, .b = 0, .a = 1 });

    var no_vertices: [0]sprite.Vertex = .{};
    var no_batches: [0]sprite.Batch = .{};
    var batch = fixtures.batch(&no_vertices, &no_batches);
    defer fixtures.freeBatch(&batch);
    const white = fixtures.texture(2, 2);
    batch.white = &white;
    batch.begin(320, 180);
    canvas.queue(&batch, 0);
    batch.prepare();

    try std.testing.expectEqual(@as(u32, 2), batch.batch_count);
    try std.testing.expectEqual(@as(*const Texture, atlas), batch.batches[0].texture);
    try std.testing.expectEqual(@as(*const Texture, &white), batch.batches[1].texture);
}

test "without a white texture on the batch, a fill is not drawn" {
    const allocator = std.testing.allocator;
    const fixtures = @import("../testing/fixtures.zig");

    const fonts = try font_store.create(allocator);
    defer font_store.discard(fonts);
    const handle = try insertFixtureFont(fonts);
    const list = try allocator.create(c.ui_quad_list);
    defer allocator.destroy(list);
    list.count = 0;
    list.dropped = 0;
    var canvas = Canvas{ .allocator = allocator, .fonts = fonts, .font = handle, .list = list };
    canvas.rect(10, 10, 20, 5, .{ .r = 1, .g = 0, .b = 0, .a = 1 });

    var no_vertices: [0]sprite.Vertex = .{};
    var no_batches: [0]sprite.Batch = .{};
    var batch = fixtures.batch(&no_vertices, &no_batches);
    defer fixtures.freeBatch(&batch);
    batch.begin(320, 180);
    canvas.queue(&batch, 0);
    batch.prepare();

    try std.testing.expectEqual(@as(u32, 0), batch.batch_count);
}

test "a fill is drawn from the white texture even when the handle names no font" {
    const allocator = std.testing.allocator;
    const fixtures = @import("../testing/fixtures.zig");

    const fonts = try font_store.create(allocator);
    defer font_store.discard(fonts);
    const list = try allocator.create(c.ui_quad_list);
    defer allocator.destroy(list);
    list.count = 0;
    list.dropped = 0;
    // No font is stored under this handle. A fill never looks one up, so queueing it does not panic.
    var canvas = Canvas{ .allocator = allocator, .fonts = fonts, .font = FontHandle.invalid, .list = list };
    canvas.rect(10, 10, 20, 5, .{ .r = 1, .g = 0, .b = 0, .a = 1 });

    var no_vertices: [0]sprite.Vertex = .{};
    var no_batches: [0]sprite.Batch = .{};
    var batch = fixtures.batch(&no_vertices, &no_batches);
    defer fixtures.freeBatch(&batch);
    const white = fixtures.texture(2, 2);
    batch.white = &white;
    batch.begin(320, 180);
    canvas.queue(&batch, 0);
    batch.prepare();

    try std.testing.expectEqual(@as(u32, 1), batch.batch_count);
    try std.testing.expectEqual(@as(*const Texture, &white), batch.batches[0].texture);
}

test "Canvas text layout validates dimensions" {
    // Moved here from engine_api_test.zig: building a store is an engine-internal step, so the public API test cannot do it.
    const fonts = try font_store.create(std.testing.allocator);
    defer font_store.discard(fonts);
    var baked = std.mem.zeroes(c.ui_font);
    baked.line_height = 10;
    const handle = try font_store.insertBfnt(fonts, .{ .baked = baked, .texture = undefined });
    const canvas = Canvas{ .allocator = std.testing.allocator, .fonts = fonts, .font = handle, .list = undefined };
    try std.testing.expectError(error.InvalidWidth, canvas.layoutText(std.testing.allocator, "text", 0, .left));
}
