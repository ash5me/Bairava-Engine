//! Test root for `zig build test`. It holds every unit test. The pure modules need only the
//! compiler. Renderer tests use SDL GPU structs without opening a window or creating a device, so
//! the test binary links SDL and needs slangc for embedded shaders.

const std = @import("std");

const animation = @import("engine/animation/animation.zig");
const math = @import("engine/core/math.zig");
const camera = @import("engine/renderer/camera.zig");
const sprite = @import("engine/renderer/sprite.zig");
const fixtures = @import("engine/test_fixtures.zig");
const Texture = @import("engine/renderer/texture.zig").Texture;
const tilemap = @import("engine/scene/tilemap.zig");
const physics_queries = @import("engine/physics/queries.zig");

test {
    _ = @import("engine/renderer/renderer.zig");
    _ = @import("engine/renderer/post.zig");
    _ = @import("engine/renderer/render_types.zig");
    _ = @import("engine/core/application.zig");
    _ = @import("engine/renderer/render_graph.zig");
    _ = @import("engine/diagnostics/plots.zig");
    _ = @import("engine/diagnostics/spike_log.zig");
    _ = @import("engine/memory/string.zig");
    _ = @import("engine/profiling/frame_history.zig");
    _ = @import("engine/diagnostics/text.zig");
    _ = @import("engine/diagnostics/debug_draw.zig");
    _ = @import("engine/diagnostics/frame_stats.zig");
    _ = @import("engine/diagnostics/collector.zig");
    _ = @import("engine/diagnostics/console.zig");
    _ = @import("engine/animation/data.zig");
    _ = @import("engine/animation/machine.zig");
    _ = @import("engine/animation/skeleton.zig");
    _ = @import("engine/renderer/skeleton_draw.zig");
    _ = @import("engine/particles.zig");
    _ = @import("game/level_data.zig");
    _ = @import("game/prefab.zig");
    _ = @import("game/save.zig");
    _ = @import("engine/renderer/debug_geometry.zig");
    _ = @import("engine/memory/hash_map.zig");
    _ = @import("engine/assets/registry.zig");
    _ = @import("engine/assets/handle.zig");
    _ = @import("engine/assets/cache.zig");
    _ = @import("engine/assets/staging.zig");
    _ = @import("engine/jobs/jobs.zig");
    _ = @import("engine/script/script.zig");
    _ = @import("engine/assets/validate.zig");
    _ = @import("engine/assets/hot_reload.zig");
    _ = @import("engine/audio/voices.zig");
    _ = @import("engine/audio/spatial.zig");
    _ = @import("engine/audio/audio.zig");
    _ = @import("engine/audio/ima.zig");
    _ = @import("engine/audio/streaming.zig");
    _ = @import("engine/assets/loaders/image.zig");
    _ = @import("engine/assets/loaders/atlas.zig");
    _ = @import("engine/memory/vector.zig");
    _ = @import("engine/ecs/entity.zig");
    _ = @import("engine/core/math.zig");
    _ = @import("engine/core/fixed_timestep.zig");
    _ = @import("engine/core/game_events.zig");
    _ = @import("engine/text/layout.zig");
    _ = @import("engine/core/transform.zig");
    _ = @import("engine/core/allocators.zig");
    _ = @import("engine/renderer/view.zig");
    _ = @import("engine/core/settings.zig");
    _ = @import("engine/renderer/backends/sdl_gpu/shader.zig");
    _ = @import("engine/renderer/backends/sdl_gpu/pass.zig");
    _ = @import("engine/renderer/backends/sdl_gpu/post.zig");
    _ = @import("engine/input/input.zig");
    _ = @import("engine/input/gamepad.zig");
    _ = @import("engine/input/action.zig");
    _ = @import("engine/input/mapping.zig");
    _ = @import("engine/platform/sdl/input.zig");
    _ = @import("engine/platform/sdl/gamepad.zig");
    _ = @import("engine/platform/sdl/audio.zig");
    _ = @import("engine/platform/sdl/init.zig");
    _ = @import("engine/platform/sdl/clock.zig");
    _ = @import("engine/platform/sdl/files.zig");
    _ = @import("engine/logging/log.zig");
    _ = @import("engine/logging/crash.zig");
    _ = @import("engine/core/startup.zig");
    _ = @import("engine/platform/sdl/window.zig");
    _ = @import("engine/physics/shapes.zig");
    _ = @import("engine/physics/collision.zig");
    _ = @import("engine/physics/queries.zig");
    _ = @import("engine/physics/broad_phase.zig");
    _ = @import("engine/assets/manager.zig");
    _ = @import("engine/scene/scene_manager.zig");
    _ = @import("engine/scene/host.zig");
    _ = @import("engine/navigation/grid.zig");
    _ = @import("engine/navigation/pathfind.zig");
    _ = @import("engine/navigation/follow.zig");
    _ = @import("game/enemy_ai.zig");
}

const testTexture = fixtures.texture;
const testBatch = fixtures.batch;
const freeTestBatch = fixtures.freeBatch;

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
        batch.drawSprite(&tex, quad, quad, .{ .tint = .{ tint, tint, tint } });
    }
    try std.testing.expectEqual(count, batch.sprite_count);
    batch.prepare();
    try std.testing.expectEqual(count * 4, batch.vertex_count);
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
        batch.drawSprite(tex, quad, quad, .{});
    }
    batch.prepare();
    try std.testing.expectEqual(@as(u32, 600), batch.batch_count);
    var b: u32 = 0;
    while (b < 600) : (b += 1) {
        try std.testing.expectEqual(b * 4, batch.batches[b].first_vertex);
        try std.testing.expectEqual(@as(u32, 4), batch.batches[b].vertex_count);
    }
    try std.testing.expect(batch.batches[599].texture == &tex_b);
}

