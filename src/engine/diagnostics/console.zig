//! Small, explicitly registered development commands. It owns bounded input/output buffers and
//! operates only on the published diagnostics snapshot and debug-geometry switches.

const std = @import("std");
const Phase = @import("frame_stats.zig").Phase;
const collector_mod = @import("collector.zig");

pub const max_input = 128;
pub const max_output = 512;

const Command = enum { help, scene, entities, assets, memory, performance, audio, tile, diagnostics, collision, tiles, layer };

pub const CommandInfo = struct {
    name: []const u8,
    usage: []const u8,
    command: Command,
};

pub const registry = [_]CommandInfo{
    .{ .name = "help", .usage = "help", .command = .help },
    .{ .name = "scene", .usage = "scene", .command = .scene },
    .{ .name = "entities", .usage = "entities [id]", .command = .entities },
    .{ .name = "assets", .usage = "assets", .command = .assets },
    .{ .name = "memory", .usage = "memory", .command = .memory },
    .{ .name = "performance", .usage = "performance [frame|events|asset|update|audio|draw|present|gpu]", .command = .performance },
    .{ .name = "audio", .usage = "audio", .command = .audio },
    .{ .name = "tile", .usage = "tile", .command = .tile },
    .{ .name = "diagnostics", .usage = "diagnostics on|off|toggle", .command = .diagnostics },
    .{ .name = "collision", .usage = "collision on|off|toggle", .command = .collision },
    .{ .name = "tiles", .usage = "tiles on|off|toggle", .command = .tiles },
    .{ .name = "layer", .usage = "layer ground|decoration|foreground on|off|toggle", .command = .layer },
};

