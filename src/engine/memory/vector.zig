//! Custom vectors of structs, stored in one of two layouts.
//!
//! Array of structs (AoS) keeps each element's fields together, so reading or writing a whole
//! element touches one block of memory. Structure of arrays (SoA) keeps each field in its own
//! column, so a system that reads a few fields across many elements touches only those columns,
//! and each column is a contiguous run of one field type. Pick the layout per container: AoS for
//! data that is used whole, SoA for data that systems scan field by field.
//!
//! Both layouts share one API and one allocation. The layout only decides where a field's bytes
//! sit, so the same code runs under either layout. `Column` is the view that makes this work: a
//! strided pointer to one field of every element.
//!
//! This module imports no SDL or logger, so `zig build test` runs its tests.

const std = @import("std");

/// How a `Vector` lays out its elements.
pub const Layout = enum {
    /// Each element's fields sit together: `[element 0][element 1]...`.
    aos,
    /// Each field is one column: `[all of field 0][all of field 1]...`.
    soa,
};

/// A strided view of one field across the elements of a vector. `at(i)` points at that field of
/// element `i`. Under AoS the stride is the element size, and under SoA it is the field size, so one
/// loop serves both layouts. A view is valid until the vector grows or is freed.
pub fn Column(comptime F: type) type {
    return struct {
        const Self = @This();

        base: [*]u8,
        stride: usize,
        len: usize,

        /// Pointer to this field of element `index`. The check runs in every build mode, because a
        /// wrong index here would read or write memory outside the vector.
        pub fn at(self: Self, index: usize) *F {
            if (index >= self.len) {
                std.debug.panic("column index {d} is out of range for {d} elements", .{ index, self.len });
            }
            const address = self.base + index * self.stride;
            return @ptrCast(@alignCast(address));
        }
    };
}

/// The smallest capacity a vector allocates on its first growth. Growth doubles from here.
const min_capacity: usize = 8;

/// The smallest capacity that is at least `needed`, growing from `current` by doubling.
fn grownCapacity(current: usize, needed: usize) usize {
    var capacity: usize = if (current < min_capacity) min_capacity else current;
    while (capacity < needed) capacity *= 2;
    return capacity;
}

/// Rounds `value` up to a multiple of `alignment`, which must be a power of two.
fn alignUp(value: usize, alignment: usize) usize {
    return (value + alignment - 1) & ~(alignment - 1);
}

/// The index of the field called `name` in struct `T`. A name that isn't a field is a compile error.
fn fieldIndex(comptime T: type, comptime name: []const u8) usize {
    inline for (std.meta.fields(T), 0..) |f, i| {
        if (std.mem.eql(u8, f.name, name)) return i;
    }
    @compileError("no field named '" ++ name ++ "' in " ++ @typeName(T));
}

/// The type of the field called `name` in struct `T`.
fn FieldType(comptime T: type, comptime name: []const u8) type {
    return std.meta.fields(T)[fieldIndex(T, name)].type;
}

