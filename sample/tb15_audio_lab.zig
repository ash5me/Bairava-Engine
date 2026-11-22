//! TB-15 exercises loaded effects, streamed playback, buses, positional emitters, and voice cleanup.

const std = @import("std");
const engine = @import("bairava");

const log = engine.log.scoped("tb15");
const white = engine.ui.Color{ .r = 0.94, .g = 0.96, .b = 1, .a = 1 };
const muted = engine.ui.Color{ .r = 0.66, .g = 0.75, .b = 0.84, .a = 1 };
const panel = engine.ui.Color{ .r = 0.025, .g = 0.04, .b = 0.07, .a = 0.93 };

const config = engine.Config{
    .title = "Bairava TB-15 Audio Laboratory",
    .window_w = 960,
    .window_h = 540,
    .native_w = 320,
    .native_h = 180,
    .clear_rgb = .{ 0.012, 0.018, 0.03 },
    .settings_file = "tb15_settings.txt",
};

const Options = struct {
    frames: u64 = 360,
};

var options = Options{};

const Tb15 = struct {
    sound: ?engine.audio.Sound = null,
    stream: ?engine.audio.StreamedSound = null,
    font: ?engine.ui.FontHandle = null,
    canvas: ?engine.ui.Canvas = null,
    audio_state: engine.diagnostics.AudioState = .{},
    music_voice: ?engine.audio.Handle = null,
    emitter_voice: ?engine.audio.Handle = null,
    effects: [8]?engine.audio.Handle = [_]?engine.audio.Handle{null} ** 8,
    tick: u64 = 0,
    phase: f32 = 0,
    frames: u64 = 0,
    voice_capacity_checks: u64 = 0,
    voice_capacity_failures: u64 = 0,
    cleanup_checks: u64 = 0,
    cleanup_failures: u64 = 0,
    bus_checks: u64 = 0,
    bus_failures: u64 = 0,
    positional_checks: u64 = 0,
    positional_failures: u64 = 0,
    wav_decode_checks: u64 = 0,
    wav_decode_failures: u64 = 0,
    wav_stream_frames: u64 = 0,
    missing_file_checks: u64 = 0,
    invalid_file_checks: u64 = 0,
    play_attempts: u64 = 0,
    play_failures: u64 = 0,
    effect_bursts: u64 = 0,
    report_written: bool = false,
    audio_available: bool = false,
    experience_started: bool = false,
    ima_sidecar_available: bool = false,
    capacity_validated: bool = false,
    sound_bytes: usize = 0,
    stream_frames: u64 = 0,
    stream_path_is_ima: bool = false,
    listener: engine.audio.spatial.Point = .{ .x = 160, .y = 92 },
    emitter: engine.audio.spatial.Point = .{ .x = 245, .y = 92 },
    sfx_gain: f32 = 0.8,
    music_gain: f32 = 0.55,
    emitter_range: f32 = 180,
    emitter_active: bool = true,

    pub fn init(ctx: *engine.Context) !Tb15 {
        var self = Tb15{};
        const font = try ctx.loadFont("assets/ui_font_9px.bfnt", 9);
        errdefer ctx.unloadFont(font) catch |err| log.err("font cleanup failed during init: {s}", .{@errorName(err)});
        self.font = font;
        self.canvas = engine.ui.Canvas.create(ctx.allocators.game, ctx.fonts, font);
        errdefer if (self.canvas) |*canvas| canvas.deinit();
        self.audio_available = ctx.audio.device != null;
        if (!self.audio_available) {
            log.warn("no playback device; audio playback checks will be reported unavailable", .{});
        } else {
            self.sound = try ctx.loadSound("assets/wind1.wav");
            errdefer if (self.sound) |*sound| sound.deinit();
            self.sound_bytes = self.sound.?.samples.len;
            self.stream = try ctx.openStreamed("assets/wind1.wav");
            self.stream_frames = self.stream.?.frames;
            self.stream_path_is_ima = std.mem.endsWith(u8, self.stream.?.path(), ".ima");
            self.ima_sidecar_available = ctx.fileExistsBeside("assets/wind1.wav.ima");
            var wav_fallback = try ctx.loadSound("assets/testbeds/tb15/wind1_wav_only.wav");
            defer wav_fallback.deinit();
            self.wav_decode_checks += 1;
            if (wav_fallback.samples.len == 0) self.wav_decode_failures += 1;
            const wav_stream = try ctx.openStreamed("assets/testbeds/tb15/wind1_wav_only.wav");
            self.wav_stream_frames = wav_stream.frames;
            if (self.wav_decode_failures == 0 and self.wav_stream_frames > 0) {
                self.wav_decode_checks += 1;
            } else {
                self.wav_decode_failures += 1;
            }
            self.validateFileFailures(ctx);
            self.validateBusGains(ctx);
            self.validateVoiceCapacity(ctx);
            ctx.audio.setListener(self.listener);
            self.validatePositionalMath();
        }
        return self;
    }

    fn validatePositionalMath(self: *Tb15) void {
        const near = engine.audio.spatial.mix(self.listener, self.listener, self.emitter_range);
        const far = engine.audio.spatial.mix(self.listener, .{
            .x = self.listener.x + self.emitter_range * 2,
            .y = self.listener.y,
        }, self.emitter_range);
        self.positional_checks += 2;
        if (near.attenuation != 1 or near.pan != 0) self.positional_failures += 1;
        if (far.attenuation != 0 or far.pan != 1) self.positional_failures += 1;
    }

    fn validateFileFailures(self: *Tb15, ctx: *engine.Context) void {
        if (ctx.loadSound("assets/testbeds/tb15/does_not_exist.wav")) |sound_value| {
            var sound = sound_value;
            sound.deinit();
            self.play_failures += 1;
            log.err("audio loader unexpectedly accepted a missing file", .{});
        } else |err| {
            if (err == error.LoadFailed) {
                self.missing_file_checks += 1;
            } else {
                self.play_failures += 1;
                log.err("missing-file check returned {s}, expected LoadFailed", .{@errorName(err)});
            }
        }

        if (ctx.loadSound("assets/font.ttf")) |sound_value| {
            var sound = sound_value;
            sound.deinit();
            self.play_failures += 1;
            log.err("audio loader unexpectedly accepted a font as audio", .{});
        } else |err| {
            if (err == error.LoadFailed) {
                self.invalid_file_checks += 1;
            } else {
                self.play_failures += 1;
                log.err("invalid-file check returned {s}, expected LoadFailed", .{@errorName(err)});
            }
        }
    }

    fn validateBusGains(self: *Tb15, ctx: *engine.Context) void {
        const audio = ctx.audio;
        audio.setBusGain(.sfx, 0.37);
        self.bus_checks += 1;
        if (audio.busGain(.sfx) != 0.37) self.bus_failures += 1;
        audio.setBusGain(.music, 0.62);
        self.bus_checks += 1;
        if (audio.busGain(.music) != 0.62) self.bus_failures += 1;
        audio.setBusGain(.ambience, 0.8);
        audio.setBusGain(.ui, 1);
        audio.setBusGain(.sfx, self.sfx_gain);
        audio.setBusGain(.music, self.music_gain);
    }

    fn validateVoiceCapacity(self: *Tb15, ctx: *engine.Context) void {
        const sound = if (self.sound) |*value| value else return;
        var handles: [engine.audio.max_voices]?engine.audio.Handle = [_]?engine.audio.Handle{null} ** engine.audio.max_voices;
        var started: usize = 0;
        while (started < handles.len) : (started += 1) {
            handles[started] = ctx.audio.play(sound, .{ .gain = 0.25, .loop = true, .bus = .sfx }) catch |err| {
                self.voice_capacity_failures += 1;
                log.err("voice capacity filled early at {d}/{d}: {s}", .{ started, handles.len, @errorName(err) });
                break;
            };
        }
        var state = engine.diagnostics.AudioState{};
        ctx.audio.describe(&state);
        self.voice_capacity_checks += 1;
        if (started != handles.len or state.voices_busy != engine.audio.max_voices) self.voice_capacity_failures += 1;

        self.play_attempts += 1;
        if (ctx.audio.play(sound, .{ .gain = 0.1, .loop = true })) |extra| {
            ctx.audio.stop(extra);
            self.voice_capacity_failures += 1;
            log.err("audio accepted a voice beyond max_voices", .{});
        } else |err| {
            self.voice_capacity_checks += 1;
            if (err != error.NoFreeVoice) {
                self.voice_capacity_failures += 1;
                log.err("voice overflow returned {s}, expected NoFreeVoice", .{@errorName(err)});
            }
        }

        for (&handles) |*handle| {
            if (handle.*) |voice| {
                ctx.audio.stop(voice);
                handle.* = null;
            }
        }
        ctx.audio.describe(&state);
        self.cleanup_checks += 1;
        if (state.voices_busy != 0) self.cleanup_failures += 1;
        self.capacity_validated = true;
    }

    fn startExperience(self: *Tb15, ctx: *engine.Context) void {
        if (self.stream) |*stream| {
            self.play_attempts += 1;
            self.music_voice = ctx.audio.playStreamed(stream, .{
                .gain = self.music_gain,
                .bus = .music,
                .loop = true,
            }) catch |err| blk: {
                self.play_failures += 1;
                log.err("streamed music start failed: {s}", .{@errorName(err)});
                break :blk null;
            };
        }

        if (self.emitter_active) self.startEmitter(ctx);
        self.playBurst(ctx);
    }

    fn startEmitter(self: *Tb15, ctx: *engine.Context) void {
        const sound = if (self.sound) |*value| value else return;
        if (self.emitter_voice) |voice| ctx.audio.stop(voice);
        self.play_attempts += 1;
        self.emitter_voice = ctx.audio.play(sound, .{
            .gain = 0.7,
            .bus = .ambience,
            .loop = true,
            .position = self.emitter,
            .range = self.emitter_range,
        }) catch |err| blk: {
            self.play_failures += 1;
            log.err("positional emitter start failed: {s}", .{@errorName(err)});
            break :blk null;
        };
        self.positional_checks += 1;
    }

    fn playBurst(self: *Tb15, ctx: *engine.Context) void {
        const sound = if (self.sound) |*value| value else return;
        const positions = [_]engine.audio.spatial.Point{
            .{ .x = self.listener.x - 24, .y = self.listener.y },
            .{ .x = self.listener.x + 24, .y = self.listener.y },
            .{ .x = self.listener.x, .y = self.listener.y - 20 },
            .{ .x = self.listener.x, .y = self.listener.y + 20 },
        };
        const count = @min(self.effects.len, positions.len);
        for (0..count) |index| {
            if (self.effects[index]) |voice| {
                if (ctx.audio.isPlaying(voice)) ctx.audio.stop(voice);
            }
            self.play_attempts += 1;
            self.effects[index] = ctx.audio.play(sound, .{
                .gain = self.sfx_gain,
                .bus = .sfx,
                .position = positions[index],
                .range = 112,
                .pan = if (index % 2 == 0) -0.15 else 0.15,
            }) catch |err| blk: {
                self.play_failures += 1;
                log.warn("effect burst voice {d} failed: {s}", .{ index, @errorName(err) });
                break :blk null;
            };
        }
        self.effect_bursts += 1;
    }

    pub fn update(self: *Tb15, ctx: *engine.Context, _: *engine.SceneNavigator) void {
        if (self.audio_available and !self.experience_started) {
            ctx.audio.setListener(self.listener);
            self.startExperience(ctx);
            self.experience_started = true;
        }
        if (ctx.input.wasPressed(.escape)) ctx.running = false;
        if (ctx.input.wasPressed(.space)) self.playBurst(ctx);
        if (ctx.input.wasPressed(.left)) self.emitter.x = @max(12, self.emitter.x - 16);
        if (ctx.input.wasPressed(.right)) self.emitter.x = @min(308, self.emitter.x + 16);
        if (ctx.input.wasPressed(.up)) {
            self.sfx_gain = @min(1, self.sfx_gain + 0.05);
            ctx.audio.setBusGain(.sfx, self.sfx_gain);
        }
        if (ctx.input.wasPressed(.down)) {
            self.sfx_gain = @max(0, self.sfx_gain - 0.05);
            ctx.audio.setBusGain(.sfx, self.sfx_gain);
        }
        if (ctx.input.wasPressed(.q)) {
            self.music_gain = if (self.music_gain > 0) 0 else 0.55;
            ctx.audio.setBusGain(.music, self.music_gain);
        }
        if (ctx.input.wasPressed(.e)) {
            self.emitter_active = !self.emitter_active;
            if (self.emitter_active) {
                self.startEmitter(ctx);
            } else if (self.emitter_voice) |voice| {
                ctx.audio.stop(voice);
                self.emitter_voice = null;
            }
        }

        self.tick += 1;
        self.frames = ctx.diagnostics.snapshot.frames;
        self.phase += ctx.dt;
        self.listener.x = 160 + @sin(self.phase * 0.4) * 18;
        ctx.audio.setListener(self.listener);
        if (self.emitter_voice) |voice| {
            const placed = engine.audio.spatial.mix(self.listener, self.emitter, self.emitter_range);
            if (!std.math.isFinite(placed.attenuation) or placed.attenuation < 0 or placed.attenuation > 1)
                self.positional_failures += 1;
            ctx.audio.setPosition(voice, self.emitter);
            self.positional_checks += 1;
            if (!ctx.audio.isPlaying(voice)) {
                self.positional_failures += 1;
                if (self.positional_failures == 1) {
                    log.err("positional voice stopped unexpectedly: attenuation {d}, range {d}, busy voices {d}", .{
                        placed.attenuation,
                        self.emitter_range,
                        self.audio_state.voices_busy,
                    });
                }
            }
        }
        ctx.audio.describe(&self.audio_state);
        if (self.tick % 120 == 0) self.playBurst(ctx);
        if (self.frames >= options.frames) ctx.running = false;
    }

    pub fn draw(self: *Tb15, dc: *const engine.DrawContext) void {
        const canvas = if (self.canvas) |*value| value else return;
        const state = self.audio_state;
        canvas.clear();
        canvas.rect(8, 8, 304, 48, panel);
        canvas.text(14, 12, "TB-15  Audio Laboratory", white);
        canvas.text(14, 26, "SPACE burst  arrows emitter/SFX gain  Q music  E emitter  ESC exit", muted);

        const emitter_x = self.emitter.x;
        canvas.rect(26, 88, 268, 2, muted);
        canvas.rect(self.listener.x - 3, 82, 6, 14, white);
        canvas.rect(emitter_x - 4, 78, 8, 22, .{ .r = 1, .g = 0.48, .b = 0.2, .a = 1 });
        canvas.text(23, 104, "LISTENER", muted);
        canvas.text(@max(4, emitter_x - 20), 104, "EMITTER", white);

        canvas.rect(8, 145, 304, 31, panel);
        var metrics: [192]u8 = undefined;
        const text = std.fmt.bufPrint(&metrics, "voices {d}/{d} music {d:.2} sfx {d:.2} bursts {d}", .{
            state.voices_busy,
            state.voices_max,
            state.bus_gain[0],
            state.bus_gain[1],
            self.effect_bursts,
        }) catch "audio metrics unavailable";
        canvas.text(14, 150, text, white);
        const device_text = if (state.device_open) "playback device open" else "no playback device";
        canvas.text(14, 164, device_text, muted);
        canvas.queue(dc.batch, 1000);
    }

    fn report(self: *Tb15, ctx: *engine.Context) void {
        self.report_written = true;
        var state = engine.diagnostics.AudioState{};
        ctx.audio.describe(&state);
        const passed = self.frames >= options.frames and self.audio_available and self.sound_bytes > 0 and self.stream_frames > 0 and
            self.capacity_validated and self.voice_capacity_checks == 2 and self.voice_capacity_failures == 0 and
            self.cleanup_checks > 0 and self.cleanup_failures == 0 and self.bus_checks == 2 and
            self.bus_failures == 0 and self.missing_file_checks == 1 and self.invalid_file_checks == 1 and
            self.positional_checks > 0 and self.positional_failures == 0 and
            self.wav_decode_checks == 2 and self.wav_decode_failures == 0 and self.wav_stream_frames > 0 and
            self.play_failures == 0;
        const status: []const u8 = if (!self.audio_available) "unavailable" else if (passed) "pass" else "incomplete";
        log.info("TB-15 {s}: device {any} ({d} Hz, {d} ch), voices {d}/{d}, capacity failures {d}, bus failures {d}, load failures checked {d}/{d}", .{
            status,
            state.device_open,
            state.sample_rate,
            state.channels,
            state.voices_busy,
            state.voices_max,
            self.voice_capacity_failures,
            self.bus_failures,
            self.missing_file_checks,
            self.invalid_file_checks,
        });

        var json: [1024]u8 = undefined;
        const output = std.fmt.bufPrint(
            &json,
            "{{\"testbed\":\"TB-15\",\"scenario\":\"audio-laboratory\",\"result\":\"{s}\",\"frames\":{d},\"device_open\":{d},\"sample_rate\":{d},\"channels\":{d},\"voices_busy_at_report\":{d},\"voices_max\":{d},\"sound_bytes\":{d},\"ima_stream_frames\":{d},\"ima_stream_selected\":{d},\"ima_sidecar_available\":{d},\"wav_decode_checks\":{d},\"wav_decode_failures\":{d},\"wav_stream_frames\":{d},\"play_attempts\":{d},\"play_failures\":{d},\"effect_bursts\":{d},\"voice_capacity_checks\":{d},\"voice_capacity_failures\":{d},\"cleanup_checks\":{d},\"cleanup_failures\":{d},\"bus_checks\":{d},\"bus_failures\":{d},\"positional_checks\":{d},\"positional_failures\":{d},\"missing_file_checks_passed\":{d},\"invalid_file_checks_passed\":{d},\"device_loss_recovery\":\"not_tested_no_public_device_injection\",\"underrun_metrics\":\"not_exposed\"}}\n",
            .{
                status,
                self.frames,
                @intFromBool(state.device_open),
                state.sample_rate,
                state.channels,
                state.voices_busy,
                state.voices_max,
                self.sound_bytes,
                self.stream_frames,
                @intFromBool(self.stream_path_is_ima),
                @intFromBool(self.ima_sidecar_available),
                self.wav_decode_checks,
                self.wav_decode_failures,
                self.wav_stream_frames,
                self.play_attempts,
                self.play_failures,
                self.effect_bursts,
                self.voice_capacity_checks,
                self.voice_capacity_failures,
                self.cleanup_checks,
                self.cleanup_failures,
                self.bus_checks,
                self.bus_failures,
                self.positional_checks,
                self.positional_failures,
                self.missing_file_checks,
                self.invalid_file_checks,
            },
        ) catch |err| {
            log.err("TB-15 metrics formatting failed: {s}", .{@errorName(err)});
            return;
        };
        ctx.writeFile("TB-15-audio-results.json", output) catch |err| {
            log.err("TB-15 metrics write failed: {s}", .{@errorName(err)});
        };
    }

    fn stopVoice(ctx: *engine.Context, handle: *?engine.audio.Handle) void {
        if (handle.*) |voice| {
            ctx.audio.stop(voice);
            handle.* = null;
        }
    }

    pub fn deinitWithContext(self: *Tb15, ctx: *engine.Context) void {
        stopVoice(ctx, &self.music_voice);
        stopVoice(ctx, &self.emitter_voice);
        for (&self.effects) |*effect| stopVoice(ctx, effect);
        var state = engine.diagnostics.AudioState{};
        ctx.audio.describe(&state);
        self.cleanup_checks += 1;
        if (state.voices_busy != 0) self.cleanup_failures += 1;
        self.report(ctx);
        if (self.sound) |*sound| {
            sound.deinit();
            self.sound = null;
        }
        if (self.canvas) |*canvas| {
            canvas.deinit();
            self.canvas = null;
        }
        if (self.font) |font| {
            ctx.unloadFont(font) catch |err| log.err("TB-15 font cleanup failed: {s}", .{@errorName(err)});
            self.font = null;
        }
    }

    pub fn deinit(self: *Tb15) void {
        if (self.sound) |*sound| sound.deinit();
        if (self.canvas) |*canvas| canvas.deinit();
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--help")) {
            std.debug.print("TB-15 options: --frames 360. SPACE triggers a positional SFX burst; arrows move the emitter/change SFX bus gain; Q toggles music bus; E toggles emitter; Escape exits.\n", .{});
            return;
        } else if (std.mem.eql(u8, args[index], "--frames") and index + 1 < args.len) {
            index += 1;
            options.frames = try std.fmt.parseUnsigned(u64, args[index], 10);
        } else {
            return error.InvalidArgument;
        }
    }
    if (options.frames == 0 or options.frames > 1_000_000) return error.InvalidArgument;
    try engine.run(engine.SceneHost(Tb15), config);
}