pub const Console = struct {
    visible: bool = false,
    input: [max_input]u8 = undefined,
    input_len: usize = 0,
    output: [max_output]u8 = undefined,
    output_len: usize = 0,
    output_is_error: bool = false,

    pub fn open(self: *Console) void {
        self.visible = true;
        self.input_len = 0;
        self.setOutput("Type help for commands.", .{});
    }

    pub fn close(self: *Console) void {
        self.visible = false;
        self.input_len = 0;
    }

    pub fn inputText(self: *const Console) []const u8 {
        return self.input[0..self.input_len];
    }

    pub fn outputText(self: *const Console) []const u8 {
        return self.output[0..self.output_len];
    }

    pub fn append(self: *Console, text: []const u8) void {
        if (!self.visible) return;
        for (text) |byte| {
            if (byte < 0x20 or byte >= 0x7f) continue;
            if (self.input_len == self.input.len) {
                self.setOutput("Input limit is {d} ASCII characters.", .{max_input});
                self.output_is_error = true;
                return;
            }
            self.input[self.input_len] = byte;
            self.input_len += 1;
        }
    }

    pub fn backspace(self: *Console) void {
        if (self.visible and self.input_len > 0) self.input_len -= 1;
    }

    pub fn submit(self: *Console, collector: anytype, diagnostics_visible: *bool) void {
        if (!self.visible) return;
        const command_text = std.mem.trim(u8, self.inputText(), " \t");
        self.input_len = 0;
        if (command_text.len == 0) {
            self.setOutput("Enter a command, or use help.", .{});
            return;
        }
        self.execute(command_text, collector, diagnostics_visible);
    }

    pub fn execute(self: *Console, text: []const u8, collector: anytype, diagnostics_visible: *bool) void {
        var tokens: [3][]const u8 = undefined;
        var count: usize = 0;
        var words = std.mem.tokenizeAny(u8, text, " \t");
        while (words.next()) |word| {
            if (count == tokens.len) {
                self.setError("too many arguments (try help)");
                return;
            }
            tokens[count] = word;
            count += 1;
        }
        if (count == 0) {
            self.setOutput("Enter a command, or use help.", .{});
            return;
        }

        for (registry) |entry| {
            if (!std.mem.eql(u8, entry.name, tokens[0])) continue;
            switch (entry.command) {
                .help => {
                    if (count != 1) return self.usage(entry);
                    self.writeHelp();
                },
                .scene => {
                    if (count != 1) return self.usage(entry);
                    self.writeScene(collector.snapshot.scene);
                },
                .entities => {
                    if (count > 2) return self.usage(entry);
                    if (count == 2) {
                        const id = std.fmt.parseInt(u32, tokens[1], 10) catch {
                            self.setError("entity id must be an unsigned integer");
                            return;
                        };
                        self.writeEntity(collector.snapshot.inspection, id);
                    } else {
                        self.writeEntities(collector.snapshot.world.entities, collector.snapshot.inspection);
                    }
                },
                .assets => {
                    if (count != 1) return self.usage(entry);
                    const assets = collector.snapshot.assets;
                    self.setOutput("loaded {d}, {d} bytes; hits {d}, misses {d}, failed {d}", .{
                        assets.loaded, assets.bytes, assets.hits, assets.misses, assets.failed,
                    });
                },
                .memory => {
                    if (count != 1) return self.usage(entry);
                    const memory = collector.snapshot.memory;
                    self.setOutput(
                        "engine: {d} alloc/{d} free/{d} fail, live {d} B, peak {d} B, arena {d} B\n" ++
                            "game: {d} alloc/{d} free/{d} fail, live {d} B, peak {d} B, arena {d} B\n" ++
                            "asset: {d} alloc/{d} free/{d} fail, live {d} B, peak {d} B, arena {d} B\n" ++
                            "frame: {d} alloc/{d} free/{d} fail, live {d} B, peak {d} B, arena {d} B",
                        .{
                            memory.engine.allocation_count, memory.engine.free_count, memory.engine.failed_allocations, memory.engine.live_bytes, memory.engine.high_water_bytes, memory.engine.arena_capacity_bytes,
                            memory.game.allocation_count,   memory.game.free_count,   memory.game.failed_allocations,   memory.game.live_bytes,   memory.game.high_water_bytes,   memory.game.arena_capacity_bytes,
                            memory.asset.allocation_count,  memory.asset.free_count,  memory.asset.failed_allocations,  memory.asset.live_bytes,  memory.asset.high_water_bytes,  memory.asset.arena_capacity_bytes,
                            memory.frame.allocation_count,  memory.frame.free_count,  memory.frame.failed_allocations,  memory.frame.live_bytes,  memory.frame.high_water_bytes,  memory.frame.arena_capacity_bytes,
                        },
                    );
                },
                .performance => {
                    if (count > 2) return self.usage(entry);
                    if (count == 2) {
                        const phase = std.meta.stringToEnum(Phase, tokens[1]) orelse {
                            self.setError("unknown phase (try help)");
                            return;
                        };
                        self.writePhase(phase, collector.stats.of(phase));
                    } else {
                        const frame = collector.stats.of(.frame);
                        self.setOutput("frame avg {d:.2} p95 {d:.2} max {d:.2} ms\nevents {d:.2} asset {d:.2} update {d:.2}\naudio {d:.2} draw {d:.2} present {d:.2} ms", .{
                            frame.average() * 1000,
                            frame.percentile(0.95) * 1000,
                            frame.max() * 1000,
                            collector.stats.of(.events).average() * 1000,
                            collector.stats.of(.asset).average() * 1000,
                            collector.stats.of(.update).average() * 1000,
                            collector.stats.of(.audio).average() * 1000,
                            collector.stats.of(.draw).average() * 1000,
                            collector.stats.of(.present).average() * 1000,
                        });
                    }
                },
                .audio => {
                    if (count != 1) return self.usage(entry);
                    self.writeAudio(collector.snapshot.audio);
                },
                .tile => {
                    if (count != 1) return self.usage(entry);
                    const world = collector.snapshot.world;
                    if (world.selected_col < 0 or world.selected_row < 0 or
                        @as(u32, @intCast(world.selected_col)) >= world.map_cols or
                        @as(u32, @intCast(world.selected_row)) >= world.map_rows)
                    {
                        self.setOutput("map {d}x{d}; cursor outside bounds", .{ world.map_cols, world.map_rows });
                    } else if (world.selected_tile) |id| {
                        self.setOutput("cell {d},{d}: tile {d}, solid {s}", .{
                            world.selected_col, world.selected_row, id, if (world.selected_solid) "yes" else "no",
                        });
                    } else {
                        self.setOutput("cell {d},{d}: empty, solid {s}", .{
                            world.selected_col, world.selected_row, if (world.selected_solid) "yes" else "no",
                        });
                    }
                },
                .diagnostics => {
                    if (count != 2) return self.usage(entry);
                    diagnostics_visible.* = trySwitch(tokens[1], diagnostics_visible.*) catch {
                        self.setError("expected on, off, or toggle");
                        return;
                    };
                    self.setOutput("diagnostics {s}", .{if (diagnostics_visible.*) "on" else "off"});
                },
                .collision, .tiles => {
                    if (count != 2) return self.usage(entry);
                    const enabled = switchMode(tokens[1], if (entry.command == .collision)
                        collector.geometry.collision
                    else
                        collector.geometry.tiles) catch {
                        self.setError("expected on, off, or toggle");
                        return;
                    };
                    if (entry.command == .collision) {
                        collector.geometry.collision = enabled;
                    } else {
                        collector.geometry.tiles = enabled;
                    }
                    self.setOutput("{s} geometry {s}", .{ entry.name, if (enabled) "on" else "off" });
                },
                .layer => {
                    if (count != 3) return self.usage(entry);
                    const layer = tokens[1];
                    const current = if (std.mem.eql(u8, layer, "ground"))
                        collector.layers.ground
                    else if (std.mem.eql(u8, layer, "decoration"))
                        collector.layers.decoration
                    else if (std.mem.eql(u8, layer, "foreground"))
                        collector.layers.foreground
                    else {
                        self.setError("unknown layer (ground, decoration, foreground)");
                        return;
                    };
                    const enabled = switchMode(tokens[2], current) catch {
                        self.setError("expected on, off, or toggle");
                        return;
                    };
                    if (std.mem.eql(u8, layer, "ground")) {
                        collector.layers.ground = enabled;
                    } else if (std.mem.eql(u8, layer, "decoration")) {
                        collector.layers.decoration = enabled;
                    } else {
                        collector.layers.foreground = enabled;
                    }
                    self.setOutput("layer {s} {s}", .{ layer, if (enabled) "on" else "off" });
                },
            }
            return;
        }
        self.setOutput("unknown command '{s}' (try help)", .{tokens[0]});
        self.output_is_error = true;
    }

    fn writeHelp(self: *Console) void {
        self.setOutput("commands: help scene entities [id] assets audio performance tile\ncontrols: diagnostics on|off|toggle; collision on|off|toggle; tiles on|off|toggle; layer NAME on|off|toggle", .{});
    }

    /// Two lines: the open scenes as a path from the root to the active scene, then the count of open scenes, the
    /// switch count, and the change waiting for the next safe point.
    fn writeScene(self: *Console, scene: collector_mod.Scene) void {
        const path = scene.openNames();
        if (path.len == 0) {
            self.setOutput("scene hierarchy: none open", .{});
        } else {
            self.setOutput("scene hierarchy: {s}", .{path[0]});
            for (path[1..]) |name| self.appendOutput(" > {s}", .{name});
            self.appendOutput(" (active)", .{});
        }
        self.appendOutput("\n{d} open, {d} switches, ", .{ path.len, scene.switches });
        if (scene.pending) |pending| {
            self.appendOutput("transition pending: {s}", .{pending});
        } else {
            self.appendOutput("no transition pending", .{});
        }
    }

    fn writeEntities(self: *Console, total: u32, inspection: collector_mod.Inspection) void {
        self.setOutput("entities: {d}", .{total});
        const shown = @min(inspection.entitySlice().len, 4);
        for (inspection.entitySlice()[0..shown]) |entity| {
            self.appendOutput("\n{d}: {s}", .{ entity.id, entity.nameText() });
        }
        const omitted = inspection.omitted + @as(u32, @intCast(inspection.entitySlice().len - shown));
        if (omitted > 0) self.appendOutput("\n{d} more; query entities ID", .{omitted});
        if (inspection.entitySlice().len == 0 and total > 0) {
            self.appendOutput("\nno entity snapshots published", .{});
        }
    }

    fn writeEntity(self: *Console, inspection: collector_mod.Inspection, id: u32) void {
        for (inspection.entitySlice()) |entity| {
            if (entity.id != id) continue;
            self.setOutput("entity {d}: {s}", .{ id, entity.nameText() });
            for (entity.componentSlice()) |component| {
                self.appendOutput("\n{s}: {s}", .{ component.nameText(), component.valueText() });
            }
            return;
        }
        self.setErrorFmt("entity {d} has no published snapshot", .{id});
    }

    fn writeAudio(self: *Console, audio: collector_mod.AudioState) void {
        if (audio.device_open) {
            self.setOutput("device open: {d} Hz, {d} channels", .{ audio.sample_rate, audio.channels });
        } else {
            self.setOutput("device closed: nothing plays", .{});
        }
        self.appendOutput("\nvoices {d}/{d} busy, master gain {d:.2}", .{ audio.voices_busy, audio.voices_max, audio.master_gain });
        for (audio.listed[0..audio.listed_count], 0..) |voice, index| {
            self.appendOutput("\n{d}: {s}, gain {d:.2}, {d} bytes", .{
                index + 1,
                if (voice.looping) "loop" else "once",
                voice.gain,
                voice.sound_bytes,
            });
        }
        const hidden = audio.voices_busy -| @as(u32, audio.listed_count);
        if (hidden > 0) self.appendOutput("\n{d} more busy", .{hidden});
    }

    fn writePhase(self: *Console, phase: Phase, history: anytype) void {
        self.setOutput("{s} ms: avg {d:.2}, p95 {d:.2}, max {d:.2}", .{
            @tagName(phase),
            history.average() * 1000,
            history.percentile(0.95) * 1000,
            history.max() * 1000,
        });
    }

    fn usage(self: *Console, command: CommandInfo) void {
        self.setErrorFmt("usage: {s}", .{command.usage});
    }

    fn setError(self: *Console, message: []const u8) void {
        self.setOutput("{s}", .{message});
        self.output_is_error = true;
    }

    fn setErrorFmt(self: *Console, comptime format: []const u8, args: anytype) void {
        self.setOutput(format, args);
        self.output_is_error = true;
    }

    fn setOutput(self: *Console, comptime format: []const u8, args: anytype) void {
        self.output_len = 0;
        self.output_is_error = false;
        self.appendOutput(format, args);
    }

    fn appendOutput(self: *Console, comptime format: []const u8, args: anytype) void {
        const remaining = self.output[self.output_len..];
        const line = std.fmt.bufPrint(remaining, format, args) catch {
            self.output_len = 0;
            const fallback = "console output exceeds its fixed buffer";
            @memcpy(self.output[0..fallback.len], fallback);
            self.output_len = fallback.len;
            self.output_is_error = true;
            return;
        };
        self.output_len += line.len;
    }
};

