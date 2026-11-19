# Physics and collision queries

The engine provides SDL-free shape and collision helpers in `engine.physics`.

## Shapes and colliders

`Collider` and `collision.Component` support a box or optional circle shape, one or more collision
layers, a query mask, and an enabled flag. Box colliders may be rotated or marked `one_way`.
Components can be attached to dense ECS rows and copied into collider slices with
`collision.collidersFromWorld`.

```zig
const wall = engine.physics.collision.Component{
    .box = .{ .x = 100, .y = 40, .w = 20, .h = 80 },
    .layer = 1,
    .rotation = std.math.pi / 4.0,
};
```

Rotation is stored in radians and turns clockwise around the rectangle's center in screen space.
Collider half-open edges follow box semantics: right and bottom edges are outside the shape.
An axis-aligned collider with `one_way = true` blocks only downward movement at its top edge.
Horizontal and upward movement pass through it. A rotated collider remains a full block even when
flagged one-way.

Set `circle` to use a circle as the collider's only shape; the `box` and `rotation` fields are then
ignored. A null circle preserves the box behavior. Circles are open disks: rim contact is not an
overlap. A circle ignores `one_way` and blocks movement as a solid shape in every direction.

## Detection

`orientedBoxesOverlap` uses the separating-axis theorem for exact rectangle-vs-rectangle overlap.
`circleOverlapsBox`, `circlesOverlap`, and `pointInCircle` provide the corresponding strict circle
tests. These operations do not allocate and do not report movement.

`queries.firstOverlap`, `anyOverlap`, `queryRegion`, and `firstAtPoint` operate on collider slices.
Every operation filters disabled colliders and checks the collision layer/mask relationship.

## Uniform grid

`broad_phase.Index` stores static colliders in a uniform grid. Rebuild the index after collider
data changes. Rotated colliders are inserted using their conservative axis-aligned bounding box;
candidate boxes and points then use exact SAT or oriented-point checks.

The index supports region, overlap, point, and movement queries.

```zig
var grid = try engine.physics.broad_phase.Index.init(allocator, &colliders, 32);
defer grid.deinit();

if (grid.firstAtPoint(.{ .x = 48, .y = 20 }, engine.physics.queries.all_layers)) |_| {
    // The point is inside an exact collider shape.
}

const end = grid.moveBox(mover, dx, dy, engine.physics.queries.all_layers);
```

`queries.moveBoxIgnoringOneWay` and `Index.moveBoxIgnoringOneWay` provide a one-slide drop-through
operation. They skip axis-aligned one-way tops while retaining solid and rotated-collider response.

## Movement

Linear and grid movement resolve X before Y, preserve movement that starts inside an overlapping
collider as escape movement, and stop at blockers when exact overlap first appears. Rotated
candidates use exact narrow-phase overlap checks, and circle colliders use analytic box-to-circle
contact stops. The moving probe remains a box.

One-way response is optional and does not change existing colliders: the default `one_way = false`
keeps them fully solid.

The movement implementation is axis-based: it does not rotate the moving box. Swept rotated-box
response, complete rotated shape resolution, and rotation of the mover are outside the current
requirement.
