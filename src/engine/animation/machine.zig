//! The animation machine chooses which clip an entity plays. Game code sets integer parameters, such as `moving`
//! and `facing`, and the machine works out the clip from its states and transitions. A state plays one of several
//! clip variants, the first whose condition holds. A transition moves to another state when its condition holds,
//! and it can crossfade the clips over a blend time and emit an event. A state can also emit events when playback
//! reaches a frame. The machine is defined by text (`machine 1`, see docs/animation.md) and checked against the
//! clips of an animation library. It draws nothing: `pose` says which frames to draw and how to mix them.
//! Pure code with no SDL, so `zig build test` covers it.

const std = @import("std");
const animation = @import("animation.zig");
const data = @import("data.zig");

/// Most parameters a machine declares.
pub const max_params = 8;
/// Most states a machine declares.
pub const max_states = 16;
/// Most transitions a machine declares.
pub const max_transitions = 32;
/// Most clip variants one state can choose between.
pub const max_variants = 4;
/// Most conditions one clause, such as a variant's or a transition's, can hold.
pub const max_conditions = 4;
/// Most frame events one state can declare.
pub const max_frame_events = 8;
/// Events waiting to be polled. Past this, the newest events are dropped and counted.
pub const event_queue_len = 16;
/// Most words on one line of machine text.
const max_tokens = 24;

/// Index of a parameter, from `Definition.findParam` or `Machine.paramId`.
pub const ParamId = u8;

pub const ParseError = std.mem.Allocator.Error || error{
    BadHeader,
    UnsupportedVersion,
    UnknownLine,
    BadParam,
    DuplicateParam,
    BadState,
    DuplicateState,
    UnknownState,
    BadClip,
    UnknownClip,
    BadCondition,
    UnknownParam,
    BadTransition,
    BadEvent,
    TooMany,
    Empty,
};

/// How a condition compares a parameter with its value.
pub const Op = enum { eq, ne, lt, le, gt, ge };

/// One comparison, `param op value`. A bare parameter name in the text means `param != 0`.
pub const Condition = struct {
    param: ParamId,
    op: Op,
    value: i32,

    fn holds(self: Condition, current: i32) bool {
        return switch (self.op) {
            .eq => current == self.value,
            .ne => current != self.value,
            .lt => current < self.value,
            .le => current <= self.value,
            .gt => current > self.value,
            .ge => current >= self.value,
        };
    }
};

/// Conditions that must all hold. An empty clause always holds.
pub const Clause = struct {
    items: [max_conditions]Condition = undefined,
    count: u8 = 0,

    pub fn slice(self: *const Clause) []const Condition {
        return self.items[0..self.count];
    }
};

pub const Param = struct {
    name: []const u8,
    /// A trigger is cleared when a transition that tests it fires, so it acts once.
    trigger: bool = false,
};

/// One clip a state can play, and the conditions under which it is chosen.
pub const Variant = struct {
    /// Index into the library's clips.
    clip: u32,
    when: Clause = .{},
};

pub const FrameEvent = struct {
    frame: u32,
    name: []const u8,
    id: ?u32 = null,
};

pub const State = struct {
    name: []const u8,
    variants: [max_variants]Variant = undefined,
    variant_count: u8 = 0,
    events: [max_frame_events]FrameEvent = undefined,
    event_count: u8 = 0,
};

pub const Transition = struct {
    /// Null matches any state.
    from: ?u8,
    to: u8,
    when: Clause = .{},
    /// Seconds the old clip is crossfaded out over. Zero switches at once.
    blend: f32 = 0,
    event: ?[]const u8 = null,
    event_id: ?u32 = null,
};

/// An event the machine emitted, read with `Machine.pollEvent`.
pub const Event = struct {
    name: []const u8,
    id: ?u32 = null,
};

/// The frames to draw this frame. While a blend runs, `previous` is drawn fully and then `frame` at `weight`.
pub const Pose = struct {
    frame: *const data.Frame,
    previous: ?*const data.Frame = null,
    /// How much `frame` shows. 1 when nothing is blending.
    weight: f32 = 1,
};

