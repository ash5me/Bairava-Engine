//! Test root for `zig build test`. It holds every unit test. The pure modules need only the
//! compiler. `input` and `renderer` import SDL's C header and the embedded shaders, so this root
//! links SDL and needs slangc. No test opens a window or creates a GPU device.

const std = @import("std");

const c = @import("engine/sdl.zig").c;
const input = @import("engine/input.zig");
const renderer = @import("engine/renderer.zig");
const sprite = @import("engine/sprite.zig");
const Texture = @import("engine/texture.zig").Texture;
const tilemap = @import("engine/tilemap.zig");

test {
    _ = @import("engine/string.zig");
    _ = @import("engine/hash_map.zig");
    _ = @import("engine/assets.zig");
    _ = @import("engine/math.zig");
    _ = @import("engine/view.zig");
}

const Input = input.Input;
const Key = input.Key;

/// SDL's keyboard state has one entry per scancode, so the input tests use an array that size.
const scancode_count: usize = @intCast(c.SDL_SCANCODE_COUNT);
const KeyState = [scancode_count]bool;

/// Each key the engine names, with the SDL scancode it maps to. The first input test checks this
/// table against `Key`, so a key added without an entry fails.
const key_scancodes = [_]struct { key: Key, code: c.SDL_Scancode }{
    .{ .key = .escape, .code = c.SDL_SCANCODE_ESCAPE },
    .{ .key = .left, .code = c.SDL_SCANCODE_LEFT },
    .{ .key = .right, .code = c.SDL_SCANCODE_RIGHT },
    .{ .key = .up, .code = c.SDL_SCANCODE_UP },
    .{ .key = .down, .code = c.SDL_SCANCODE_DOWN },
    .{ .key = .w, .code = c.SDL_SCANCODE_W },
    .{ .key = .a, .code = c.SDL_SCANCODE_A },
    .{ .key = .s, .code = c.SDL_SCANCODE_S },
    .{ .key = .d, .code = c.SDL_SCANCODE_D },
    .{ .key = .i, .code = c.SDL_SCANCODE_I },
};

/// A key event as SDL fills one in. `repeat` marks an auto-repeated key-down.
fn keyEvent(event_type: anytype, code: anytype, repeat: bool) c.SDL_Event {
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = @intCast(event_type);
    event.key.scancode = @intCast(code);
    event.key.repeat = repeat;
    return event;
}

/// A mouse button event as SDL fills one in.
fn buttonEvent(event_type: anytype, button: anytype) c.SDL_Event {
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = @intCast(event_type);
    event.button.button = @intCast(button);
    return event;
}

/// A mouse motion event at a window position, in points.
fn motionEvent(x: f32, y: f32) c.SDL_Event {
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = @intCast(c.SDL_EVENT_MOUSE_MOTION);
    event.motion.x = x;
    event.motion.y = y;
    return event;
}

test "the scancode table lists every key the engine names, once" {
    // Equal counts plus every key appearing means no key is missing and none is listed twice.
    try std.testing.expectEqual(std.enums.values(Key).len, key_scancodes.len);
    for (std.enums.values(Key)) |key| {
        var found = false;
        for (key_scancodes) |entry| {
            if (entry.key == key) found = true;
        }
        try std.testing.expect(found);
    }
}

test "held reads the scancode in the table for each key" {
    // Pressing one table scancode must hold that key and no other.
    for (key_scancodes) |down| {
        var keys: KeyState = [_]bool{false} ** scancode_count;
        keys[@intCast(down.code)] = true;
        const state = Input{ .keys = &keys };
        for (key_scancodes) |other| {
            try std.testing.expectEqual(other.key == down.key, state.held(other.key));
        }
    }
}

