//! Scene lifecycle: a stack of open scenes, with changes applied at a safe point.
//!
//! The top of the stack is the active scene, and it is the only scene that is updated. A scene below it is
//! suspended: it keeps its state, is not updated, and is drawn under the scenes above it. The stack holds at
//! most `max_depth` scenes.
//!
//! The manager owns every scene it opens. It heap-allocates each scene, so a scene's address stays fixed while
//! the manager itself moves. Each scene is released exactly once: when it is popped, when a switch replaces it,
//! or when the manager is deinitialized. Deinitialization releases the stack from the top down.
//!
//! A scene asks for a change through its navigator, which `update` receives. The request is recorded, not run:
//! `switchTo(T)` replaces the active scene with a new `T` and leaves the scenes below it, `push(T)` opens a new
//! `T` above the active scene as its child, and `pop()` closes the active scene so the one below it resumes.
//! The host loop calls `applyPending` after its update steps and before drawing. That is the safe point: the
//! scene the change affects is not being updated or drawn, so it can be released. A later request replaces an
//! earlier one that has not been applied yet.
//!
//! `applyPending` creates the new scene before it releases the one it replaces. If the new scene's `init` fails,
//! the error is returned, the stack keeps its scenes, and the failed request is dropped. Both scenes exist briefly
//! during a switch or push, so a scene's `init` must not claim a resource that the scene it replaces still holds.
//!
//! Two requests are refused with an error from `applyPending`: popping the root scene, and pushing past `max_depth`.
//! Use `switchTo` to replace the root.
//!
//! A scene owns what its `init` opens and releases it in `deinit`. Assets loaded through the engine's asset
//! loaders are kept until the run ends, because there is no unload yet (P1.5), so an asset a scene loads stays in
//! memory after the scene is gone.

const std = @import("std");
const scene = @import("scene.zig");
const Text = @import("../diagnostics/text.zig").Text;

