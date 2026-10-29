//! On-screen debug overlay: a frame-time graph and the frame's numbers, drawn into the native view
//! above the game. The engine toggles it with F3. It replaces the stats that used to go in the
//! window title. Its text uses a font of its own, loaded from a preprocessed sidecar when available.

const std = @import("std");

const sdl = @import("sdl.zig");
const sprite = @import("sprite.zig");
const ui = @import("ui.zig");
const frame_history = @import("frame_history.zig");

/// Draw order. Above the game's sprites and its UI panel, which use 1000.
const z: i32 = 2000;

/// The 60 Hz frame budget in seconds. The top of the graph is two budgets, so a frame that takes
/// longer than that is drawn at full height.
const budget_s: f32 = 1.0 / 60.0;
const full_scale_s: f32 = 2.0 * budget_s;

/// Layout in native pixels. The graph is one column per kept frame, so it is `capacity` pixels wide.
const graph_w: f32 = frame_history.capacity;
const graph_h: f32 = 40;
const pad: f32 = 3;
const margin: f32 = 4;

/// Lines of text under the graph, and the size of each line's buffer.
const text_lines = 5;
const line_capacity = 64;

const panel_color = ui.c.ui_color{ .r = 0.04, .g = 0.04, .b = 0.07, .a = 0.75 };
const text_color = ui.c.ui_color{ .r = 0.92, .g = 0.92, .b = 0.92, .a = 1.0 };
const budget_color = ui.c.ui_color{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 0.35 };
const good_color = ui.c.ui_color{ .r = 0.35, .g = 0.80, .b = 0.45, .a = 1.0 };
const slow_color = ui.c.ui_color{ .r = 0.95, .g = 0.80, .b = 0.30, .a = 1.0 };
const late_color = ui.c.ui_color{ .r = 0.95, .g = 0.35, .b = 0.35, .a = 1.0 };

/// What the overlay shows about the frame. The engine fills this in each frame.
pub const Stats = struct {
    /// Sprites the game queued this frame, not counting the overlay's own.
    sprites: u32,
    /// Draw calls from the last frame. This frame's are not known until its batches are drawn.
    draw_calls: u32,
    /// "fit" or "integer".
    mode: []const u8,
    /// Window pixels per view pixel.
    scale: f32,
    zoom: f32,
    view_w: u32,
    view_h: u32,
};

