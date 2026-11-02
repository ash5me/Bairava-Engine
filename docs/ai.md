# Behavior trees

The engine exposes `engine.ai`, a small allocation-free behavior-tree runtime for game-independent decisions. A tree
is defined as a flat `[]const ai.Node`; composites refer to child nodes by `u16` index. `ai.Node.run(action)` creates
an action, while `ai.Node.sequence(children)` and `ai.Node.selector(children)` create composites. Actions receive a
caller-owned context as `*anyopaque` and return `ai.Status.success`, `.failure`, or `.running`.

```zig
const children = [_]u16{ 1, 2 };
const nodes = [_]ai.Node{
    ai.Node.sequence(&children),
    ai.Node.run(checkTarget),
    ai.Node.run(chaseTarget),
};
var tree = try ai.Tree.init(allocator, &nodes, 0);
defer tree.deinit();

const result = tree.tick(context);
```

A sequence succeeds only when all children succeed, and fails on the first failure. A selector succeeds on the first
success, and fails only when every child fails. Both composites stop on `.running` and resume at that child on the next
tick. `reset` clears those cursors so evaluation starts over. The tree validates that all nodes are reachable from its
root, child references are in range, and the graph is a tree rather than a cycle or shared-child graph. The node array,
child-index slices, and anything captured by action callbacks must outlive the tree.

The sample game's enemy uses a small dedicated state machine in `src/game/enemy_ai.zig`; the generic behavior tree is
available to games that need reusable sequence/selector composition. Navigation primitives and the `navigation.Agent`
that combines route planning with movement are documented in [navigation](navigation.md).
