//! A small, allocation-free behavior-tree runtime for game-independent AI decisions.
//! Nodes and their child-index slices belong to the caller and must outlive the tree.

const std = @import("std");

pub const Status = enum { success, failure, running };
pub const Kind = enum { action, sequence, selector };
pub const Action = *const fn (*anyopaque) Status;

pub const Node = struct {
    kind: Kind,
    children: []const u16 = &.{},
    action: ?Action = null,

    pub fn run(action: Action) Node {
        return .{ .kind = .action, .action = action };
    }

    pub fn sequence(children: []const u16) Node {
        return .{ .kind = .sequence, .children = children };
    }

    pub fn selector(children: []const u16) Node {
        return .{ .kind = .selector, .children = children };
    }
};

pub const TreeError = error{InvalidTree};

/// Runs a fixed behavior tree. Running composites resume at the child that was running last tick.
pub const Tree = struct {
    allocator: std.mem.Allocator,
    nodes: []const Node,
    root: u16,
    active_child: []u16,

    pub fn init(allocator: std.mem.Allocator, nodes: []const Node, root: u16) (TreeError || std.mem.Allocator.Error)!Tree {
        if (nodes.len == 0 or nodes.len > std.math.maxInt(u16) or root >= nodes.len) return error.InvalidTree;
        const active_child = try allocator.alloc(u16, nodes.len);
        errdefer allocator.free(active_child);
        @memset(active_child, 0);

        var seen = try allocator.alloc(bool, nodes.len);
        defer allocator.free(seen);
        @memset(seen, false);
        var queue = try allocator.alloc(u16, nodes.len);
        defer allocator.free(queue);
        var read: usize = 0;
        var written: usize = 1;
        queue[0] = root;
        seen[root] = true;
        while (read < written) : (read += 1) {
            const node_index = queue[read];
            const node = nodes[node_index];
            switch (node.kind) {
                .action => {
                    if (node.action == null or node.children.len != 0) return error.InvalidTree;
                },
                .sequence, .selector => {
                    if (node.action != null or node.children.len == 0) return error.InvalidTree;
                    for (node.children) |child| {
                        if (child >= nodes.len or seen[child]) return error.InvalidTree;
                        seen[child] = true;
                        queue[written] = child;
                        written += 1;
                    }
                },
            }
        }
        if (written != nodes.len) return error.InvalidTree;
        return .{ .allocator = allocator, .nodes = nodes, .root = root, .active_child = active_child };
    }

    pub fn deinit(self: *Tree) void {
        self.allocator.free(self.active_child);
        self.* = undefined;
    }

    pub fn tick(self: *Tree, context: *anyopaque) Status {
        return self.tickNode(self.root, context);
    }

    /// Clears all running-child cursors, so the next tick starts from the root of each composite.
    pub fn reset(self: *Tree) void {
        @memset(self.active_child, 0);
    }

    fn tickNode(self: *Tree, node_index: u16, context: *anyopaque) Status {
        const node = self.nodes[node_index];
        switch (node.kind) {
            .action => return node.action.?(context),
            .sequence => {
                var child_index: usize = self.active_child[node_index];
                while (child_index < node.children.len) : (child_index += 1) {
                    const status = self.tickNode(node.children[child_index], context);
                    if (status == .running) {
                        self.active_child[node_index] = @intCast(child_index);
                        return .running;
                    }
                    if (status == .failure) {
                        self.active_child[node_index] = 0;
                        return .failure;
                    }
                }
                self.active_child[node_index] = 0;
                return .success;
            },
            .selector => {
                var child_index: usize = self.active_child[node_index];
                while (child_index < node.children.len) : (child_index += 1) {
                    const status = self.tickNode(node.children[child_index], context);
                    if (status == .running) {
                        self.active_child[node_index] = @intCast(child_index);
                        return .running;
                    }
                    if (status == .success) {
                        self.active_child[node_index] = 0;
                        return .success;
                    }
                }
                self.active_child[node_index] = 0;
                return .failure;
            },
        }
    }
};

test "a sequence resumes its running child and finishes only after all children succeed" {
    const Context = struct {
        calls: u8 = 0,
    };
    const actions = struct {
        fn first(raw: *anyopaque) Status {
            const context: *Context = @ptrCast(@alignCast(raw));
            context.calls += 1;
            return .success;
        }

        fn second(raw: *anyopaque) Status {
            const context: *Context = @ptrCast(@alignCast(raw));
            context.calls += 1;
            return if (context.calls < 3) .running else .success;
        }
    };
    const children = [_]u16{ 1, 2 };
    const nodes = [_]Node{
        Node.sequence(&children),
        Node.run(actions.first),
        Node.run(actions.second),
    };
    var tree = try Tree.init(std.testing.allocator, &nodes, 0);
    defer tree.deinit();
    var context = Context{};
    const raw: *anyopaque = @ptrCast(&context);

    try std.testing.expectEqual(Status.running, tree.tick(raw));
    try std.testing.expectEqual(@as(u8, 2), context.calls);
    try std.testing.expectEqual(Status.success, tree.tick(raw));
    try std.testing.expectEqual(@as(u8, 3), context.calls);
}

test "a selector tries the next child after failure and reset restarts a running branch" {
    const Context = struct {
        running_calls: u8 = 0,
        success_calls: u8 = 0,
    };
    const actions = struct {
        fn fail(_: *anyopaque) Status {
            return .failure;
        }

        fn running(raw: *anyopaque) Status {
            const context: *Context = @ptrCast(@alignCast(raw));
            context.running_calls += 1;
            return .running;
        }

        fn succeed(raw: *anyopaque) Status {
            const context: *Context = @ptrCast(@alignCast(raw));
            context.success_calls += 1;
            return .success;
        }
    };
    const children = [_]u16{ 1, 2, 3 };
    const nodes = [_]Node{
        Node.selector(&children),
        Node.run(actions.fail),
        Node.run(actions.running),
        Node.run(actions.succeed),
    };
    var tree = try Tree.init(std.testing.allocator, &nodes, 0);
    defer tree.deinit();
    var context = Context{};
    const raw: *anyopaque = @ptrCast(&context);
    try std.testing.expectEqual(Status.running, tree.tick(raw));
    tree.reset();
    try std.testing.expectEqual(Status.running, tree.tick(raw));
    try std.testing.expectEqual(@as(u8, 2), context.running_calls);
    try std.testing.expectEqual(@as(u8, 0), context.success_calls);
}

test "a behavior tree rejects disconnected, shared, cyclic, and malformed nodes" {
    const action = struct {
        fn run(_: *anyopaque) Status {
            return .success;
        }
    }.run;
    const disconnected = [_]Node{ Node.run(action), Node.run(action) };
    try std.testing.expectError(error.InvalidTree, Tree.init(std.testing.allocator, &disconnected, 0));
    const shared_children = [_]u16{ 1, 1 };
    const shared = [_]Node{ Node.sequence(&shared_children), Node.run(action) };
    try std.testing.expectError(error.InvalidTree, Tree.init(std.testing.allocator, &shared, 0));
    const cycle_children = [_]u16{0};
    const cycle = [_]Node{Node.sequence(&cycle_children)};
    try std.testing.expectError(error.InvalidTree, Tree.init(std.testing.allocator, &cycle, 0));
    const missing_action = [_]Node{.{ .kind = .action }};
    try std.testing.expectError(error.InvalidTree, Tree.init(std.testing.allocator, &missing_action, 0));
}