/// A parsed machine. It copies the text and owns it, and its names point into that copy, so it lives until `deinit`.
pub const Definition = struct {
    allocator: std.mem.Allocator,
    source: []u8,
    params: [max_params]Param = undefined,
    param_count: u8 = 0,
    states: [max_states]State = undefined,
    state_count: u8 = 0,
    transitions: [max_transitions]Transition = undefined,
    transition_count: u8 = 0,
    /// The state a machine starts in: the first state, unless the text says `start`.
    start: u8 = 0,

    /// Parses machine text against the clips of `library`. Clip names are resolved to their indices, so the same
    /// library must be used to run the machine.
    pub fn parse(allocator: std.mem.Allocator, source: []const u8, library: *const data.Library) ParseError!Definition {
        const owned = try allocator.dupe(u8, source);
        errdefer allocator.free(owned);

        var def = Definition{ .allocator = allocator, .source = owned };
        var words_buf: [max_tokens][]const u8 = undefined;
        var have_header = false;
        var lines = std.mem.splitScalar(u8, owned, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const words = try tokenize(line, &words_buf);
            if (!have_header) {
                if (words.len != 2 or !std.mem.eql(u8, words[0], "machine")) return error.BadHeader;
                const version = std.fmt.parseInt(u32, words[1], 10) catch return error.BadHeader;
                if (version != 1) return error.UnsupportedVersion;
                have_header = true;
                continue;
            }
            const keyword = words[0];
            if (std.mem.eql(u8, keyword, "param")) {
                try def.addParam(words);
            } else if (std.mem.eql(u8, keyword, "state")) {
                try def.addState(words);
            } else if (std.mem.eql(u8, keyword, "clip")) {
                try def.addVariant(words, library);
            } else if (std.mem.eql(u8, keyword, "event")) {
                try def.addEvent(words);
            } else if (std.mem.eql(u8, keyword, "start")) {
                if (words.len != 2) return error.BadState;
                def.start = def.findState(words[1]) orelse return error.UnknownState;
            } else if (std.mem.eql(u8, keyword, "transition")) {
                try def.addTransition(words);
            } else {
                return error.UnknownLine;
            }
        }
        if (!have_header) return error.BadHeader;
        if (def.state_count == 0) return error.Empty;
        for (def.states[0..def.state_count]) |state| {
            if (state.variant_count == 0) return error.BadState;
        }
        return def;
    }

    pub fn deinit(self: *Definition) void {
        self.allocator.free(self.source);
        self.* = undefined;
    }

    pub fn findParam(self: *const Definition, name: []const u8) ?ParamId {
        for (self.params[0..self.param_count], 0..) |param, index| {
            if (std.mem.eql(u8, param.name, name)) return @intCast(index);
        }
        return null;
    }

    pub fn findState(self: *const Definition, name: []const u8) ?u8 {
        for (self.states[0..self.state_count], 0..) |state, index| {
            if (std.mem.eql(u8, state.name, name)) return @intCast(index);
        }
        return null;
    }

    fn addParam(self: *Definition, words: []const []const u8) ParseError!void {
        if (words.len < 2 or words.len > 3) return error.BadParam;
        const trigger = words.len == 3;
        if (trigger and !std.mem.eql(u8, words[2], "trigger")) return error.BadParam;
        if (self.findParam(words[1]) != null) return error.DuplicateParam;
        if (self.param_count == max_params) return error.TooMany;
        self.params[self.param_count] = .{ .name = words[1], .trigger = trigger };
        self.param_count += 1;
    }

    fn addState(self: *Definition, words: []const []const u8) ParseError!void {
        if (words.len != 2) return error.BadState;
        if (self.findState(words[1]) != null) return error.DuplicateState;
        if (self.state_count == max_states) return error.TooMany;
        self.states[self.state_count] = .{ .name = words[1] };
        self.state_count += 1;
    }

    /// `clip NAME [when CONDITIONS]`, which adds a variant to the most recent state.
    fn addVariant(self: *Definition, words: []const []const u8, library: *const data.Library) ParseError!void {
        if (self.state_count == 0) return error.BadClip;
        if (words.len < 2) return error.BadClip;
        const clip = library.indexOf(words[1]) orelse return error.UnknownClip;
        const state = &self.states[self.state_count - 1];
        if (state.variant_count == max_variants) return error.TooMany;
        var variant = Variant{ .clip = clip };
        var i: usize = 2;
        if (i < words.len) {
            if (!std.mem.eql(u8, words[i], "when")) return error.BadClip;
            const parsed = try self.parseClause(words, i + 1);
            variant.when = parsed.clause;
            i = parsed.next;
        }
        if (i != words.len) return error.BadClip;
        state.variants[state.variant_count] = variant;
        state.variant_count += 1;
    }

    /// `event STATE FRAME NAME`: an event the state emits when playback reaches FRAME.
    fn addEvent(self: *Definition, words: []const []const u8) ParseError!void {
        if (words.len != 4) return error.BadEvent;
        const index = self.findState(words[1]) orelse return error.UnknownState;
        const frame = std.fmt.parseInt(u32, words[2], 10) catch return error.BadEvent;
        const state = &self.states[index];
        if (state.event_count == max_frame_events) return error.TooMany;
        const id = std.fmt.parseInt(u32, words[3], 10) catch null;
        state.events[state.event_count] = .{
            .frame = frame,
            .name = if (id == null) words[3] else "",
            .id = id,
        };
        state.event_count += 1;
    }

    /// `transition FROM -> TO [when CONDITIONS] [blend SECONDS] [event NAME]`. FROM may be `*`.
    fn addTransition(self: *Definition, words: []const []const u8) ParseError!void {
        if (words.len < 4 or !std.mem.eql(u8, words[2], "->")) return error.BadTransition;
        const from: ?u8 = if (std.mem.eql(u8, words[1], "*")) null else (self.findState(words[1]) orelse return error.UnknownState);
        const to = self.findState(words[3]) orelse return error.UnknownState;
        if (self.transition_count == max_transitions) return error.TooMany;
        var transition = Transition{ .from = from, .to = to };
        var i: usize = 4;
        while (i < words.len) {
            if (std.mem.eql(u8, words[i], "when")) {
                if (transition.when.count != 0) return error.BadTransition;
                const parsed = try self.parseClause(words, i + 1);
                transition.when = parsed.clause;
                i = parsed.next;
            } else if (std.mem.eql(u8, words[i], "blend")) {
                if (i + 1 >= words.len) return error.BadTransition;
                const seconds = std.fmt.parseFloat(f32, words[i + 1]) catch return error.BadTransition;
                if (!std.math.isFinite(seconds) or seconds < 0) return error.BadTransition;
                transition.blend = seconds;
                i += 2;
            } else if (std.mem.eql(u8, words[i], "event")) {
                if (i + 1 >= words.len or transition.event != null or transition.event_id != null) return error.BadTransition;
                const id = std.fmt.parseInt(u32, words[i + 1], 10) catch null;
                if (id) |value| {
                    transition.event_id = value;
                } else {
                    transition.event = words[i + 1];
                }
                i += 2;
            } else {
                return error.BadTransition;
            }
        }
        self.transitions[self.transition_count] = transition;
        self.transition_count += 1;
    }

    const Parsed = struct {
        clause: Clause,
        next: usize,
    };

    /// Reads conditions from `words`, starting at `start`, up to a keyword or the end of the line.
    fn parseClause(self: *const Definition, words: []const []const u8, start: usize) ParseError!Parsed {
        var clause = Clause{};
        var i = start;
        while (i < words.len and !isKeyword(words[i])) {
            if (clause.count == max_conditions) return error.BadCondition;
            const param = self.findParam(words[i]) orelse return error.UnknownParam;
            i += 1;
            var condition = Condition{ .param = param, .op = .ne, .value = 0 };
            const op: ?Op = if (i < words.len) parseOp(words[i]) else null;
            if (op) |found| {
                if (i + 1 >= words.len) return error.BadCondition;
                condition.op = found;
                condition.value = std.fmt.parseInt(i32, words[i + 1], 10) catch return error.BadCondition;
                i += 2;
            }
            clause.items[clause.count] = condition;
            clause.count += 1;
            if (i < words.len and std.mem.eql(u8, words[i], "and")) {
                i += 1;
            } else {
                break;
            }
        }
        if (clause.count == 0) return error.BadCondition;
        return .{ .clause = clause, .next = i };
    }
};