pub fn Manager(comptime Ctx: type, comptime DrawCtx: type) type {
    return struct {
        const Self = @This();

        /// Behavior of one scene type, built at compile time. The scene's storage is type-erased
        /// behind `ptr`, and each function casts it back to the scene type.
        const Vtable = struct {
            update: *const fn (ptr: *anyopaque, ctx: *Ctx, nav: *Navigator) void,
            draw: *const fn (ptr: *anyopaque, dc: *const DrawCtx) void,
            destroy: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
            debug_text: *const fn (ptr: *anyopaque, out: *Text) void,
        };

        /// An open scene. Copying an `Instance` copies the handle, not the scene.
        pub const Instance = struct {
            ptr: *anyopaque,
            vtable: *const Vtable,
            allocator: std.mem.Allocator,
            /// The scene type's name, from `@typeName`. The overlay and the console show it.
            name: []const u8,

            fn update(self: Instance, ctx: *Ctx, nav: *Navigator) void {
                self.vtable.update(self.ptr, ctx, nav);
            }

            fn draw(self: Instance, dc: *const DrawCtx) void {
                self.vtable.draw(self.ptr, dc);
            }

            fn destroy(self: Instance) void {
                self.vtable.destroy(self.ptr, self.allocator);
            }

            fn debugText(self: Instance, out: *Text) void {
                self.vtable.debug_text(self.ptr, out);
            }
        };

        /// The most scenes the stack holds at once. A push past this is refused.
        pub const max_depth = 8;

        /// What the diagnostics show about the scenes: the open scenes from the root up, the active scene's name, the
        /// change waiting for the next safe point, how many scenes have opened so far, and how many are open now.
        pub const Info = struct {
            /// Name of the active scene, or "none" when no scene is open.
            name: []const u8,
            /// The open scenes' names, root first. Only the first `depth` entries are set.
            stack: [max_depth][]const u8,
            pending: ?[]const u8,
            switches: u32,
            depth: usize,
        };

        /// Opens one scene type. A switch or push request holds one of these.
        const Factory = *const fn (allocator: std.mem.Allocator, ctx: *Ctx) anyerror!Instance;

        /// A switch or push waiting for the next safe point. `label` is what the diagnostics show for it.
        const Opening = struct {
            factory: Factory,
            label: []const u8,
        };

        /// A change waiting for the next safe point.
        const Request = union(enum) {
            switch_to: Opening,
            push: Opening,
            pop,
        };

        /// The handle `update` receives. It records a request for the next safe point. A later request replaces
        /// an earlier one that has not been applied yet.
        pub const Navigator = struct {
            pending: ?Request = null,

            /// Asks for a scene of type `T` to replace the active one at the next safe point. The scenes below the
            /// active one stay open.
            pub fn switchTo(self: *Navigator, comptime T: type) void {
                scene.assertScene(T);
                self.pending = .{ .switch_to = .{ .factory = &Maker(T).make, .label = @typeName(T) } };
            }

            /// Asks for a scene of type `T` to open above the active one at the next safe point. The active scene is
            /// suspended until the new one is popped. It is not updated, but it is still drawn, under the new scene.
            pub fn push(self: *Navigator, comptime T: type) void {
                scene.assertScene(T);
                self.pending = .{ .push = .{ .factory = &Maker(T).make, .label = "push " ++ @typeName(T) } };
            }

            /// Asks for the active scene to be closed at the next safe point. The scene below it resumes. The root
            /// scene cannot be popped: use `switchTo` to replace it.
            pub fn pop(self: *Navigator) void {
                self.pending = .pop;
            }
        };

        allocator: std.mem.Allocator,
        /// The open scenes, root first. The last one is the active scene, and the rest are suspended below it.
        stack: [max_depth]Instance = undefined,
        depth: usize = 0,
        navigator: Navigator = .{},
        /// Name of the active scene, or "none" when no scene is open.
        active_name: []const u8 = "none",
        /// Scenes opened so far, counting the first.
        switches: u32 = 0,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        /// Releases every open scene, top first, and drops any pending request. The manager is empty afterward.
        pub fn deinit(self: *Self) void {
            while (self.depth > 0) {
                self.depth -= 1;
                self.stack[self.depth].destroy();
            }
            self.active_name = "none";
            self.navigator.pending = null;
        }

        /// Asks for a scene of type `T` to replace the active one, from host code such as a menu handler. The
        /// switch happens at the next `applyPending`, the same as a request made from `update`.
        pub fn switchTo(self: *Self, comptime T: type) void {
            self.navigator.switchTo(T);
        }

        /// Asks for a scene of type `T` to open above the active one, from host code. See `Navigator.push`.
        pub fn push(self: *Self, comptime T: type) void {
            self.navigator.push(T);
        }

        /// Asks for the active scene to be closed, from host code. See `Navigator.pop`.
        pub fn pop(self: *Self) void {
            self.navigator.pop();
        }

        /// The active scene, which is the top of the stack, or null when no scene is open.
        fn top(self: *const Self) ?Instance {
            if (self.depth == 0) return null;
            return self.stack[self.depth - 1];
        }

        /// Runs the active scene's update. The scene may ask for a change through its navigator. Scenes below it
        /// are suspended, so they are not updated.
        pub fn update(self: *Self, ctx: *Ctx) void {
            if (self.top()) |active| active.update(ctx, &self.navigator);
        }

        /// Draws every open scene from the bottom of the stack up, so a pushed scene draws over the one below it.
        /// Drawing cannot request a change, so the stack stays the same for the whole draw.
        pub fn draw(self: *Self, dc: *const DrawCtx) void {
            for (self.stack[0..self.depth]) |instance| instance.draw(dc);
        }

        /// The open scenes' names, the active scene's name, the change waiting for the next safe point, and the
        /// counts, for the diagnostics.
        pub fn info(self: *const Self) Info {
            const pending: ?[]const u8 = if (self.navigator.pending) |request| labelOf(request) else null;
            var names = [_][]const u8{""} ** max_depth;
            for (self.stack[0..self.depth], 0..) |instance, index| names[index] = instance.name;
            return .{
                .name = self.active_name,
                .stack = names,
                .pending = pending,
                .switches = self.switches,
                .depth = self.depth,
            };
        }

        /// Adds the active scene's debug lines. A scene that has no `debugText` method adds none.
        pub fn debugText(self: *const Self, out: *Text) void {
            if (self.top()) |active| active.debugText(out);
        }

        /// Applies the pending request, if there is one. If the new scene's `init` fails, its error is returned, the
        /// stack keeps its scenes, and the failed request is dropped.
        pub fn applyPending(self: *Self, ctx: *Ctx) anyerror!void {
            const request = self.navigator.pending orelse return;
            self.navigator.pending = null;
            switch (request) {
                .switch_to => |opening| {
                    const next = try opening.factory(self.allocator, ctx);
                    self.replaceTop(next);
                },
                .push => |opening| {
                    if (self.depth == max_depth) return error.SceneStackFull;
                    const next = try opening.factory(self.allocator, ctx);
                    self.stack[self.depth] = next;
                    self.depth += 1;
                    self.noteOpened(next);
                },
                .pop => {
                    if (self.depth <= 1) return error.CannotPopRoot;
                    self.depth -= 1;
                    self.stack[self.depth].destroy();
                    self.noteActive();
                },
            }
        }

        /// Puts `next` in place of the active scene, or as the root when the stack is empty. `next` has already
        /// opened, so the scene it replaces is released only after the new one is running.
        fn replaceTop(self: *Self, next: Instance) void {
            if (self.depth == 0) {
                self.stack[0] = next;
                self.depth = 1;
            } else {
                self.stack[self.depth - 1].destroy();
                self.stack[self.depth - 1] = next;
            }
            self.noteOpened(next);
        }

        fn noteOpened(self: *Self, opened: Instance) void {
            self.active_name = opened.name;
            self.switches += 1;
        }

        fn noteActive(self: *Self) void {
            if (self.top()) |active| {
                self.active_name = active.name;
            } else {
                self.active_name = "none";
            }
        }

        /// What the diagnostics show for a pending change.
        fn labelOf(request: Request) []const u8 {
            return switch (request) {
                .switch_to => |opening| opening.label,
                .push => |opening| opening.label,
                .pop => "pop",
            };
        }

        fn Maker(comptime T: type) type {
            return struct {
                fn make(allocator: std.mem.Allocator, ctx: *Ctx) anyerror!Instance {
                    const storage = try allocator.create(T);
                    errdefer allocator.destroy(storage);
                    storage.* = try T.init(ctx);
                    return .{ .ptr = storage, .vtable = &Erased(T).vtable, .allocator = allocator, .name = @typeName(T) };
                }
            };
        }

        // The helpers have their own names. Inside this struct a bare `update` or `draw` would also
        // match the manager's methods of the same name, and Zig rejects that as ambiguous.
        fn Erased(comptime T: type) type {
            return struct {
                fn callUpdate(ptr: *anyopaque, ctx: *Ctx, nav: *Navigator) void {
                    const self: *T = @ptrCast(@alignCast(ptr));
                    self.update(ctx, nav);
                }

                fn callDraw(ptr: *anyopaque, dc: *const DrawCtx) void {
                    const self: *T = @ptrCast(@alignCast(ptr));
                    self.draw(dc);
                }

                fn callDestroy(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                    const self: *T = @ptrCast(@alignCast(ptr));
                    self.deinit();
                    allocator.destroy(self);
                }

                // A scene with no `debugText` method adds no lines, so the check is made at compile time.
                fn callDebugText(ptr: *anyopaque, out: *Text) void {
                    const self: *T = @ptrCast(@alignCast(ptr));
                    if (comptime @hasDecl(T, "debugText")) {
                        self.debugText(out);
                    }
                }

                const vtable: Vtable = .{
                    .update = callUpdate,
                    .draw = callDraw,
                    .destroy = callDestroy,
                    .debug_text = callDebugText,
                };
            };
        }
    };
}