test "a key-down for each table scancode presses exactly its key" {
    // This goes through handleEvent, so it checks the engine's own scancode mapping too.
    const keys: KeyState = [_]bool{false} ** scancode_count;
    for (key_scancodes) |down| {
        var state = Input{ .keys = &keys };
        const event = keyEvent(c.SDL_EVENT_KEY_DOWN, down.code, false);
        state.handleEvent(&event);
        state.latch();
        for (key_scancodes) |other| {
            try std.testing.expectEqual(other.key == down.key, state.wasPressed(other.key));
        }
    }
}

test "held follows the keyboard state and needs no event" {
    var keys: KeyState = [_]bool{false} ** scancode_count;
    keys[@intCast(c.SDL_SCANCODE_S)] = true;
    const state = Input{ .keys = &keys };
    try std.testing.expect(state.held(.s));
    // Held is live state. A press only counts once an event has been latched.
    try std.testing.expect(!state.wasPressed(.s));
}

test "a press reaches the update step only after latch, and only once" {
    const keys: KeyState = [_]bool{false} ** scancode_count;
    var state = Input{ .keys = &keys };
    const event = keyEvent(c.SDL_EVENT_KEY_DOWN, c.SDL_SCANCODE_W, false);
    state.handleEvent(&event);
    try std.testing.expect(!state.wasPressed(.w));

    state.latch();
    try std.testing.expect(state.wasPressed(.w));

    // The next update step has no new events, so the press is gone.
    state.latch();
    try std.testing.expect(!state.wasPressed(.w));
}

test "a release reaches the update step only after latch, and only once" {
    const keys: KeyState = [_]bool{false} ** scancode_count;
    var state = Input{ .keys = &keys };
    const event = keyEvent(c.SDL_EVENT_KEY_UP, c.SDL_SCANCODE_S, false);
    state.handleEvent(&event);
    try std.testing.expect(!state.wasReleased(.s));

    state.latch();
    try std.testing.expect(state.wasReleased(.s));

    state.latch();
    try std.testing.expect(!state.wasReleased(.s));
}

test "an auto-repeated key-down is not a new press" {
    // Holding a key makes the OS send repeats. Each one must not count as a fresh press.
    const keys: KeyState = [_]bool{false} ** scancode_count;
    var state = Input{ .keys = &keys };
    const event = keyEvent(c.SDL_EVENT_KEY_DOWN, c.SDL_SCANCODE_W, true);
    state.handleEvent(&event);
    state.latch();
    try std.testing.expect(!state.wasPressed(.w));
}

test "a press and a release in the same frame both reach the next update" {
    const keys: KeyState = [_]bool{false} ** scancode_count;
    var state = Input{ .keys = &keys };
    const down = keyEvent(c.SDL_EVENT_KEY_DOWN, c.SDL_SCANCODE_A, false);
    const up = keyEvent(c.SDL_EVENT_KEY_UP, c.SDL_SCANCODE_A, false);
    state.handleEvent(&down);
    state.handleEvent(&up);
    state.latch();
    try std.testing.expect(state.wasPressed(.a));
    try std.testing.expect(state.wasReleased(.a));
}

test "events from frames with no update wait for the next latch" {
    // A frame with no update step never latches, so its events must survive until one does.
    const keys: KeyState = [_]bool{false} ** scancode_count;
    var state = Input{ .keys = &keys };
    const w_down = keyEvent(c.SDL_EVENT_KEY_DOWN, c.SDL_SCANCODE_W, false);
    const d_down = keyEvent(c.SDL_EVENT_KEY_DOWN, c.SDL_SCANCODE_D, false);
    state.handleEvent(&w_down);
    state.handleEvent(&d_down);
    state.latch();
    try std.testing.expect(state.wasPressed(.w));
    try std.testing.expect(state.wasPressed(.d));

    state.latch();
    try std.testing.expect(!state.wasPressed(.w));
    try std.testing.expect(!state.wasPressed(.d));
}

test "keys the engine does not name are ignored" {
    // Z is not in `Key`, so the event is dropped and no key is reported.
    const keys: KeyState = [_]bool{false} ** scancode_count;
    var state = Input{ .keys = &keys };
    const event = keyEvent(c.SDL_EVENT_KEY_DOWN, c.SDL_SCANCODE_Z, false);
    state.handleEvent(&event);
    state.latch();
    for (std.enums.values(Key)) |key| {
        try std.testing.expect(!state.wasPressed(key));
    }
}

