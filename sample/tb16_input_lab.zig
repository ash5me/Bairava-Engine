//! TB-16 visualizes supported controls and checks input edges, mappings, hotplug, and buffering.

const std = @import("std");
const engine = @import("bairava");

const log = engine.log.scoped("tb16");
const Action = enum { confirm, fire, pause };
const ActionMap = engine.ActionMap(Action);
const ActionBuffer = engine.ActionBuffer(Action);
const Defaults = engine.ActionDefaults(Action);
const Binding = engine.Binding;
const Color = engine.ui.Color;

const white = Color{ .r = 0.94, .g = 0.96, .b = 1, .a = 1 };
const muted = Color{ .r = 0.65, .g = 0.73, .b = 0.83, .a = 1 };
const panel = Color{ .r = 0.025, .g = 0.04, .b = 0.07, .a = 0.92 };
const green = Color{ .r = 0.3, .g = 1, .b = 0.58, .a = 1 };
const amber = Color{ .r = 1, .g = 0.72, .b = 0.25, .a = 1 };
const keys_per_page = 13;

const defaults = Defaults.init(.{
    .confirm = &.{ .{ .key = .space }, .{ .gamepad_button = .south } },
    .fire = &.{.{ .mouse = .left }},
    .pause = &.{ .{ .key = .escape }, .{ .gamepad_button = .start } },
});

const config = engine.Config{
    .title = "Bairava TB-16 Input Laboratory",
    .window_w = 960,
    .window_h = 540,
    .native_w = 320,
    .native_h = 180,
    .clear_rgb = .{ 0.012, 0.018, 0.03 },
    .settings_file = "tb16_settings.txt",
};

const Options = struct {
    frames: u64 = 360,
};

var options = Options{};

const Validation = struct {
    checks: u64 = 0,
    failures: u64 = 0,
    key_edges: u64 = 0,
    mouse_edges: u64 = 0,
    action_remaps: u64 = 0,
    pad_disconnects: u64 = 0,
    pad_reconnections: u64 = 0,
    buffer_retention: u64 = 0,
    low_fps_catchup: u64 = 0,
    simulated_pause: u64 = 0,

    fn expect(self: *Validation, condition: bool) void {
        self.checks += 1;
        if (!condition) self.failures += 1;
    }
};