fn trySwitch(mode: []const u8, current: bool) error{InvalidMode}!bool {
    if (std.mem.eql(u8, mode, "on")) return true;
    if (std.mem.eql(u8, mode, "off")) return false;
    if (std.mem.eql(u8, mode, "toggle")) return !current;
    return error.InvalidMode;
}

fn switchMode(mode: []const u8, current: bool) error{InvalidMode}!bool {
    return trySwitch(mode, current);
}

test "registry commands inspect published state and reject invalid arguments" {
    const Diagnostics = struct {
        snapshot: struct {
            scene: collector_mod.Scene = .{ .name = "test" },
            assets: struct { loaded: usize = 2, bytes: usize = 1024, hits: u64 = 3, misses: u64 = 1, failed: u64 = 0 } = .{},
            memory: struct {
                engine: struct { allocation_count: u64 = 2, free_count: u64 = 1, failed_allocations: u64 = 0, live_bytes: usize = 64, high_water_bytes: usize = 96, arena_capacity_bytes: usize = 128 } = .{},
                game: struct { allocation_count: u64 = 3, free_count: u64 = 1, failed_allocations: u64 = 0, live_bytes: usize = 128, high_water_bytes: usize = 256, arena_capacity_bytes: usize = 256 } = .{},
                asset: struct { allocation_count: u64 = 4, free_count: u64 = 0, failed_allocations: u64 = 1, live_bytes: usize = 512, high_water_bytes: usize = 512, arena_capacity_bytes: usize = 512 } = .{},
                frame: struct { allocation_count: u64 = 5, free_count: u64 = 3, failed_allocations: u64 = 0, live_bytes: usize = 32, high_water_bytes: usize = 80, arena_capacity_bytes: usize = 128 } = .{},
            } = .{},
            world: struct {
                entities: u32 = 4,
                map_cols: u32 = 1,
                map_rows: u32 = 1,
                selected_col: i32 = 0,
                selected_row: i32 = 0,
                selected_tile: ?u8 = 0,
                selected_solid: bool = true,
            } = .{},
            inspection: collector_mod.Inspection = .{},
            audio: collector_mod.AudioState = .{},
        } = .{},
        stats: struct {
            pub fn of(_: *@This(), _: Phase) *const History {
                return &history;
            }
            const History = struct {
                pub fn average(_: *const @This()) f32 {
                    return 0.01;
                }
                pub fn percentile(_: *const @This(), _: f32) f32 {
                    return 0.02;
                }
                pub fn max(_: *const @This()) f32 {
                    return 0.03;
                }
            };
            const history = History{};
        } = .{},
        geometry: struct { collision: bool = false, tiles: bool = false } = .{},
        layers: struct { ground: bool = true, decoration: bool = true, foreground: bool = true } = .{},
    };

    var console = Console{};
    var collector = Diagnostics{};
    var overlay = true;
    console.execute("entities", &collector, &overlay);
    try std.testing.expectEqualStrings("entities: 4\nno entity snapshots published", console.outputText());
    console.execute("memory", &collector, &overlay);
    try std.testing.expect(std.mem.indexOf(u8, console.outputText(), "asset: 4 alloc/0 free/1 fail, live 512 B, peak 512 B, arena 512 B") != null);
    console.execute("collision toggle", &collector, &overlay);
    try std.testing.expect(collector.geometry.collision);
    console.execute("layer ground off", &collector, &overlay);
    try std.testing.expect(!collector.layers.ground);
    console.execute("tile", &collector, &overlay);
    try std.testing.expectEqualStrings("cell 0,0: tile 0, solid yes", console.outputText());
    console.execute("diagnostics off", &collector, &overlay);
    try std.testing.expect(!overlay);
    console.execute("scene invalid", &collector, &overlay);
    try std.testing.expect(console.output_is_error);
    try std.testing.expect(std.mem.startsWith(u8, console.outputText(), "usage:"));
    console.execute("unknown", &collector, &overlay);
    try std.testing.expect(console.output_is_error);
}

