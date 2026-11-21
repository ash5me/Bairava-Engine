# TB-19 Resource and Entity Lifecycle

Purpose: stress ECS entity generations and public texture handle lifecycles independently of
gameplay.

## Run

```sh
zig build run-tb19 -- --count 100 --cycles 60 --frames 180
zig build run-tb19 -- --count 500 --cycles 30 --frames 180
zig build run-tb19 -- --count 1000 --cycles 15 --frames 180
```

Supported counts are `100`, `500`, and `1000`. `--cycles` controls lifecycle interval in updates.
`--frames` controls when the JSON summary is written. The window remains open until Escape.

The laboratory verifies:

- Entity despawn rejects stale handles and double despawn is safe.
- Slot reuse changes the entity generation and old handles stay stale.
- Rows keep their handles after removal and replacement.
- Texture handles use counted references and release as two holders.
- Unloading a texture rejects stale copies and recreating it uses a new load.
- The scene-owned workload continues after the summary is written.

The run writes `TB-19-resource-entity-lifecycle-results.json` beside the executable.

## Existing coverage

The ECS unit tests cover AoS and SoA handles, row moves, reverse-order mutation, stale handles,
and failed spawn atomicity. The asset cache tests cover stale handles, double release, retained
references, release/reacquire generations, and repeated unload cycles.