fn validateInputContracts() Validation {
    var result = Validation{};

    var edge = engine.Input{};
    edge.apply(.{ .key_down = .{ .scancode = .space, .repeat = false } });
    edge.apply(.{ .key_up = .{ .scancode = .space } });
    edge.latch();
    result.expect(edge.wasPressed(.space) and edge.wasReleased(.space));
    result.expect(!edge.held(.space));
    edge.latch();
    result.expect(!edge.wasPressed(.space) and !edge.wasReleased(.space));
    result.key_edges += 1;

    var mouse = engine.Input{};
    mouse.apply(.{ .mouse_button_down = .right });
    mouse.latch();
    result.expect(mouse.mouseDown(.right) and mouse.mousePressed(.right));
    mouse.apply(.{ .mouse_button_up = .right });
    mouse.latch();
    result.expect(!mouse.mouseDown(.right) and mouse.mouseReleased(.right));
    result.mouse_edges += 1;

    var map = ActionMap.fromDefaults(defaults);
    var remapped = engine.Input{};
    map.set(.confirm, &.{.{ .key = .enter }});
    remapped.apply(.{ .key_down = .{ .scancode = .enter, .repeat = false } });
    remapped.latch();
    result.expect(map.pressed(&remapped, .confirm));
    result.expect(!map.held(&remapped, .pause));
    result.action_remaps += 1;

    const pad_map = ActionMap.fromDefaults(defaults);
    const pad_a = engine.GamepadId{ .slot = 0, .generation = 1 };
    const pad_b = engine.GamepadId{ .slot = 0, .generation = 2 };
    var pad = engine.Input{};
    pad.apply(.{ .gamepad_added = pad_a });
    pad.apply(.{ .gamepad_button_down = .{ .id = pad_a, .button = .south } });
    pad.latch();
    result.expect(pad.primaryPad() != null and pad_map.held(&pad, .confirm));
    pad.apply(.{ .gamepad_removed = pad_a });
    pad.latch();
    result.expect(pad.primaryPad() == null);
    result.expect(pad.pads[0].released[@intFromEnum(engine.GamepadButton.south)]);
    result.pad_disconnects += 1;
    pad.apply(.{ .gamepad_added = pad_b });
    pad.apply(.{ .gamepad_button_down = .{ .id = pad_a, .button = .south } });
    pad.latch();
    result.expect(pad.primaryPad().?.id.?.generation == pad_b.generation);
    result.expect(!pad.primaryPad().?.pressed[@intFromEnum(engine.GamepadButton.south)]);
    pad.apply(.{ .gamepad_button_down = .{ .id = pad_b, .button = .south } });
    pad.latch();
    result.expect(pad.primaryPad().?.pressed[@intFromEnum(engine.GamepadButton.south)]);
    result.pad_reconnections += 1;

    var buffered = engine.Input{};
    var buffer_map = ActionMap.fromDefaults(defaults);
    var buffer = ActionBuffer{};
    buffer.setWindow(.confirm, 0.1);
    buffered.apply(.{ .key_down = .{ .scancode = .space, .repeat = false } });
    buffered.latch();
    buffer.begin(&buffer_map, &buffered, 1.0 / 60.0);
    result.expect(buffer.pending(.confirm));
    buffered.latch();
    buffer.begin(&buffer_map, &buffered, 1.0 / 60.0);
    result.expect(buffer.pending(.confirm));
    var tick: u8 = 0;
    while (tick < 5) : (tick += 1) {
        buffered.latch();
        buffer.begin(&buffer_map, &buffered, 1.0 / 60.0);
    }
    result.expect(!buffer.pending(.confirm));
    result.expect(!buffer.consume(.confirm));
    result.buffer_retention += 1;

    var catchup_input = engine.Input{};
    var catchup_map = ActionMap.fromDefaults(defaults);
    var catchup_buffer = ActionBuffer{};
    catchup_buffer.setWindow(.confirm, 0.05);
    catchup_input.apply(.{ .key_down = .{ .scancode = .space, .repeat = false } });
    catchup_input.latch();
    catchup_buffer.begin(&catchup_map, &catchup_input, 1.0 / 60.0);
    result.expect(catchup_buffer.pending(.confirm));
    for (0..3) |_| {
        catchup_input.latch();
        catchup_buffer.begin(&catchup_map, &catchup_input, 1.0 / 60.0);
    }
    result.expect(!catchup_buffer.pending(.confirm));
    result.low_fps_catchup += 1;

    var paused_input = engine.Input{};
    var pause_buffer = ActionBuffer{};
    pause_buffer.setWindow(.confirm, 0.1);
    paused_input.apply(.{ .key_down = .{ .scancode = .space, .repeat = false } });
    paused_input.latch();
    pause_buffer.begin(&buffer_map, &paused_input, 1.0 / 60.0);
    const remaining = pause_buffer.remaining[@intFromEnum(Action.confirm)];
    for (0..120) |_| {
        // A paused simulation does not call buffer.begin, so its fixed-update window does not age.
    }
    result.expect(pause_buffer.remaining[@intFromEnum(Action.confirm)] == remaining);
    paused_input.latch();
    pause_buffer.begin(&buffer_map, &paused_input, 1.0 / 60.0);
    result.expect(pause_buffer.pending(.confirm));
    result.simulated_pause += 1;

    return result;
}