test "normal-mapped sprites form their own runs, split by normal map, in draw order" {
    var no_vertices: [0]sprite.Vertex = .{};
    var no_batches: [0]sprite.Batch = .{};
    var batch = testBatch(&no_vertices, &no_batches);
    defer freeTestBatch(&batch);
    const albedo = testTexture(16, 16);
    const map_a = testTexture(16, 16);
    const map_b = testTexture(16, 16);
    const quad = sprite.Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };

    batch.begin(320, 180);
    batch.drawSprite(&albedo, quad, quad, .{ .normal = &map_a });
    batch.drawSprite(&albedo, quad, quad, .{ .normal = &map_b });
    batch.drawSprite(&albedo, quad, quad, .{});
    batch.prepare();

    try std.testing.expectEqual(@as(u32, 3), batch.batch_count);
    try std.testing.expectEqual(@as(?*const Texture, &map_a), batch.batches[0].normal);
    try std.testing.expectEqual(@as(?*const Texture, &map_b), batch.batches[1].normal);
    try std.testing.expectEqual(@as(?*const Texture, null), batch.batches[2].normal);
    try std.testing.expect(batch.has_lit_runs);
}

test "a lit sprite with no normal map samples the flat map, and a plain sprite does not" {
    var no_vertices: [0]sprite.Vertex = .{};
    var no_batches: [0]sprite.Batch = .{};
    var batch = testBatch(&no_vertices, &no_batches);
    defer freeTestBatch(&batch);
    const albedo = testTexture(16, 16);
    const flat = testTexture(1, 1);
    batch.flat_normal = &flat;
    const quad = sprite.Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };

    batch.begin(320, 180);
    batch.drawSprite(&albedo, quad, quad, .{ .lit = true });
    batch.drawSprite(&albedo, quad, quad, .{});
    batch.prepare();

    try std.testing.expectEqual(@as(u32, 2), batch.batch_count);
    try std.testing.expectEqual(@as(?*const Texture, &flat), batch.batches[0].normal);
    try std.testing.expectEqual(@as(?*const Texture, null), batch.batches[1].normal);
    try std.testing.expect(batch.has_lit_runs);
}

test "a batch with no normal maps has no lit runs, so it pushes no lights" {
    var no_vertices: [0]sprite.Vertex = .{};
    var no_batches: [0]sprite.Batch = .{};
    var batch = testBatch(&no_vertices, &no_batches);
    defer freeTestBatch(&batch);
    const albedo = testTexture(16, 16);
    const quad = sprite.Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };

    batch.begin(320, 180);
    batch.drawSprite(&albedo, quad, quad, .{});
    batch.drawSprite(&albedo, quad, quad, .{ .tint = .{ 0.5, 0.5, 0.5 } });
    batch.prepare();

    try std.testing.expectEqual(@as(u32, 1), batch.batch_count);
    try std.testing.expect(!batch.has_lit_runs);
}

test "lights and ambient light are stored for the frame and restored by the next begin" {
    var no_vertices: [0]sprite.Vertex = .{};
    var no_batches: [0]sprite.Batch = .{};
    var batch = testBatch(&no_vertices, &no_batches);
    defer freeTestBatch(&batch);

    batch.begin(320, 180);
    batch.setAmbient(.{ 0.2, 0.2, 0.3 });
    batch.addLight(.{ .x = 40, .y = 30, .radius = 64, .color = .{ 1, 0.5, 0 }, .intensity = 2 });
    batch.addShadowSegment(.{ .start = .{ 30, 20 }, .end = .{ 50, 20 } });
    try std.testing.expectEqual(@as(u32, 1), batch.light_count);
    try std.testing.expectEqual(@as(u32, 1), batch.shadow_segment_count);
    try std.testing.expectEqual(@as(f32, 1), batch.lighting.info[0]);
    try std.testing.expectEqual(@as(f32, 1), batch.lighting.info[1]);
    try std.testing.expectEqual(@as(f32, 40), batch.lighting.position[0][0]);
    try std.testing.expectEqual(@as(f32, 64), batch.lighting.position[0][3]);
    try std.testing.expectEqual(@as(f32, 0.5), batch.lighting.color[0][1]);
    try std.testing.expectEqual(@as(f32, 2), batch.lighting.color[0][3]);
    try std.testing.expectEqual([4]f32{ 30, 20, 50, 20 }, batch.lighting.shadow_segment[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), batch.lighting.ambient[0], 1e-6);

    batch.begin(320, 180);
    try std.testing.expectEqual(@as(u32, 0), batch.light_count);
    try std.testing.expectEqual(@as(u32, 0), batch.shadow_segment_count);
    try std.testing.expectEqual(@as(f32, 0), batch.lighting.info[0]);
    try std.testing.expectEqual(@as(f32, 0), batch.lighting.info[1]);
    try std.testing.expectEqual(@as(f32, 1), batch.lighting.ambient[0]);
}