fn tokenize(line: []const u8, out: *[max_tokens][]const u8) ParseError![]const []const u8 {
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, line, " \t");
    while (it.next()) |word| {
        if (count == max_tokens) return error.TooMany;
        out[count] = word;
        count += 1;
    }
    return out[0..count];
}

fn isKeyword(word: []const u8) bool {
    return std.mem.eql(u8, word, "blend") or std.mem.eql(u8, word, "event");
}

fn parseOp(word: []const u8) ?Op {
    if (std.mem.eql(u8, word, "==")) return .eq;
    if (std.mem.eql(u8, word, "!=")) return .ne;
    if (std.mem.eql(u8, word, "<")) return .lt;
    if (std.mem.eql(u8, word, "<=")) return .le;
    if (std.mem.eql(u8, word, ">")) return .gt;
    if (std.mem.eql(u8, word, ">=")) return .ge;
    return null;
}

/// A running machine. It owns its definition, and it needs the clip library only when it is called, so the library
/// can stay where the game keeps it.
pub const Machine = struct {
    def: Definition,
    values: [max_params]i32 = [_]i32{0} ** max_params,
    state: u8,
    /// Index of the clip the current state plays.
    clip: u32,
    play: animation.Timeline,
    /// The clip being crossfaded away from, while a blend runs.
    previous: ?animation.Timeline = null,
    blend_len: f32 = 0,
    blend_time: f32 = 0,
    queue: [event_queue_len]Event = undefined,
    queued: usize = 0,
    /// Events dropped because the queue was full.
    dropped: u32 = 0,

    /// Starts the machine in its start state, with every parameter at 0, and takes any transition the starting
    /// parameters allow. The machine takes ownership of `definition`; free it with `deinit`.
    pub fn init(definition: Definition, library: *const data.Library) Machine {
        var machine = Machine{
            .def = definition,
            .state = definition.start,
            .clip = 0,
            .play = undefined,
        };
        machine.clip = machine.chosenClip();
        machine.play = animation.Timeline.init(&library.clips[machine.clip]);
        machine.settle(library);
        return machine;
    }

    pub fn deinit(self: *Machine) void {
        self.def.deinit();
        self.* = undefined;
    }

    /// The index of a parameter, for `set` and `get`, or null when the definition has no such parameter.
    pub fn paramId(self: *const Machine, name: []const u8) ?ParamId {
        return self.def.findParam(name);
    }

    /// Sets a parameter. Transitions and clip choices see the new value from the next update.
    pub fn set(self: *Machine, id: ParamId, value: i32) void {
        self.values[id] = value;
    }

    pub fn get(self: *const Machine, id: ParamId) i32 {
        return self.values[id];
    }

    /// Name of the current state.
    pub fn stateName(self: *const Machine) []const u8 {
        return self.def.states[self.state].name;
    }

    /// Name of the clip playing now.
    pub fn clipName(self: *const Machine) []const u8 {
        return self.play.clip.name;
    }

    /// Seconds into the current clip.
    pub fn clipTime(self: *const Machine) f32 {
        return self.play.time;
    }

    /// The frame of the current clip to show.
    pub fn frameIndex(self: *const Machine) usize {
        return self.play.frameIndex();
    }

    /// Advances the machine by `dt` seconds. At most one transition fires, the clip is chosen, the clips and any
    /// blend advance, and the frame events the playback passed are queued.
    pub fn update(self: *Machine, dt: f32, library: *const data.Library) void {
        _ = self.takeTransition(library, false);
        self.refreshClip(library);
        const before = self.play.frameIndex();
        const looping = self.play.clip.looping;
        self.play.update(dt);
        const after = self.play.frameIndex();
        if (self.previous) |*old| old.update(dt);
        if (self.previous != null) {
            self.blend_time += dt;
            if (self.blend_time >= self.blend_len) self.previous = null;
        }
        self.collectFrameEvents(before, after, looping and after < before);
    }

    /// The next queued event, oldest first, or null when none is waiting.
    pub fn pollEvent(self: *Machine) ?Event {
        if (self.queued == 0) return null;
        const event = self.queue[0];
        var i: usize = 1;
        while (i < self.queued) : (i += 1) self.queue[i - 1] = self.queue[i];
        self.queued -= 1;
        return event;
    }

    /// The frames to draw now. While a blend runs, `previous` is drawn fully and `frame` at `weight`.
    pub fn pose(self: *const Machine) Pose {
        const current = self.play.frame();
        if (self.previous) |*old| {
            const weight: f32 = if (self.blend_len > 0) std.math.clamp(self.blend_time / self.blend_len, 0, 1) else 1;
            return .{ .frame = current, .previous = old.frame(), .weight = weight };
        }
        return .{ .frame = current };
    }

    /// Puts the machine back where a save left it. The parameters are already set, so this settles the state from
    /// them and seeks the clip to `elapsed` seconds. It blends nothing and queues no events.
    pub fn restore(self: *Machine, library: *const data.Library, elapsed: f32) void {
        self.settle(library);
        self.previous = null;
        self.blend_len = 0;
        self.blend_time = 0;
        const length = self.play.clip.duration();
        self.play.time = if (length > 0 and std.math.isFinite(elapsed)) @mod(@max(elapsed, 0), length) else 0;
    }

    /// Fires the transitions the current parameters allow, with no blend and no events, then chooses the clip.
    /// It stops after as many steps as there are states, so a cycle of transitions cannot loop forever.
    fn settle(self: *Machine, library: *const data.Library) void {
        var steps: usize = 0;
        while (steps < max_states and self.takeTransition(library, true)) : (steps += 1) {}
        self.refreshClip(library);
    }

    /// Fires the first transition from the current state whose conditions hold. Returns whether one fired.
    fn takeTransition(self: *Machine, library: *const data.Library, instant: bool) bool {
        for (self.def.transitions[0..self.def.transition_count]) |transition| {
            if (transition.to == self.state) continue;
            if (transition.from) |from| {
                if (from != self.state) continue;
            }
            if (!self.conditionsHold(transition.when.slice())) continue;
            self.enter(transition, library, instant);
            return true;
        }
        return false;
    }

    fn enter(self: *Machine, transition: Transition, library: *const data.Library, instant: bool) void {
        for (transition.when.slice()) |condition| {
            if (self.def.params[condition.param].trigger) self.values[condition.param] = 0;
        }
        const leaving = self.play;
        self.state = transition.to;
        self.clip = self.chosenClip();
        self.play = animation.Timeline.init(&library.clips[self.clip]);
        self.previous = null;
        self.blend_len = 0;
        self.blend_time = 0;
        if (!instant) {
            if (transition.blend > 0) {
                self.previous = leaving;
                self.blend_len = transition.blend;
            }
            if (transition.event) |name| self.push(name);
            if (transition.event_id) |id| self.pushId(id);
        }
    }

    /// Switches to the variant the current parameters choose. A switch restarts the clip, with no blend.
    fn refreshClip(self: *Machine, library: *const data.Library) void {
        const clip = self.chosenClip();
        if (clip == self.clip) return;
        self.clip = clip;
        self.play = animation.Timeline.init(&library.clips[clip]);
    }

    /// The clip the current state plays now: its first variant whose conditions hold, or its first variant if none do.
    fn chosenClip(self: *const Machine) u32 {
        const state = &self.def.states[self.state];
        for (state.variants[0..state.variant_count]) |variant| {
            if (self.conditionsHold(variant.when.slice())) return variant.clip;
        }
        return state.variants[0].clip;
    }

    fn conditionsHold(self: *const Machine, conditions: []const Condition) bool {
        for (conditions) |condition| {
            if (!condition.holds(self.values[condition.param])) return false;
        }
        return true;
    }

    /// Queues the current state's frame events that playback passed. A looping clip that wrapped passed the frames
    /// after `before` and up to `after`.
    fn collectFrameEvents(self: *Machine, before: usize, after: usize, wrapped: bool) void {
        const state = &self.def.states[self.state];
        for (state.events[0..state.event_count]) |event| {
            const frame: usize = event.frame;
            const passed = if (wrapped) (frame > before or frame <= after) else (frame > before and frame <= after);
            if (passed) {
                if (event.id) |id| self.pushId(id) else self.push(event.name);
            }
        }
    }

    fn push(self: *Machine, name: []const u8) void {
        if (self.queued == event_queue_len) {
            self.dropped += 1;
            return;
        }
        self.queue[self.queued] = .{ .name = name };
        self.queued += 1;
    }

    fn pushId(self: *Machine, id: u32) void {
        if (self.queued == event_queue_len) {
            self.dropped += 1;
            return;
        }
        self.queue[self.queued] = .{ .name = "", .id = id };
        self.queued += 1;
    }
};

