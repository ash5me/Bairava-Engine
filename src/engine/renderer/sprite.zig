const std = @import("std");

const math = @import("../core/math.zig");
const profile = @import("../profiling/profile.zig");
const render_types = @import("render_types.zig");
const texture = @import("texture.zig");
const backend = @import("backends/sdl_gpu/backend.zig");
const platform = @import("../platform/platform.zig");

const Texture = texture.Texture;
const vertices_per_quad = render_types.vertices_per_quad;
const grownCapacity = render_types.grownCapacity;

/// Vertex layout for sprite quads. Positions are in normalized device coordinates. Color is RGBA:
/// the tint in RGB, and the sprite's alpha in A.
pub const Vertex = render_types.Vertex;

/// The index the index buffer holds at position `k` of quad number `quad`. See render_types.zig.
pub const indexValue = render_types.indexValue;

/// A rectangle in pixels (for destinations) or texels (for sources).
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

/// Per-sprite settings beyond the source and destination rectangles. The defaults draw the sprite as
/// it is: untinted, opaque, unflipped, unrotated, and in the order it was added.
pub const Options = struct {
    /// Multiplies the texture's RGB, each channel from 0 to 1.
    tint: [3]f32 = .{ 1, 1, 1 },
    /// Multiplies the texture's alpha. 0 is invisible and 1 is opaque.
    alpha: f32 = 1,
    /// Mirrors the texture left to right, or top to bottom. The place the sprite covers stays the same.
    flip_x: bool = false,
    flip_y: bool = false,
    /// The point inside the destination rectangle, in pixels from its top-left corner, that the
    /// sprite turns around. Rotation leaves this point where it is.
    origin: [2]f32 = .{ 0, 0 },
    /// Clockwise rotation in radians around `origin`. Screen y points down, so a positive angle turns
    /// clockwise as seen on screen.
    rotation: f32 = 0,
    /// Draw order. Lower values draw first. Sprites with equal values keep the order they were added in.
    /// Batches only merge neighbors with the same texture, so alternating textures in z order costs draw calls.
    z: i32 = 0,
    /// A normal map that lights the sprite with the batch's point lights. Its colors store unit normals as 0..1 per
    /// channel: x points right, y points down the image, and z points out of the screen. It must be the same size as
    /// the texture and read at the same source rectangle, so the sprite's texel coordinates index both. The normals
    /// turn with the sprite: a flip mirrors their x or y, and a rotation turns them as it turns the sprite.
    normal: ?*const Texture = null,
    /// Light the sprite with the batch's point lights even when it has no normal map. Such a sprite is lit as a flat
    /// surface that faces the viewer, so a light brightens it where it reaches and fades past its radius. A sprite
    /// with a normal map is lit by it either way. A sprite with neither is drawn unlit.
    lit: bool = false,
};

/// A point light for lit sprites. Its place and radius are in view pixels, the space sprites are drawn in, so a
/// game converts a world position with `Camera.screenX` and `Camera.screenY`.
pub const Light = struct {
    x: f32,
    y: f32,
    /// How far the light sits above the view. A high light spreads evenly over a sprite, and a low one lights only
    /// the side of it that faces the light.
    height: f32 = 24,
    /// The distance, in pixels, at which the light fades to nothing.
    radius: f32,
    /// The light's color, each channel from 0 to 1.
    color: [3]f32 = .{ 1, 1, 1 },
    /// A multiplier on the color. 1 is full strength.
    intensity: f32 = 1,
};

/// A 2D line segment that occludes point lights. Coordinates are in view pixels.
pub const ShadowSegment = struct {
    start: [2]f32,
    end: [2]f32,
};

/// ECS-friendly point-light data. Convert enabled components to Light values before adding them.
pub const PointLightComponent = struct {
    x: f32,
    y: f32,
    height: f32 = 24,
    radius: f32,
    color: [3]f32 = .{ 1, 1, 1 },
    intensity: f32 = 1,
    enabled: bool = true,

    pub fn light(self: PointLightComponent) Light {
        return .{
            .x = self.x,
            .y = self.y,
            .height = self.height,
            .radius = self.radius,
            .color = self.color,
            .intensity = self.intensity,
        };
    }
};

