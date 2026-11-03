# 2D lighting

The sprite batch supports ambient and point lighting for lit sprites. A sprite uses a normal map
through `Options.normal`, or the flat, viewer-facing normal with `Options.lit = true`. Each frame,
set the ambient RGB and add point lights and optional shadow segments to the batch before queuing the
lit sprites:

```zig
dc.batch.setAmbient(.{ 0.12, 0.14, 0.2 });
dc.batch.addLight(.{
    .x = light_x,
    .y = light_y,
    .height = 24,
    .radius = 120,
    .color = .{ 1, 0.75, 0.4 },
    .intensity = 1,
});
dc.batch.addShadowSegment(.{
    .start = .{ wall_left, wall_y },
    .end = .{ wall_right, wall_y },
});
dc.batch.drawSprite(albedo, source, destination, .{ .normal = normal_map });
```

Light and shadow coordinates are in view pixels, matching sprite positions after camera projection.
`addShadowSegment` defines a 2D line segment: for each lit fragment, it blocks a point light when
the segment lies between the fragment and the light. The light's contribution is omitted behind the
segment; ambient illumination remains. This produces hard 2D shadows. Segments are supplied per
frame and are not inferred from tile or sprite geometry.

Normal maps are selected with `Options.normal`; `.lit = true` uses the batch-owned flat viewer-facing
normal for a sprite without a normal map. Normal maps must match the albedo texture dimensions. Sprite
flip and rotation also transform the normal map basis in the lit shader.

The public ECS-friendly types `PointLightComponent` and `ShadowSegmentComponent` can be accumulated
directly by the batch:

```zig
dc.batch.addPointLightWorld(world);
dc.batch.addShadowSegmentWorld(world);
```

The world form supports dense AoS or SoA rows containing the named component fields. Each enabled
component is accumulated for the current frame. Slices can be supplied with
`addPointLightComponents` and `addShadowSegmentComponents`.

A batch supports up to 16 point lights and 16 shadow segments per frame. Exceeding either limit
panics, matching the fixed GPU uniform capacity. `begin` resets ambient to full brightness and clears
the lights and segments, so configure them for each frame. Unlit sprites are unaffected.