test "anyHeld, anyPressed and anyReleased are true when any listed key matches" {
    var keys: KeyState = [_]bool{false} ** scancode_count;
    keys[@intCast(c.SDL_SCANCODE_LEFT)] = true;
    var state = Input{ .keys = &keys };
    try std.testing.expect(state.anyHeld(&.{ .w, .left }));
    try std.testing.expect(!state.anyHeld(&.{ .w, .d }));
    const none: []const Key = &.{};
    try std.testing.expect(!state.anyHeld(none));

    const d_down = keyEvent(c.SDL_EVENT_KEY_DOWN, c.SDL_SCANCODE_D, false);
    state.handleEvent(&d_down);
    state.latch();
    try std.testing.expect(state.anyPressed(&.{ .w, .d }));
    try std.testing.expect(!state.anyPressed(&.{ .w, .a }));
    try std.testing.expect(!state.anyReleased(&.{ .w, .d }));
}

test "mouse motion updates the position at once, before the next latch" {
    const keys: KeyState = [_]bool{false} ** scancode_count;
    var state = Input{ .keys = &keys };
    const event = motionEvent(120.5, 60.25);
    state.handleEvent(&event);
    try std.testing.expectEqual(@as(f32, 120.5), state.mouse_x);
    try std.testing.expectEqual(@as(f32, 60.25), state.mouse_y);
}

test "a left button press is latched as one click" {
    const keys: KeyState = [_]bool{false} ** scancode_count;
    var state = Input{ .keys = &keys };
    const event = buttonEvent(c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_BUTTON_LEFT);
    state.handleEvent(&event);
    try std.testing.expect(!state.left_clicked);

    state.latch();
    try std.testing.expect(state.left_clicked);

    state.latch();
    try std.testing.expect(!state.left_clicked);
}

test "other buttons and button releases do not count as a left click" {
    const keys: KeyState = [_]bool{false} ** scancode_count;
    var state = Input{ .keys = &keys };
    const right_down = buttonEvent(c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_BUTTON_RIGHT);
    const left_up = buttonEvent(c.SDL_EVENT_MOUSE_BUTTON_UP, c.SDL_BUTTON_LEFT);
    state.handleEvent(&right_down);
    state.handleEvent(&left_up);
    state.latch();
    try std.testing.expect(!state.left_clicked);
}

test "colorTargetInfo clears the target to the given color and keeps the result" {
    var marker: u8 = 0;
    const target: *c.SDL_GPUTexture = @ptrCast(&marker);
    const clear = c.SDL_FColor{ .r = 0.25, .g = 0.5, .b = 0.75, .a = 1.0 };
    const info = renderer.colorTargetInfo(target, clear);

    try std.testing.expect(info.texture == target);
    try std.testing.expectEqual(@as(f32, 0.25), info.clear_color.r);
    try std.testing.expectEqual(@as(f32, 0.5), info.clear_color.g);
    try std.testing.expectEqual(@as(f32, 0.75), info.clear_color.b);
    try std.testing.expectEqual(@as(f32, 1.0), info.clear_color.a);
    // A pass that loaded instead of clearing would draw over the last frame's pixels.
    try std.testing.expect(info.load_op == c.SDL_GPU_LOADOP_CLEAR);
    try std.testing.expect(info.store_op == c.SDL_GPU_STOREOP_STORE);
}

test "colorTargetInfo leaves the fields it does not use at zero" {
    // Zero selects the base mip and layer, with no resolve target and no cycling. Those are the
    // defaults the pass was written against, so a stray value here would change what gets drawn.
    var marker: u8 = 0;
    const target: *c.SDL_GPUTexture = @ptrCast(&marker);
    const info = renderer.colorTargetInfo(target, .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 });
    try std.testing.expectEqual(@as(u32, 0), info.mip_level);
    try std.testing.expectEqual(@as(u32, 0), info.layer_or_depth_plane);
    try std.testing.expect(info.resolve_texture == null);
    try std.testing.expect(!info.cycle);
}

