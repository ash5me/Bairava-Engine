# Changes: job system and scripting

## Requirements implementation update

- Completed manifest asset validation, dependency graphs, generated runtime indexes, BC1/BC3/ASTC/RGBA8 texture variants, and build-time font sidecars.
- Added configurable bitmap/SDF font ranges, kerning metadata, dynamic glyph cache growth, and FreeType CFF support.
- Added ECS collision components with AABB/rotated boxes, layers and masks, SAT overlap, oriented point containment, linear queries, and a uniform-grid broad phase.
- Added integer IDs alongside string names for skeleton and state-machine animation events.
- Added normal-map sprite rendering and ECS point-light/shadow-component accumulation.

## What was added

- Job system, C core: `src/engine/jobs/jobs.h`, `jobs.c`. Worker threads, a bounded queue, counters, and waits that run
  queued jobs. POSIX and Win32 thread paths.
- Job system, Zig interface: `src/engine/jobs/jobs.zig`.
- Background texture loading: `src/engine/core/texture_stream.zig` (streamer) and `src/engine/assets/staging.zig`
  (CPU decode, no GPU or logging). Requested textures decode on workers and upload on the main thread between frames.
- Cache split for background loads: `beginLoad`, `finishLoad`, `failLoad` in `src/engine/assets/cache.zig`, forwarded
  by `manager.zig`.
- Quiet platform read for workers: `readQuiet` in `platform/sdl/files.zig` and `platform/platform.zig`.
- Scripting runtime, C core: `src/engine/script/script.h`, `script.c`. Tokenizer, parser, tree-walking evaluator, host
  bindings, step and depth limits, reload that keeps the previous script on failure.
- Scripting runtime, Zig interface: `src/engine/script/script.zig`, with typed bindings through `Bindings(Ctx)`.
- Game bindings and example: `src/game/script_host.zig`, `assets/scripts/game.bs`, hook in `src/game/game.zig`, script
  path and step budget in `src/game/config.zig`, manifest row `game_script` in `assets/asset_manifest.txt`.
- Tests: `tests/jobs/test_jobs.c`, `tests/script/test_script.c`, `tests/script/fuzz_script.c` (manual),
  new cache tests, staging tests, job and script Zig wrapper tests, a worker-count validation test in
  `application.zig`.
- Docs: `docs/jobs.md`, `docs/scripting.md`; README status rows and project structure; `src/engine/jobs/README.md`.

## What changed

- Added a repository-specific [Dear ImGui migration plan](docs/dearimgui-migration-plan.md) covering build integration,
  native-input mapping, font/renderer adapters, Semkootru parity, testing, rollback, and legacy removal.
- Debug UI: compact native overlays cap width to 44% and height to 42% of the view, limit text rows to the
  available height, and reduce graph/strip heights on small views. Semkootru uses a 7-pixel native UI font,
  a 140-pixel maximum panel width, and compact screen heights.
- `Config.worker_threads` (default 2, max 32). `Config.allocator` must be thread-safe when workers are above zero.
- `texture_loads_per_frame` now caps uploads per frame, not loads.
- `Context.loadTexture` uses the same staging step as background loads. New `Context.stageFormats` and
  `Context.uploadStaged`. `Context.worker_allocator` added.
- `runtime.zig` calls `session.streamer.pump` instead of `session.textures.pump`.
- `lifecycle.zig` creates the pool after the platform starts, and the streamer after the texture store. Shutdown waits
  for decodes, then destroys the pool, then closes the textures.
- `build.zig`: C sources and include paths for the engine and the test module, two C test harnesses in `zig build test`,
  and `vendor/stb_image_impl.c` in the test module.
- `build.zig.zon`: `assets` and `tests` added to `.paths`, since the build now reads assets and runs C tests.
- Engine API version not changed (0.1.0). The additions are compatible; bump to 0.2.0 if you consider this a release.

## Verification status

- Checked by running: the C job tests (ASan, UBSan, and ThreadSanitizer over five runs), the C script tests (ASan,
  UBSan, `-Werror`), and a fuzz run over 60,000 random programs. All on Linux with gcc 13.
- Not checked: any Zig file. This sandbox has no Zig compiler and the archive has no `vendor/` directory, so the full
  build could not run. Expect a few compile errors to fix on the first `zig build test`.
- Not checked: the Win32 thread path, and the C harnesses under the Zig build.

## Asset loading status

- Font parsing/baking and sound WAV/IMA decoding run on worker threads; font atlas texture creation remains on the main thread.
- Scripts reload only on startup; hot reload from the game is not wired.
- The script language has no strings beyond literals, no tables, and no escapes.
- `pthread` is not linked explicitly. Systems with glibc older than 2.34 may need `-lpthread` for the C harnesses.
