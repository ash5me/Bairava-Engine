//! FIFO storage for translated platform events exposed to game updates.

const std = @import("std");
const platform = @import("../platform/platform.zig");
const platform_types = @import("../platform/types.zig");

pub const Event = platform.Event;
pub const Reader = opaque {};

pub const Queue = struct {
    allocator: std.mem.Allocator,
    items: []Event = &.{},
    head: usize = 0,
    len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Queue {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Queue) void {
        if (self.items.len != 0) self.allocator.free(self.items);
        self.* = undefined;
    }

    pub fn append(self: *Queue, event: Event) std.mem.Allocator.Error!void {
        if (self.head + self.len == self.items.len and self.head != 0) {
            std.mem.copyForwards(Event, self.items[0..self.len], self.items[self.head..][0..self.len]);
            self.head = 0;
        }
        if (self.len == self.items.len) {
            const new_capacity = if (self.items.len == 0) 16 else std.math.mul(usize, self.items.len, 2) catch return error.OutOfMemory;
            self.items = if (self.items.len == 0)
                try self.allocator.alloc(Event, new_capacity)
            else
                try self.allocator.realloc(self.items, new_capacity);
        }
        self.items[self.head + self.len] = event;
        self.len += 1;
    }

    fn pollNext(self: *Queue) ?Event {
        if (self.len == 0) return null;
        const event = self.items[self.head];
        self.head += 1;
        self.len -= 1;
        if (self.len == 0) self.head = 0;
        return event;
    }

    pub fn reader(self: *Queue) *Reader {
        return @ptrCast(self);
    }

    pub fn count(self: *const Queue) usize {
        return self.len;
    }
};

pub fn poll(reader: *Reader) ?Event {
    const queue: *Queue = @ptrCast(@alignCast(reader));
    return queue.pollNext();
}

test "game event queue preserves FIFO order across append and polling" {
    var queue = Queue.init(std.testing.allocator);
    defer queue.deinit();

    for (0..20) |index| {
        try queue.append(.{ .mouse_motion = .{ .x = @floatFromInt(index), .y = 0 } });
    }
    for (0..7) |index| {
        const event = poll(queue.reader()).?;
        try std.testing.expectEqual(@as(f32, @floatFromInt(index)), event.mouse_motion.x);
    }
    for (20..40) |index| {
        try queue.append(.{ .mouse_motion = .{ .x = @floatFromInt(index), .y = 0 } });
    }
    try std.testing.expectEqual(@as(usize, 33), queue.count());
    for (7..40) |index| {
        const event = poll(queue.reader()).?;
        try std.testing.expectEqual(@as(f32, @floatFromInt(index)), event.mouse_motion.x);
    }
    try std.testing.expect(poll(queue.reader()) == null);
}

test "queued event payloads are copied by value" {
    var queue = Queue.init(std.testing.allocator);
    defer queue.deinit();
    var text = platform_types.TextInput{};
    text.bytes[0] = 'x';
    text.len = 1;
    try queue.append(.{ .text_input = text });
    text.bytes[0] = 'y';
    const queued = poll(queue.reader()).?.text_input;
    try std.testing.expectEqualStrings("x", queued.slice());
}