/// ECS-friendly shadow occlusion data.
pub const ShadowSegmentComponent = struct {
    start: [2]f32,
    end: [2]f32,
    enabled: bool = true,

    pub fn segment(self: ShadowSegmentComponent) ShadowSegment {
        return .{ .start = self.start, .end = self.end };
    }
};

/// Storage starts at these sizes and doubles when a frame needs more. A frame has no sprite or
/// texture-switch limit.
const initial_sprites = 1024;
const initial_batches = 64;

/// One queued sprite. Its corners are in the order drawSprite writes them: top-left, bottom-left,
/// bottom-right, top-right. `seq` is the order the sprite was added in. It breaks ties in the z sort.
const Quad = struct {
    texture: *const Texture,
    normal: ?*const Texture,
    corners: [vertices_per_quad]Vertex,
    z: i32,
    seq: u32,
    src: Rect = undefined,
    dst: Rect = undefined,
    tint: [3]f32 = .{ 1, 1, 1 },
    alpha: f32 = 1,
    flip_x: bool = false,
    flip_y: bool = false,
    origin: [2]f32 = .{ 0, 0 },
    rotation: f32 = 0,
};

/// Consecutive quads that sample the same texture, drawn in one call. `first_vertex` and
/// `vertex_count` count vertices. Public so tests can build a batch without a GPU.
pub const Batch = struct {
    texture: *const Texture,
    /// The normal map the run's sprites are lit with, or null for a run drawn unlit.
    normal: ?*const Texture,
    /// True for a run of alpha-only atlas sprites (see Texture.coverage), drawn through the coverage pipeline.
    coverage: bool = false,
    first_vertex: u32,
    vertex_count: u32,
};

/// The backend's GPU state, hidden behind an opaque type so the public SpriteBatch names no backend type.
const SpriteBatchHandle = opaque {};

