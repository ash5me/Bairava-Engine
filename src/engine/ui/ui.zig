//! Text and widgets, bridged from the C code in src/engine/ui/. The C side builds quads in pixels,
//! all sampling one font atlas. This file queues each quad as a sprite. Fonts are loaded and baked
//! in text/font.zig.
//!
//! The C headers are private to this file and to text/font.zig. Everything else reaches the UI
//! through `Canvas` (text and rectangles) and `Ui` (widgets), which take and return Zig types.

const std = @import("std");
const c = @import("c.zig").c;
const input = @import("../input/input.zig");
const sprite = @import("../renderer/sprite.zig");
const view = @import("../renderer/view.zig");

/// A font on the GPU. See text/font.zig.
pub const Font = @import("../text/font.zig").Font;

/// An RGBA color, each channel from 0 to 1.
pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};


/// A font and a quad list on the heap, with text and rectangle helpers. The debug overlay draws
/// with one directly, and `Ui` builds one for its widgets. The font lives on the heap because the
/// C side keeps pointers into it.
pub const Canvas = struct {
    font: *Font,
    list: *c.ui_quad_list,

    /// Takes ownership of `font`. Panics when memory runs out, like the rest of the engine's setup.
    pub fn create(font: Font) Canvas {
        const heap_font = std.heap.page_allocator.create(Font) catch @panic("out of memory");
        heap_font.* = font;
        const list = std.heap.page_allocator.create(c.ui_quad_list) catch @panic("out of memory");
        list.count = 0;
        list.dropped = 0;
        return .{ .font = heap_font, .list = list };
    }

    pub fn deinit(self: *Canvas) void {
        self.font.deinit();
        std.heap.page_allocator.destroy(self.font);
        std.heap.page_allocator.destroy(self.list);
    }

    /// Empties the quad list, ready for a new frame.
    pub fn clear(self: *Canvas) void {
        self.list.count = 0;
        self.list.dropped = 0;
    }

    /// The width of `str` in pixels, in this font.
    pub fn textWidth(self: *const Canvas, str: []const u8) f32 {
        return c.ui_font_text_width(&self.font.baked, str.ptr, str.len);
    }

    /// Adds `str` with its top-left corner at (x, y), in pixels.
    pub fn text(self: *Canvas, x: f32, y: f32, str: []const u8, color: Color) void {
        c.ui_font_draw_text(&self.font.baked, self.list, x, y, str.ptr, str.len, toC(color));
    }

    /// Adds a solid rectangle. It samples the font's white block, so it shares the font's texture
    /// and its draw call. Like `ui_quad_push`, quads past the list's capacity are counted in
    /// `dropped` and not drawn.
    pub fn rect(self: *Canvas, x: f32, y: f32, w: f32, h: f32, color: Color) void {
        const list = self.list;
        if (list.count >= c.UI_MAX_QUADS) {
            list.dropped += 1;
            return;
        }
        list.items[@intCast(list.count)] = .{
            .dst = .{ .x = x, .y = y, .w = w, .h = h },
            .src = self.font.baked.white,
            .color = toC(color),
        };
        list.count += 1;
    }

    /// Queues the quads as sprites at depth `z`.
    pub fn queue(self: *Canvas, batch: *sprite.SpriteBatch, z: i32) void {
        queueQuads(batch, self.font, self.list, z);
    }
};

/// Immediate-mode widgets. The C side keeps the layout and the widget state, and this wrapper hands
/// it Zig values. Labels are copied into a buffer for the length of each call, because the C side
/// hashes them and draws them during the call and keeps no pointer to them.
pub const Ui = struct {
    canvas: Canvas,
    ctx: *c.ui_context,

    /// Takes ownership of `font`. The context keeps a pointer to the font, so both live on the heap.
    pub fn init(font: Font) Ui {
        const canvas = Canvas.create(font);
        const ctx = std.heap.page_allocator.create(c.ui_context) catch @panic("out of memory");
        c.ui_init(ctx, &canvas.font.baked);
        return .{ .canvas = canvas, .ctx = ctx };
    }

    pub fn deinit(self: *Ui) void {
        std.heap.page_allocator.destroy(self.ctx);
        self.canvas.deinit();
    }

    /// Starts the frame's widgets in the column (x, y, width), in view pixels. The pointer comes
    /// from `in_state` in window points, so it is mapped through `layout` first.
    pub fn begin(self: *Ui, in_state: *const input.Input, layout: view.Layout, x: f32, y: f32, width: f32) void {
        const pointer = view.windowToView(layout, .{ .x = in_state.mouse_x, .y = in_state.mouse_y });
        const frame = c.ui_input{
            .mouse_x = pointer.x,
            .mouse_y = pointer.y,
            .mouse_down = @intFromBool(in_state.mouse_down),
            .mouse_pressed = @intFromBool(in_state.mouse_pressed),
            .mouse_released = @intFromBool(in_state.mouse_released),
        };
        c.ui_begin(self.ctx, &frame, x, y, width);
    }

    /// Ends the frame's widgets. Call `queue` after this to draw them.
    pub fn end(self: *Ui) void {
        c.ui_end(self.ctx);
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

    /// Queues this frame's widgets as sprites at depth `z`.
    pub fn queue(self: *Ui, batch: *sprite.SpriteBatch, z: i32) void {
        queueQuads(batch, self.canvas.font, &self.ctx.list, z);
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

/// Queues each quad in `list` as one sprite on `batch`. A quad's `src` is its texel rectangle in
/// `texture`, its `dst` is its pixel rectangle, and the color's RGB and alpha become the sprite's
/// tint and alpha. `z` puts the UI above or below other sprites, as with any sprite.
fn queueQuads(batch: *sprite.SpriteBatch, font: *Font, list: *const c.ui_quad_list, z: i32) void {
    font.refreshTexture();
    const count: usize = @intCast(list.count);
    for (list.items[0..count]) |q| {
        batch.drawSprite(
            &font.texture,
            .{ .x = q.src.x, .y = q.src.y, .w = q.src.w, .h = q.src.h },
            .{ .x = q.dst.x, .y = q.dst.y, .w = q.dst.w, .h = q.dst.h },
            .{ .tint = .{ q.color.r, q.color.g, q.color.b }, .alpha = q.color.a, .z = z, .sdf = q.sdf != 0 },
        );
    }
}