// Tests. Each scene writes its calls into a trace in the test context, so a test can check the
// exact order of events. Each event is two characters: the scene's tag, then the event.
// `+` is init, `u` is update, `d` is draw, and `-` is deinit.

const Trace = struct {
    log: [1024]u8 = undefined,
    len: usize = 0,
    /// Scenes that have finished `init` and have not been deinitialized yet.
    live: usize = 0,

    fn note(self: *Trace, c: u8) void {
        if (self.len == self.log.len) @panic("test trace is full");
        self.log[self.len] = c;
        self.len += 1;
    }

    fn text(self: *const Trace) []const u8 {
        return self.log[0..self.len];
    }
};

const TestCtx = struct { trace: Trace = .{} };
const TestDraw = struct {};
const M = Manager(TestCtx, TestDraw);

fn mark(trace: *Trace, tag: u8, event: u8) void {
    trace.note(tag);
    trace.note(event);
}

/// Scene `A`. Its update asks for `Beta`, so the switch is still pending when update returns.
const Alpha = struct {
    trace: *Trace,

    pub fn init(ctx: *TestCtx) !Alpha {
        mark(&ctx.trace, 'A', '+');
        ctx.trace.live += 1;
        return .{ .trace = &ctx.trace };
    }

    pub fn update(self: *Alpha, ctx: *TestCtx, nav: *M.Navigator) void {
        _ = ctx;
        mark(self.trace, 'A', 'u');
        nav.switchTo(Beta);
    }

    pub fn draw(self: *Alpha, dc: *const TestDraw) void {
        _ = dc;
        mark(self.trace, 'A', 'd');
    }

    pub fn deinit(self: *Alpha) void {
        mark(self.trace, 'A', '-');
        self.trace.live -= 1;
    }
};