pub const SpriteBatch = struct {
    /// The GPU objects, owned by the backend. Only `init` creates them, and `deinit` releases them.
    gpu_state: *SpriteBatchHandle,
    allocator: std.mem.Allocator,

    /// Sprites queued this frame, in the order they were added. `prepare` sorts them by z in place.
    /// Heap-allocated, and doubled when a frame needs more.
    quads: []Quad = &.{},
    /// Sprites queued this frame. Each one is a quad.
    sprite_count: u32 = 0,

    /// CPU-side vertices for the current frame, in draw order. `prepare` fills them.
    vertices: []Vertex,
    vertex_count: u32 = 0,
    /// Runs of sprites that share a texture, in draw order. `prepare` fills them.
    batches: []Batch,
    batch_count: u32 = 0,
    /// Draw calls issued by draw() this frame. Shows whether batching is working.
    draw_calls: u32 = 0,
    /// Maps pixel coordinates in the viewport to normalized device coordinates. Set by `begin`.
    projection: math.Mat4 = undefined,
    /// The ambient light, point lights, and shadow segments for this frame. `begin` resets them.
    lighting: render_types.LightUniforms = undefined,
    light_count: u32 = 0,
    shadow_segment_count: u32 = 0,
    /// True when `prepare` found a run with a normal map, so `upload` must push the lights.
    has_lit_runs: bool = false,
    /// The one-texel map that lit sprites without a normal map sample. It faces the viewer. The batch owns it, and
    /// `deinit` releases it. Null only for a batch that was never given a device, such as a test fixture.
    flat_normal: ?*const Texture = null,

    /// Builds the pipeline and GPU buffers. `color_format` is the swapchain format
    /// the sprites render into. `fragment` is the shader the quads run through.
    /// `lit` is the fragment stage for normal-mapped runs, or null for a batch that draws none. `coverage` is the
    /// fragment stage for alpha-only atlas runs (fonts), or null.
    fn init(allocator: std.mem.Allocator, device: *backend.Device, color_format: backend.TextureFormat, fragment: backend.shader.Source, lit: ?backend.shader.Source, coverage: ?backend.shader.Source) SpriteBatch {
        const gpu_state = backend.sprite.create(allocator, device, color_format, initial_sprites * vertices_per_quad, fragment, lit, coverage);
        var batch = SpriteBatch{
            .gpu_state = @ptrCast(gpu_state),
            .allocator = allocator,
            .quads = allocQuads(allocator, initial_sprites),
            .vertices = allocVertices(allocator, initial_sprites * vertices_per_quad),
            .batches = allocBatches(allocator, initial_batches),
            .flat_normal = createFlatNormal(allocator, device),
            .projection = math.ortho2d(1.0, 1.0),
        };
        batch.lighting.reset();
        return batch;
    }

    /// Starts a new frame of sprites. `viewport_w` and `viewport_h` are the drawing area in pixels,
    /// with (0,0) at the top-left.
    pub fn begin(self: *SpriteBatch, viewport_w: f32, viewport_h: f32) void {
        self.sprite_count = 0;
        self.vertex_count = 0;
        self.batch_count = 0;
        self.draw_calls = 0;
        self.projection = math.ortho2d(viewport_w, viewport_h);
        self.lighting.reset();
        self.light_count = 0;
        self.shadow_segment_count = 0;
        self.has_lit_runs = false;
    }

    /// Sets the ambient light: the brightness a lit sprite has with no point light on it. It starts at full, so a
    /// lit sprite looks as it would unlit until a game darkens the scene. `begin` restores full each frame.
    pub fn setAmbient(self: *SpriteBatch, rgb: [3]f32) void {
        self.lighting.ambient = .{ rgb[0], rgb[1], rgb[2], 0 };
    }

    /// Adds a point light for this frame. A frame holds `render_types.max_lights` lights, and one more panics, since
    /// the lights are fixed-size uniform data.
    pub fn addLight(self: *SpriteBatch, light: Light) void {
        if (self.light_count == render_types.max_lights) {
            std.debug.panic("a frame holds at most {d} lights", .{render_types.max_lights});
        }
        const slot = self.light_count;
        self.lighting.position[slot] = .{ light.x, light.y, light.height, light.radius };
        self.lighting.color[slot] = .{ light.color[0], light.color[1], light.color[2], light.intensity };
        self.light_count += 1;
        self.lighting.info[0] = @floatFromInt(self.light_count);
    }

    /// Adds every enabled point-light component. Components accumulate into the same fixed-size
    /// frame data as addLight; the limit is enforced by addLight.
    pub fn addPointLightComponents(self: *SpriteBatch, components: []const PointLightComponent) void {
        for (components) |component| {
            if (component.enabled) self.addLight(component.light());
        }
    }

    /// Adds point-light components directly from live ECS rows. The row may use AoS or SoA storage
    /// and must contain a field named `point_light`, or exactly one PointLightComponent field.
    pub fn addPointLightWorld(self: *SpriteBatch, world: anytype) void {
        var index: usize = 0;
        while (index < world.count()) : (index += 1) {
            const row = world.rows.get(index);
            inline for (std.meta.fields(@TypeOf(row))) |field| {
                if (field.type == PointLightComponent) {
                    const component = @field(row, field.name);
                    if (component.enabled) self.addLight(component.light());
                }
            }
        }
    }

    /// Adds a line segment that blocks point lights when the segment lies between the light and a
    /// lit fragment. Ambient light is not blocked. A frame holds `render_types.max_shadow_segments`
    /// segments; exceeding that limit panics.
    pub fn addShadowSegment(self: *SpriteBatch, segment: ShadowSegment) void {
        if (self.shadow_segment_count == render_types.max_shadow_segments) {
            std.debug.panic("a frame holds at most {d} shadow segments", .{render_types.max_shadow_segments});
        }
        const slot = self.shadow_segment_count;
        self.lighting.shadow_segment[slot] = .{
            segment.start[0],
            segment.start[1],
            segment.end[0],
            segment.end[1],
        };
        self.shadow_segment_count += 1;
        self.lighting.info[1] = @floatFromInt(self.shadow_segment_count);
    }

    /// Adds every enabled shadow-segment component to this frame.
    pub fn addShadowSegmentComponents(self: *SpriteBatch, components: []const ShadowSegmentComponent) void {
        for (components) |component| {
            if (component.enabled) self.addShadowSegment(component.segment());
        }
    }

    /// Adds shadow-segment components directly from live ECS rows. The row may use AoS or SoA.
    pub fn addShadowSegmentWorld(self: *SpriteBatch, world: anytype) void {
        var index: usize = 0;
        while (index < world.count()) : (index += 1) {
            const row = world.rows.get(index);
            inline for (std.meta.fields(@TypeOf(row))) |field| {
                if (field.type == ShadowSegmentComponent) {
                    const component = @field(row, field.name);
                    if (component.enabled) self.addShadowSegment(component.segment());
                }
            }
        }
    }

    /// Queues one sprite. `src` is the texel rectangle to sample, and `dst` is the on-screen rectangle
    /// in pixels, before `opts` applies. `opts` sets the tint, alpha, flip, origin, rotation, and z.
    /// Sprites draw in z order, and sprites with equal z draw in the order they were added.
    pub fn drawSprite(self: *SpriteBatch, texture_ref: *const Texture, src: Rect, dst: Rect, opts: Options) void {
        // A normal map indexes the same texels as the texture, so the two must have the same size.
        if (opts.normal) |map| {
            if (map.width != texture_ref.width or map.height != texture_ref.height) {
                std.debug.panic("a normal map is {d}x{d} but the texture it lights is {d}x{d}; they must match", .{
                    map.width, map.height, texture_ref.width, texture_ref.height,
                });
            }
        }
        // Make room before writing. Storage doubles when it fills, so a frame has no sprite limit.
        if (self.sprite_count == self.quads.len) self.growQuads(self.sprite_count + 1);
        // A lit sprite with no normal map of its own samples the flat map, which faces the viewer.
        const normal: ?*const Texture = if (opts.normal) |map| map else if (opts.lit) self.flat_normal else null;
        if (normal != null and texture_ref.coverage) std.debug.panic("an alpha-only font atlas cannot be lit", .{});
        self.quads[self.sprite_count] = .{
            .texture = texture_ref,
            .normal = normal,
            .corners = cornersFor(&self.projection, texture_ref, src, dst, opts),
            .z = opts.z,
            .seq = self.sprite_count,
            .src = src,
            .dst = dst,
            .tint = opts.tint,
            .alpha = opts.alpha,
            .flip_x = opts.flip_x,
            .flip_y = opts.flip_y,
            .origin = opts.origin,
            .rotation = opts.rotation,
        };
        self.sprite_count += 1;
    }

    /// Puts this frame's sprites in draw order, and writes their vertices and texture runs. `upload`
    /// calls this, and so do tests, which have no GPU. It rebuilds the same result if it runs again.
    pub fn prepare(self: *SpriteBatch) void {
        const zone = profile.zoneNamed(@src(), "sprite prepare");
        defer zone.End();
        const queued = self.quads[0..self.sprite_count];
        if (!inZOrder(queued)) heapSort(queued);

        self.vertex_count = 0;
        self.batch_count = 0;
        self.has_lit_runs = false;
        const needed = @as(usize, self.sprite_count) * vertices_per_quad;
        if (needed > self.vertices.len) self.growVertices(needed);

        for (queued) |quad| {
            // Start a new run whenever the texture or its normal map changes. Runs double too, so there is no switch limit.
            const starts_run = self.batch_count == 0 or
                self.batches[self.batch_count - 1].texture != quad.texture or
                self.batches[self.batch_count - 1].normal != quad.normal;
            if (starts_run) {
                if (self.batch_count == self.batches.len) self.growBatches(self.batch_count + 1);
                self.batches[self.batch_count] = .{
                    .texture = quad.texture,
                    .normal = quad.normal,
                    .coverage = quad.texture.coverage,
                    .first_vertex = self.vertex_count,
                    .vertex_count = 0,
                };
                self.batch_count += 1;
                if (quad.normal != null) self.has_lit_runs = true;
            }
            self.batches[self.batch_count - 1].vertex_count += vertices_per_quad;
            for (quad.corners) |corner| {
                self.vertices[self.vertex_count] = corner;
                self.vertex_count += 1;
            }
        }
    }

    /// Copies this frame's vertices to the GPU. Call before beginPass, since the copy
    /// has to happen outside a render pass.
    fn upload(self: *SpriteBatch, cmd: *backend.CommandBuffer) void {
        const zone = profile.zoneNamed(@src(), "sprite upload");
        defer zone.End();
        self.prepare();
        if (self.vertex_count == 0) return;
        backend.sprite.upload(gpuOf(self), cmd, self.vertices[0..self.vertex_count]);
        if (self.has_lit_runs) backend.sprite.pushLights(cmd, &self.lighting);
    }

    /// Records one draw call per batch. Call inside a render pass, after upload().
    fn draw(self: *SpriteBatch, pass: ?*backend.RenderPass) void {
        const zone = profile.zoneNamed(@src(), "sprite draw");
        defer zone.End();
        if (self.batch_count == 0) return;
        backend.sprite.beginDraw(gpuOf(self), pass);

        for (self.batches[0..self.batch_count]) |batch| {
            // A texture whose upload is still running has nothing to sample yet. Skip its batch this
            // frame. The game queues the sprite again next frame. The same holds for its normal map.
            if (!batch.texture.isReady()) continue;
            var normal_state: ?*const backend.texture.State = null;
            if (batch.normal) |map| {
                if (!map.isReady()) continue;
                normal_state = texture.backendState(map);
            }
            backend.sprite.drawRun(gpuOf(self), pass, texture.backendState(batch.texture), normal_state, batch.coverage, batch.first_vertex, batch.vertex_count);
            self.draw_calls += 1;
        }
    }

    /// Doubles the quad storage until it holds `needed` sprites. Sprites already queued this frame
    /// are kept.
    fn growQuads(self: *SpriteBatch, needed: usize) void {
        const bigger = allocQuads(self.allocator, grownCapacity(self.quads.len, needed));
        @memcpy(bigger[0..self.sprite_count], self.quads[0..self.sprite_count]);
        freeSlice(self.allocator, Quad, self.quads);
        self.quads = bigger;
    }

    /// Doubles the vertex storage until it holds `needed` vertices. Vertices already written this
    /// frame are kept.
    fn growVertices(self: *SpriteBatch, needed: usize) void {
        const bigger = allocVertices(self.allocator, grownCapacity(self.vertices.len, needed));
        @memcpy(bigger[0..self.vertex_count], self.vertices[0..self.vertex_count]);
        freeSlice(self.allocator, Vertex, self.vertices);
        self.vertices = bigger;
    }

    /// Doubles the batch storage until it holds `needed` batches. Batches already built this frame
    /// are kept.
    fn growBatches(self: *SpriteBatch, needed: usize) void {
        const bigger = allocBatches(self.allocator, grownCapacity(self.batches.len, needed));
        @memcpy(bigger[0..self.batch_count], self.batches[0..self.batch_count]);
        freeSlice(self.allocator, Batch, self.batches);
        self.batches = bigger;
    }

    /// Releases the GPU objects and the CPU storage. Call before the renderer is deinitialized.
    pub fn deinit(self: *SpriteBatch) void {
        backend.sprite.destroy(gpuOf(self), self.allocator);
        if (self.flat_normal) |flat| {
            // `init` made this map and stored it as a const pointer, so the batch owns it and may release it.
            const owned: *Texture = @constCast(flat);
            owned.deinit();
            self.allocator.destroy(owned);
        }
        freeSlice(self.allocator, Quad, self.quads);
        freeSlice(self.allocator, Vertex, self.vertices);
        freeSlice(self.allocator, Batch, self.batches);
        self.* = undefined;
    }
};