/// A texture for the sprite tests. Sprites read only its size, so the GPU handles stay undefined and
/// are never used.
fn testTexture(width: u32, height: u32) Texture {
    return .{ .device = undefined, .texture = undefined, .sampler = undefined, .width = width, .height = height };
}

/// A sprite batch with no GPU objects. `begin` and `drawSprite` use only the CPU-side fields, so the
/// tests can fill it without a device. Its storage starts empty and grows on the heap.
fn testBatch(no_vertices: *[0]sprite.Vertex, no_batches: *[0]sprite.Batch) sprite.SpriteBatch {
    return .{
        .device = undefined,
        .pipeline = undefined,
        .vertex_buffer = undefined,
        .vb_binding = undefined,
        .upload_buffer = undefined,
        .vertices = no_vertices,
        .batches = no_batches,
    };
}

/// Frees the storage a test batch grew into. A batch that never grew still points at the empty
/// arrays on the test's stack, which have length 0, so they are skipped.
fn freeTestBatch(batch: *sprite.SpriteBatch) void {
    if (batch.vertices.len != 0) std.heap.page_allocator.free(batch.vertices);
    if (batch.batches.len != 0) std.heap.page_allocator.free(batch.batches);
}

test "drawSprite keeps every sprite of a frame, past the old 8192 limit" {
    var no_vertices: [0]sprite.Vertex = .{};
    var no_batches: [0]sprite.Batch = .{};
    var batch = testBatch(&no_vertices, &no_batches);
    defer freeTestBatch(&batch);
    const tex = testTexture(16, 16);
    const quad = sprite.Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };

    batch.begin(320, 180);
    const count: u32 = 9000;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        // Each sprite gets its own tint, so the last vertices can be checked against their sprite.
        const tint = @as(f32, @floatFromInt(i)) / 10000.0;
        batch.drawSprite(&tex, quad, quad, .{ tint, tint, tint });
    }
    try std.testing.expectEqual(count, batch.sprite_count);
    try std.testing.expectEqual(count * 6, batch.vertex_count);
    const last_tint = @as(f32, @floatFromInt(count - 1)) / 10000.0;
    try std.testing.expectApproxEqAbs(last_tint, batch.vertices[batch.vertex_count - 1].color[0], 1e-6);
}

test "drawSprite batches past the old 256 texture-switch limit" {
    var no_vertices: [0]sprite.Vertex = .{};
    var no_batches: [0]sprite.Batch = .{};
    var batch = testBatch(&no_vertices, &no_batches);
    defer freeTestBatch(&batch);
    const tex_a = testTexture(16, 16);
    const tex_b = testTexture(32, 32);
    const quad = sprite.Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };

    batch.begin(320, 180);
    var i: u32 = 0;
    while (i < 600) : (i += 1) {
        // Alternating textures makes every sprite start a new batch.
        const tex = if (i % 2 == 0) &tex_a else &tex_b;
        batch.drawSprite(tex, quad, quad, .{ 1, 1, 1 });
    }
    try std.testing.expectEqual(@as(u32, 600), batch.batch_count);
    var b: u32 = 0;
    while (b < 600) : (b += 1) {
        try std.testing.expectEqual(b * 6, batch.batches[b].first_vertex);
        try std.testing.expectEqual(@as(u32, 6), batch.batches[b].vertex_count);
    }
    try std.testing.expect(batch.batches[599].texture == &tex_b);
}