/// Scene `B`. It never asks for a change.
const Beta = struct {
    trace: *Trace,

    pub fn init(ctx: *TestCtx) !Beta {
        mark(&ctx.trace, 'B', '+');
        ctx.trace.live += 1;
        return .{ .trace = &ctx.trace };
    }

    pub fn update(self: *Beta, ctx: *TestCtx, nav: *M.Navigator) void {
        _ = ctx;
        _ = nav;
        mark(self.trace, 'B', 'u');
    }

    pub fn draw(self: *Beta, dc: *const TestDraw) void {
        _ = dc;
        mark(self.trace, 'B', 'd');
    }

    pub fn deinit(self: *Beta) void {
        mark(self.trace, 'B', '-');
        self.trace.live -= 1;
    }
};

/// A scene whose `init` fails. Its other methods only satisfy the scene contract, and they must
/// never run, so they write nothing into the trace.
const Broken = struct {
    field: u8 = 0,

    pub fn init(ctx: *TestCtx) !Broken {
        ctx.trace.note('F');
        return error.SceneBoom;
    }

    pub fn update(self: *Broken, ctx: *TestCtx, nav: *M.Navigator) void {
        _ = self;
        _ = ctx;
        _ = nav;
    }

    pub fn draw(self: *Broken, dc: *const TestDraw) void {
        _ = self;
        _ = dc;
    }

    pub fn deinit(self: *Broken) void {
        _ = self;
    }
};

/// Scene `G`. It runs as a child, and its update asks to be popped, so a test can see the pop at the safe point.
const Gamma = struct {
    trace: *Trace,

    pub fn init(ctx: *TestCtx) !Gamma {
        mark(&ctx.trace, 'G', '+');
        ctx.trace.live += 1;
        return .{ .trace = &ctx.trace };
    }

    pub fn update(self: *Gamma, ctx: *TestCtx, nav: *M.Navigator) void {
        _ = ctx;
        mark(self.trace, 'G', 'u');
        nav.pop();
    }

    pub fn draw(self: *Gamma, dc: *const TestDraw) void {
        _ = dc;
        mark(self.trace, 'G', 'd');
    }

    pub fn deinit(self: *Gamma) void {
        mark(self.trace, 'G', '-');
        self.trace.live -= 1;
    }
};

test "lifecycle: init, update, and draw in order, with deinit once when replaced and at shutdown" {
    var ctx = TestCtx{};
    var manager = M.init(std.testing.allocator);

    manager.switchTo(Alpha);
    try manager.applyPending(&ctx);
    manager.update(&ctx);
    manager.draw(&TestDraw{});
    try manager.applyPending(&ctx);
    manager.update(&ctx);
    manager.draw(&TestDraw{});
    manager.deinit();

    try std.testing.expectEqualStrings("A+AuAdB+A-BuBdB-", ctx.trace.text());
    try std.testing.expectEqual(@as(usize, 0), ctx.trace.live);
}

test "a switch requested during update waits for applyPending" {
    var ctx = TestCtx{};
    var manager = M.init(std.testing.allocator);

    manager.switchTo(Alpha);
    try manager.applyPending(&ctx);
    manager.update(&ctx);
    try std.testing.expectEqualStrings("A+Au", ctx.trace.text());

    try manager.applyPending(&ctx);
    try std.testing.expectEqualStrings("A+AuB+A-", ctx.trace.text());

    manager.deinit();
    try std.testing.expectEqual(@as(usize, 0), ctx.trace.live);
}

test "a failed init keeps the current scene running and drops the request" {
    var ctx = TestCtx{};
    var manager = M.init(std.testing.allocator);

    manager.switchTo(Beta);
    try manager.applyPending(&ctx);

    manager.switchTo(Broken);
    try std.testing.expectError(error.SceneBoom, manager.applyPending(&ctx));
    try std.testing.expectEqual(@as(usize, 1), ctx.trace.live);

    // The failed request was dropped, so applying again changes nothing.
    try manager.applyPending(&ctx);
    manager.update(&ctx);
    try std.testing.expectEqualStrings("B+FBu", ctx.trace.text());

    manager.deinit();
    try std.testing.expectEqualStrings("B+FBuB-", ctx.trace.text());
    try std.testing.expectEqual(@as(usize, 0), ctx.trace.live);
}