/// A batch of sprites. Sprites with no normal map use the default sprite shader, and sprites with one are lit
/// by the batch's lights through the lit shader.
pub fn create(allocator: std.mem.Allocator, device: *backend.Device, color_format: backend.TextureFormat) SpriteBatch {
    return SpriteBatch.init(allocator, device, color_format, backend.sprite.sprite_fragment, backend.sprite.lit_fragment, backend.sprite.coverage_fragment);
}

/// A batch whose quads run through one post-processing effect's shader. It takes the same vertices as a
/// sprite batch, so a post-processing chain can queue one full-view quad through it.
pub fn createEffect(allocator: std.mem.Allocator, device: *backend.Device, color_format: backend.TextureFormat, effect: render_types.Effect) SpriteBatch {
    return SpriteBatch.init(allocator, device, color_format, backend.post.fragmentSource(effect), null, null);
}

pub fn upload(batch: *SpriteBatch, cmd: *backend.CommandBuffer) void {
    batch.upload(cmd);
}

pub fn draw(batch: *SpriteBatch, pass: ?*backend.RenderPass) void {
    batch.draw(pass);
}

/// Draws the queued quads through SDL3's 2D renderer. This path intentionally uses the
/// same CPU z-sort as the GPU path, so game code and UI drawing remain backend-independent.
pub fn draw2d(batch: *SpriteBatch, dst_x: f32, dst_y: f32, scale_x: f32, scale_y: f32) void {
    batch.prepare();
    for (batch.quads[0..batch.sprite_count]) |quad| {
        if (!quad.texture.isReady()) continue;
        const sdl_texture = texture.sdl2dState(quad.texture) orelse continue;
        platform.renderer2d.draw(
            sdl_texture,
            quad.src,
            quad.dst,
            dst_x,
            dst_y,
            scale_x,
            scale_y,
            quad.tint,
            quad.alpha,
            quad.flip_x,
            quad.flip_y,
            quad.origin,
            quad.rotation,
        );
    }
}