const test_clips =
    \\animation 1
    \\clip idle loop
    \\frame 0 0 1 1 0.1
    \\frame 1 0 1 1 0.1
    \\clip walk loop
    \\frame 0 1 1 1 0.1
    \\frame 1 1 1 1 0.1
    \\clip walk_up loop
    \\frame 0 3 1 1 0.1
    \\clip hit once
    \\frame 0 2 1 1 0.2
;

const test_machine =
    \\machine 1
    \\param moving
    \\param facing
    \\param hurt trigger
    \\state idle
    \\clip idle
    \\state walk
    \\clip walk when facing == 0
    \\clip walk_up when facing == 2
    \\event walk 1 step
    \\state hit
    \\clip hit
    \\start idle
    \\transition idle -> walk when moving == 1 blend 0.2 event started
    \\transition walk -> idle when moving == 0 blend 0.2
    \\transition * -> hit when hurt
;

test "a transition fires when its condition holds, and blends out of the clip it leaves" {
    var library = try data.Library.parse(std.testing.allocator, test_clips, 4, 4);
    defer library.deinit();
    var machine = Machine.init(try Definition.parse(std.testing.allocator, test_machine, &library), &library);
    defer machine.deinit();
    try std.testing.expectEqualStrings("idle", machine.stateName());

    machine.set(machine.paramId("moving").?, 1);
    machine.update(0.05, &library);
    try std.testing.expectEqualStrings("walk", machine.stateName());
    try std.testing.expectEqualStrings("walk", machine.clipName());
    const pose = machine.pose();
    try std.testing.expect(pose.previous != null);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), pose.weight, 1e-5);

    // The blend lasts 0.2 seconds, so a further 0.2 seconds finishes it.
    machine.update(0.2, &library);
    try std.testing.expect(machine.pose().previous == null);
}

