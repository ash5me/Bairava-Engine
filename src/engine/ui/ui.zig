//! Text and widgets, bridged from the C code in src/engine/ui/. The C side builds quads in pixels,
//! all sampling one font atlas. This file queues each quad as a sprite. Fonts are loaded and baked
//! in text/font.zig.
//!
//! The C headers are private to this file and to text/font.zig. Everything else reaches the UI
//! through `Canvas` (text and rectangles) and `Ui` (widgets), which take and return Zig types.

const std = @import("std");
const c = @import("c.zig").c;
const input = @import("../input/input.zig");
const action = @import("../input/action.zig");
const sprite = @import("../renderer/sprite.zig");
const view = @import("../renderer/view.zig");
const text_layout = @import("../text/layout.zig");

/// A font on the GPU. See text/font.zig.
pub const Font = @import("../text/font.zig").Font;
pub const TextAlignment = text_layout.Alignment;
pub const TextLayout = text_layout.Layout;

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

/// A font and a quad list on the heap, with text and rectangle helpers. The debug overlay draws
/// with one directly, and `Ui` builds one for its widgets. The font lives on the heap because the
/// C side keeps pointers into it.
pub const Canvas = struct {
    allocator: std.mem.Allocator,
    font: *Font,
    list: *c.ui_quad_list,

    /// Takes ownership of `font`; all wrapper memory uses `allocator`.
    pub fn create(allocator: std.mem.Allocator, font: Font) Canvas {
        const heap_font = allocator.create(Font) catch @panic("out of memory");
        heap_font.* = font;
        const list = allocator.create(c.ui_quad_list) catch @panic("out of memory");
        list.count = 0;
        list.dropped = 0;
        return .{ .allocator = allocator, .font = heap_font, .list = list };
    }

    pub fn deinit(self: *Canvas) void {
        self.font.deinit();
        self.allocator.destroy(self.font);
        self.allocator.destroy(self.list);
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

    /// Builds a wrapped, aligned text block. Line slices borrow `str`; release the result with
    /// `TextLayout.deinit` and the allocator used here.
    pub fn layoutText(self: *const Canvas, allocator: std.mem.Allocator, str: []const u8, max_width: f32, alignment: TextAlignment) text_layout.LayoutError!TextLayout {
        return text_layout.layout(
            allocator,
            str,
            max_width,
            @floatFromInt(self.font.baked.line_height),
            alignment,
            self,
            measureCanvasText,
        );
    }

    /// Adds each line of a previously measured text block at `(x, y)`.
    pub fn drawTextLayout(self: *Canvas, x: f32, y: f32, layout: *const TextLayout, color: Color) void {
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

fn measureCanvasText(context: *const anyopaque, str: []const u8) f32 {
    const canvas: *const Canvas = @ptrCast(@alignCast(context));
    return canvas.textWidth(str);
}

/// Immediate-mode widgets. The C side keeps the layout and the widget state, and this wrapper hands
/// it Zig values. Labels are copied into a buffer for the length of each call, because the C side
/// hashes them and draws them during the call and keeps no pointer to them.
pub const Ui = struct {
    allocator: std.mem.Allocator,
    canvas: Canvas,
    ctx: *c.ui_context,

    /// Takes ownership of `font`; wrapper memory uses `allocator`.
    pub fn init(allocator: std.mem.Allocator, font: Font) Ui {
        const canvas = Canvas.create(allocator, font);
        const ctx = allocator.create(c.ui_context) catch @panic("out of memory");
        c.ui_init(ctx, &canvas.font.baked);
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
        const frame = c.ui_input{
            .mouse_x = pointer.x,
            .mouse_y = pointer.y,
            .mouse_down = @intFromBool(in_state.mouseDown(.left)),
            .mouse_pressed = @intFromBool(in_state.mousePressed(.left)),
            .mouse_released = @intFromBool(in_state.mouseReleased(.left)),
            .control = @intCast(action.pressedCode(in_state)),
            .cancel = @intFromBool(in_state.wasPressed(.escape)),
        };
        c.ui_begin(self.ctx, &frame, if (std.math.isFinite(x)) x else 0, if (std.math.isFinite(y)) y else 0, if (std.math.isFinite(width) and width > 0) width else 1);
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

test "ui begin substitutes a safe layout and origin when input is invalid" {
    var ui = Ui.init(std.testing.allocator, .{
        .texture = .{},
        .baked = .{
            .white = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        },
    });
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
    var ui = Ui.init(std.testing.allocator, .{
        .texture = .{},
        .baked = .{
            .white = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        },
    });
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