/// The backend state of a batch. The cast reverses how `init` stored it.
fn gpuOf(batch: *const SpriteBatch) *backend.sprite.State {
    return @ptrCast(@alignCast(batch.gpu_state));
}

/// The four corners of one sprite in pixels, through `projection`. The texture coordinates, flip,
/// origin, rotation, and color are applied. The order is top-left, bottom-left, bottom-right, top-right.
fn cornersFor(projection: *const math.Mat4, texture_ref: *const Texture, src: Rect, dst: Rect, opts: Options) [vertices_per_quad]Vertex {
    // Texel rectangle -> UV coordinates (0..1). A flip swaps the two ends of an axis.
    // Names avoid u0/u1, which are Zig's unsigned integer type names.
    const tw: f32 = @floatFromInt(texture_ref.width);
    const th: f32 = @floatFromInt(texture_ref.height);
    var u_left = src.x / tw;
    var u_right = (src.x + src.w) / tw;
    var v_top = src.y / th;
    var v_bottom = (src.y + src.h) / th;
    if (opts.flip_x) std.mem.swap(f32, &u_left, &u_right);
    if (opts.flip_y) std.mem.swap(f32, &v_top, &v_bottom);

    // The corners relative to the origin, before rotation. The origin is the pivot, and it stays at
    // dst.x + origin[0], dst.y + origin[1].
    const ox = opts.origin[0];
    const oy = opts.origin[1];
    const s = @sin(opts.rotation);
    const co = @cos(opts.rotation);
    const pivot_x = dst.x + ox;
    const pivot_y = dst.y + oy;
    const o_tl = turned(-ox, -oy, s, co);
    const o_bl = turned(-ox, dst.h - oy, s, co);
    const o_br = turned(dst.w - ox, dst.h - oy, s, co);
    const o_tr = turned(dst.w - ox, -oy, s, co);

    const p_tl = math.transformPoint(projection, pivot_x + o_tl[0], pivot_y + o_tl[1]);
    const p_bl = math.transformPoint(projection, pivot_x + o_bl[0], pivot_y + o_bl[1]);
    const p_br = math.transformPoint(projection, pivot_x + o_br[0], pivot_y + o_br[1]);
    const p_tr = math.transformPoint(projection, pivot_x + o_tr[0], pivot_y + o_tr[1]);

    const color = [4]f32{ opts.tint[0], opts.tint[1], opts.tint[2], opts.alpha };
    // A normal map turns with the sprite. The flip happens in the sprite's own frame and the rotation after it, so the
    // basis is R * F: R is the clockwise turn `turned` applies, and F mirrors x or y. Normal z never changes.
    const flip_x_sign: f32 = if (opts.flip_x) -1 else 1;
    const flip_y_sign: f32 = if (opts.flip_y) -1 else 1;
    const basis = [4]f32{ co * flip_x_sign, -s * flip_y_sign, s * flip_x_sign, co * flip_y_sign };
    return .{
        .{ .pos = p_tl, .uv = .{ u_left, v_top }, .color = color, .normal_basis = basis },
        .{ .pos = p_bl, .uv = .{ u_left, v_bottom }, .color = color, .normal_basis = basis },
        .{ .pos = p_br, .uv = .{ u_right, v_bottom }, .color = color, .normal_basis = basis },
        .{ .pos = p_tr, .uv = .{ u_right, v_top }, .color = color, .normal_basis = basis },
    };
}