test "entities console lists and safely inspects copied component snapshots" {
    var console = Console{};
    var collector = collector_mod.Collector{};
    var overlay = true;
    const components = [_]collector_mod.ComponentInput{
        .{ .name = "transform", .value = "x=12 y=24" },
        .{ .name = "facing", .value = "left" },
    };
    const entities = [_]collector_mod.EntityInput{.{
        .id = 7,
        .name = "player",
        .components = &components,
    }};
    try collector.publishEntities(1, &entities);

    console.execute("entities", &collector, &overlay);
    try std.testing.expectEqualStrings("entities: 1\n7: player", console.outputText());
    console.execute("entities 7", &collector, &overlay);
    try std.testing.expectEqualStrings("entity 7: player\ntransform: x=12 y=24\nfacing: left", console.outputText());
    console.execute("entities 8", &collector, &overlay);
    try std.testing.expect(console.output_is_error);
    try std.testing.expectEqualStrings("entity 8 has no published snapshot", console.outputText());
}

test "console input is bounded, ignores control characters, and supports backspace" {
    var console = Console{};
    console.open();
    console.append("foo\nbar");
    try std.testing.expectEqualStrings("foobar", console.inputText());
    console.backspace();
    try std.testing.expectEqualStrings("fooba", console.inputText());
    console.close();
    console.append("ignored");
    try std.testing.expectEqual(@as(usize, 0), console.input_len);
}