test "machine frame and transition events accept integer IDs" {
    var library = try data.Library.parse(std.testing.allocator, test_clips, 4, 4);
    defer library.deinit();
    const definition =
        \\machine 1
        \\param moving
        \\state idle
        \\clip idle
        \\event idle 1 101
        \\state walk
        \\clip walk
        \\start idle
        \\transition idle -> walk when moving == 1 event 202
    ;
    var machine = Machine.init(try Definition.parse(std.testing.allocator, definition, &library), &library);
    defer machine.deinit();

    machine.update(0.1, &library);
    const frame_event = machine.pollEvent() orelse return error.TestExpectedEvent;
    try std.testing.expectEqual(@as(?u32, 101), frame_event.id);

    machine.set(machine.paramId("moving").?, 1);
    machine.update(0, &library);
    const transition_event = machine.pollEvent() orelse return error.TestExpectedEvent;
    try std.testing.expectEqual(@as(?u32, 202), transition_event.id);
}

test "a state picks its clip variant from the parameters, and a switch restarts the clip" {
    var library = try data.Library.parse(std.testing.allocator, test_clips, 4, 4);
    defer library.deinit();
    var machine = Machine.init(try Definition.parse(std.testing.allocator, test_machine, &library), &library);
    defer machine.deinit();

    machine.set(machine.paramId("moving").?, 1);
    machine.update(0, &library);
    try std.testing.expectEqualStrings("walk", machine.clipName());

    machine.set(machine.paramId("facing").?, 2);
    machine.update(0.05, &library);
    try std.testing.expectEqualStrings("walk_up", machine.clipName());
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), machine.clipTime(), 1e-5);
}