test "a flipped sprite mirrors its normal map's x or y, and a turned sprite turns them" {
    var no_vertices: [0]sprite.Vertex = .{};
    var no_batches: [0]sprite.Batch = .{};
    var batch = testBatch(&no_vertices, &no_batches);
    defer freeTestBatch(&batch);
    const tex = testTexture(16, 16);
    const quad = sprite.Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };

    batch.begin(320, 180);
    batch.drawSprite(&tex, quad, quad, .{ .flip_x = true });
    batch.drawSprite(&tex, quad, quad, .{ .rotation = std.math.pi / 2.0 });
    batch.drawSprite(&tex, quad, quad, .{});
    batch.prepare();

    // The three quads share z 0, so they keep the order they were added in. Each quad's corners share one basis.
    try expectBasis(batch.vertices[sprite.indexValue(0, 0)].normal_basis, .{ -1, 0, 0, 1 });
    try expectBasis(batch.vertices[sprite.indexValue(1, 2)].normal_basis, .{ 0, -1, 1, 0 });
    try expectBasis(batch.vertices[sprite.indexValue(2, 1)].normal_basis, .{ 1, 0, 0, 1 });
}

fn expectBasis(actual: [4]f32, expected: [4]f32) !void {
    for (expected, 0..) |value, i| {
        try std.testing.expectApproxEqAbs(value, actual[i], 1e-6);
    }
}

/// Checks the six corners that the index buffer names for quad `q` against the texel rectangle the
/// quad was drawn with. It follows the GPU's path: index buffer entry, then vertex, then UV. A quad
/// whose indices name another quad's vertices fails here.
fn expectQuadUvs(batch: *const sprite.SpriteBatch, q: usize, src: sprite.Rect, tex_w: f32, tex_h: f32) !void {
    const u_left = src.x / tex_w;
    const v_top = src.y / tex_h;
    const u_right = (src.x + src.w) / tex_w;
    const v_bottom = (src.y + src.h) / tex_h;
    // Top-left, bottom-left, bottom-right, then top-left, bottom-right, top-right.
    const expected = [6][2]f32{
        .{ u_left, v_top }, .{ u_left, v_bottom },  .{ u_right, v_bottom },
        .{ u_left, v_top }, .{ u_right, v_bottom }, .{ u_right, v_top },
    };
    for (expected, 0..) |uv, k| {
        const corner = batch.vertices[sprite.indexValue(q, k)];
        try std.testing.expectApproxEqAbs(uv[0], corner.uv[0], 1e-6);
        try std.testing.expectApproxEqAbs(uv[1], corner.uv[1], 1e-6);
    }
}

test "each quad's indices name its own four vertices, in a batch with many quads" {
    var no_vertices: [0]sprite.Vertex = .{};
    var no_batches: [0]sprite.Batch = .{};
    var batch = testBatch(&no_vertices, &no_batches);
    defer freeTestBatch(&batch);
    const tex = testTexture(48, 16);
    const dst = sprite.Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };

    // Three quads, each showing a different part of the texture, all in one batch.
    batch.begin(320, 180);
    var srcs: [3]sprite.Rect = undefined;
    for (&srcs, 0..) |*src, q| {
        src.* = .{ .x = @floatFromInt(q * 16), .y = 0, .w = 16, .h = 16 };
        batch.drawSprite(&tex, src.*, dst, .{});
    }
    batch.prepare();
    try std.testing.expectEqual(@as(u32, 1), batch.batch_count);
    for (srcs, 0..) |src, q| try expectQuadUvs(&batch, q, src, 48, 16);
}

test "quads in later batches name their own vertices too" {
    var no_vertices: [0]sprite.Vertex = .{};
    var no_batches: [0]sprite.Batch = .{};
    var batch = testBatch(&no_vertices, &no_batches);
    defer freeTestBatch(&batch);
    const tex_a = testTexture(48, 16);
    const tex_b = testTexture(32, 32);
    const dst = sprite.Rect{ .x = 0, .y = 0, .w = 8, .h = 8 };

    // Alternating textures gives every quad its own batch, so each batch starts at a later vertex.
    batch.begin(320, 180);
    var srcs: [6]sprite.Rect = undefined;
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const tex = if (i % 2 == 0) &tex_a else &tex_b;
        srcs[i] = .{ .x = @floatFromInt(i * 8), .y = 0, .w = 8, .h = 8 };
        batch.drawSprite(tex, srcs[i], dst, .{});
    }
    batch.prepare();
    try std.testing.expectEqual(@as(u32, 6), batch.batch_count);
    for (srcs, 0..) |src, q| {
        const w: f32 = if (q % 2 == 0) 48 else 32;
        const h: f32 = if (q % 2 == 0) 16 else 32;
        try expectQuadUvs(&batch, q, src, w, h);
    }
}

/// Checks that a two-value point (a position or a UV) matches, within a small tolerance.
fn expectNear2(expected: [2]f32, actual: [2]f32) !void {
    try std.testing.expectApproxEqAbs(expected[0], actual[0], 1e-5);
    try std.testing.expectApproxEqAbs(expected[1], actual[1], 1e-5);
}

test "default options place the corners on the destination rectangle" {
    var no_vertices: [0]sprite.Vertex = .{};
    var no_batches: [0]sprite.Batch = .{};
    var batch = testBatch(&no_vertices, &no_batches);
    defer freeTestBatch(&batch);
    const tex = testTexture(16, 16);
    const quad = sprite.Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };
    const dst = sprite.Rect{ .x = 32, .y = 24, .w = 16, .h = 16 };

    batch.begin(320, 180);
    batch.drawSprite(&tex, quad, dst, .{});
    batch.prepare();
    try expectNear2(math.transformPoint(&batch.projection, 32, 24), batch.vertices[0].pos);
    try expectNear2(math.transformPoint(&batch.projection, 48, 40), batch.vertices[2].pos);
}