/// An offset (x, y) turned clockwise by the angle with sine `s` and cosine `co`. Screen y points
/// down, so this turns clockwise as seen on screen.
fn turned(x: f32, y: f32, s: f32, co: f32) [2]f32 {
    return .{ x * co - y * s, x * s + y * co };
}

/// True when the quads are already in non-decreasing z order, so no sort is needed. Most frames are.
fn inZOrder(quads: []const Quad) bool {
    var i: usize = 1;
    while (i < quads.len) : (i += 1) {
        if (quads[i].z < quads[i - 1].z) return false;
    }
    return true;
}

/// Quads sort by z, and then by the order they were added. The second key makes every quad distinct,
/// so the heap sort below gives the same result a stable sort would.
fn quadBefore(a: Quad, b: Quad) bool {
    return a.z < b.z or (a.z == b.z and a.seq < b.seq);
}

/// Sifts the quad at `root` down until the heap property holds below it, within the first `end` quads.
fn siftDown(quads: []Quad, root_start: usize, end: usize) void {
    var root = root_start;
    while (true) {
        var child = 2 * root + 1;
        if (child >= end) return;
        if (child + 1 < end and quadBefore(quads[child], quads[child + 1])) child += 1;
        if (!quadBefore(quads[root], quads[child])) return;
        std.mem.swap(Quad, &quads[root], &quads[child]);
        root = child;
    }
}