test "transition events and frame events are polled in the order they happen" {
    var library = try data.Library.parse(std.testing.allocator, test_clips, 4, 4);
    defer library.deinit();
    var machine = Machine.init(try Definition.parse(std.testing.allocator, test_machine, &library), &library);
    defer machine.deinit();

    machine.set(machine.paramId("moving").?, 1);
    machine.update(0, &library);
    const first = machine.pollEvent() orelse return error.TestExpectedEvent;
    try std.testing.expectEqualStrings("started", first.name);
    try std.testing.expect(machine.pollEvent() == null);

    // Playback reaches frame 1 of walk, which emits the state's step event.
    machine.update(0.1, &library);
    const second = machine.pollEvent() orelse return error.TestExpectedEvent;
    try std.testing.expectEqualStrings("step", second.name);
    try std.testing.expect(machine.pollEvent() == null);
}

test "a trigger parameter fires its transition once, and is cleared when it does" {
    var library = try data.Library.parse(std.testing.allocator, test_clips, 4, 4);
    defer library.deinit();
    var machine = Machine.init(try Definition.parse(std.testing.allocator, test_machine, &library), &library);
    defer machine.deinit();

    const hurt = machine.paramId("hurt").?;
    machine.set(hurt, 1);
    machine.update(0, &library);
    try std.testing.expectEqualStrings("hit", machine.stateName());
    try std.testing.expectEqual(@as(i32, 0), machine.get(hurt));

    machine.update(0.1, &library);
    try std.testing.expectEqualStrings("hit", machine.stateName());
}