test "flip mirrors the texture coordinates" {
    var no_vertices: [0]sprite.Vertex = .{};
    var no_batches: [0]sprite.Batch = .{};
    var batch = testBatch(&no_vertices, &no_batches);
    defer freeTestBatch(&batch);
    const tex = testTexture(16, 16);
    const quad = sprite.Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };

    batch.begin(320, 180);
    batch.drawSprite(&tex, quad, quad, .{ .flip_x = true, .flip_y = true });
    batch.prepare();
    // Both axes flipped: the top-left corner shows the texture's bottom-right, and the top-right
    // corner shows its bottom-left.
    try expectNear2(.{ 1, 1 }, batch.vertices[0].uv);
    try expectNear2(.{ 0, 1 }, batch.vertices[3].uv);
}

test "rotation turns the sprite clockwise around its origin" {
    var no_vertices: [0]sprite.Vertex = .{};
    var no_batches: [0]sprite.Batch = .{};
    var batch = testBatch(&no_vertices, &no_batches);
    defer freeTestBatch(&batch);
    const tex = testTexture(16, 16);
    const quad = sprite.Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };
    const dst = sprite.Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };

    batch.begin(320, 180);
    batch.drawSprite(&tex, quad, dst, .{ .rotation = std.math.pi / 2.0 });
    batch.prepare();
    // A quarter turn clockwise about the top-left corner: the top-right corner moves below the origin,
    // and the bottom-left corner moves to its left. The order is top-left, bottom-left, bottom-right,
    // top-right.
    try expectNear2(math.transformPoint(&batch.projection, 0, 0), batch.vertices[0].pos);
    try expectNear2(math.transformPoint(&batch.projection, -16, 0), batch.vertices[1].pos);
    try expectNear2(math.transformPoint(&batch.projection, -16, 16), batch.vertices[2].pos);
    try expectNear2(math.transformPoint(&batch.projection, 0, 16), batch.vertices[3].pos);
}

test "the origin stays where it is while the sprite turns" {
    var no_vertices: [0]sprite.Vertex = .{};
    var no_batches: [0]sprite.Batch = .{};
    var batch = testBatch(&no_vertices, &no_batches);
    defer freeTestBatch(&batch);
    const tex = testTexture(16, 16);
    const quad = sprite.Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };
    const dst = sprite.Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };

    batch.begin(320, 180);
    batch.drawSprite(&tex, quad, dst, .{ .origin = .{ 8, 8 }, .rotation = 0.7 });
    batch.prepare();
    // A rotation about the middle of the sprite keeps the middle in place, so the four corners
    // average to the origin.
    var sum = [2]f32{ 0, 0 };
    for (0..4) |k| {
        sum[0] += batch.vertices[k].pos[0];
        sum[1] += batch.vertices[k].pos[1];
    }
    try expectNear2(math.transformPoint(&batch.projection, 8, 8), .{ sum[0] / 4, sum[1] / 4 });
}

test "alpha goes into the vertex color, next to the tint" {
    var no_vertices: [0]sprite.Vertex = .{};
    var no_batches: [0]sprite.Batch = .{};
    var batch = testBatch(&no_vertices, &no_batches);
    defer freeTestBatch(&batch);
    const tex = testTexture(16, 16);
    const quad = sprite.Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };

    batch.begin(320, 180);
    batch.drawSprite(&tex, quad, quad, .{ .tint = .{ 0.5, 0.25, 1 }, .alpha = 0.25 });
    batch.prepare();
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), batch.vertices[0].color[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), batch.vertices[0].color[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), batch.vertices[0].color[2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), batch.vertices[0].color[3], 1e-6);
}

test "sprites draw in z order, and equal z keeps the order they were added" {
    var no_vertices: [0]sprite.Vertex = .{};
    var no_batches: [0]sprite.Batch = .{};
    var batch = testBatch(&no_vertices, &no_batches);
    defer freeTestBatch(&batch);
    const tex = testTexture(16, 16);
    const quad = sprite.Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };

    batch.begin(320, 180);
    // The tint marks each sprite. The first one added has the highest z, so it draws last.
    batch.drawSprite(&tex, quad, quad, .{ .tint = .{ 0.1, 0.1, 0.1 }, .z = 1 });
    batch.drawSprite(&tex, quad, quad, .{ .tint = .{ 0.2, 0.2, 0.2 }, .z = 0 });
    batch.drawSprite(&tex, quad, quad, .{ .tint = .{ 0.3, 0.3, 0.3 }, .z = 0 });
    batch.prepare();
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), batch.vertices[0].color[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), batch.vertices[4].color[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), batch.vertices[8].color[0], 1e-6);
    // All three share a texture, so they still draw as one batch.
    try std.testing.expectEqual(@as(u32, 1), batch.batch_count);
}