const Tb16 = struct {
    font: engine.ui.FontHandle,
    canvas: engine.ui.Canvas,
    input: *engine.Input,
    action_map: ActionMap,
    action_buffer: ActionBuffer = .{},
    validation: Validation,
    page: u8 = 0,
    frames: u64 = 0,
    input_events: u64 = 0,
    key_events: u64 = 0,
    mouse_events: u64 = 0,
    pad_events: u64 = 0,
    remap_armed: bool = false,
    remap_failures: u64 = 0,
    remap_successes: u64 = 0,
    pause_buffer: bool = false,
    buffer_window: f32 = 0.1,
    action_pressed: u64 = 0,
    action_released: u64 = 0,
    held_key_peak: u32 = 0,
    primary_pad_seen: bool = false,
    primary_pad_id: ?engine.GamepadId = null,
    primary_pad_changes: u64 = 0,
    report_written: bool = false,

    pub fn init(ctx: *engine.Context) !Tb16 {
        const font = try ctx.loadFont("assets/ui_font_9px.bfnt", 9);
        errdefer ctx.unloadFont(font) catch |err| log.err("font cleanup failed during init: {s}", .{@errorName(err)});
        const canvas = engine.ui.Canvas.create(ctx.allocators.game, ctx.fonts, font);
        const validation = validateInputContracts();
        return .{
            .font = font,
            .canvas = canvas,
            .input = ctx.input,
            .action_map = engine.bindings.load(Action, defaults, ctx.settings_text),
            .validation = validation,
        };
    }

    pub fn update(self: *Tb16, ctx: *engine.Context, _: *engine.SceneNavigator) void {
        self.frames += 1;
        while (ctx.pollEvent()) |event| {
            self.input_events += 1;
            switch (event) {
                .key_down, .key_up => self.key_events += 1,
                .mouse_motion, .mouse_button_down, .mouse_button_up => self.mouse_events += 1,
                .gamepad_added, .gamepad_removed, .gamepad_button_down, .gamepad_button_up, .gamepad_axis => self.pad_events += 1,
                .quit, .text_input => {},
            }
        }

        if (ctx.input.wasPressed(.escape)) ctx.running = false;
        if (ctx.input.wasPressed(.tab)) self.page = (self.page + 1) % 4;
        if (ctx.input.wasPressed(.left)) self.page = (self.page + 3) % 4;
        if (ctx.input.wasPressed(.right)) self.page = (self.page + 1) % 4;
        if (ctx.input.wasPressed(.r)) self.pause_buffer = !self.pause_buffer;
        if (ctx.input.wasPressed(.f)) self.remap_armed = !self.remap_armed;
        if (ctx.input.wasPressed(.up)) self.buffer_window = @min(0.5, self.buffer_window + 0.025);
        if (ctx.input.wasPressed(.down)) self.buffer_window = @max(0, self.buffer_window - 0.025);

        if (self.remap_armed and !ctx.input.wasPressed(.f)) {
            const code = engine.bindings.pressedCode(ctx.input);
            if (code != 0) {
                if (engine.bindings.bindingOf(code)) |binding| {
                    self.action_map.set(.confirm, &.{binding});
                    self.remap_successes += 1;
                    ctx.saveBindings(Action, &self.action_map) catch |err| {
                        self.remap_failures += 1;
                        log.err("saving remapped input bindings failed: {s}", .{@errorName(err)});
                    };
                } else {
                    self.remap_failures += 1;
                }
                self.remap_armed = false;
            }
        }

        for (std.enums.values(Action)) |action| {
            if (self.action_map.pressed(ctx.input, action)) self.action_pressed += 1;
            if (self.action_map.released(ctx.input, action)) self.action_released += 1;
        }
        self.action_buffer.setWindow(.confirm, self.buffer_window);
        if (!self.pause_buffer) self.action_buffer.begin(&self.action_map, ctx.input, ctx.dt);
        self.held_key_peak = @max(self.held_key_peak, ctx.input.heldCount());
        const current_pad = if (ctx.input.primaryPad()) |pad| pad.id else null;
        if (!samePad(self.primary_pad_id, current_pad)) {
            self.primary_pad_id = current_pad;
            self.primary_pad_changes += 1;
        }
        if (current_pad != null) self.primary_pad_seen = true;

        if (self.frames >= options.frames) {
            if (!self.report_written) self.report(ctx);
            ctx.running = false;
        }
    }

    pub fn draw(self: *Tb16, dc: *const engine.DrawContext) void {
        self.canvas.clear();
        self.canvas.rect(4, 4, 312, 25, panel);
        self.canvas.text(9, 7, "TB-16  Input Laboratory", white);
        self.canvas.text(9, 18, "Tab / Left / Right pages   F rebind Confirm   R pause buffer   Esc exit", muted);
        switch (self.page) {
            0, 1 => self.drawKeys(self.page),
            2 => self.drawGamepad(),
            else => self.drawActions(),
        }
        self.canvas.rect(4, 157, 312, 20, panel);
        var footer: [128]u8 = undefined;
        const footer_text = std.fmt.bufPrint(&footer, "P{d}/4 keys {d}/{d} events {d} K/M/P {d}/{d}/{d} checks {d}/{d}", .{
            self.page + 1,
            self.input.heldCount(),
            std.enums.values(engine.Key).len,
            self.key_events,
            self.mouse_events,
            self.pad_events,
            self.input_events,
            self.validation.checks - self.validation.failures,
            self.validation.checks,
        }) catch "input metrics unavailable";
        self.canvas.text(9, 163, footer_text, white);
        self.canvas.queue(dc.batch, 1000);
    }

    fn drawKeys(self: *Tb16, page: u8) void {
        const keys = std.enums.values(engine.Key);
        const start = @as(usize, page) * keys_per_page;
        const end = @min(start + keys_per_page, keys.len);
        self.canvas.rect(6, 32, 308, 120, panel);
        self.canvas.text(12, 35, if (page == 0) "Keyboard controls 1/2 + mouse buttons" else "Keyboard controls 2/2", green);
        var row: usize = 0;
        for (keys[start..end], 0..) |key, index| {
            const column = index % 2;
            if (column == 0) row = index / 2;
            const x: f32 = if (column == 0) 12 else 165;
            const y = 48 + @as(f32, @floatFromInt(row)) * 10;
            const state = if (self.input.held(key)) "HELD" else if (self.input.wasPressed(key)) "DOWN" else if (self.input.wasReleased(key)) "UP" else "--";
            var line: [64]u8 = undefined;
            const text = std.fmt.bufPrint(&line, "{s: <12} {s}", .{ @tagName(key), state }) catch @tagName(key);
            self.canvas.text(x, y, text, if (self.input.held(key)) green else white);
        }
        if (page == 0) {
            var mouse_row: usize = 0;
            for (std.enums.values(engine.MouseButton)) |button| {
                const y = 118 + @as(f32, @floatFromInt(mouse_row)) * 9;
                const state = if (self.input.mouseDown(button)) "HELD" else if (self.input.mousePressed(button)) "DOWN" else if (self.input.mouseReleased(button)) "UP" else "--";
                var line: [64]u8 = undefined;
                const text = std.fmt.bufPrint(&line, "mouse_{s: <7} {s}", .{ @tagName(button), state }) catch @tagName(button);
                self.canvas.text(165, y, text, if (self.input.mouseDown(button)) green else muted);
                mouse_row += 1;
            }
            var position: [48]u8 = undefined;
            const position_text = std.fmt.bufPrint(&position, "pointer {d:.0}, {d:.0}", .{
                self.input.mouse_x,
                self.input.mouse_y,
            }) catch "pointer position unavailable";
            self.canvas.text(165, 146, position_text, muted);
        }
    }

    fn drawGamepad(self: *Tb16) void {
        self.canvas.rect(6, 32, 308, 120, panel);
        const pad = self.input.primaryPad();
        if (pad) |connected| {
            var info: [112]u8 = undefined;
            const text = std.fmt.bufPrint(&info, "Pad slot {d} gen {d} order {d}  devices {d}/{d} changes {d}", .{
                connected.id.?.slot,
                connected.id.?.generation,
                connected.order,
                connectedPadCount(self.input),
                self.input.pads.len,
                self.primary_pad_changes,
            }) catch "Gamepad connected";
            self.canvas.text(12, 35, text, green);
        } else {
            self.canvas.text(12, 35, "No gamepad connected (connect one to inspect controls)", amber);
        }
        var row: usize = 0;
        for (std.enums.values(engine.GamepadButton), 0..) |button, index| {
            const column = index % 2;
            if (column == 0) row = index / 2;
            const x: f32 = if (column == 0) 12 else 165;
            const y = 48 + @as(f32, @floatFromInt(row)) * 10;
            const state = if (pad) |connected|
                if (connected.held[index]) "HELD" else if (connected.pressed[index]) "DOWN" else if (connected.released[index]) "UP" else "--"
            else
                "--";
            var line: [64]u8 = undefined;
            const text = std.fmt.bufPrint(&line, "{s: <17} {s}", .{ @tagName(button), state }) catch @tagName(button);
            self.canvas.text(x, y, text, if (std.mem.eql(u8, state, "HELD")) green else white);
        }
        for (std.enums.values(engine.GamepadAxis), 0..) |axis, index| {
            const value = if (pad) |connected| connected.axes[index] else 0;
            const column = index % 2;
            const y = 128 + @as(f32, @floatFromInt(index / 2)) * 9;
            var line: [48]u8 = undefined;
            const text = std.fmt.bufPrint(&line, "{s} {d:.2}", .{ @tagName(axis), value }) catch @tagName(axis);
            self.canvas.text(if (column == 0) 12 else 165, y, text, muted);
        }
    }

    fn drawActions(self: *Tb16) void {
        self.canvas.rect(6, 32, 308, 120, panel);
        self.canvas.text(12, 35, "Semantic actions and fixed-tick press buffer", green);
        var row: usize = 0;
        for (std.enums.values(Action)) |action| {
            const y = 51 + @as(f32, @floatFromInt(row)) * 15;
            var bindings: [64]u8 = undefined;
            const binding_text = formatBindings(self.action_map.bindingsOf(action), &bindings);
            const held = self.action_map.held(self.input, action);
            var line: [96]u8 = undefined;
            const text = std.fmt.bufPrint(&line, "{s: <8} [{s}] {s}", .{
                @tagName(action),
                binding_text,
                if (held) "HELD" else "--",
            }) catch @tagName(action);
            self.canvas.text(12, y, text, if (held) green else white);
            row += 1;
        }
        const remap_text = if (self.remap_armed) "Press a control to bind Confirm..." else "Press F, then any non-left-mouse control to rebind Confirm";
        self.canvas.text(12, 102, remap_text, if (self.remap_armed) amber else muted);
        var buffer_line: [96]u8 = undefined;
        const pending = self.action_buffer.pending(.confirm);
        const buffered = std.fmt.bufPrint(&buffer_line, "Confirm buffer {d:.3}s  pending {s}  updates {d}", .{
            self.buffer_window,
            if (pending) "yes" else "no",
            self.action_buffer.remaining[@intFromEnum(Action.confirm)],
        }) catch "buffer metrics unavailable";
        self.canvas.text(12, 119, buffered, if (pending) amber else white);
        self.canvas.text(12, 136, if (self.pause_buffer) "Buffer aging paused (R resumes)" else "R pauses buffer aging; UP/DOWN changes its window", muted);
    }

    fn formatBindings(bindings: []const Binding, buffer: *[64]u8) []const u8 {
        var len: usize = 0;
        if (bindings.len == 0) return "none";
        for (bindings) |binding| {
            if (len > 0) appendBinding(buffer, &len, " | ");
            switch (binding) {
                .key => |key| appendBinding(buffer, &len, @tagName(key)),
                .mouse => |button| {
                    appendBinding(buffer, &len, "mouse_");
                    appendBinding(buffer, &len, @tagName(button));
                },
                .gamepad_button => |button| {
                    appendBinding(buffer, &len, "pad_");
                    appendBinding(buffer, &len, @tagName(button));
                },
                .gamepad_axis => |axis| {
                    appendBinding(buffer, &len, "pad_");
                    appendBinding(buffer, &len, @tagName(axis.axis));
                    appendBinding(buffer, &len, if (axis.direction == .positive) "+" else "-");
                },
            }
        }
        return buffer[0..len];
    }

    fn appendBinding(buffer: *[64]u8, len: *usize, text: []const u8) void {
        const available = buffer.len - len.*;
        const amount = @min(available, text.len);
        @memcpy(buffer[len.*..][0..amount], text[0..amount]);
        len.* += amount;
    }

    fn connectedPadCount(input: *const engine.Input) usize {
        var count: usize = 0;
        for (input.pads) |pad| {
            if (pad.id != null) count += 1;
        }
        return count;
    }

    fn report(self: *Tb16, ctx: *engine.Context) void {
        if (self.report_written) return;
        self.report_written = true;
        const passed = self.validation.failures == 0 and self.remap_failures == 0;
        const status: []const u8 = if (passed) "pass" else "fail";
        log.info("TB-16 {s}: checks {d}/{d}, key/mouse/pad-event samples {d}/{d}/{d}, remaps {d} failed {d}, action edges {d}/{d}", .{
            status,
            self.validation.checks - self.validation.failures,
            self.validation.checks,
            self.key_events,
            self.mouse_events,
            self.pad_events,
            self.remap_successes,
            self.remap_failures,
            self.action_pressed,
            self.action_released,
        });
        var output: [768]u8 = undefined;
        const json = std.fmt.bufPrint(
            &output,
            "{{\"testbed\":\"TB-16\",\"scenario\":\"input-laboratory\",\"result\":\"{s}\",\"frames\":{d},\"checks\":{d},\"failures\":{d},\"key_edge_checks\":{d},\"mouse_edge_checks\":{d},\"action_remap_checks\":{d},\"gamepad_disconnect_checks\":{d},\"gamepad_reconnect_checks\":{d},\"buffer_retention_checks\":{d},\"low_fps_catchup_checks\":{d},\"simulated_pause_checks\":{d},\"remap_successes\":{d},\"remap_failures\":{d},\"action_pressed_edges\":{d},\"action_released_edges\":{d},\"event_counts\":{{\"all\":{d},\"keys\":{d},\"mouse\":{d},\"gamepad\":{d}}},\"focus_loss\":\"unavailable_no_focus_event_in_public_input_api\",\"touch\":\"unsupported\"}}\n",
            .{
                status,
                self.frames,
                self.validation.checks,
                self.validation.failures + self.remap_failures,
                self.validation.key_edges,
                self.validation.mouse_edges,
                self.validation.action_remaps,
                self.validation.pad_disconnects,
                self.validation.pad_reconnections,
                self.validation.buffer_retention,
                self.validation.low_fps_catchup,
                self.validation.simulated_pause,
                self.remap_successes,
                self.remap_failures,
                self.action_pressed,
                self.action_released,
                self.input_events,
                self.key_events,
                self.mouse_events,
                self.pad_events,
            },
        ) catch |err| {
            log.err("TB-16 metrics formatting failed: {s}", .{@errorName(err)});
            return;
        };
        ctx.writeFile("TB-16-input-results.json", json) catch |err| {
            log.err("TB-16 metrics write failed: {s}", .{@errorName(err)});
        };
    }

    pub fn deinitWithContext(self: *Tb16, ctx: *engine.Context) void {
        self.canvas.deinit();
        ctx.unloadFont(self.font) catch |err| log.err("TB-16 font cleanup failed: {s}", .{@errorName(err)});
        self.report(ctx);
    }

    pub fn deinit(self: *Tb16) void {
        self.canvas.deinit();
    }
};

fn samePad(a: ?engine.GamepadId, b: ?engine.GamepadId) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.slot == b.?.slot and a.?.generation == b.?.generation;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--help")) {
            std.debug.print("TB-16 options: --frames 360. Tab/Left/Right pages; F arms Confirm remapping; R pauses input-buffer time; Up/Down changes the buffer; Escape exits. Focus loss has no public event representation.\n", .{});
            return;
        } else if (std.mem.eql(u8, args[index], "--frames") and index + 1 < args.len) {
            index += 1;
            options.frames = try std.fmt.parseUnsigned(u64, args[index], 10);
        } else {
            return error.InvalidArgument;
        }
    }
    if (options.frames == 0 or options.frames > 1_000_000) return error.InvalidArgument;
    try engine.run(engine.SceneHost(Tb16), config);
}
