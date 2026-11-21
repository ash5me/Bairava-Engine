# TB-02 Asset Loading and Streaming

Purpose: validate texture discovery, cache identity, counted handles, eviction/reload, worker
requests, missing assets, and hot-reload polling through the public engine API.

## Run

```sh
zig build run-tb02 -- --count 100 --cycles 60 --frames 180
zig build run-tb02 -- --count 500 --cycles 30 --frames 180
zig build run-tb02 -- --count 1000 --cycles 15 --frames 180
```

The `--count` value controls repeated asset requests and the visual sprite workload.
Supported values are `100`, `500`, and `1000`. `--cycles` controls how often live handles are
released, idle textures are evicted, and textures are acquired again. `--frames` sets the frame
count at which the metrics summary is written. The window remains open until Escape.

The sample:

- Registers and acquires four public texture assets.
- Retains and releases handles, then verifies repeated identities through cache stats.
- Requests preloading through the worker texture streamer.
- Deliberately acquires a missing asset and records the recoverable error.
- Releases live references and unloads unused textures periodically.
- Watches `assets/forest_bush.png` for settled development hot reload changes.
- Writes `TB-02-asset-streaming-results.json` beside the executable.

## Known limitations

- Corrupt and unsupported compressed variants are covered by the headless staging tests, not by
  automatic file corruption in this visual sample.
- The sample records missing-file behavior and cache/eviction metrics but does not synthesize
  staging-budget exhaustion or GPU upload-depth saturation.
- Reference screenshots are not generated automatically.

## Existing coverage

The unit suite already covers cache hits, stale handles, retained references, repeated unload/load
cycles, cache budgets, preloading priorities, worker tickets, staging variants, staging budgets,
settled hot reload, and transitive asset dependencies.
