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

Set `is_trigger = true` to make a collider a sensor. Triggers remain in overlap, point, region, and
grid queries, but are ignored by box movement response.

## Detection

`orientedBoxesOverlap` uses the separating-axis theorem for exact rectangle-vs-rectangle overlap.
`circleOverlapsBox`, `circlesOverlap`, and `pointInCircle` provide the corresponding strict circle
tests. These operations do not allocate and do not report movement.

`queries.firstOverlap`, `anyOverlap`, `queryRegion`, and `firstAtPoint` operate on collider slices.
Every operation filters disabled colliders and checks the collision layer/mask relationship.
`queries.collectTriggerEvents` compares current trigger overlaps with a caller-owned previous-pair
slice and fills caller-owned current-pair and event buffers. It emits `enter`, `stay`, and `exit`
events for pairs where at least one enabled collider is a trigger. Pairwise layer/mask checks apply,
indices are ordered by the collider slice, and that slice must keep the same ordering across updates.
The result reports total pair/event counts and how many entries did not fit in either output buffer;
size those buffers for the expected maximum if every pair and event must be retained. Use the current
pair buffer as the previous-pair slice on the next fixed update.

## Rays and shape casts

`queries.raycast` returns the nearest `Hit` along a segment; `raycastAll` writes hits sorted by
fraction and then collider index, retaining the nearest hits when its output is too small. Both
include trigger colliders and filter disabled colliders by layer mask. Box faces count as contact
surfaces (including the otherwise-exclusive right and bottom edges), and circle tangencies count
as hits. A ray that starts inside a shape returns fraction zero with an outward normal; a zero-length
ray therefore only hits when its origin is inside (or on a box contact face; circle containment is
strict). Empty or non-finite geometry and ray inputs miss.

`queries.castBox` sweeps an axis-aligned box and `queries.castCircle` sweeps a circle. Their `Hit`
point is the moving shape's reference position at first contact (box top-left or circle center).
The uniform-grid `Index` provides matching `raycast`, `raycastAll`, `castBox`, and `castCircle`
queries over its static collider slice.

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
