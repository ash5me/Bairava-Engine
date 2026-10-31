//! Small, explicitly registered development commands. It owns bounded input/output buffers and
//! operates only on the published diagnostics snapshot and debug-geometry switches.

const std = @import("std");
const Phase = @import("frame_stats.zig").Phase;

pub const max_input = 128;
pub const max_output = 512;

const Command = enum { help, scene, entities, assets, performance, tile, diagnostics, collision, tiles, layer };

pub const CommandInfo = struct {
    name: []const u8,
    usage: []const u8,
    command: Command,
};

pub const registry = [_]CommandInfo{
    .{ .name = "help", .usage = "help", .command = .help },
    .{ .name = "scene", .usage = "scene", .command = .scene },
    .{ .name = "entities", .usage = "entities", .command = .entities },
    .{ .name = "assets", .usage = "assets", .command = .assets },
    .{ .name = "performance", .usage = "performance [frame|events|asset|update|audio|draw|present]", .command = .performance },
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
                    const scene = collector.snapshot.scene;
                    if (scene.pending) |pending| {
                        self.setOutput("{s} -> {s} (transition pending)", .{ scene.name, pending });
                    } else {
                        self.setOutput("{s} (no transition pending)", .{scene.name});
                    }
                },
                .entities => {
                    if (count != 1) return self.usage(entry);
                    self.setOutput("entities: {d}", .{collector.snapshot.world.entities});
                },
                .assets => {
                    if (count != 1) return self.usage(entry);
                    const assets = collector.snapshot.assets;
                    self.setOutput("loaded {d}, {d} bytes; hits {d}, misses {d}, failed {d}", .{
                        assets.loaded, assets.bytes, assets.hits, assets.misses, assets.failed,
                    });
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
        self.setOutput("commands: help scene entities assets performance tile\ncontrols: diagnostics on|off|toggle; collision on|off|toggle; tiles on|off|toggle; layer NAME on|off|toggle", .{});
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
            scene: struct { name: []const u8 = "test", pending: ?[]const u8 = null } = .{},
            assets: struct { loaded: usize = 2, bytes: usize = 1024, hits: u64 = 3, misses: u64 = 1, failed: u64 = 0 } = .{},
            world: struct {
                entities: u32 = 4,
                map_cols: u32 = 1,
                map_rows: u32 = 1,
                selected_col: i32 = 0,
                selected_row: i32 = 0,
                selected_tile: ?u8 = 0,
                selected_solid: bool = true,
            } = .{},
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
    try std.testing.expectEqualStrings("entities: 4", console.outputText());
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
