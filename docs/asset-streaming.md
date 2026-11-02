# Asset streaming

The texture store supports prioritized preloading, background decode, bounded in-flight staging, and a GPU-memory
budget. Textures needed immediately can still be acquired synchronously; preloading lets the runtime do CPU work ahead
of demand.

```zig
try ctx.requestTexture("forest", .high);
try ctx.requestTexture("menu", .normal);
try ctx.requestTexture("distant", .low);
```

The runtime starts requested loads between frames. Requests are serviced high to low priority, with registration order
breaking ties. Image files are read and decoded on worker threads into staging memory; GPU upload and installation
happen on the main thread. At most four decode/upload jobs are in flight, and `Config.texture_loads_per_frame` caps
uploads per frame. Set it to zero to disable background preloading. `Config.worker_threads` controls the shared worker
pool; zero runs jobs synchronously on the main thread.

`Config.texture_staging_budget_bytes` bounds the sum of decoded/compressed payloads held by in-flight loads until
upload. Its default is 128 MiB; zero removes the cap. A texture larger than the entire budget fails explicitly. If a
texture fits the budget but not the currently available portion, its request is deferred and retried at its original
priority after staged payloads are uploaded or discarded. `Streamer.stagedBytes()` and each pump's `deferred` count
expose current use and temporary pressure. The cap applies to retained payloads, not source-file read buffers or
temporary decoder internals.

`Config.texture_budget_bytes` sets the resident texture-cache budget. Loaded textures are estimated at four bytes per texel.
When a new texture exceeds the budget, the least-recently-used unreferenced textures are evicted first. A texture with a
live handle is never evicted, so the budget can temporarily be exceeded while all candidates are in use. Call
`ctx.releaseTexture` when a handle is no longer needed, then `ctx.unloadUnusedTextures` if immediate reclamation is
desired. `ctx.textureStats()` reports resident bytes, loaded count, evictions, and budget pressure.

The lower-level generic asset `Store(T)` also exposes `request`, `pump`, `setBudget`, `beginLoad`, `finishLoad`, and
`failLoad`. Those operations let a store keep cache bookkeeping on its owning thread while a caller performs a
thread-safe CPU load elsewhere. GPU resources must still be created and destroyed on the graphics-owning thread.
Workers must use a thread-safe allocator and must not access the store, game state, GPU, or logger.

The current asynchronous pipeline is for textures. Other asset types can use the generic store's split-load interface
when their loader and ownership rules support background work.