test "the z sort orders many sprites, with ties in the order they were added" {
    var no_vertices: [0]sprite.Vertex = .{};
    var no_batches: [0]sprite.Batch = .{};
    var batch = testBatch(&no_vertices, &no_batches);
    defer freeTestBatch(&batch);
    const tex = testTexture(16, 16);
    const quad = sprite.Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };
    const count: u32 = 300;

    // A fixed pseudo-random sequence gives each sprite a z from 0 to 5. The tint records the
    // insertion index in red and the z in green, so the sorted order can be read from the vertices.
    batch.begin(320, 180);
    var seed: u32 = 12345;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        seed = seed *% 1664525 +% 1013904223;
        const z: i32 = @intCast((seed >> 16) % 6);
        const index_tint = @as(f32, @floatFromInt(i)) / 1000.0;
        const z_tint = @as(f32, @floatFromInt(z)) / 10.0;
        batch.drawSprite(&tex, quad, quad, .{ .tint = .{ index_tint, z_tint, 0 }, .z = z });
    }
    batch.prepare();

    // Read the quads back in draw order. Z must never drop, and within one z the insertion index
    // must rise.
    var prev_z: f32 = -1;
    var prev_index: f32 = -1;
    var q: u32 = 0;
    while (q < count) : (q += 1) {
        const color = batch.vertices[q * 4].color;
        const index = @round(color[0] * 1000);
        const z = @round(color[1] * 10);
        if (q > 0) {
            try std.testing.expect(z >= prev_z);
            if (z == prev_z) try std.testing.expect(index > prev_index);
        }
        prev_z = z;
        prev_index = index;
    }
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
    while (i < 3000) : (i += 1) batch.drawSprite(&tex, quad, quad, .{});
    batch.prepare();
    const grown = batch.vertices.len;
    try std.testing.expect(grown >= 3000 * 4);

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

// ---- Tile maps (engine/scene/tilemap.zig) ----

/// A 6x6 room. Walls form the border, plus one wall at column 3, row 2. Open floor is columns 1 to 4
/// in rows 1 to 4, so cell (1, 1) is open.
const room_text =
    \\size 6 6
    \\solid 1
    \\layer ground
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
    try std.testing.expect(map.solid[1]);
    try std.testing.expect(!map.solid[0]);
    try std.testing.expectEqual(@as(?u8, 1), map.idAt(.ground, 3, 2));
    try std.testing.expectEqual(@as(?u8, 0), map.idAt(.ground, 2, 2));
    try std.testing.expectEqual(@as(?u8, null), map.idAt(.ground, 6, 2));
}

test "parse skips comments and blank lines and accepts CRLF line endings" {
    const allocator = std.testing.allocator;
    const text = "# a comment\r\n\r\nsize 1 2\r\nsolid 1\r\nlayer ground\r\n0\r\n1\r\n";
    const map = try tilemap.TileMap.parse(allocator, text);
    defer map.deinit(allocator);
    try std.testing.expectEqual(@as(?u8, 0), map.idAt(.ground, 0, 0));
    try std.testing.expectEqual(@as(?u8, 1), map.idAt(.ground, 0, 1));
}

test "versioned maps validate tile IDs against the declared tileset" {
    const allocator = std.testing.allocator;
    const text = "version 1\nsize 1 1\ntileset 2\nsolid 1\nlayer ground\n1\n";
    const map = try tilemap.TileMap.parse(allocator, text);
    defer map.deinit(allocator);
    try std.testing.expectEqual(@as(?u32, 2), map.tileset_count);

    try std.testing.expectError(
        error.TileOutsideTileset,
        tilemap.TileMap.parse(allocator, "version 1\nsize 1 1\ntileset 1\nsolid 1\nlayer ground\n0\n"),
    );
    try std.testing.expectError(
        error.UnsupportedVersion,
        tilemap.TileMap.parse(allocator, "version 2\nsize 1 1\nlayer ground\n0\n"),
    );
    try std.testing.expectError(
        error.BadHeader,
        tilemap.TileMap.parse(allocator, "size 1 1\nsize 1 1\nlayer ground\n0\n"),
    );
    try std.testing.expectError(
        error.InvalidDimensions,
        tilemap.TileMap.parse(allocator, "size 4294967295 4294967295\nlayer ground\n"),
    );
}

test "each layer keeps its own tiles, in any order, and a dot is an empty cell" {
    const allocator = std.testing.allocator;
    const text =
        \\size 2 1
        \\layer decoration
        \\. 5
        \\layer ground
        \\0 0
    ;
    const map = try tilemap.TileMap.parse(allocator, text);
    defer map.deinit(allocator);
    try std.testing.expectEqual(@as(?u8, 0), map.idAt(.ground, 0, 0));
    try std.testing.expectEqual(@as(?u8, null), map.idAt(.decoration, 0, 0));
    try std.testing.expectEqual(@as(?u8, 5), map.idAt(.decoration, 1, 0));
    // A layer the file leaves out is empty everywhere.
    try std.testing.expectEqual(@as(?u8, null), map.idAt(.foreground, 1, 0));
}

test "a solid tile on any layer blocks its cell" {
    const allocator = std.testing.allocator;
    const text =
        \\size 3 1
        \\solid 7
        \\layer ground
        \\0 0 0
        \\layer decoration
        \\. 7 .
    ;
    const map = try tilemap.TileMap.parse(allocator, text);
    defer map.deinit(allocator);
    try std.testing.expect(!map.isSolid(0, 0));
    try std.testing.expect(map.isSolid(1, 0));
    try std.testing.expect(!map.isSolid(2, 0));
}

