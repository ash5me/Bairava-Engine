# TB-07 Top-Down Adventure Integration

Run the public-API integration sample:

```sh
zig build run-tb07
```

Controls:

- WASD or arrow keys: move.
- `E` or `Space`: talk to the villager or use the shrine door when nearby.
- `Escape`: quit.

The sample uses the packaged level map and atlas, tilemap box movement and wall constraints,
camera follow, the warrior animation state machine, a nearby NPC and on-screen interaction hint,
positional interaction audio when an audio device is available, and scene transitions between the
village and shrine. Each scene owns and releases its map, atlas, animation data, and optional sound.

After 600 render frames, and every two seconds until the core journey criteria are satisfied, the
sample writes `TB-07-adventure-results.json` beside the executable. The result remains `incomplete`
until the player has moved, collided with a wall, triggered animation, interacted with the NPC, and
used a door to change scenes. Audio availability and played positional effects are recorded
separately because machines without an audio device cannot exercise playback.

This is the roadmap's only game-like adventure integration sample. It uses the repository's
existing level and art assets; it is not intended as a complete game, save system, or production
content pipeline.