test "repeated switches leak nothing and keep exactly one scene live" {
    var ctx = TestCtx{};
    var manager = M.init(std.testing.allocator);

    var cycle: usize = 0;
    while (cycle < 50) : (cycle += 1) {
        if (cycle % 2 == 0) {
            manager.switchTo(Alpha);
        } else {
            manager.switchTo(Beta);
        }
        try manager.applyPending(&ctx);
        try std.testing.expectEqual(@as(usize, 1), ctx.trace.live);
    }

    manager.deinit();
    try std.testing.expectEqual(@as(usize, 0), ctx.trace.live);
}

test "the manager names the active scene, and reports a switch as pending until it opens" {
    var ctx = TestCtx{};
    var manager = M.init(std.testing.allocator);
    defer manager.deinit();
    try std.testing.expectEqualStrings("none", manager.info().name);

    manager.switchTo(Alpha);
    try std.testing.expect(manager.info().pending != null);
    try manager.applyPending(&ctx);
    try std.testing.expect(manager.info().pending == null);
    try std.testing.expectEqualStrings(@typeName(Alpha), manager.info().name);
    try std.testing.expectEqual(@as(u32, 1), manager.info().switches);
}

test "the diagnostics list the open scenes root first, and the list shrinks when a scene is popped" {
    var ctx = TestCtx{};
    var manager = M.init(std.testing.allocator);
    defer manager.deinit();
    try std.testing.expectEqual(@as(usize, 0), manager.info().depth);

    manager.switchTo(Beta);
    try manager.applyPending(&ctx);
    manager.push(Gamma);
    try manager.applyPending(&ctx);
    manager.push(Gamma);
    try manager.applyPending(&ctx);

    const deep = manager.info();
    try std.testing.expectEqual(@as(usize, 3), deep.depth);
    try std.testing.expectEqualStrings(@typeName(Beta), deep.stack[0]);
    try std.testing.expectEqualStrings(@typeName(Gamma), deep.stack[1]);
    try std.testing.expectEqualStrings(@typeName(Gamma), deep.stack[2]);
    try std.testing.expectEqualStrings(@typeName(Gamma), deep.name);

    manager.pop();
    try manager.applyPending(&ctx);
    const shallow = manager.info();
    try std.testing.expectEqual(@as(usize, 2), shallow.depth);
    try std.testing.expectEqualStrings(@typeName(Beta), shallow.stack[0]);
    try std.testing.expectEqualStrings(@typeName(Gamma), shallow.stack[1]);
}

test "an empty manager ignores update, draw, and applyPending" {
    var ctx = TestCtx{};
    var manager = M.init(std.testing.allocator);

    manager.update(&ctx);
    manager.draw(&TestDraw{});
    try manager.applyPending(&ctx);
    try std.testing.expectEqualStrings("", ctx.trace.text());

    manager.deinit();
}

test "a pushed scene runs above the scene below it: only the top updates, and draws run bottom to top" {
    var ctx = TestCtx{};
    var manager = M.init(std.testing.allocator);
    defer manager.deinit();

    manager.switchTo(Beta);
    try manager.applyPending(&ctx);
    manager.push(Gamma);
    try manager.applyPending(&ctx);
    try std.testing.expectEqual(@as(usize, 2), manager.info().depth);

    manager.update(&ctx);
    try std.testing.expectEqualStrings("B+G+Gu", ctx.trace.text());
    manager.draw(&TestDraw{});
    try std.testing.expectEqualStrings("B+G+GuBdGd", ctx.trace.text());
}

test "popping a pushed scene destroys it, and the scene below resumes" {
    var ctx = TestCtx{};
    var manager = M.init(std.testing.allocator);

    manager.switchTo(Beta);
    try manager.applyPending(&ctx);
    manager.push(Gamma);
    try manager.applyPending(&ctx);
    manager.update(&ctx);
    try manager.applyPending(&ctx);
    try std.testing.expectEqual(@as(usize, 1), manager.info().depth);
    try std.testing.expectEqualStrings(@typeName(Beta), manager.info().name);

    manager.update(&ctx);
    try std.testing.expectEqualStrings("B+G+GuG-Bu", ctx.trace.text());
    try std.testing.expectEqual(@as(usize, 1), ctx.trace.live);

    manager.deinit();
    try std.testing.expectEqualStrings("B+G+GuG-BuB-", ctx.trace.text());
    try std.testing.expectEqual(@as(usize, 0), ctx.trace.live);
}