test "parse rejects malformed maps, and frees what it had allocated" {
    // testing.allocator fails the test if anything is left allocated. So every error after the
    // first `layer` line must free the tile storage.
    const allocator = std.testing.allocator;
    const expectErr = std.testing.expectError;
    try expectErr(error.MissingSize, tilemap.TileMap.parse(allocator, "layer ground\n0\n"));
    try expectErr(error.MissingLayer, tilemap.TileMap.parse(allocator, "size 1 1\n"));
    try expectErr(error.BadNumber, tilemap.TileMap.parse(allocator, "size 1 1\nlayer ground\nx\n"));
    try expectErr(error.BadNumber, tilemap.TileMap.parse(allocator, "size 1 1\nlayer ground\n256\n"));
    try expectErr(error.BadNumber, tilemap.TileMap.parse(allocator, "size 1 1\nlayer ground\n255\n"));
    try expectErr(error.BadRow, tilemap.TileMap.parse(allocator, "size 2 1\nlayer ground\n0\n"));
    try expectErr(error.BadRow, tilemap.TileMap.parse(allocator, "size 1 1\nlayer ground\n0 0\n"));
    try expectErr(error.BadRow, tilemap.TileMap.parse(allocator, "size 1 2\nlayer ground\n0\n"));
    try expectErr(error.BadRow, tilemap.TileMap.parse(allocator, "size 1 1\nlayer ground\n0\n0\n"));
    try expectErr(error.BadRow, tilemap.TileMap.parse(allocator, "size 1 1\nlayer ground\nlayer decoration\n0\n"));
    try expectErr(error.BadRow, tilemap.TileMap.parse(allocator, "size 1 1\nlayer ground\n0\nlayer decoration\n"));
    try expectErr(error.BadHeader, tilemap.TileMap.parse(allocator, "size 1 1\nlevel 3\nlayer ground\n0\n"));
    try expectErr(error.BadHeader, tilemap.TileMap.parse(allocator, "size 1 1\n0\nlayer ground\n0\n"));
    try expectErr(error.BadHeader, tilemap.TileMap.parse(allocator, "size 0 1\nlayer ground\n"));
    try expectErr(error.BadHeader, tilemap.TileMap.parse(allocator, "size 1 1\nlayer sky\n0\n"));
    try expectErr(error.BadHeader, tilemap.TileMap.parse(allocator, "size 1 1\nlayer ground\n0\nlayer ground\n0\n"));
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

test "largestId reports the highest tile ID in the map, and ignores empty cells" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, room_text);
    defer map.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), map.largestId());

    const sparse = try tilemap.TileMap.parse(allocator, "size 2 1\nlayer foreground\n. 3\n");
    defer sparse.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 3), sparse.largestId());
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

test "a box covering a solid cell overlaps it, and one flush against it does not" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, room_text);
    defer map.deinit(allocator);
    // The wall at column 3, row 2 spans x 48 to 64 and y 32 to 48.
    try std.testing.expect(map.boxOverlapsSolid(.{ .x = 48, .y = 32, .w = 16, .h = 16 }));
    try std.testing.expect(map.boxOverlapsSolid(.{ .x = 47, .y = 31, .w = 16, .h = 16 }));
    // Flush against the wall's left edge, and against its bottom edge: no overlap.
    try std.testing.expect(!map.boxOverlapsSolid(.{ .x = 32, .y = 32, .w = 16, .h = 16 }));
    try std.testing.expect(!map.boxOverlapsSolid(.{ .x = 48, .y = 48, .w = 16, .h = 16 }));
}

test "a box past the edge of the map overlaps, since cells outside the map are solid" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, room_text);
    defer map.deinit(allocator);
    try std.testing.expect(map.boxOverlapsSolid(.{ .x = -4, .y = 16, .w = 16, .h = 16 }));
    // The spawn cell (1, 1) is open floor.
    try std.testing.expect(!map.boxOverlapsSolid(.{ .x = 16, .y = 16, .w = 16, .h = 16 }));
}

test "a box flush against a wall cannot step into it" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, room_text);
    defer map.deinit(allocator);
    const moved = map.moveBox(.{ .x = 32, .y = 32, .w = 16, .h = 16 }, 0.5, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 32), moved.x, 1e-4);
}

