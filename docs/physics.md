# Physics and collision queries

The engine provides SDL-free shape and collision helpers in `engine.physics`.

## Shapes and colliders

`Collider` and `collision.Component` support an axis-aligned or rotated rectangle, an enabled flag,
one or more collision layers, and a query mask. Components can be attached to dense ECS rows and
copied into collider slices with `collision.collidersFromWorld`.

```zig
const wall = engine.physics.collision.Component{
    .box = .{ .x = 100, .y = 40, .w = 20, .h = 80 },
    .layer = 1,
    .rotation = std.math.pi / 4.0,
};
```

Rotation is stored in radians and turns clockwise around the rectangle's center in screen space.
Collider half-open edges follow box semantics: right and bottom edges are outside the shape.

## Detection

`orientedBoxesOverlap` uses the separating-axis theorem for exact rectangle-vs-rectangle overlap.
`pointInOrientedBox` performs exact point containment for a rotated box. These operations do not
allocate and do not report movement.

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

## Movement

Linear and grid movement resolve X before Y, preserve movement that starts inside an overlapping
collider as escape movement, and stop at blockers when exact overlap first appears. Rotated
candidates use exact narrow-phase overlap checks.

The movement implementation is axis-based: it does not rotate the moving box. Swept rotated-box
response, complete rotated shape resolution, and rotation of the mover are outside the current
requirement.
