# TB-09 Platformer

Run the interactive platformer and its built-in physics checks:

```sh
zig build run-tb09
```

For a bounded smoke run:

```sh
zig build run-tb09 -- --frames 240
```

Controls: A/D or the arrow keys move, Space or W jumps, Down+Space drops through one-way
platforms, and Escape quits. The level includes static ledges, a horizontally moving platform,
a hazard, a checkpoint, landing particles, and optional sound effects. The player uses the
existing warrior idle/walk animation machine. The camera follows the player through the level.

The startup checks compare fixed-step simulation at 30, 60, and 120 render updates per second,
exercise a high-speed movement against a wall, and check that a grounded character is carried by
the moving platform. Results are written to `TB-09-platformer-results.json` beside the executable.
The collision API supports one-way platforms; slopes, moving-platform vertical motion, and
multiple jump animation states are not implemented in this testbed.