/// A growable vector of `T`, stored in `layout`. `T` must be a struct. Under SoA each field of `T`
/// becomes one column, and under AoS the elements sit in one block.
pub fn Vector(comptime T: type, comptime layout: Layout) type {
    if (@typeInfo(T) != .@"struct") {
        @compileError("Vector needs a struct type, found " ++ @typeName(T));
    }

    return struct {
        const Self = @This();
        const fields = std.meta.fields(T);

        allocator: std.mem.Allocator,
        /// Elements in use. They occupy the first `count` positions of every column, or of the block.
        count: usize,
        /// Elements the storage can hold without growing.
        cap: usize,
        /// The allocation as `allocator` returned it, which `free` needs. `base` is the first usable
        /// byte inside it, aligned for `T`. The two differ when the allocator aligns less than `T` needs.
        raw: []u8,
        base: [*]u8,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .count = 0,
                .cap = 0,
                .raw = &[_]u8{},
                .base = @ptrFromInt(@alignOf(T)),
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.raw);
            self.* = undefined;
        }

        pub fn len(self: *const Self) usize {
            return self.count;
        }

        pub fn capacity(self: *const Self) usize {
            return self.cap;
        }

        /// Makes room for `additional` more elements. Once this succeeds, that many appends cannot fail.
        pub fn reserve(self: *Self, additional: usize) std.mem.Allocator.Error!void {
            const needed = self.count + additional;
            if (needed <= self.cap) return;
            try self.grow(grownCapacity(self.cap, needed));
        }

        pub fn append(self: *Self, value: T) std.mem.Allocator.Error!void {
            try self.reserve(1);
            self.appendAssumeCapacity(value);
        }

        /// Appends without checking for room. Call `reserve` first, or this panics when full.
        pub fn appendAssumeCapacity(self: *Self, value: T) void {
            if (self.count == self.cap) {
                std.debug.panic("vector is full: {d} of {d} elements in use", .{ self.count, self.cap });
            }
            const index = self.count;
            self.count += 1;
            self.set(index, value);
        }

        /// Removes element `index` by moving the last element into its place. That is O(1), but the
        /// last element changes index, so callers that remember indices must update them.
        pub fn swapRemove(self: *Self, index: usize) void {
            self.checkIndex(index);
            const last = self.count - 1;
            inline for (fields, 0..) |_, i| {
                const col = self.fieldColumn(i);
                col.at(index).* = col.at(last).*;
            }
            self.count = last;
        }

        pub fn get(self: *const Self, index: usize) T {
            self.checkIndex(index);
            var value: T = undefined;
            inline for (fields, 0..) |f, i| {
                @field(value, f.name) = self.fieldColumn(i).at(index).*;
            }
            return value;
        }

        pub fn set(self: *Self, index: usize, value: T) void {
            self.checkIndex(index);
            inline for (fields, 0..) |f, i| {
                self.fieldColumn(i).at(index).* = @field(value, f.name);
            }
        }

        /// A view of field `name` across all elements. It works under either layout, so one loop can
        /// serve both. A view is valid until the vector grows, so take it after the appends are done.
        pub fn column(self: *Self, comptime name: []const u8) Column(FieldType(T, name)) {
            const index = comptime fieldIndex(T, name);
            return self.fieldColumn(index);
        }

        /// The contiguous slice of field `name`. Only SoA stores a field contiguously, so this is a
        /// compile error under AoS. Under AoS, use `column`.
        pub fn items(self: *Self, comptime name: []const u8) []FieldType(T, name) {
            if (layout != .soa) {
                @compileError("items() needs the soa layout; under aos use column()");
            }
            const F = FieldType(T, name);
            const index = comptime fieldIndex(T, name);
            const typed: [*]F = @ptrCast(@alignCast(self.fieldColumn(index).base));
            return typed[0..self.count];
        }

        fn checkIndex(self: *const Self, index: usize) void {
            if (index >= self.count) {
                std.debug.panic("index {d} is out of range for {d} elements", .{ index, self.count });
            }
        }

        /// Where field `index` lives. Under AoS the stride skips a whole element, from the field's offset
        /// inside it. Under SoA the field is a contiguous column, stride one field.
        fn fieldColumn(self: *const Self, comptime index: usize) Column(fields[index].type) {
            if (layout == .aos) {
                return .{
                    .base = self.base + @offsetOf(T, fields[index].name),
                    .stride = @sizeOf(T),
                    .len = self.count,
                };
            } else {
                return .{
                    .base = self.base + columnOffset(index, self.cap),
                    .stride = @sizeOf(fields[index].type),
                    .len = self.count,
                };
            }
        }

        /// Byte offset of SoA column `index` from `base`, when storage holds `elements` elements. Each
        /// column starts at its field's alignment, and the columns are packed one after another.
        /// Passing `fields.len` gives the total size of the storage.
        fn columnOffset(comptime index: usize, elements: usize) usize {
            var offset: usize = 0;
            inline for (fields, 0..) |f, i| {
                offset = alignUp(offset, @alignOf(f.type));
                if (i == index) return offset;
                offset += elements * @sizeOf(f.type);
            }
            return offset;
        }

        /// Bytes the storage needs for `elements` elements, before the alignment slack.
        fn totalBytes(elements: usize) usize {
            if (layout == .aos) {
                return elements * @sizeOf(T);
            } else {
                return columnOffset(fields.len, elements);
            }
        }

        /// Moves every element into new storage that holds `new_capacity`. Only the used part is copied.
        fn grow(self: *Self, new_capacity: usize) std.mem.Allocator.Error!void {
            const alignment = @alignOf(T);
            // Allocate slack so the usable base can be moved up to an aligned address.
            const raw = try self.allocator.alloc(u8, totalBytes(new_capacity) + alignment - 1);
            const start = @intFromPtr(raw.ptr);
            const base = raw.ptr + (alignUp(start, alignment) - start);

            if (self.count > 0) {
                if (layout == .aos) {
                    const used = self.count * @sizeOf(T);
                    @memcpy(base[0..used], self.base[0..used]);
                } else {
                    inline for (fields, 0..) |f, i| {
                        const used = self.count * @sizeOf(f.type);
                        const to = base + columnOffset(i, new_capacity);
                        const from = self.base + columnOffset(i, self.cap);
                        @memcpy(to[0..used], from[0..used]);
                    }
                }
            }

            self.allocator.free(self.raw);
            self.raw = raw;
            self.base = base;
            self.cap = new_capacity;
        }
    };
}