/// Sorts the quads in place by z, then by insertion order. Heap sort needs no extra memory.
fn heapSort(quads: []Quad) void {
    if (quads.len < 2) return;
    var start = quads.len / 2;
    while (start > 0) {
        start -= 1;
        siftDown(quads, start, quads.len);
    }
    var end = quads.len;
    while (end > 1) {
        end -= 1;
        std.mem.swap(Quad, &quads[0], &quads[end]);
        siftDown(quads, 0, end);
    }
}

/// The one-texel normal map that faces the viewer. Its texel stores (0.5, 0.5, 1), which decodes to the unit vector
/// (0, 0, 1). It is heap-allocated, so the batch keeps a stable pointer to it.
fn createFlatNormal(allocator: std.mem.Allocator, device: *backend.Device) *const Texture {
    const flat = allocator.create(Texture) catch @panic("out of memory");
    const texel = [4]u8{ 128, 128, 255, 255 };
    flat.* = texture.createRgba8(allocator, device, 1, 1, &texel);
    return flat;
}

fn allocQuads(allocator: std.mem.Allocator, count: usize) []Quad {
    return allocator.alloc(Quad, count) catch @panic("out of memory");
}

fn allocVertices(allocator: std.mem.Allocator, count: usize) []Vertex {
    return allocator.alloc(Vertex, count) catch @panic("out of memory");
}

fn allocBatches(allocator: std.mem.Allocator, count: usize) []Batch {
    return allocator.alloc(Batch, count) catch @panic("out of memory");
}

/// Frees storage from `allocQuads`, `allocVertices`, or `allocBatches`. A zero-length slice owns no
/// memory, so it is skipped.
fn freeSlice(allocator: std.mem.Allocator, comptime T: type, slice: []T) void {
    if (slice.len != 0) allocator.free(slice);
}