pub const Overlay = struct {
    font: ui.Font,
    /// This frame's quads. On the heap, because a full list is large.
    list: *ui.c.ui_quad_list,
    history: frame_history.FrameHistory = .{},
    visible: bool = true,

    /// Loads matching preprocessed font data when available, and otherwise bakes the TTF bytes.
    pub fn init(device: *sdl.c.SDL_GPUDevice, ttf: []const u8, prebaked: []const u8, pixel_height: f32) !Overlay {
        var font = try ui.Font.load(device, ttf, prebaked, pixel_height);
        const list = std.heap.page_allocator.create(ui.c.ui_quad_list) catch |err| {
            font.deinit();
            return err;
        };
        return .{ .font = font, .list = list };
    }

    pub fn deinit(self: *Overlay) void {
        self.font.deinit();
        std.heap.page_allocator.destroy(self.list);
    }

    /// Adds one frame time to the graph. The engine calls this once per loop iteration.
    pub fn record(self: *Overlay, seconds: f32) void {
        self.history.push(seconds);
    }

    pub fn toggle(self: *Overlay) void {
        self.visible = !self.visible;
    }

    /// Queues the overlay into `batch`, above the game in the native view. `view_w` is the view's
    /// width in view pixels. The panel sits in the top-right corner.
    pub fn draw(self: *Overlay, batch: *sprite.SpriteBatch, view_w: f32, stats: Stats) void {
        if (!self.visible) return;
        const list = self.list;
        list.count = 0;
        list.dropped = 0;
        const white = self.font.baked.white;

        // The text is built first, so the panel can be sized to its widest line.
        var bufs: [text_lines][line_capacity]u8 = undefined;
        const avg = self.history.average();
        const fps: f32 = if (avg > 0) 1.0 / avg else 0;
        const lines = [text_lines][]const u8{
            formatLine(&bufs[0], "FPS {d:.0}  frame {d:.1} ms", .{ fps, self.history.last() * 1000.0 }),
            formatLine(&bufs[1], "avg {d:.1}  max {d:.1} ms", .{ avg * 1000.0, self.history.max() * 1000.0 }),
            formatLine(&bufs[2], "sprites {d}  draws {d}", .{ stats.sprites, stats.draw_calls }),
            formatLine(&bufs[3], "{s} {d:.0}%  zoom {d:.2}", .{ stats.mode, stats.scale * 100.0, stats.zoom }),
            formatLine(&bufs[4], "view {d}x{d}", .{ stats.view_w, stats.view_h }),
        };
        var widest: f32 = graph_w;
        for (lines) |line| {
            widest = @max(widest, ui.c.ui_font_text_width(&self.font.baked, line.ptr, line.len));
        }

        const line_h: f32 = @floatFromInt(self.font.baked.line_height);
        const panel_w = widest + 2 * pad;
        const panel_h = pad + graph_h + pad + text_lines * line_h + pad;
        const x0 = view_w - panel_w - margin;
        const y0 = margin;
        const graph_x = x0 + pad;
        const graph_bottom = y0 + pad + graph_h;

        pushRect(list, white, .{ .x = x0, .y = y0, .w = panel_w, .h = panel_h }, panel_color);

        // One column per frame, with the newest at the right edge. An empty history leaves the graph empty.
        const kept = self.history.len;
        var i: usize = 0;
        while (i < kept) : (i += 1) {
            const seconds = self.history.at(i);
            const h = frame_history.fraction(seconds, full_scale_s) * graph_h;
            if (h <= 0) continue;
            const column: f32 = @floatFromInt(frame_history.capacity - kept + i);
            pushRect(list, white, .{ .x = graph_x + column, .y = graph_bottom - h, .w = 1, .h = h }, barColor(seconds));
        }

        // The 60 Hz budget, as a line across the whole graph.
        const budget_y = graph_bottom - frame_history.fraction(budget_s, full_scale_s) * graph_h;
        pushRect(list, white, .{ .x = graph_x, .y = budget_y, .w = graph_w, .h = 1 }, budget_color);

        var text_y = graph_bottom + pad;
        for (lines) |line| {
            ui.c.ui_font_draw_text(&self.font.baked, list, x0 + pad, text_y, line.ptr, line.len, text_color);
            text_y += line_h;
        }

        ui.queueQuads(batch, &self.font, list, z);
    }
};

/// Formats one text line into `buf`. The lines are short and fixed, so a full buffer is a bug.
fn formatLine(buf: []u8, comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, format, args) catch std.debug.panic("overlay line does not fit its buffer", .{});
}

/// The color of a frame's bar: green within a little over the budget, yellow within two budgets, and
/// red beyond that.
fn barColor(seconds: f32) ui.c.ui_color {
    if (seconds <= budget_s * 1.1) return good_color;
    if (seconds <= budget_s * 2.0) return slow_color;
    return late_color;
}

/// Adds a solid rectangle. It samples the font's white block, so it shares the overlay's texture and
/// its draw call. Like `ui_quad_push`, quads past the list's capacity are counted rather than drawn.
fn pushRect(list: *ui.c.ui_quad_list, white: ui.c.ui_rect, rect: ui.c.ui_rect, color: ui.c.ui_color) void {
    if (list.count >= ui.c.UI_MAX_QUADS) {
        list.dropped += 1;
        return;
    }
    list.items[@intCast(list.count)] = .{ .dst = rect, .src = white, .color = color };
    list.count += 1;
}
