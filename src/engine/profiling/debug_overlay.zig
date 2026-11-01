//! The on-screen debug overlay, drawn into the native view above the game. It shows frame timing by
//! phase, the active scene, input and asset counts, the game's own lines, and the debug geometry. The
//! engine toggles it with F3, and F4 toggles the geometry. It reads only the collector's published
//! snapshot, so it never reaches into a subsystem. It exists only in development builds: the engine
//! creates it with no font in release builds, and then it draws nothing.

const std = @import("std");

const sprite = @import("../renderer/sprite.zig");
const ui = @import("../ui/ui.zig");
const frame_history = @import("frame_history.zig");
const collector_mod = @import("../diagnostics/collector.zig");
const debug_draw = @import("../diagnostics/debug_draw.zig");
const text_mod = @import("../diagnostics/text.zig");
const console_mod = @import("../diagnostics/console.zig");

const Collector = collector_mod.Collector;

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

/// Lines the engine writes, then the game's lines. Each line's buffer is `line_capacity` bytes.
const engine_lines = 14;
const max_lines = engine_lines + text_mod.max_lines;
const line_capacity = text_mod.max_line_len;

const panel_color = ui.Color{ .r = 0.04, .g = 0.04, .b = 0.07, .a = 0.75 };
const text_color = ui.Color{ .r = 0.92, .g = 0.92, .b = 0.92, .a = 1.0 };
const budget_color = ui.Color{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 0.35 };
const good_color = ui.Color{ .r = 0.35, .g = 0.80, .b = 0.45, .a = 1.0 };
const slow_color = ui.Color{ .r = 0.95, .g = 0.80, .b = 0.30, .a = 1.0 };
const late_color = ui.Color{ .r = 0.95, .g = 0.35, .b = 0.35, .a = 1.0 };

pub const Overlay = struct {
    /// Null when the overlay has no font, which is always the case in release builds.
    canvas: ?ui.Canvas,
    visible: bool = true,

    /// Takes ownership of the font. The overlay draws with it every frame, so it lives for the run.
    pub fn init(allocator: std.mem.Allocator, font: ?ui.Font) Overlay {
        return .{ .canvas = if (font) |value| ui.Canvas.create(allocator, value) else null };
    }

    pub fn deinit(self: *Overlay) void {
        if (self.canvas) |*canvas| canvas.deinit();
    }

    pub fn toggle(self: *Overlay) void {
        self.visible = !self.visible;
    }

    /// Queues the overlay into `batch`, above the game in the native view. `view_w` is the view's width
    /// in view pixels, and the panel sits in the top-right corner. The debug shapes are drawn first, so
    /// the panel covers them where the two overlap.
    pub fn draw(self: *Overlay, batch: *sprite.SpriteBatch, view_w: f32, view_h: f32, collector: *const Collector, dev_console: *const console_mod.Console) void {
        if (!self.visible and !dev_console.visible) return;
        const canvas = if (self.canvas) |*value| value else return;
        canvas.clear();
        if (!self.visible) {
            drawConsole(canvas, dev_console, view_w, view_h);
            canvas.queue(batch, z);
            return;
        }
        drawShapes(canvas, &collector.debug);

        var store: [max_lines][line_capacity]u8 = undefined;
        var lines: [max_lines][]const u8 = undefined;
        const count = buildLines(&store, &lines, collector);

        var widest: f32 = graph_w;
        for (lines[0..count]) |line| {
            widest = @max(widest, canvas.textWidth(line));
        }

        const line_h: f32 = @floatFromInt(canvas.font.baked.line_height);
        const panel_w = widest + 2 * pad;
        const panel_h = pad + graph_h + pad + @as(f32, @floatFromInt(count)) * line_h + pad;
        const x0 = view_w - panel_w - margin;
        const y0 = margin;
        const graph_x = x0 + pad;
        const graph_bottom = y0 + pad + graph_h;

        canvas.rect(x0, y0, panel_w, panel_h, panel_color);
        drawGraph(canvas, collector, graph_x, graph_bottom);

        var text_y = graph_bottom + pad;
        for (lines[0..count]) |line| {
            canvas.text(x0 + pad, text_y, line, text_color);
            text_y += line_h;
        }

        if (dev_console.visible) drawConsole(canvas, dev_console, view_w, view_h);
        canvas.queue(batch, z);
    }
};