test "restore settles the state from the saved parameters, seeks the clip, and queues no events" {
    var library = try data.Library.parse(std.testing.allocator, test_clips, 4, 4);
    defer library.deinit();
    var machine = Machine.init(try Definition.parse(std.testing.allocator, test_machine, &library), &library);
    defer machine.deinit();

    machine.set(machine.paramId("moving").?, 1);
    machine.restore(&library, 0.15);
    try std.testing.expectEqualStrings("walk", machine.stateName());
    try std.testing.expectApproxEqAbs(@as(f32, 0.15), machine.clipTime(), 1e-5);
    try std.testing.expectEqual(@as(usize, 1), machine.frameIndex());
    try std.testing.expect(machine.pose().previous == null);
    try std.testing.expect(machine.pollEvent() == null);
}

test "machine text is checked against the clips, parameters, and states it names" {
    var library = try data.Library.parse(std.testing.allocator, test_clips, 4, 4);
    defer library.deinit();
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedVersion, Definition.parse(allocator, "machine 2\n", &library));
    try std.testing.expectError(error.BadHeader, Definition.parse(allocator, "state a\n", &library));
    try std.testing.expectError(error.UnknownClip, Definition.parse(allocator, "machine 1\nstate a\nclip missing\n", &library));
    try std.testing.expectError(error.UnknownParam, Definition.parse(allocator, "machine 1\nstate a\nclip idle when ghost == 1\n", &library));
    try std.testing.expectError(error.UnknownState, Definition.parse(allocator, "machine 1\nstate a\nclip idle\ntransition a -> nowhere\n", &library));
    try std.testing.expectError(error.BadCondition, Definition.parse(allocator, "machine 1\nparam p\nstate a\nclip idle when p ==\n", &library));
    try std.testing.expectError(error.BadState, Definition.parse(allocator, "machine 1\nstate a\n", &library));
}
