# Navigation

Navigation lets AI units find routes through a level. It has two parts. The engine provides the walkable grid, the
route search, and a follower that walks a box along a route through the tile map's collision. The game provides the
enemies, which use those parts to wander, chase the player, and walk home. The engine code is in
`src/engine/navigation/`. The enemy code is in `src/game/enemy.zig` and `src/game/enemy_ai.zig`.

The engine modules name no game type. They are reached through `engine.navigation`.

## The walkable grid

`navigation.Grid` wraps a `TileMap`. A cell is walkable when the map does not block it. A solid tile on any layer
blocks its cell, and the edge of the map counts as a wall. A grid keeps a pointer to its map, so make one where it
is used, and don't store it in a struct that is later moved.

`cellOf` gives the cell that holds a point in pixels, and `cellCenter` gives the center of a cell. `Grid.lineOfSight`
answers whether a straight line between two points crosses only walkable cells. It checks every cell the line
crosses, in order, so it cannot step past a thin wall at a corner.

## Routes

`navigation.Pathfinder` runs A* over the grid, and returns the cheapest route as a list of cells, from start to goal.

- A route may enter a cell from any of its eight neighbors. A straight step costs 10, and a diagonal step costs 14.
- A diagonal step is allowed only when both cells beside it are walkable. A route never squeezes between two wall
  corners.
- The start may be inside a wall, since a unit can be pushed there. The goal must be walkable.
- `find` writes the route into a buffer the caller provides. A failed search writes nothing, so the caller's old route
  stays in place. The errors are `OutOfBounds`, `GoalBlocked`, `NoPath`, and `PathTooLong`.
- The pathfinder keeps its arrays between searches, and only grows them when a bigger map is searched.

A search can visit every cell of the map, so its worst case grows with the map. Enemies keep the cost low: a chasing
enemy replans every 0.4 seconds, or as soon as the player moves into another cell.

## Navigation agent

`navigation.Agent` composes a reusable A* pathfinder and route follower for one moving unit. Initialize it with an
allocator, call `plan(grid, start, goal)`, then pass the map, the unit's collision box, speed, and fixed update delta to
`step`. `goal`, `hasPath`, `atGoal`, and `nextWaypoint` expose the current route state. `clear` drops both the route and
its remembered goal. The agent owns its pathfinder, so call `deinit` when it is no longer needed.

Planning is transactional: if a new goal is blocked, unreachable, outside the grid, too far for the route buffer, or
allocation fails, the current route remains available and `plan` returns the error. The caller chooses when to replan
for moving targets or changed world state. The map and grid remain caller-owned; the map must outlive each `step`.

## Following a route

`navigation.Follower` holds a route of up to `max_path` (128) cells. Its `step` moves a box toward the next waypoint,
by at most `speed * dt` pixels. The box uses the same collision as the player, so it slides along walls and stops
where a solid tile blocks it.

When the box comes within 2 pixels of an open waypoint, it snaps onto that cell's center. Steering diagonally can
leave the box a fraction of a pixel off the grid, and that fraction can put its edge over a wall row, which then
blocks the next straight move. Snapping keeps the box on the grid. A box centered on an open cell never overlaps a
wall.

If the box makes no progress for 0.35 seconds while it still has a route, the follower drops the route. The owner
decides what to do next, and a chasing enemy replans on its next repath.

## Enemies

Each enemy is in one of four states. The brain in `enemy_ai.zig` picks the state, and `enemy.zig` plans and walks.

| State | Entered when | What it does | Leaves when |
|---|---|---|---|
| idle | at spawn, or after a rest | stands still for a random 1.5 to 3.0 seconds | sees the player: chase. Wait over: wander |
| wander | the idle wait ends | routes to a random walkable cell within 4 cells of home | sees the player: chase. Route done: idle |
| chase | sees the player, from any state | routes to the player's cell, at 44 pixels per second | no sight for 2.0 seconds: return home |
| return_home | lost sight of the player | routes back to home, at 20 pixels per second | sees the player: chase. Arrived: idle |

An enemy sees the player when the player's feet are within 88 pixels of its own feet, and a clear line joins them.
Walls block sight. Enemies don't see each other, and they don't attack yet.

Each enemy is drawn with the warrior's walk and idle clips, tinted red. Its brain is seeded from its position in the
level's list, so every run of a level makes the same random choices.

Enemies are placed with `enemy <col> <row>` lines in the level's metadata file. The cell is the enemy's home. See
[prefabs](prefabs.md) for the file format.

## Changing the numbers

- `src/game/enemy.zig`: speeds, sight range, wander radius, and the repath interval.
- `src/game/enemy_ai.zig`: the idle wait range and the lose-sight time.
- `src/engine/navigation/follow.zig`: the arrival distance and the stuck time.
- `src/engine/navigation/pathfind.zig`: the step costs.

## Debugging

- F4 turns on the debug geometry. Each enemy's feet are outlined in red, and the cells left on its route are drawn as
  blue points.
- In development builds, the debug overlay (F3) lists the enemy count and how many are chasing.

## Tests

`zig build test` runs the grid, pathfinder, follower, navigation agent, and behavior brain tests. The enemy glue in
`enemy.zig` imports the engine, so the tests do not cover it. The game is the check for that part.

## Limits

- Enemies do not fight, and the player takes no damage.
- Enemies are not saved. Loading a save leaves them on their home cells, as the level placed them.
- A route holds at most 128 cells. A longer one is refused with `PathTooLong`, and the enemy stays where it is.
- Enemies do not avoid each other or the player, so they can overlap.
- The grid is built from the static tiles of the level. A route does not change when a tile changes.
- Routes are not smoothed. A route can zigzag between diagonal and straight steps.