test "switchTo replaces the active scene and leaves the scene below it open" {
    var ctx = TestCtx{};
    var manager = M.init(std.testing.allocator);

    manager.switchTo(Beta);
    try manager.applyPending(&ctx);
    manager.push(Gamma);
    try manager.applyPending(&ctx);
    manager.switchTo(Alpha);
    try manager.applyPending(&ctx);
    try std.testing.expectEqual(@as(usize, 2), manager.info().depth);

    manager.update(&ctx);
    try manager.applyPending(&ctx);
    try std.testing.expectEqual(@as(usize, 2), manager.info().depth);
    try std.testing.expectEqualStrings("B+G+A+G-AuB+A-", ctx.trace.text());
    try std.testing.expectEqual(@as(usize, 2), ctx.trace.live);

    manager.deinit();
    try std.testing.expectEqualStrings("B+G+A+G-AuB+A-B-B-", ctx.trace.text());
    try std.testing.expectEqual(@as(usize, 0), ctx.trace.live);
}

test "a push whose init fails leaves the stack as it was" {
    var ctx = TestCtx{};
    var manager = M.init(std.testing.allocator);

    manager.switchTo(Beta);
    try manager.applyPending(&ctx);
    manager.push(Broken);
    try std.testing.expectError(error.SceneBoom, manager.applyPending(&ctx));
    try std.testing.expectEqual(@as(usize, 1), manager.info().depth);
    try std.testing.expectEqual(@as(usize, 1), ctx.trace.live);

    manager.update(&ctx);
    try std.testing.expectEqualStrings("B+FBu", ctx.trace.text());
    manager.deinit();
    try std.testing.expectEqualStrings("B+FBuB-", ctx.trace.text());
}

test "the stack holds at most max_depth scenes, and one more push is refused" {
    var ctx = TestCtx{};
    var manager = M.init(std.testing.allocator);

    manager.switchTo(Beta);
    try manager.applyPending(&ctx);
    var pushed: usize = 1;
    while (pushed < M.max_depth) : (pushed += 1) {
        manager.push(Gamma);
        try manager.applyPending(&ctx);
    }
    try std.testing.expectEqual(@as(usize, M.max_depth), manager.info().depth);
    try std.testing.expectEqual(@as(usize, M.max_depth), ctx.trace.live);

    manager.push(Gamma);
    try std.testing.expectError(error.SceneStackFull, manager.applyPending(&ctx));
    try std.testing.expectEqual(@as(usize, M.max_depth), manager.info().depth);

    manager.deinit();
    try std.testing.expectEqual(@as(usize, 0), ctx.trace.live);
}

test "the root scene cannot be popped, and the scene stays open" {
    var ctx = TestCtx{};
    var manager = M.init(std.testing.allocator);
    defer manager.deinit();

    manager.switchTo(Beta);
    try manager.applyPending(&ctx);
    manager.pop();
    try std.testing.expectError(error.CannotPopRoot, manager.applyPending(&ctx));
    try std.testing.expectEqual(@as(usize, 1), manager.info().depth);
    try std.testing.expectEqual(@as(usize, 1), ctx.trace.live);
}

test "deinit releases the pushed scenes from the top down, before the scene they sit on" {
    var ctx = TestCtx{};
    var manager = M.init(std.testing.allocator);

    manager.switchTo(Beta);
    try manager.applyPending(&ctx);
    manager.push(Gamma);
    try manager.applyPending(&ctx);
    manager.push(Gamma);
    try manager.applyPending(&ctx);
    manager.deinit();
    try std.testing.expectEqualStrings("B+G+G+G-G-B-", ctx.trace.text());
    try std.testing.expectEqual(@as(usize, 0), ctx.trace.live);
}

test "the pending change is named for the diagnostics, for a switch, a push, and a pop" {
    var ctx = TestCtx{};
    var manager = M.init(std.testing.allocator);
    defer manager.deinit();

    manager.switchTo(Beta);
    try std.testing.expectEqualStrings(@typeName(Beta), manager.info().pending.?);
    try manager.applyPending(&ctx);

    manager.push(Gamma);
    try std.testing.expectEqualStrings("push " ++ @typeName(Gamma), manager.info().pending.?);
    try manager.applyPending(&ctx);

    manager.pop();
    try std.testing.expectEqualStrings("pop", manager.info().pending.?);
    try manager.applyPending(&ctx);
    try std.testing.expect(manager.info().pending == null);
}