test "the scene command shows the open scenes root first, the active one, the switch count, and any pending change" {
    var console = Console{};
    var collector = collector_mod.Collector{};
    var overlay = true;

    console.execute("scene", &collector, &overlay);
    try std.testing.expectEqualStrings(
        "scene hierarchy: none open\n0 open, 0 switches, no transition pending",
        console.outputText(),
    );

    var stack = [_][]const u8{""} ** collector_mod.max_scene_depth;
    stack[0] = "main.Red";
    stack[1] = "main.Blue";
    stack[2] = "main.Swarm";
    collector.snapshot.scene = .{ .name = "main.Swarm", .pending = "pop", .switches = 5, .depth = 3, .stack = stack };
    console.execute("scene", &collector, &overlay);
    try std.testing.expect(!console.output_is_error);
    try std.testing.expectEqualStrings(
        "scene hierarchy: main.Red > main.Blue > main.Swarm (active)\n3 open, 5 switches, transition pending: pop",
        console.outputText(),
    );

    collector.snapshot.scene.pending = null;
    console.execute("scene", &collector, &overlay);
    try std.testing.expectEqualStrings(
        "scene hierarchy: main.Red > main.Blue > main.Swarm (active)\n3 open, 5 switches, no transition pending",
        console.outputText(),
    );

    collector.snapshot.scene.depth = 1;
    collector.snapshot.scene.name = "main.Red";
    collector.snapshot.scene.switches = 1;
    console.execute("scene", &collector, &overlay);
    try std.testing.expectEqualStrings(
        "scene hierarchy: main.Red (active)\n1 open, 1 switches, no transition pending",
        console.outputText(),
    );
}

test "the audio command reports the device, the busy voices, and the first few by slot" {
    var console = Console{};
    var collector = collector_mod.Collector{};
    var overlay = true;
    collector.snapshot.audio = .{
        .device_open = true,
        .sample_rate = 48000,
        .channels = 2,
        .voices_busy = 4,
        .voices_max = 32,
        .master_gain = 0.5,
        .listed_count = 1,
    };
    collector.snapshot.audio.listed[0] = .{ .looping = true, .gain = 0.25, .sound_bytes = 1024 };

    console.execute("audio", &collector, &overlay);
    try std.testing.expectEqualStrings(
        "device open: 48000 Hz, 2 channels\nvoices 4/32 busy, master gain 0.50\n1: loop, gain 0.25, 1024 bytes\n3 more busy",
        console.outputText(),
    );
    console.execute("audio extra", &collector, &overlay);
    try std.testing.expect(console.output_is_error);
}