test "begin starts a new frame but keeps the storage a frame grew" {
    var no_vertices: [0]sprite.Vertex = .{};
    var no_batches: [0]sprite.Batch = .{};
    var batch = testBatch(&no_vertices, &no_batches);
    defer freeTestBatch(&batch);
    const tex = testTexture(16, 16);
    const quad = sprite.Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };

    batch.begin(320, 180);
    var i: u32 = 0;
    while (i < 3000) : (i += 1) batch.drawSprite(&tex, quad, quad, .{ 1, 1, 1 });
    const grown = batch.vertices.len;
    try std.testing.expect(grown >= 3000 * 6);

    // A new frame reuses the grown storage instead of shrinking and growing again.
    batch.begin(320, 180);
    try std.testing.expectEqual(@as(u32, 0), batch.sprite_count);
    try std.testing.expectEqual(@as(u32, 0), batch.batch_count);
    try std.testing.expectEqual(grown, batch.vertices.len);
}

test "a texture with no upload is ready at once" {
    // Only the fence-free path is tested here. Waiting on a real upload needs a GPU.
    const tex = testTexture(16, 16);
    try std.testing.expect(tex.isReady());
}

// ---- Tile maps (engine/tilemap.zig) ----

/// A 6x6 room. Walls form the border, plus one wall at column 3, row 2. Open floor is columns 1 to 4
/// in rows 1 to 4, so the spawn cell (1, 1) is open.
const room_text =
    \\size 6 6
    \\solid 1
    \\spawn 1 1
    \\tiles
    \\1 1 1 1 1 1
    \\1 0 0 0 0 1
    \\1 0 0 1 0 1
    \\1 0 0 0 0 1
    \\1 0 0 0 0 1
    \\1 1 1 1 1 1
;

test "parse reads the header and the tile IDs row by row" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, room_text);
    defer map.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 6), map.cols);
    try std.testing.expectEqual(@as(u32, 6), map.rows);
    try std.testing.expectEqual(@as(u32, 1), map.spawn.col);
    try std.testing.expectEqual(@as(u32, 1), map.spawn.row);
    try std.testing.expect(map.solid[1]);
    try std.testing.expect(!map.solid[0]);
    try std.testing.expectEqual(@as(?u8, 1), map.idAt(3, 2));
    try std.testing.expectEqual(@as(?u8, 0), map.idAt(2, 2));
}

test "parse skips comments and blank lines and accepts CRLF line endings" {
    const allocator = std.testing.allocator;
    const text = "# a comment\r\n\r\nsize 1 2\r\nsolid 1\r\n# spawn comes next\r\nspawn 0 1\r\ntiles\r\n0\r\n1\r\n";
    const map = try tilemap.TileMap.parse(allocator, text);
    defer map.deinit(allocator);
    try std.testing.expectEqual(@as(?u8, 0), map.idAt(0, 0));
    try std.testing.expectEqual(@as(?u8, 1), map.idAt(0, 1));
    try std.testing.expectEqual(@as(u32, 1), map.spawn.row);
}

test "parse rejects malformed maps, and frees what it had allocated" {
    // testing.allocator fails the test if anything is left allocated. So every error after the
    // `tiles` line must free the tile storage.
    const allocator = std.testing.allocator;
    const expectErr = std.testing.expectError;
    try expectErr(error.MissingSize, tilemap.TileMap.parse(allocator, "spawn 0 0\ntiles\n0\n"));
    try expectErr(error.MissingSpawn, tilemap.TileMap.parse(allocator, "size 1 1\ntiles\n0\n"));
    try expectErr(error.MissingTiles, tilemap.TileMap.parse(allocator, "size 1 1\nspawn 0 0\n"));
    try expectErr(error.BadNumber, tilemap.TileMap.parse(allocator, "size 1 1\nspawn 0 0\ntiles\nx\n"));
    try expectErr(error.BadNumber, tilemap.TileMap.parse(allocator, "size 1 1\nspawn 0 0\ntiles\n256\n"));
    try expectErr(error.BadRow, tilemap.TileMap.parse(allocator, "size 2 1\nspawn 0 0\ntiles\n0\n"));
    try expectErr(error.BadRow, tilemap.TileMap.parse(allocator, "size 1 1\nspawn 0 0\ntiles\n0 0\n"));
    try expectErr(error.BadRow, tilemap.TileMap.parse(allocator, "size 1 2\nspawn 0 0\ntiles\n0\n"));
    try expectErr(error.BadRow, tilemap.TileMap.parse(allocator, "size 1 1\nspawn 0 0\ntiles\n0\n0\n"));
    try expectErr(error.SpawnOutside, tilemap.TileMap.parse(allocator, "size 1 1\nspawn 1 0\ntiles\n0\n"));
    try expectErr(error.BadHeader, tilemap.TileMap.parse(allocator, "size 1 1\nspawn 0 0\nlevel 3\ntiles\n0\n"));
    try expectErr(error.BadHeader, tilemap.TileMap.parse(allocator, "size 0 1\nspawn 0 0\ntiles\n"));
}

