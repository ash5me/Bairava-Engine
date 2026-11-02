//! An enemy's decisions, as a small state machine. This file is pure code with no engine types, so `zig build test`
//! covers it. Each update step, the enemy's code (enemy.zig) works out what the enemy can see and whether it has
//! reached the end of its route, and passes those answers in as `Senses`. The brain answers with an `Order` when
//! the enemy must plan a new route. The enemy's code plans it and carries out the walk.
//!
//!     idle        waits a random time, then wanders
//!     wander      walks to a random open cell near home; on arrival, idle again
//!     chase       any state that sees the target starts chasing; it keeps chasing while it can see the target,
//!                 and for `lose_sight_seconds` after losing sight of it
//!     return_home walks back to the home cell; on arrival, idle again; seeing the target again starts a chase

const std = @import("std");

/// An idle enemy waits a random time between these two values, in seconds, before it wanders.
pub const idle_min: f32 = 1.5;
pub const idle_max: f32 = 3.0;
/// Seconds without sight of the target before a chasing enemy gives up and walks home.
pub const lose_sight_seconds: f32 = 2.0;

pub const State = enum { idle, wander, chase, return_home };

/// What the enemy's code knows at this step.
pub const Senses = struct {
    /// True when the target is in sight range, and nothing blocks the line between the two.
    sees_target: bool,
    /// True when the enemy has reached the end of its route, or never had one.
    path_done: bool,
};

/// The route the enemy's code should plan now. `none` leaves the current route alone.
pub const Order = enum { none, wander, chase, return_home };

pub const Brain = struct {
    state: State = .idle,
    /// Seconds spent in the current state. An idle enemy counts toward its wait. A chasing enemy counts the time since
    /// it last saw the target.
    timer: f32 = 0,
    /// How long the current idle wait lasts, in seconds.
    wait: f32 = idle_min,
    /// The state of a linear congruential random generator. Each enemy has its own seed, so the enemies wander
    /// differently, and the same seed always gives the same choices.
    seed: u32,

    pub fn init(seed: u32) Brain {
        var brain = Brain{ .seed = seed };
        brain.wait = brain.randomWait();
        return brain;
    }

    /// Moves the decision on by one update step of `dt` seconds, and returns the order the enemy's code must carry out.
    pub fn update(self: *Brain, senses: Senses, dt: f32) Order {
        switch (self.state) {
            .idle => {
                if (senses.sees_target) return self.enter(.chase, .chase);
                self.timer += dt;
                if (self.timer >= self.wait) return self.enter(.wander, .wander);
            },
            .wander => {
                if (senses.sees_target) return self.enter(.chase, .chase);
                if (senses.path_done) self.rest();
            },
            .chase => {
                if (senses.sees_target) {
                    self.timer = 0;
                } else {
                    self.timer += dt;
                    if (self.timer >= lose_sight_seconds) return self.enter(.return_home, .return_home);
                }
            },
            .return_home => {
                if (senses.sees_target) return self.enter(.chase, .chase);
                if (senses.path_done) self.rest();
            },
        }
        return .none;
    }

    /// The next random number, from 0 to 2^24 - 1.
    pub fn random(self: *Brain) u32 {
        self.seed = self.seed *% 1664525 +% 1013904223;
        return self.seed >> 8;
    }

    fn enter(self: *Brain, state: State, order: Order) Order {
        self.state = state;
        self.timer = 0;
        return order;
    }

    /// Stands idle, with a new random wait.
    fn rest(self: *Brain) void {
        self.state = .idle;
        self.timer = 0;
        self.wait = self.randomWait();
    }

    fn randomWait(self: *Brain) f32 {
        const fraction = @as(f32, @floatFromInt(self.random() % 1000)) / 1000.0;
        return idle_min + (idle_max - idle_min) * fraction;
    }
};

test "an idle enemy waits about its random wait, then wanders" {
    var brain = Brain{ .seed = 1, .wait = 1.0 };
    const nothing = Senses{ .sees_target = false, .path_done = true };
    var order: Order = .none;
    var steps: usize = 0;
    while (steps < 200 and order == .none) : (steps += 1) order = brain.update(nothing, 1.0 / 60.0);
    try std.testing.expectEqual(Order.wander, order);
    try std.testing.expectEqual(State.wander, brain.state);
    // One second is 60 steps of 1/60 s, give or take the rounding of the sum.
    try std.testing.expect(steps >= 59 and steps <= 62);
}

test "sighting the target starts a chase from idle, and from wandering too" {
    const seen = Senses{ .sees_target = true, .path_done = true };
    var idle = Brain.init(3);
    try std.testing.expectEqual(Order.chase, idle.update(seen, 1.0 / 60.0));
    try std.testing.expectEqual(State.chase, idle.state);

    var wanderer = Brain{ .seed = 3, .state = .wander };
    try std.testing.expectEqual(Order.chase, wanderer.update(seen, 1.0 / 60.0));
    try std.testing.expectEqual(State.chase, wanderer.state);
}

test "a chase keeps going for the lose-sight time, and sighting the target again resets the clock" {
    var brain = Brain{ .seed = 5, .state = .chase };
    const lost = Senses{ .sees_target = false, .path_done = false };
    const seen = Senses{ .sees_target = true, .path_done = false };

    // 1.5 seconds without sight: still chasing.
    var i: usize = 0;
    while (i < 6) : (i += 1) try std.testing.expectEqual(Order.none, brain.update(lost, 0.25));

    // Sighting the target resets the time without sight.
    try std.testing.expectEqual(Order.none, brain.update(seen, 0.25));

    // 1.75 seconds without sight since then: still chasing.
    i = 0;
    while (i < 7) : (i += 1) try std.testing.expectEqual(Order.none, brain.update(lost, 0.25));

    // Reaching the full lose-sight time sends the enemy home.
    try std.testing.expectEqual(Order.return_home, brain.update(lost, 0.25));
    try std.testing.expectEqual(State.return_home, brain.state);
}

test "a returning enemy rests once it is home, with a fresh wait" {
    var brain = Brain{ .seed = 9, .state = .return_home };
    try std.testing.expectEqual(Order.none, brain.update(.{ .sees_target = false, .path_done = false }, 1.0 / 60.0));
    try std.testing.expectEqual(Order.none, brain.update(.{ .sees_target = false, .path_done = true }, 1.0 / 60.0));
    try std.testing.expectEqual(State.idle, brain.state);
    try std.testing.expectEqual(@as(f32, 0), brain.timer);
    try std.testing.expect(brain.wait >= idle_min and brain.wait <= idle_max);
}

test "a wandering enemy whose route ends rests, and one going home that sees the target chases at once" {
    var wanderer = Brain{ .seed = 11, .state = .wander };
    try std.testing.expectEqual(Order.none, wanderer.update(.{ .sees_target = false, .path_done = true }, 1.0 / 60.0));
    try std.testing.expectEqual(State.idle, wanderer.state);

    var walker_home = Brain{ .seed = 11, .state = .return_home };
    try std.testing.expectEqual(Order.chase, walker_home.update(.{ .sees_target = true, .path_done = false }, 1.0 / 60.0));
    try std.testing.expectEqual(State.chase, walker_home.state);
}

test "waits stay inside the idle range, and the same seed gives the same waits" {
    var first = Brain.init(42);
    var second = Brain.init(42);
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const a = first.randomWait();
        const b = second.randomWait();
        try std.testing.expectEqual(a, b);
        try std.testing.expect(a >= idle_min and a <= idle_max);
    }
}
