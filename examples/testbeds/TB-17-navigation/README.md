# TB-17 Navigation Laboratory

TB-17 exercises the engine's A* pathfinder, shared-goal flow fields, and collision-aware follower
steering. The bounded run writes `TB-17-navigation-results.json` beside the executable, including
path lengths, search expansion counts, CPU timings, flow-field rebuild costs, and expected no-route
results.

## Run a bounded test

```powershell
zig build run-tb17 -- --frames 360
```

Startup fixtures verify a narrow corridor path, a disconnected map returning `NoPath`, dynamic gate
closure/reopening, a flow-field route reaching its goal, and a collision-aware follower reaching the
same goal. The lab also executes repeated A* queries for a shared destination, builds one flow field,
and updates a configurable group of agents using flow-field directions and follower collision
movement.

## Controls

- Q: open map.
- W: narrow corridor.
- E: disconnected map with no route.
- F: dynamic gate map.
- Space: close/open the gate in the dynamic map.
- Plus/Equal or Minus: increase/decrease the visual agent count (up to 64).
- R: rebuild the shared-goal flow field.
- Escape: exit.

The reported durations are process CPU time from the C runtime clock, not wall-clock frame times;
use them to compare bounded work on the same host and build configuration.