test "cells outside the map are solid, so the map's edge is a wall" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, room_text);
    defer map.deinit(allocator);
    try std.testing.expect(map.isSolid(-1, 1));
    try std.testing.expect(map.isSolid(6, 1));
    try std.testing.expect(map.isSolid(1, -1));
    try std.testing.expect(map.isSolid(1, 6));
    try std.testing.expect(map.isSolid(3, 2));
    try std.testing.expect(!map.isSolid(1, 1));
}

test "largestId reports the highest tile ID in the map" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, room_text);
    defer map.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), map.largestId());
}

test "a box moves its full distance across open floor" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, room_text);
    defer map.deinit(allocator);
    const moved = map.moveBox(.{ .x = 16, .y = 16, .w = 16, .h = 16 }, 3, 2);
    try std.testing.expectApproxEqAbs(@as(f32, 19), moved.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 18), moved.y, 1e-4);
}

test "a box stops flush against a wall on its right" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, room_text);
    defer map.deinit(allocator);
    // The box covers columns 3 and 4 and is pushed right into the border at column 5.
    const moved = map.moveBox(.{ .x = 48, .y = 16, .w = 16, .h = 16 }, 100, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 64), moved.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 16), moved.y, 1e-4);
}

test "a box stops flush against a wall on its left" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, room_text);
    defer map.deinit(allocator);
    const moved = map.moveBox(.{ .x = 32, .y = 16, .w = 16, .h = 16 }, -100, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 16), moved.x, 1e-4);
}

test "a box moving diagonally into a wall slides along it" {
    // X is blocked by the wall at column 3, row 2. Y is still free, so the box slides down the wall.
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, room_text);
    defer map.deinit(allocator);
    const moved = map.moveBox(.{ .x = 32, .y = 32, .w = 16, .h = 16 }, 20, 20);
    try std.testing.expectApproxEqAbs(@as(f32, 32), moved.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 52), moved.y, 1e-4);
}

test "a box moving down stops flush above a wall" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, room_text);
    defer map.deinit(allocator);
    const moved = map.moveBox(.{ .x = 16, .y = 48, .w = 16, .h = 16 }, 0, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 64), moved.y, 1e-4);
}

test "a box moving up stops flush below a wall" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, room_text);
    defer map.deinit(allocator);
    const moved = map.moveBox(.{ .x = 16, .y = 32, .w = 16, .h = 16 }, 0, -100);
    try std.testing.expectApproxEqAbs(@as(f32, 16), moved.y, 1e-4);
}

test "a box already inside a wall can move out of it" {
    // The box overlaps the wall at column 3, row 2, so the wall's own cells don't stop the move.
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, room_text);
    defer map.deinit(allocator);
    const box = tilemap.Box{ .x = 50, .y = 34, .w = 16, .h = 16 };
    try std.testing.expectApproxEqAbs(@as(f32, 40), map.moveBox(box, -10, 0).x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 60), map.moveBox(box, 10, 0).x, 1e-4);
}

test "a box flush against a wall cannot step into it" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, room_text);
    defer map.deinit(allocator);
    const moved = map.moveBox(.{ .x = 32, .y = 32, .w = 16, .h = 16 }, 0.5, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 32), moved.x, 1e-4);
}
