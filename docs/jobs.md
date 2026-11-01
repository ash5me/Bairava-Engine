# Jobs and background loading

The job system runs work on worker threads. Its first user is texture loading: a requested texture is decoded on a
worker, and the main thread uploads it to the GPU between frames.

## Parts

- `src/engine/jobs/jobs.h`, `jobs.c`: the C core. A pool owns its threads, a bounded queue, and a mutex with two
  condition variables. POSIX threads are used on Linux and macOS, and Win32 threads on Windows.
- `src/engine/jobs/jobs.zig`: the Zig interface. `Pool.submit` takes a typed function and its data, and `wait` and
  `isDone` read a counter.
- `src/engine/core/texture_stream.zig`: the streamer, which moves textures through the pool. See "Texture loading".
- `src/engine/assets/staging.zig`: the CPU half of texture loading. It reads and decodes a texture with no GPU calls
  and no logging, so it can run on a worker.

## Rules for jobs

A job runs on a thread that is not the main thread. To keep it safe:

- Do not log. The logger is not safe to call from several threads.
- Do not touch the GPU, the texture store, the asset arenas, or game state. Those belong to the main thread.
- Allocate only through an allocator that is safe to use from several threads. The engine passes the page
  allocator, which is.
- Keep a counter alive until every job submitted with it has finished and has been waited on.
- A job may submit jobs and wait on them. A waiting thread runs queued jobs while it waits, so a single worker
  cannot deadlock on its own children.
- Hand results back through memory the caller reads only after `wait` or `isDone` reports completion. The pool's
  lock makes those reads see the writes.

With zero workers, every job runs on the thread that submits it. Tests and single-threaded builds use this mode.
A full queue also runs the job on the submitting thread, so `submit` never blocks.

## Configuration

- `Config.worker_threads` (default 2, at most 32) sets the number of workers. Zero runs everything on the main
  thread.
- `Config.allocator` must be safe to use from several threads when `worker_threads` is above zero.
- `Config.texture_loads_per_frame` (default 2) caps the texture uploads per frame. Each upload copies pixels to the
  GPU, so this bounds the GPU work per frame.

## Texture loading

`Context.requestTexture` marks a registered texture for preloading. Each frame, before the updates, the runtime calls
`Streamer.pump`, which does three things on the main thread:

1. Uploads finished decodes, up to the per-frame cap. A decode that finishes after the cap waits for a later frame.
2. Reports failed decodes. The texture store counts each one, and the log names it. A failed texture is not retried
   until it is requested again.
3. Starts decodes for waiting requests while one of the four in-flight slots is free.

Each in-flight slot holds its decoded pixels until upload, which bounds the memory used by streaming. A texture that a
synchronous `acquireTexture` loads first is not uploaded twice: the stray decode is dropped when it finishes.

`Context.loadTexture` still loads on the calling thread, using the same staging step, so direct loads and
background loads choose the same variant.

Shutdown order matters. The session waits for in-flight decodes (`Streamer.deinit`), then destroys the pool, and only
then closes the texture store and the GPU.

## Limits

- The queue holds 256 jobs. A full queue runs the job on the caller.
- The streamer has four decode slots.
- The decoded data of a finished but unuploaded texture stays in memory until its upload.

## Testing

- `zig build test` builds and runs the C harnesses `test_jobs` and `test_script` (from `tests/jobs/` and
  `tests/script/`) alongside the Zig tests.
- Run the C job tests under ThreadSanitizer on Linux or macOS with
  `cc -std=c11 -pthread -fsanitize=thread -Isrc/engine/jobs tests/jobs/test_jobs.c src/engine/jobs/jobs.c`.
  The Win32 implementation is not covered by that run.
- The Zig wrapper and the streamer are tested through `zig build test`, where they run in the test binary.

## Not yet done

- Fonts and sounds still load on the main thread. Only textures use the streamer.
- The Win32 thread path has not been run on Windows yet.