fn drawConsole(canvas: *ui.Canvas, dev_console: *const console_mod.Console, view_w: f32, view_h: f32) void {
    const line_h: f32 = @floatFromInt(canvas.font.baked.line_height);
    const max_w = @max(0, view_w - 2 * margin);
    const output_line_count = @min(std.mem.count(u8, dev_console.outputText(), "\n") + 1, 6);
    const panel_h = @as(f32, @floatFromInt(output_line_count + 1)) * line_h + 2 * pad;
    const y0 = @max(margin, view_h - panel_h - margin);
    const x0 = margin;
    canvas.rect(x0, y0, max_w, panel_h, panel_color);

    var output_lines = std.mem.splitScalar(u8, dev_console.outputText(), '\n');
    var line_index: usize = 0;
    while (output_lines.next()) |line| : (line_index += 1) {
        if (line_index == output_line_count) break;
        canvas.text(x0 + pad, y0 + pad + @as(f32, @floatFromInt(line_index)) * line_h, line, if (dev_console.output_is_error) late_color else text_color);
    }

    var prompt: [console_mod.max_input + 2]u8 = undefined;
    const prompt_text = std.fmt.bufPrint(&prompt, "> {s}", .{dev_console.inputText()}) catch unreachable;
    canvas.text(x0 + pad, y0 + panel_h - line_h - pad, prompt_text, good_color);
}

/// Writes the engine's lines, then the game's, into `lines`. Returns how many lines there are.
fn buildLines(store: *[max_lines][line_capacity]u8, lines: *[max_lines][]const u8, collector: *const Collector) usize {
    const snap = &collector.snapshot;
    const frame = collector.stats.of(.frame);
    const avg = frame.average();
    const fps: f32 = if (avg > 0) 1.0 / avg else 0;
    const pending: []const u8 = if (snap.scene.pending != null) " (switch pending)" else "";
    const geometry: []const u8 = if (collector.geometry.any()) "on" else "off";

    var count: usize = 0;
    lines[count] = formatLine(&store[count], "FPS {d:.0}  avg {d:.1}  p95 {d:.1}  max {d:.1} ms", .{
        fps,
        frame.average() * 1000.0,
        frame.percentile(0.95) * 1000.0,
        frame.max() * 1000.0,
    });
    count += 1;
    lines[count] = formatLine(&store[count], "update {d:.2} ms  render {d:.2} ms", .{
        collector.stats.of(.update).last() * 1000.0,
        (collector.stats.of(.draw).last() + collector.stats.of(.present).last()) * 1000.0,
    });
    count += 1;
    lines[count] = formatLine(&store[count], "scene {s}{s}  switches {d}", .{ snap.scene.name, pending, snap.scene.switches });
    count += 1;
    lines[count] = formatLine(&store[count], "entities {d}  sprites {d}  draws {d}  zoom {d:.2}", .{ snap.world.entities, snap.world.sprites, snap.world.draw_calls, snap.world.zoom });
    count += 1;
    lines[count] = formatLine(&store[count], "{s} {d:.0}%  view {d}x{d}  cam {d:.0},{d:.0}", .{
        snap.world.mode, snap.world.scale * 100.0, snap.world.view_w, snap.world.view_h, snap.world.cam_x, snap.world.cam_y,
    });
    count += 1;
    lines[count] = formatLine(&store[count], "input: held {d}  pressed {d}  mouse {d:.0},{d:.0}", .{
        snap.input.held, snap.input.pressed, snap.input.mouse_x, snap.input.mouse_y,
    });
    count += 1;
    lines[count] = namesLine(&store[count], "keys", &snap.input.keys);
    count += 1;
    lines[count] = namesLine(&store[count], "actions", &snap.input.actions);
    count += 1;
    lines[count] = formatLine(&store[count], "assets: loaded {d}  hits {d}  misses {d}  failed {d}", .{
        snap.assets.loaded, snap.assets.hits, snap.assets.misses, snap.assets.failed,
    });
    count += 1;
    lines[count] = formatLine(&store[count], "memory live E/G/A/F {d}/{d}/{d}/{d} KiB; peak {d}/{d}/{d}/{d} KiB", .{
        snap.memory.engine.live_bytes / 1024,
        snap.memory.game.live_bytes / 1024,
        snap.memory.asset.live_bytes / 1024,
        snap.memory.frame.live_bytes / 1024,
        snap.memory.engine.high_water_bytes / 1024,
        snap.memory.game.high_water_bytes / 1024,
        snap.memory.asset.high_water_bytes / 1024,
        snap.memory.frame.high_water_bytes / 1024,
    });
    count += 1;
    lines[count] = formatLine(&store[count], "arena E/G/A/F {d}/{d}/{d}/{d} KiB", .{
        snap.memory.engine.arena_capacity_bytes / 1024,
        snap.memory.game.arena_capacity_bytes / 1024,
        snap.memory.asset.arena_capacity_bytes / 1024,
        snap.memory.frame.arena_capacity_bytes / 1024,
    });
    count += 1;
    lines[count] = formatLine(&store[count], "map {d}x{d}  cursor cell {d},{d}  tile {d}  solid {d}", .{
        snap.world.map_cols,
        snap.world.map_rows,
        snap.world.selected_col,
        snap.world.selected_row,
        if (snap.world.selected_tile) |id| @as(i32, id) else -1,
        @intFromBool(snap.world.selected_solid),
    });
    count += 1;
    lines[count] = formatLine(&store[count], "geometry {s}  shapes {d}  dropped {d}  collision queries {d}", .{
        geometry, collector.debug.count, collector.debug.dropped, snap.world.collision_queries,
    });
    count += 1;
    lines[count] = formatLine(&store[count], "frames {d}", .{snap.frames});
    count += 1;

    var i: usize = 0;
    while (i < collector.text.count) : (i += 1) {
        lines[count] = collector.text.line(i);
        count += 1;
    }
    return count;
}