/// Covers padding and alignment: a byte, two floats, and an eight-byte integer.
const Body = struct {
    alive: u8,
    x: f32,
    vx: f32,
    id: u64,
};

fn body(id: u64, x: f32, vx: f32) Body {
    return .{ .alive = 1, .x = x, .vx = vx, .id = id };
}

fn expectBody(expected: Body, actual: Body) !void {
    const testing = std.testing;
    try testing.expectEqual(expected.alive, actual.alive);
    try testing.expectEqual(expected.x, actual.x);
    try testing.expectEqual(expected.vx, actual.vx);
    try testing.expectEqual(expected.id, actual.id);
}

fn checkVector(comptime layout: Layout) !void {
    const testing = std.testing;
    var v = Vector(Body, layout).init(testing.allocator);
    defer v.deinit();

    // A hundred appends force several doublings, so the growth copy runs under this layout.
    for (0..100) |i| {
        const id: u64 = @intCast(i);
        try v.append(body(id, @floatFromInt(i), 0.5));
    }
    try testing.expectEqual(@as(usize, 100), v.len());
    try expectBody(body(42, 42, 0.5), v.get(42));

    v.set(42, body(7, -1, 2));
    try expectBody(body(7, -1, 2), v.get(42));
    try expectBody(body(43, 43, 0.5), v.get(43));

    // Removing element 0 moves element 99 into its place and shortens the vector by one.
    v.swapRemove(0);
    try testing.expectEqual(@as(usize, 99), v.len());
    try expectBody(body(99, 99, 0.5), v.get(0));

    // A column reads one field across the elements, and writes land in the same storage.
    const xs = v.column("x");
    for (0..v.len()) |i| {
        xs.at(i).* += 1;
    }
    try expectBody(body(99, 100, 0.5), v.get(0));
    try testing.expectEqual(@as(f32, 44), v.get(43).x);

    if (layout == .soa) {
        const ids = v.items("id");
        try testing.expectEqual(@as(usize, 99), ids.len);
        try testing.expectEqual(@as(u64, 99), ids[0]);
    }

    try v.reserve(1000);
    try testing.expect(v.capacity() >= v.len() + 1000);
    try expectBody(body(43, 44, 0.5), v.get(43));
}

test "vector keeps whole elements and field columns under both layouts" {
    inline for (.{ Layout.aos, Layout.soa }) |layout| {
        try checkVector(layout);
    }
}

test "AoS strides by the element size and SoA by the field size" {
    const testing = std.testing;

    var aos = Vector(Body, .aos).init(testing.allocator);
    defer aos.deinit();
    try aos.append(body(1, 1, 1));
    try aos.append(body(2, 2, 2));
    const ax = aos.column("x");
    try testing.expectEqual(@as(usize, @sizeOf(Body)), @intFromPtr(ax.at(1)) - @intFromPtr(ax.at(0)));

    var soa = Vector(Body, .soa).init(testing.allocator);
    defer soa.deinit();
    try soa.append(body(1, 1, 1));
    try soa.append(body(2, 2, 2));
    const sx = soa.column("x");
    try testing.expectEqual(@as(usize, @sizeOf(f32)), @intFromPtr(sx.at(1)) - @intFromPtr(sx.at(0)));
}

test "SoA columns start at their own alignment" {
    var soa = Vector(Body, .soa).init(std.testing.allocator);
    defer soa.deinit();
    // Capacity is rounded up by growth, so this holds for any count the vector reaches.
    try soa.append(body(1, 1, 1));
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(soa.column("id").at(0)) % @alignOf(u64));
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(soa.column("x").at(0)) % @alignOf(f32));
}
