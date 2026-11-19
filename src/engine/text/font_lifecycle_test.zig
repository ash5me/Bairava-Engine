//! Lifecycle tests for font ownership. The session's font store owns each font. `Canvas` and `Ui` only borrow it, so
//! deinitializing either one leaves the font alive, and the store releases it once, at shutdown, while the GPU is alive.
//!
//! The releases are counted by a function in place of `FontResource.deinit`, so no GPU object is needed. The session
//! test replaces the two GPU calls shutdown makes, so it needs no device either. The store's own rules (insert owns,
//! destroy releases once, and a failed insert releases the new font) are in font_store.zig.

const std = @import("std");
const c = @import("../ui/c.zig").c;
const ui = @import("../ui/ui.zig");
const lifecycle = @import("../core/lifecycle.zig");
const platform = @import("../platform/platform.zig");
const font_mod = @import("font.zig");
const font_resource = @import("font_resource.zig");
const font_store = @import("font_store.zig");
const fixtures = @import("../test_fixtures.zig");

const testing = std.testing;

/// Steps of shutdown, as the test sees them, in order.
const Step = enum { wait_idle, font_release, device_deinit, wrong_device };

var steps: [16]Step = undefined;
var step_count: usize = 0;
/// The device the session was built with. The fake wait checks that it is the one it was given.
var expected_device: ?*platform.gpu.Device = null;

/// Markers (line heights) of the fonts released so far, in release order.
var released_markers: [8]c_int = undefined;
var released_count: usize = 0;

fn recordStep(step: Step) void {
    steps[step_count] = step;
    step_count += 1;
}

fn countRelease(resource: *font_resource.FontResource) void {
    switch (resource.*) {
        .bfnt_coverage => |f| {
            released_markers[released_count] = f.baked.line_height;
            released_count += 1;
        },
        .msdf => @panic("the lifecycle test holds only bfnt fonts"),
        .bitmap => @panic("the lifecycle test holds only bfnt fonts"),
        .runtime_coverage => @panic("the lifecycle test holds only bfnt fonts"),
    }
    recordStep(.font_release);
    resource.* = undefined;
}

/// How many releases carried `marker`.
fn releasesOf(marker: c_int) usize {
    var n: usize = 0;
    for (released_markers[0..released_count]) |m| {
        if (m == marker) n += 1;
    }
    return n;
}

fn countingStore() !*font_store.FontStore {
    released_count = 0;
    step_count = 0;
    return font_store.createWithRelease(testing.allocator, &countRelease);
}

/// A bitmap font with no GPU object behind it, carrying `marker` as its line height.
fn testFont(marker: c_int) font_mod.Font {
    var baked = std.mem.zeroes(c.ui_font);
    baked.line_height = marker;
    baked.white = .{ .x = 0, .y = 0, .w = 1, .h = 1 };
    return .{ .baked = baked, .texture = fixtures.texture(1, 1) };
}

test "a Canvas deinitialized leaves its font in the store, alive and unreleased" {
    const fonts = try countingStore();
    const handle = try font_store.insertBfnt(fonts, testFont(31));
    var canvas = ui.Canvas.create(testing.allocator, fonts, handle);
    canvas.deinit();

    try testing.expectEqual(@as(usize, 0), released_count);
    try testing.expectEqual(@as(usize, 1), font_store.count(fonts));
    // The store still answers for the handle, so the font is alive.
    try testing.expectEqual(@as(f32, 31), fonts.lineHeight(handle));

    font_store.destroy(fonts);
    try testing.expectEqual(@as(usize, 1), released_count);
    try testing.expectEqual(@as(usize, 1), releasesOf(31));
}

test "a Ui deinitialized leaves its font in the store, alive and unreleased" {
    const fonts = try countingStore();
    const handle = try font_store.insertBfnt(fonts, testFont(32));
    var widgets = ui.Ui.init(testing.allocator, fonts, handle);
    widgets.deinit();

    try testing.expectEqual(@as(usize, 0), released_count);
    try testing.expectEqual(@as(usize, 1), font_store.count(fonts));
    try testing.expectEqual(@as(f32, 32), fonts.lineHeight(handle));

    font_store.destroy(fonts);
    try testing.expectEqual(@as(usize, 1), released_count);
    try testing.expectEqual(@as(usize, 1), releasesOf(32));
}

/// Fake GPU wait: records whether it was given the session's device.
fn fakeWaitIdle(device: *platform.gpu.Device) void {
    recordStep(if (device == expected_device) .wait_idle else .wrong_device);
}

/// Fake device teardown: records that the device went away.
fn fakeDeviceDeinit(_: *platform.gpu.Gpu) void {
    recordStep(.device_deinit);
}

test "shutdown releases the fonts after the GPU is waited on, and before the device is torn down" {
    const fonts = try countingStore();
    // A token stands in for the device. The fakes compare its address and never dereference it.
    var device_token: u8 = 0;

    var session = lifecycle.Session{
        .stopped = false,
        .fonts = fonts,
        .fonts_ready = true,
        .gpu_created = true,
        .gpu_wait_idle = &fakeWaitIdle,
        .gpu_device_deinit = &fakeDeviceDeinit,
    };
    session.gpu.device = @ptrCast(&device_token);
    expected_device = session.gpu.device;
    step_count = 0;

    _ = try font_store.insertBfnt(fonts, testFont(41));
    _ = try font_store.insertBfnt(fonts, testFont(42));
    session.stop();

    // Two fonts are released, both after the wait and both before the device goes. Nothing else happens.
    const expected = [_]Step{ .wait_idle, .font_release, .font_release, .device_deinit };
    try testing.expectEqualSlices(Step, &expected, steps[0..step_count]);
    try testing.expectEqual(@as(usize, 1), releasesOf(41));
    try testing.expectEqual(@as(usize, 1), releasesOf(42));
    try testing.expect(!session.fonts_ready);
    try testing.expect(!session.gpu_created);
}