/// The frame graph: one column per kept frame, newest at the right, with the 60 Hz budget across it.
fn drawGraph(canvas: *ui.Canvas, collector: *const Collector, graph_x: f32, graph_bottom: f32) void {
    const history = collector.stats.of(.frame);
    var i: usize = 0;
    while (i < history.len) : (i += 1) {
        const seconds = history.at(i);
        const h = frame_history.fraction(seconds, full_scale_s) * graph_h;
        if (h <= 0) continue;
        const column: f32 = @floatFromInt(frame_history.capacity - history.len + i);
        canvas.rect(graph_x + column, graph_bottom - h, 1, h, barColor(seconds));
    }
    const budget_y = graph_bottom - frame_history.fraction(budget_s, full_scale_s) * graph_h;
    canvas.rect(graph_x, budget_y, graph_w, 1, budget_color);
}

/// Draws the debug shapes into the canvas. An outline is four one-pixel rectangles.
fn drawShapes(canvas: *ui.Canvas, draw: *const debug_draw.Draw) void {
    for (draw.slice()) |shape| {
        const color = ui.Color{ .r = shape.color.r, .g = shape.color.g, .b = shape.color.b, .a = shape.color.a };
        switch (shape.kind) {
            .fill => canvas.rect(shape.x, shape.y, shape.w, shape.h, color),
            .outline => {
                canvas.rect(shape.x, shape.y, shape.w, 1, color);
                canvas.rect(shape.x, shape.y + shape.h - 1, shape.w, 1, color);
                canvas.rect(shape.x, shape.y, 1, shape.h, color);
                canvas.rect(shape.x + shape.w - 1, shape.y, 1, shape.h, color);
            },
        }
    }
}

/// Formats a line of names, such as the held keys. A list that dropped names says how many.
fn namesLine(buf: *[line_capacity]u8, label: []const u8, names: *const collector_mod.NameList) []const u8 {
    const body: []const u8 = if (names.count == 0) "none" else names.text();
    if (names.omitted == 0) return formatLine(buf, "{s}: {s}", .{ label, body });
    return formatLine(buf, "{s}: {s} +{d}", .{ label, body, names.omitted });
}

/// Formats one text line into `buf`. The lines are short and fixed, so a full buffer is a bug.
fn formatLine(buf: *[line_capacity]u8, comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, format, args) catch std.debug.panic("overlay line does not fit its buffer", .{});
}

/// The color of a frame's bar: green within a little over the budget, yellow within two budgets, and
/// red beyond that.
fn barColor(seconds: f32) ui.Color {
    if (seconds <= budget_s * 1.1) return good_color;
    if (seconds <= budget_s * 2.0) return slow_color;
    return late_color;
}
