//! Text and widgets, bridged from the C code in src/engine/ui/. The C side builds quads in pixels,
//! all sampling one font atlas. This file loads preprocessed font assets when they match the
//! requested size, falls back to baking TTF data, and queues each quad as a sprite.
//!
//! The C headers are private to this file. Everything else reaches the UI through `Canvas` (text
//! and rectangles) and `Ui` (widgets), which take and return Zig types.

const std = @import("std");

const input = @import("input.zig");
const profile = @import("profile.zig");
const sdl = @import("sdl.zig");
const sprite = @import("sprite.zig");
const view = @import("view.zig");
const Texture = @import("texture.zig").Texture;

const c = @cImport({
    @cInclude("imgui.h");
});

/// The first codepoint baked, and how many. 32 to 255 covers printable ASCII and Latin-1.
const first_codepoint: c_int = 32;
const codepoint_count: c_int = 224;

/// An RGBA color, each channel from 0 to 1.
pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

/// A font on the GPU: the baked metrics and glyphs from C, plus the atlas texture they sample.
pub const Font = struct {
    /// Metrics and glyphs, owned by the C side. Pass `&font.baked` to C functions.
    baked: c.ui_font,
    texture: Texture,
    uploaded_generation: u32,

    /// Loads a build-preprocessed font when present and baked at the requested size; otherwise it
    /// bakes the supplied TTF data. Both inputs are only read during this call.
    pub fn load(device: *sdl.c.SDL_GPUDevice, ttf: []const u8, prebaked: []const u8, pixel_height: f32) !Font {
        if (prebaked.len > 0) {
            var baked: c.ui_font = undefined;
            if (c.ui_font_load_prebaked(prebaked.ptr, prebaked.len, pixel_height, &baked) == 0) {
                var font = fromBaked(device, baked);
                // Dynamic glyphs are rasterized from the TTF. Without it, codepoints outside the
                // baked range draw blank, and the prebaked font is still usable.
                if (ttf.len > 0) try font.enableDynamic(ttf);
                return font;
            }
        }
        var font = try bake(device, ttf, pixel_height);
        try font.enableDynamic(ttf);
        return font;
    }

    /// Bakes TTF bytes at `pixel_height` pixels, then uploads the atlas. Use `load` when a matching
    /// build-time font asset may be available.
    pub fn bake(device: *sdl.c.SDL_GPUDevice, ttf: []const u8, pixel_height: f32) !Font {
        const zone = profile.zoneNamed(@src(), "bake font");
        defer zone.End();
        var baked: c.ui_font = undefined;
        if (c.ui_font_bake(ttf.ptr, ttf.len, pixel_height, first_codepoint, codepoint_count, &baked) != 0) {
            return error.BakeFailed;
        }
        return fromBaked(device, baked);
    }

    /// Bakes an SDF atlas from TTF bytes for smooth text scaling. `distance_range` sets the encoded
    /// distance range in pixels; eight pixels is a useful default for UI fonts.
    pub fn bakeSdf(device: *sdl.c.SDL_GPUDevice, ttf: []const u8, pixel_height: f32, distance_range: f32) !Font {
        const zone = profile.zoneNamed(@src(), "bake SDF font");
        defer zone.End();
        var baked: c.ui_font = undefined;
        if (c.ui_font_bake_sdf(ttf.ptr, ttf.len, pixel_height, first_codepoint, codepoint_count, distance_range, &baked) != 0) {
            return error.BakeFailed;
        }
        return fromBaked(device, baked);
    }

    /// Enables lazy rasterization for codepoints outside the baked range. The font bytes are copied
    /// into the C font object and kept until deinit.
    pub fn enableDynamic(self: *Font, ttf: []const u8) !void {
        if (c.ui_font_enable_dynamic(&self.baked, ttf.ptr, ttf.len) != 0) return error.DynamicFontFailed;
    }

    fn fromBaked(device: *sdl.c.SDL_GPUDevice, baked: c.ui_font) Font {
        const w: u32 = @intCast(baked.atlas_w);
        const h: u32 = @intCast(baked.atlas_h);
        const pixels = baked.rgba[0 .. @as(usize, w) * @as(usize, h) * 4];
        // initRgba8 copies the pixels into a transfer buffer before returning, so the C copy can go.
        const texture = if (baked.sdf != 0)
            Texture.initRgba8Linear(device, w, h, pixels)
        else
            Texture.initRgba8(device, w, h, pixels);
        return .{ .baked = baked, .texture = texture, .uploaded_generation = baked.atlas_generation };
    }

    fn refreshTexture(self: *Font) void {
        if (self.uploaded_generation == self.baked.atlas_generation) return;
        self.texture.deinit();
        const w: u32 = @intCast(self.baked.atlas_w);
        const h: u32 = @intCast(self.baked.atlas_h);
        const pixels = self.baked.rgba[0 .. @as(usize, w) * @as(usize, h) * 4];
        self.texture = if (self.baked.sdf != 0)
            Texture.initRgba8Linear(self.texture.device, w, h, pixels)
        else
            Texture.initRgba8(self.texture.device, w, h, pixels);
        self.uploaded_generation = self.baked.atlas_generation;
    }

    pub fn deinit(self: *Font) void {
        self.texture.deinit();
        c.ui_font_destroy(&self.baked);
    }
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
