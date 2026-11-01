//! Local transforms and parent-child composition for scene entities.

const std = @import("std");
const entity = @import("../ecs/entity.zig");
const math = @import("math.zig");

pub const Transform = struct {
    position: math.Vec3 = .{ 0.0, 0.0, 0.0 },
    rotation: math.Quat = math.quatIdentity(),
    scale: math.Vec3 = .{ 1.0, 1.0, 1.0 },

    /// Builds the local matrix in translate-rotate-scale order.
    pub fn localMatrix(self: Transform) math.Mat4 {
        return math.mul(
            math.translate3d(self.position),
            math.mul(math.quatToMat4(math.quatNormalize(self.rotation)), math.scale3d(self.scale)),
        );
    }
};

const Node = struct {
    transform: Transform = .{},
    parent: ?entity.Handle = null,
};

/// ECS-backed transform storage with validated parent relationships.
pub const Hierarchy = struct {
    const Nodes = entity.World(Node, .aos);

    nodes: Nodes,

    pub fn init(allocator: std.mem.Allocator) Hierarchy {
        return .{ .nodes = Nodes.init(allocator) };
    }

    pub fn deinit(self: *Hierarchy) void {
        self.nodes.deinit();
    }

    pub fn count(self: *const Hierarchy) usize {
        return self.nodes.count();
    }

    pub fn spawn(self: *Hierarchy, transform: Transform) std.mem.Allocator.Error!entity.Handle {
        return self.nodes.spawn(.{ .transform = transform });
    }

    /// A parent cannot be removed while it still has children.
    pub fn despawn(self: *Hierarchy, handle: entity.Handle) error{ InvalidEntity, HasChildren }!void {
        if (!self.nodes.isAlive(handle)) return error.InvalidEntity;
        for (0..self.nodes.count()) |row| {
            const node = self.nodes.rows.get(row);
            if (node.parent) |parent| {
                if (sameHandle(parent, handle)) return error.HasChildren;
            }
        }
        if (!self.nodes.despawn(handle)) return error.InvalidEntity;
    }

    pub fn get(self: *const Hierarchy, handle: entity.Handle) ?Transform {
        const node = self.nodes.get(handle) orelse return null;
        return node.transform;
    }

    pub fn set(self: *Hierarchy, handle: entity.Handle, transform: Transform) bool {
        var node = self.nodes.get(handle) orelse return false;
        node.transform = transform;
        return self.nodes.set(handle, node);
    }

    /// Reparents `child`; null makes it a root. Existing world position is not preserved.
    pub fn setParent(self: *Hierarchy, child: entity.Handle, parent: ?entity.Handle) error{ InvalidEntity, InvalidParent, HierarchyCycle }!void {
        var node = self.nodes.get(child) orelse return error.InvalidEntity;

        var ancestor = parent;
        var depth: usize = 0;
        while (ancestor) |handle| {
            if (!self.nodes.isAlive(handle)) return error.InvalidParent;
            if (sameHandle(handle, child)) return error.HierarchyCycle;
            if (depth >= self.nodes.count()) return error.HierarchyCycle;
            const parent_node = self.nodes.get(handle) orelse return error.InvalidParent;
            ancestor = parent_node.parent;
            depth += 1;
        }

        node.parent = parent;
        if (!self.nodes.set(child, node)) return error.InvalidEntity;
    }

    /// Returns the composed world matrix, applying each ancestor before the local transform.
    pub fn worldMatrix(self: *const Hierarchy, handle: entity.Handle) error{ InvalidEntity, InvalidParent, HierarchyCycle }!math.Mat4 {
        var node = self.nodes.get(handle) orelse return error.InvalidEntity;
        var result = node.transform.localMatrix();
        var depth: usize = 0;
        while (node.parent) |parent| {
            if (depth >= self.nodes.count()) return error.HierarchyCycle;
            node = self.nodes.get(parent) orelse return error.InvalidParent;
            result = math.mul(node.transform.localMatrix(), result);
            depth += 1;
        }
        return result;
    }

    fn sameHandle(a: entity.Handle, b: entity.Handle) bool {
        return a.index == b.index and a.generation == b.generation;
    }
};

test "local transforms apply translation, rotation, and scale" {
    const transform: Transform = .{
        .position = .{ 4.0, 5.0, 0.0 },
        .rotation = math.quatFromAxisAngle(.{ 0.0, 0.0, 1.0 }, std.math.pi / 2.0),
        .scale = .{ 2.0, 1.0, 1.0 },
    };
    const matrix = transform.localMatrix();
    const point = math.transformPoint(&matrix, 1.0, 0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), point[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), point[1], 1e-5);
}

test "hierarchy composes parents, rejects cycles, and protects parents with children" {
    var hierarchy = Hierarchy.init(std.testing.allocator);
    defer hierarchy.deinit();

    const parent = try hierarchy.spawn(.{ .position = .{ 10.0, 20.0, 0.0 } });
    const child = try hierarchy.spawn(.{ .position = .{ 3.0, 4.0, 0.0 } });
    const grandchild = try hierarchy.spawn(.{ .position = .{ 1.0, 2.0, 0.0 } });

    try hierarchy.setParent(child, parent);
    try hierarchy.setParent(grandchild, child);
    try std.testing.expectError(error.HierarchyCycle, hierarchy.setParent(parent, grandchild));
    try std.testing.expectError(error.HasChildren, hierarchy.despawn(parent));

    const matrix = try hierarchy.worldMatrix(grandchild);
    const point = math.transformPoint(&matrix, 0.0, 0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 14.0), point[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 26.0), point[1], 1e-5);

    try hierarchy.setParent(child, null);
    try hierarchy.despawn(parent);
}