test "generic movement against solid-tile colliders matches the tile map's own movement" {
    const allocator = std.testing.allocator;
    const map = try tilemap.TileMap.parse(allocator, room_text);
    defer map.deinit(allocator);

    // Every solid cell, plus a ring around the map. Cells outside the map are solid for the tile map too.
    const cols: i32 = @intCast(map.cols);
    const rows: i32 = @intCast(map.rows);
    const capacity = @as(usize, @intCast(cols + 2)) * @as(usize, @intCast(rows + 2));
    const walls = try allocator.alloc(physics_queries.Collider, capacity);
    defer allocator.free(walls);
    var count: usize = 0;
    var row: i32 = -1;
    while (row <= rows) : (row += 1) {
        var col: i32 = -1;
        while (col <= cols) : (col += 1) {
            if (!map.isSolid(col, row)) continue;
            walls[count] = .{
                .box = .{
                    .x = @as(f32, @floatFromInt(col)) * tilemap.tile_px,
                    .y = @as(f32, @floatFromInt(row)) * tilemap.tile_px,
                    .w = tilemap.tile_px,
                    .h = tilemap.tile_px,
                },
                .layer = 1,
            };
            count += 1;
        }
    }
    const colliders = walls[0..count];

    const cases = [_]struct { box: tilemap.Box, dx: f32, dy: f32 }{
        .{ .box = .{ .x = 16, .y = 16, .w = 16, .h = 16 }, .dx = 3, .dy = 2 },
        .{ .box = .{ .x = 48, .y = 16, .w = 16, .h = 16 }, .dx = 100, .dy = 0 },
        .{ .box = .{ .x = 32, .y = 16, .w = 16, .h = 16 }, .dx = -100, .dy = 0 },
        .{ .box = .{ .x = 32, .y = 32, .w = 16, .h = 16 }, .dx = 20, .dy = 20 },
        .{ .box = .{ .x = 16, .y = 48, .w = 16, .h = 16 }, .dx = 0, .dy = 100 },
        .{ .box = .{ .x = 16, .y = 32, .w = 16, .h = 16 }, .dx = 0, .dy = -100 },
        .{ .box = .{ .x = 50, .y = 34, .w = 16, .h = 16 }, .dx = -10, .dy = 0 },
        .{ .box = .{ .x = 50, .y = 34, .w = 16, .h = 16 }, .dx = 10, .dy = 0 },
        .{ .box = .{ .x = 32, .y = 32, .w = 16, .h = 16 }, .dx = 0.5, .dy = 0 },
    };
    for (cases) |c| {
        const expected = map.moveBox(c.box, c.dx, c.dy);
        const actual = physics_queries.moveBox(colliders, c.box, c.dx, c.dy, physics_queries.all_layers);
        try std.testing.expectApproxEqAbs(expected.x, actual.x, 1e-4);
        try std.testing.expectApproxEqAbs(expected.y, actual.y, 1e-4);
    }
}

test "follow centers the view and clamps it inside the world" {
    var cam = camera.Camera{ .view_w = 40, .view_h = 40, .world_w = 100, .world_h = 100 };
    cam.follow(50, 50);
    try std.testing.expectEqual(@as(f32, 30), cam.x);
    try std.testing.expectEqual(@as(f32, 30), cam.y);
    cam.follow(5, 99);
    try std.testing.expectEqual(@as(f32, 0), cam.x);
    try std.testing.expectEqual(@as(f32, 60), cam.y);
}

test "the first followSmooth places the camera at once, so the view doesn't glide in" {
    var cam = camera.Camera{ .view_w = 40, .view_h = 40, .world_w = 100, .world_h = 100 };
    cam.followSmooth(50, 50, 1.0 / 60.0, 10);
    try std.testing.expectEqual(@as(f32, 30), cam.x);
    try std.testing.expectEqual(@as(f32, 30), cam.y);
}

test "followSmooth eases toward the target and gets there over time" {
    var cam = camera.Camera{ .view_w = 40, .view_h = 40, .world_w = 1000, .world_h = 1000 };
    cam.follow(0, 0);
    // A target at 500 centers the view at 480.
    cam.followSmooth(500, 500, 1.0 / 60.0, 10);
    try std.testing.expect(cam.x > 0 and cam.x < 480);
    var i: u32 = 0;
    while (i < 600) : (i += 1) cam.followSmooth(500, 500, 1.0 / 60.0, 10);
    try std.testing.expectApproxEqAbs(@as(f32, 480), cam.x, 0.01);
}

test "followSmooth covers the same distance at any frame rate" {
    var slow = camera.Camera{ .view_w = 40, .view_h = 40, .world_w = 1000, .world_h = 1000 };
    var fast = slow;
    slow.follow(0, 0);
    fast.follow(0, 0);
    var i: u32 = 0;
    while (i < 30) : (i += 1) slow.followSmooth(500, 500, 1.0 / 30.0, 6);
    i = 0;
    while (i < 120) : (i += 1) fast.followSmooth(500, 500, 1.0 / 120.0, 6);
    try std.testing.expectApproxEqAbs(slow.x, fast.x, 1e-3);
}

test "the camera keeps fractions, and screenX rounds once from them" {
    var cam = camera.Camera{ .view_w = 320, .view_h = 180, .world_w = 1000, .world_h = 1000 };
    cam.x = 10.5;
    try std.testing.expectEqual(@as(f32, 11), cam.screenX(21.0));
    try std.testing.expectEqual(@as(f32, 10), cam.screenX(20.4));
}

test "a sprite that keeps pace with the camera stays on one pixel" {
    // The sprite and the camera both move 0.37 px per step, and the sprite sits 16.3 px right of the
    // camera's left edge. Rounding the camera and the sprite separately would step the sprite by a
    // pixel now and then.
    var cam = camera.Camera{ .view_w = 320, .view_h = 180, .world_w = 4000, .world_h = 180 };
    var sprite_x: f32 = 100;
    cam.x = sprite_x - 16.3;
    const first = cam.screenX(sprite_x);
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        sprite_x += 0.37;
        cam.x += 0.37;
        try std.testing.expectEqual(first, cam.screenX(sprite_x));
    }
}

test "a rate of zero snaps the camera to its target" {
    var cam = camera.Camera{ .view_w = 40, .view_h = 40, .world_w = 1000, .world_h = 1000 };
    cam.follow(0, 0);
    cam.followSmooth(500, 500, 1.0 / 60.0, 0);
    try std.testing.expectEqual(@as(f32, 480), cam.x);
}

test "a zoomed-in view is clamped inside the world at its smaller size" {
    // At zoom 2 the view is 160x90 in a 320x180 world, so its corner can reach at most (160, 90).
    var cam = camera.Camera{ .view_w = 160, .view_h = 90, .world_w = 320, .world_h = 180 };
    cam.follow(300, 170);
    try std.testing.expectEqual(@as(f32, 160), cam.x);
    try std.testing.expectEqual(@as(f32, 90), cam.y);
}

test "approachZoom eases toward the target and reaches it" {
    var cam = camera.Camera{ .view_w = 320, .view_h = 180, .world_w = 1000, .world_h = 1000 };
    cam.approachZoom(2.0, 1.0 / 60.0, 8);
    try std.testing.expect(cam.zoom > 1 and cam.zoom < 2);
    var i: u32 = 0;
    while (i < 600) : (i += 1) cam.approachZoom(2.0, 1.0 / 60.0, 8);
    try std.testing.expectApproxEqAbs(@as(f32, 2), cam.zoom, 1e-4);
}

test "approachZoom covers the same distance at any frame rate" {
    var slow = camera.Camera{ .view_w = 320, .view_h = 180, .world_w = 1000, .world_h = 1000 };
    var fast = slow;
    var i: u32 = 0;
    while (i < 30) : (i += 1) slow.approachZoom(3.0, 1.0 / 30.0, 6);
    i = 0;
    while (i < 120) : (i += 1) fast.approachZoom(3.0, 1.0 / 120.0, 6);
    try std.testing.expectApproxEqAbs(slow.zoom, fast.zoom, 1e-3);
}

test "approachZoom covers the same ratio in the same time at any starting zoom" {
    // Going from 1x to 2x and from 2x to 4x is the same ratio, so after the same time the second
    // camera is exactly twice the first.
    var from_one = camera.Camera{ .view_w = 320, .view_h = 180, .world_w = 1000, .world_h = 1000 };
    var from_two = from_one;
    from_two.zoom = 2.0;
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        from_one.approachZoom(2.0, 1.0 / 60.0, 8);
        from_two.approachZoom(4.0, 1.0 / 60.0, 8);
    }
    try std.testing.expectApproxEqAbs(from_one.zoom * 2.0, from_two.zoom, 1e-4);
}

test "a zoom rate of zero snaps to the target" {
    var cam = camera.Camera{ .view_w = 320, .view_h = 180, .world_w = 1000, .world_h = 1000 };
    cam.approachZoom(0.5, 1.0 / 60.0, 0);
    try std.testing.expectEqual(@as(f32, 0.5), cam.zoom);
}

test "zoomTarget multiplies the target and keeps it within the bounds" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.25), camera.Camera.zoomTarget(1.0, 1.25, 0.5, 4.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), camera.Camera.zoomTarget(3.5, 1.25, 0.5, 4.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), camera.Camera.zoomTarget(0.5, 0.8, 0.5, 4.0), 1e-6);
}

const walk_clip = animation.Clip{ .row = 2, .frame_count = 4, .frame_time = 0.25, .looping = true };

test "an animator advances one frame each frame_time" {
    var anim = animation.Animator.init(walk_clip);
    try std.testing.expectEqual(@as(u32, 0), anim.frame());
    anim.update(0.25);
    try std.testing.expectEqual(@as(u32, 1), anim.frame());
    anim.update(0.25);
    try std.testing.expectEqual(@as(u32, 2), anim.frame());
}

test "a looping clip starts over after its last frame" {
    var anim = animation.Animator.init(walk_clip);
    var i: u32 = 0;
    while (i < 4) : (i += 1) anim.update(0.25);
    try std.testing.expectEqual(@as(u32, 0), anim.frame());
    anim.update(0.25);
    try std.testing.expectEqual(@as(u32, 1), anim.frame());
}

test "a clip that does not loop holds its last frame" {
    var clip = walk_clip;
    clip.looping = false;
    var anim = animation.Animator.init(clip);
    var i: u32 = 0;
    while (i < 10) : (i += 1) anim.update(0.25);
    try std.testing.expectEqual(@as(u32, 3), anim.frame());
}

test "playing the clip that is already playing keeps its place" {
    var anim = animation.Animator.init(walk_clip);
    anim.update(0.5);
    anim.play(walk_clip);
    try std.testing.expectEqual(@as(u32, 2), anim.frame());

    // A different clip starts from its first frame.
    var idle = walk_clip;
    idle.frame_count = 1;
    anim.play(idle);
    try std.testing.expectEqual(@as(u32, 0), anim.frame());
    try std.testing.expectEqual(@as(f32, 0), anim.time);
}

test "a single-frame clip always shows its first frame" {
    var clip = walk_clip;
    clip.frame_count = 1;
    var anim = animation.Animator.init(clip);
    anim.update(3.0);
    try std.testing.expectEqual(@as(u32, 0), anim.frame());
}

test "a looping animator keeps its time inside one play-through" {
    var anim = animation.Animator.init(walk_clip);
    var i: u32 = 0;
    while (i < 1000) : (i += 1) anim.update(0.1);
    try std.testing.expect(anim.time >= 0 and anim.time < walk_clip.duration());
}

test "log timestamps follow the platform clock after injection" {
    const logging = @import("engine/logging/log.zig");
    const platform = @import("engine/platform/platform.zig");
    logging.setClock(platform.clock.nowNs);
    defer logging.setClock(null);
    // The logger and the frame loop read the same clock, so a read between two logger reads falls between them.
    const before = logging.timestampMs();
    const runtime_ms = platform.clock.nowNs() / 1_000_000;
    const after = logging.timestampMs();
    try std.testing.expect(before <= runtime_ms and runtime_ms <= after);
}
