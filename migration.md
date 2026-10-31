<<<<<<< HEAD
# Bairava Engine — P0 Architecture Migration Plan

> **Scope:** P0 foundation work only  
> **Project:** Bairava Engine / Semkootru host application  
> **Status:** P0.1 through P0.7 pass locally on Windows; Linux and macOS remain unverified until CI smoke coverage is available.
> **Baseline reviewed:** Uploaded `Bairava-Engine(1).rar` snapshot and the corresponding `ash5me/Bairava-Engine` source files  
> **Target:** Make Bairava a reusable, game-independent engine module with explicit API, ownership, lifecycle, and dependency boundaries.

---

## 1. Objective

Complete the architectural foundation before adding new engine systems.

At the end of this migration:

1. A game consumes Bairava through a named public Zig module, not by importing engine source paths directly.
2. Gameplay uses documented engine-facing APIs and does not depend on SDL implementation types.
3. Allocator ownership and resource lifetime are explicit and testable.
4. Engine startup and shutdown have one owner and unwind safely on failure.
5. Engine/game dependency rules are enforced by automated checks.
6. Engine configuration is distinct from game configuration.
7. Recoverable runtime failures use error returns or logged fallback behavior; panics are reserved for violated invariants and unrecoverable programmer errors.
8. The existing Semkootru application continues to build and run throughout the migration.

This is a refactor, not a feature expansion. Do not add physics, scene management, editor tooling, a second renderer, or new gameplay behavior as part of this plan.

## 2. Baseline observations

The reviewed source already has several useful foundations:

- `src/engine/core/engine.zig` acts as a central public re-export module.
- `src/main.zig` delegates startup to `engine.run(Game, config)`.
- `src/game/game.zig` imports the engine facade rather than importing the SDL backend directly.
- `src/engine/platform/platform.zig` centralizes much of the platform API, and its comments establish `platform/sdl/` as the SDL implementation boundary.
- `src/engine/platform/types.zig` defines platform-facing value types without importing SDL.
- `src/engine/core/runtime.zig` and `src/engine/core/lifecycle.zig` provide a centralized runtime/lifecycle path.
- `src/engine/assets/cache.zig` already accepts an allocator and an injected loader, which is a useful ownership pattern to reuse.
- Tests and a boundary-checking workflow are present in the project.

The migration should preserve these foundations rather than replace them wholesale.

### Known gaps to address

| Area | Current observation | Migration target |
|---|---|---|
| Build/package boundary | `build.zig` now provides a named `bairava` module through `src/engine/bairava.zig`; the game imports it by name. Windows and Linux builds pass locally; macOS remains unverified. | Keep module dependencies owned by the engine/game roots and validate the supported CI targets. |
| Public API | `engine.zig` remains the API definition. `Context` no longer exposes a typed GPU-device field, but `Texture` and `SpriteBatch` still expose SDL GPU fields through the public graph. | Audit the complete public type graph and keep SDL handles behind engine-owned abstractions. |
| Renderer boundary | `src/engine/renderer/renderer.zig` imports `platform/sdl/sdl.zig` and uses `SDL_GPU*` types directly. | Keep SDL-specific renderer code explicitly backend-private; expose engine-level rendering operations/types. |
| Allocation | `run` now owns engine/game/asset/frame arenas, and `Context.readFile` accepts an explicit allocator. Audio, UI, texture, and sprite internals still use `page_allocator`. | Finish routing owned runtime allocations through the appropriate allocator role. |
| Resource lifetime | Game code explicitly deinitializes its atlas, UI, audio sound, and level. Runtime owns platform/window/GPU setup. There is no single documented ownership table covering all engine resources. | Document and enforce ownership, destruction order, and failure cleanup. |
| Error policy | Some loading APIs panic on missing or invalid assets while others return errors. | Establish a consistent recoverable-error versus invariant-failure policy. |
| Configuration | `game/config.zig` contains game settings, while `engine.Config` contains window, timing, view, and engine startup settings. | Preserve this split and make the engine configuration a clear public contract. |

**Important:** The public `engine.zig` facade and platform layer already exist. Do not create duplicate facades or a second platform abstraction. Tighten and formalize what is there.

## 3. Priority and dependency order

| Order | ID | Work item | Priority | Depends on |
|---:|---|---|---|---|
| 1 | P0.1 | Expose Bairava as a named reusable Zig module | Critical | Baseline build audit |
| 2 | P0.2 | Stabilize public API and hide backend implementation types | Critical | P0.1 |
| 3 | P0.3 | Define allocator and memory ownership conventions | Critical | Baseline ownership audit |
| 4 | P0.4 | Centralize resource ownership and lifecycle cleanup | Critical | P0.3 |
| 5 | P0.5 | Enforce engine/game dependency boundaries | Critical | P0.1, P0.2 |
| 6 | P0.6 | Formalize engine configuration separately from game configuration | High | P0.1, P0.2 |
| 7 | P0.7 | Standardize runtime error handling and failure cleanup | High | P0.2, P0.3, P0.4 |

Do not run these as independent parallel refactors. Complete each stage's acceptance criteria before moving to the next.

---

# 4. Implementation tasks

## P0.1 — Expose Bairava as a named reusable Zig module

**Goal:** A game imports Bairava through a build-provided module name, such as `@import("bairava")`, rather than importing `../engine/core/engine.zig`.

### Current files

- `build.zig`
- `build.zig.zon`
- `src/main.zig`
- `src/engine/bairava.zig`
- `src/engine_api_test.zig`
- `src/engine/core/engine.zig`
- `src/game/game.zig`

### Work

1. Keep `src/engine/core/engine.zig` as the public API definition. Do not move the source tree yet.
2. In `build.zig`, create a named Zig module rooted at `src/engine/bairava.zig`. This small shim re-exports `core/engine.zig` from the `src/engine` package root; the pinned Zig toolchain rejects the core file's sibling imports when it is itself the package root.
3. Configure the module with the same target and optimization mode as the consuming application.
4. Move engine-specific imports, C source compilation, include paths, build options, and linked libraries into a dedicated engine-module configuration helper. Avoid attaching all engine C sources and dependencies indiscriminately to the game root module.
5. Attach the named engine module to the game/application module using the build API supported by the repository's pinned Zig toolchain.
6. Change game imports from relative engine source paths to `@import("bairava")`.
7. Keep `src/main.zig` responsible for selecting the game and passing startup configuration. It should not initialize SDL or construct renderer internals.
8. Add a minimal engine-module compile test that imports the module without importing `src/game/`.

### Suggested build shape (illustrative; adapt to the project's Zig 0.16 development toolchain)

```zig
const bairava_module = b.createModule(.{
    .root_source_file = b.path("src/engine/bairava.zig"),
    .target = target,
    .optimize = optimize,
    // Add engine-required imports and build configuration here.
});

const game_module = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
});

game_module.addImport("bairava", bairava_module);
```

This is an architectural sketch, not a drop-in replacement for the existing `build.zig`. The existing SDL, C, shader, asset-tool, and profiling setup must be assigned to the correct module or build artifact. Check the actual Zig version/API before editing the build graph.

### Do not

- Move the whole source tree in the same change.
- Publish a separate dynamic library or C ABI.
- Introduce a second game executable before the named module works.
- Duplicate SDL/C dependencies in both the engine and game modules.

### Acceptance criteria

- [x] `src/game/` imports Bairava only through `@import("bairava")`.
- [x] No game source imports `src/engine/...` by relative path.
- [ ] The normal application builds for the existing supported targets.
- [x] Existing `run`, `test`, asset, shader, and profiling build steps still work.
- [x] A tiny test consumer can import the named module without importing any game source.
- [x] Engine C sources are configured once on the Bairava module; the game root owns only Parson.

---

## P0.2 — Stabilize the public API and hide backend implementation types

**Goal:** The game sees engine concepts, not SDL GPU objects or backend-specific implementation details.

### Current files

- `src/engine/core/engine.zig`
- `src/engine/core/context.zig`
- `src/engine/core/runtime.zig`
- `src/engine/platform/platform.zig`
- `src/engine/platform/types.zig`
- `src/engine/renderer/renderer.zig`
- `src/engine/renderer/texture.zig`
- `src/engine/renderer/sprite.zig`
- `src/game/game.zig`

### Work

1. Treat `engine.zig` as the only supported public import root.
2. Mark internal modules as implementation details in documentation and do not re-export them unless a game-facing use case requires them.
3. Audit every public type and function reachable from `engine.zig`, including fields and nested types. A facade is not a boundary if a public field exposes an internal handle.
4. Remove direct GPU-device access from the game-facing `Context`. Prefer engine-owned loading and resource APIs.
5. Review `DrawContext.batch` and `DrawContext.cam`. Keep the existing explicit drawing model if useful, but make sure the exposed types are stable engine concepts and do not contain SDL handles or backend-owned state accessible to gameplay.
6. Make texture, atlas, font, and audio resource types opaque or engine-owned handles where practical. Their public operations should not require SDL types.
7. Keep SDL GPU command buffers, render passes, swapchain details, and SDL handles inside backend implementation files.
8. Document the supported game lifecycle contract: `init`, `update`, `draw`, and `deinit`, including ownership and error behavior.
9. Avoid premature abstraction for hypothetical backends. The immediate target is an SDL-backed engine with a clean public API, not a multi-backend renderer.

### API design principles

- Game code requests actions; it does not operate the SDL device.
- Public types describe engine concepts, not SDL concepts.
- Avoid exposing mutable internal pointers unless the game genuinely needs them.
- Prefer narrow methods over exposing a whole subsystem struct.
- Keep the existing API usable during migration; introduce replacements before removing old fields.

### Acceptance criteria

- [x] The audited public resource types expose no SDL-prefixed field types; backend operations remain module-level renderer internals.
- [x] `Context` no longer exposes a typed GPU-device pointer; its GPU state is represented by a private opaque handle.
- [x] Gameplay can load and use required resources without accessing the GPU device.
- [x] Public API documentation describes the game lifecycle and resource ownership order.
- [x] Semkootru's public API render path completed 156 frames under GPU validation without reported validation messages.
- [x] An API audit test/check identifies SDL-prefixed field types and backend operations on public resource types.

**Progress:** `Context`, `Texture`, and `SpriteBatch` keep GPU state behind opaque handles. SDL-facing texture creation, font baking, and sprite GPU submission are renderer-module operations rather than methods on exported resource types. `engine_api_test.zig` audits the exposed resource fields and public method signatures. A GPU-validation runtime smoke loaded the atlas, font, and ambience, completed 156 presented frames, and exited without reported validation messages; a screenshot was not captured.

---

## P0.3 — Define allocator and memory ownership conventions

**Goal:** Every allocation has a documented allocator, owner, and release point.

### Current files

- `src/engine/core/context.zig`
- `src/engine/core/runtime.zig`
- `src/engine/core/lifecycle.zig`
- `src/engine/assets/cache.zig`
- `src/engine/assets/registry.zig`
- `src/engine/audio/audio.zig`
- `src/engine/renderer/texture.zig`
- `src/engine/renderer/loaded_atlas.zig`
- `src/engine/ui/ui.zig`
- `src/game/game.zig`
- `src/game/save.zig`

### Work

1. Write an ownership inventory for every allocation-owning engine subsystem and game-facing resource.
2. Introduce an engine allocator policy with explicit allocator roles:
   - **Engine allocator:** data that lives for the engine/application lifetime.
   - **Game allocator:** data owned by a game instance.
   - **Frame allocator:** temporary data discarded after a frame/update boundary.
   - **Asset/resource allocator:** data owned by a loaded asset or cache entry, where separate lifetime is needed.
3. Decide which allocators are passed into `engine.run`, stored by runtime, and exposed through a restricted context/service API.
4. Replace hidden `std.heap.page_allocator` use in engine runtime paths with the allocator appropriate to the resource lifetime.
5. For every function returning allocated memory, document who owns it and which allocator must free it.
6. Make allocator use consistent across `readFile`, image decode, atlas parsing, asset registry/cache, and save serialization.
7. Preserve dependency injection in `assets/cache.zig`; use it as a model for testable resource services.
8. Add tests using `std.testing.allocator` for allocation-owning modules. Ensure tests catch leaks and double frees.
9. Do not create a custom general-purpose allocator or memory pool until profiling demonstrates a need.

### Ownership table to maintain

| Resource | Created by | Owner | Allocator / backing | Destroyed by |
|---|---|---|---|---|
| Settings bytes | `lifecycle.readSettings` | `Session` | Engine arena backed by `Config.allocator` | `Session.stop`; arena releases backing storage when `run` ends |
| Window, GPU device, and audio device | Platform lifecycle | `Session` | SDL-owned opaque handles | `Session.stop`, in dependency order |
| Render target and sprite batches | `lifecycle.Session` | `Session` | SDL GPU objects; batch CPU/state allocations use the engine allocator | `Session.stop`, before GPU teardown |
| Texture GPU state | `Texture` renderer functions | Value owner (`Session`, atlas, or font) | SDL GPU handles plus a state record using the caller-supplied engine/asset allocator | `Texture.deinit` |
| Atlas index | `Context.loadAtlas` | `LoadedAtlas`, normally `Game` | Asset arena; allocator is stored by `atlas.Atlas` | `LoadedAtlas.deinit`; arena releases backing storage when `run` ends |
| Level tile map | `Level.load` | `Game` | Asset arena; allocator is stored by `Level` | `Level.deinit`; arena releases backing storage when `run` ends |
| UI font, quad list, and widget context | `ui.Canvas` / `ui.Ui` | Game UI | C-owned font internals; wrapper/list/context allocations use the caller-supplied allocator; font also owns a texture | `Ui.deinit`, which destroys context, font, and list |
| Sound samples | `Audio.loadSound` | Game/caller | Caller-supplied asset allocator, recorded in `Sound.allocator` | `Sound.deinit`; stop its voices first |
| Audio voices and streams | `Audio.play` | `Audio` | Fixed inline voice pool plus SDL stream handles | `Audio.stop`, `Audio.update`, or `Audio.deinit` |
| Asset registry/cache | `Table.init` / `Cache.init` | Caller/cache | Allocator supplied by caller; cache values use loader callbacks | `Table.deinit`, `Cache.unloadUnused` / `Cache.deinit` |
| File read buffers | `Context.readFile` / platform file API | Caller | Caller-selected allocator (`asset` for level/font/atlas, `frame` for save reads); platform API uses its supplied allocator | Caller frees with the same allocator; arena reclaims at run end |
| Save serialization buffer | `save.serialize` | Caller | Frame arena supplied by `Context` | Caller frees with the frame allocator; arena reclaims at the next frame reset |
| Save parser's temporary zero-terminated copy | `save.deserialize` | Function/frame scope | Frame arena supplied by caller | Freed by allocator call or reclaimed at the next frame reset |

Update this table when ownership decisions change. Do not leave a resource with two owners or no owner.

**P0.3 progress:** The ownership inventory and four arena roles are in place. `Config.allocator` is the parent; `run` owns engine, game, asset, and frame arenas. Settings use engine lifetime; `Context` exposes restricted game/asset/frame allocators; level maps, atlas indices, file reads, save serialization, and save parsing select their lifetimes explicitly. Textures and sprite batches record the allocator that created them, and audio loading accepts the asset allocator and records it in `Sound`. Build and tests (**204/204**) pass after this routing. The only source-level `page_allocator` default is `Config.allocator`, which is a deliberate process-level fallback supplied by the caller when no parent allocator is specified; the registry and cache already accept an allocator.

### Acceptance criteria

- [x] All engine allocations have an identified allocator and lifetime.
- [x] No engine API requires callers to guess which allocator frees returned memory.
- [x] `std.heap.page_allocator` remains only where explicitly justified/documented, not as an accidental default.
- [x] Unit tests pass with `std.testing.allocator` and report no leaks.
- [x] Asset cache, atlas, audio, UI, and file-read ownership are documented.
- [x] No use-after-free or double-free is introduced during shutdown.

---

## P0.4 — Centralize resource ownership and lifecycle cleanup

**Goal:** Startup, normal shutdown, and partial-startup failure all release resources in a deterministic order.

### Current files

- `src/engine/core/runtime.zig`
- `src/engine/core/lifecycle.zig`
- `src/engine/core/application.zig`
- `src/engine/core/context.zig`
- `src/engine/platform/platform.zig`
- `src/engine/platform/sdl/`
- `src/game/game.zig`

### Work

1. Document the runtime startup order from platform initialization through window, GPU, audio, game initialization, and main loop.
2. Document the reverse shutdown order.
3. Make the runtime the owner of platform, window, GPU, frame resources, and other engine-global resources.
4. Make the game lifecycle the owner of game-created resources. The engine must not silently free resources owned by the game unless the ownership contract explicitly transfers them.
5. Ensure each successful initialization step registers or establishes its cleanup before the next fallible step.
6. Use structured cleanup (`defer`, `errdefer`, or existing lifecycle helpers) so partial startup failure releases everything already created.
7. Ensure the game `deinit` runs exactly once if and only if game initialization completed successfully.
8. Ensure GPU-dependent resources are destroyed before the GPU device, and streams are destroyed before their audio device.
9. Ensure platform shutdown occurs last, after all SDL-backed resources have been released.
10. Make shutdown idempotent only where that is a deliberate contract; otherwise detect invalid repeated teardown in debug builds.

### Required lifecycle sketch

```text
Start
  |
  v
Initialize platform
  |
  v
Create window and GPU
  |
  v
Initialize audio (optional/fallback policy)
  |
  v
Initialize engine services
  |
  v
Initialize game
  |
  v
Run loop
  |
  v
Game deinit
  |
  v
Release game-independent engine resources
  |
  v
Destroy audio streams/device
  |
  v
Destroy GPU resources/device
  |
  v
Destroy window
  |
  v
Shutdown platform
```

The actual order must follow dependencies in the implementation. In particular, do not destroy the GPU device before textures, atlases, fonts, or other GPU-owned objects.

**P0.4 implementation:**
- `run` owns one `RuntimeAllocators` instance and one `Session`.
- `Session.start` records each completed stage and installs `errdefer self.stop()` before fallible startup work.
- Platform startup failure after settings reads frees settings through the engine arena cleanup and does not call platform shutdown unless SDL was started.
- Window, GPU, target/batch, and audio stages are represented independently, so startup unwinding releases only stages that exist.
- `Session.stop` is idempotent: it marks the session stopped before cleanup, destroys audio streams first, then sprite/texture GPU resources, then the GPU, window, and platform in dependency order.
- Runtime defers run in reverse dependency order: debug overlay, game, session, allocators, and logging. A successfully initialized game has exactly one `defer game.deinit()` before engine teardown; failed startup never initializes or deinitializes the game.

### Acceptance criteria

- [x] Normal startup/shutdown has one documented owner and one path.
- [ ] Injected failures at each startup stage leave no leaked platform or GPU resources.
- [x] Game `deinit` is called exactly once after successful `init`.
- [x] GPU resources are destroyed before GPU device teardown.
- [x] Audio streams are destroyed before the playback device closes.
- [x] Platform shutdown is last.
- [x] Repeated run/exit cycles work without stale global state.

---

## P0.5 — Enforce engine/game dependency boundaries

**Goal:** Make architectural rules executable checks, not just comments or conventions.

### Current files

- Existing boundary-check scripts (locate the current script and preserve its allowlist/behavior)
- `src/engine/`
- `src/game/`
- `src/main.zig`
- CI workflow files

### Rules to enforce

1. `src/engine/**` must never import `src/game/**`.
2. `src/game/**` may import the public `bairava` module only; it must not import engine implementation paths directly.
3. `src/game/**` must not import SDL bindings, `platform/sdl/**`, SDL C headers, or SDL GPU types.
4. SDL imports must remain inside approved backend files under `src/engine/platform/sdl/**` and explicitly approved renderer backend implementation files, until the renderer boundary is fully contained.
5. Build tools and asset-processing tools must not become runtime imports.
6. Engine public API tests must not depend on game modules.
7. Exceptions must be narrow, named, documented, and have an owner/removal condition. Do not add broad directory-wide exceptions to make the scanner pass.

### Work

1. Find the existing boundary scanner and document exactly what it scans and what it excludes.
2. Add the rules above without weakening existing checks.
3. Ensure generated files, vendored dependencies, test fixtures, and build scripts are classified intentionally.
4. Run the checker locally and in CI.
5. Add a negative test fixture for each prohibited dependency direction so a broken rule makes CI fail.
6. Keep the exception list small and review it whenever a new exception is added.

### Acceptance criteria

- [x] Engine-to-game imports fail the boundary check.
- [x] Game-to-private-engine imports fail the boundary check.
- [x] Game-to-SDL imports fail the boundary check.
- [x] Approved SDL backend imports pass.
- [x] The scanner and self-test run in CI on every matrix OS.
- [x] No rule is silently disabled or broadened during the migration.

### Scanner scope and exceptions

- `scripts/boundary_scan.py` scans Zig, C, and header files under `src/`.
- Reachability starts at `src/main.zig`, `src/engine/core/engine.zig`,
  `src/tests.zig`, and `src/engine_api_test.zig`.
- Generated files, vendored dependencies, build scripts, tools, and files
  outside `src/` are excluded unless a future work item deliberately adds them
  to a build root.
- `scripts/boundary-fixtures/` contains isolated positive and negative fixture
  inputs. Fixtures are exercised by `--self-test` and are not part of the
  production reachability graph.
- SDL exceptions are limited to the entries in the scanner's `ALLOWLIST`:
  SDL implementation files, named renderer backend implementation files,
  the platform facade forwarding import, and existing SDL platform tests.
  Any new exception must be path-specific, category-specific, documented here,
  and removed when the containing subsystem is backend-independent.

---

## P0.6 — Formalize engine configuration separately from game configuration

**Goal:** The engine owns platform/window/timing configuration; the game owns its own gameplay settings.

### Current files

- `src/engine/core/application.zig`
- `src/engine/core/settings.zig`
- `src/engine/core/engine.zig`
- `src/game/config.zig`
- `src/main.zig`

### Work

1. Keep `engine.Config` (currently exported from `application.zig`) as the engine startup configuration.
2. Keep game-specific values such as level paths, player tuning, game save filenames, and game controls in `src/game/`.
3. Review every field in `engine.Config` and classify it as:
   - Required engine startup setting.
   - Optional engine setting with a safe default.
   - Game-specific setting that should move out of the engine config.
4. Group related values only where it improves clarity; do not build a generic configuration framework.
5. Validate configuration before initializing SDL/window/GPU. Return a descriptive error for invalid dimensions, update frequency, zoom bounds, or other invalid values.
6. Define precedence between compiled defaults, settings file, and explicit game startup values.
7. Keep settings-file parsing independent of gameplay concepts. The engine may parse window/vsync/fullscreen settings; the game may parse action bindings from its own settings section or file.
8. Document the configuration file format and behavior when fields are absent or malformed.

### Acceptance criteria

- [x] No game-specific concept is required by the engine configuration type.
- [x] Engine configuration validates before platform initialization.
- [x] Defaults and settings-file precedence are documented and tested.
- [x] Semkootru configuration remains in the game layer where appropriate.
- [x] Invalid configuration produces a useful error rather than an unexplained crash.

### Configuration contract

- `engine.Config` owns engine startup concerns only: parent allocation, window
  defaults, reference view, fixed update rate, presentation defaults, zoom
  infrastructure, debug overlay font, logging, and the window settings file.
- Semkootru content and gameplay values stay in `src/game/config.zig`,
  `src/game/game.zig`, and game-owned controls/save modules. The engine config
  does not require game data files or gameplay concepts.
- Every engine config field has a safe default. A game may override defaults
  explicitly at startup.
- Precedence is: engine compiled defaults, then explicit `engine.Config` values
  supplied by the game at `run`, then valid window keys in `settings_file`.
  Missing settings files keep explicit values. Unreadable or malformed lines keep
  the last valid value and log a warning; unknown keys remain available to the
  game.
- The settings file format is `name = value`. Blank lines and lines beginning
  with `#` are comments. Engine window keys are `resolution`, `fullscreen`,
  and `vsync`. `resolution` is `WIDTHxHEIGHT`; booleans accept
  `true`/`false`, `yes`/`no`, or `on`/`off` case-insensitively. Binding lines
  begin with `bind` and are parsed independently by the game.
- Before settings or platform startup, `Config.validate()` rejects empty titles,
  invalid window/native dimensions, invalid update rates, non-finite or
  out-of-range clear colors, invalid zoom bounds/rate, invalid debug fonts, and
  empty settings filenames with specific configuration errors and messages.

---

## P0.7 — Standardize runtime error handling and failure cleanup

**Goal:** Make failure behavior predictable and prevent recoverable runtime problems from terminating the application unexpectedly.

### Current files

- `src/engine/core/context.zig`
- `src/engine/core/runtime.zig`
- `src/engine/core/lifecycle.zig`
- `src/engine/platform/platform.zig`
- `src/engine/assets/loaders/`
- `src/engine/audio/`
- `src/engine/logging/log.zig`
- `src/game/game.zig`

### Error policy

| Failure type | Expected behavior |
|---|---|
| Missing optional sound/device | Return error or use documented silent fallback; log at appropriate level |
| Missing required startup asset | Return a contextual initialization error; application may choose to abort startup |
| Invalid user settings/save file | Log warning and use safe defaults where possible |
| Out of memory | Propagate; do not silently continue with partial state |
| Invalid internal state / violated invariant | Assert or panic in development; preserve useful diagnostics |
| Window/GPU/platform initialization failure | Return startup error and unwind previously initialized resources |

### Work

1. Audit public engine APIs for functions that panic on file, decode, allocation, or device errors.
2. Convert recoverable failures to explicit error unions, beginning with asset loading and file access.
3. Include useful context in errors (asset name/path, operation, subsystem) without forcing every low-level function to allocate formatted strings.
4. Keep `std.debug.panic` for violated invariants and unrecoverable internal corruption, not routine missing files or malformed user data.
5. Define whether game `init` can fail. If it can, make the runtime handle the error and clean up partial engine/game state.
6. Ensure logging does not become the only way callers can detect failure.
7. Preserve the current panic logging hook for truly fatal errors.
8. Add tests for missing files, invalid assets, failed device initialization, malformed settings, and partial initialization cleanup.

### Acceptance criteria

- [x] Recoverable I/O/decode/configuration failures are returned to the caller.
- [x] Error messages identify the failed operation and relevant resource.
- [x] Startup failures unwind all previously initialized resources.
- [x] Optional subsystems retain documented fallback behavior.
- [x] Panics are limited to programmer errors, broken invariants, and truly unrecoverable failures.
- [x] Tests cover both failure return values and cleanup behavior.

### Error contract

- `Context.loadTexture`, `Context.loadFont`, and `Context.loadAtlas` return
  `AssetError` values for missing files, path limits, decode failures, invalid
  indexes, mismatched atlas dimensions, and font failures. Callers can recover,
  log, or abort initialization.
- Game `init` may return an error. The runtime logs it, skips creation of game
  resources and the frame loop, and then runs the session cleanup path.
- Missing optional ambience audio remains silent and logged. Missing debug font
  disables only the debug overlay; gameplay continues.
- Malformed settings and save data remain game/user-data fallbacks and are logged,
  not panics. Settings parse failures keep the last valid value.
- Window, GPU, and platform startup failures return through `Session.start` and
  use staged `errdefer` cleanup. Allocation failures are propagated; they are
  never converted to successful partial state.
- `std.debug.panic` is reserved for violated invariants, backend/internal
  corruption, and other unrecoverable programmer errors. Routine asset and
  configuration failures use returned errors and diagnostics.

---

# 5. Migration sequence and checkpoints

Implement in small reviewable commits. Avoid one large architecture rewrite.

| Commit | Scope | Must pass before merge |
|---|---|---|
| `refactor(build): expose bairava as named module` | P0.1 | Existing build/test/run plus module-only consumer |
| `refactor(api): hide backend handles from game` | P0.2 | Public API audit and Semkootru render smoke test |
| `refactor(memory): define allocator ownership` | P0.3 | Allocator tests and leak checks |
| `refactor(runtime): make lifecycle cleanup deterministic` | P0.4 | Normal and injected-failure lifecycle tests |
| `test(architecture): enforce engine game boundaries` | P0.5 | Positive and negative boundary fixtures in CI |
| `refactor(config): formalize engine startup settings` | P0.6 | Config validation and precedence tests |
| `refactor(errors): propagate recoverable engine failures` | P0.7 | Error-path tests and cleanup tests |

A commit may contain preparatory changes from the next item only when required by the current item. Keep each commit independently buildable.

## 6. Global acceptance gate

P0 is complete only when all of the following are true:

- [ ] The Semkootru application builds and runs through the normal project workflow.
- [ ] A minimal separate consumer imports `bairava` by module name and can create a window, load an asset, render a sprite, and exit cleanly.
- [ ] The separate consumer contains no Semkootru/game imports.
- [ ] Game code cannot import SDL or private engine implementation modules.
- [ ] The public API does not expose SDL types or direct GPU-device access.
- [ ] Allocator ownership is documented and leak-tested.
- [ ] Normal and partial-failure shutdown release resources in dependency order.
- [ ] Engine configuration is independent of game-specific configuration.
- [ ] Recoverable errors are propagated and fatal invariants remain diagnosable.
- [ ] Existing supported CI targets and tests remain green.

## 7. Explicitly out of scope

Do not include these in P0:

- Scene manager or scene editor.
- Physics/collision expansion.
- ECS feature expansion or redesign.
- Renderer abstraction for multiple graphics backends.
- Vulkan/Direct3D/Metal backend implementation.
- Asset hot reload.
- Tilemap or animation editor.
- Gamepad support.
- Particle, lighting, or post-processing systems.
- Scripting, networking, or plugin architecture.
- Gameplay polish or Semkootru-specific features.

These should be reconsidered after the P0 global acceptance gate is met.

## 8. Risks and implementation notes

1. **Zig toolchain compatibility:** The repository uses a Zig 0.16 development toolchain. Build-system APIs can change between development snapshots. Verify the checked-in toolchain before copying examples or changing module construction.
2. **C dependencies:** `build.zig` compiles C sources for SDL-adjacent and engine subsystems. When splitting modules, assign each C source/include path to exactly one owning module or host tool. Avoid duplicate object compilation and linker conflicts.
3. **Public API transitive leakage:** Removing `Context.device` alone is not enough. Audit nested public types such as textures, sprite batches, audio objects, UI/font objects, and any callback signatures for backend pointers.
4. **Ownership migration:** Do not change allocator policy and resource teardown in one untestable step. First document ownership, then migrate one subsystem at a time.
5. **Error-handling scope:** Do not mechanically replace every panic. Some panics represent real invariants. Convert only failures that a caller can reasonably recover from.
6. **Compatibility:** Keep Semkootru working at every checkpoint. Temporary compatibility wrappers are acceptable only when they have a removal condition and are not allowed to become permanent parallel APIs.

## 9. Definition of done

P0 is done when Bairava can be consumed as a named module by a small independent game, its public API does not expose SDL implementation details, and every runtime resource has a clear owner and deterministic cleanup path. Automated architecture checks and failure-path tests must protect those guarantees against regression.

**Next milestone after P0:** P1 core engine functionality (scene lifecycle, 2D collision, ECS integration, asset handles, and gamepad input). Do not start P1 until the global acceptance gate above passes.
=======
# Bairava SDL Platform Boundary Migration Plan

**Status:** Steps 8 and 9 implemented locally. Supersedes the earlier `migration.md`.
**Scope:** SDL3 platform-boundary migration only.
**Baseline:** Bairava-Engine snapshot targeting Zig `0.16.0-dev` and SDL `3.4.2`.
**Verification:** Local `zig build`, `zig build test`, and the SDL boundary scanner pass. The scanner's negative check rejects an SDL import in reachable core code. Hosted Linux, macOS, and Windows CI results remain unverified.

---

## 1. Goal

Confine SDL-specific platform code to `src/engine/platform/sdl/`, with `src/engine/platform/platform.zig` defining the engine-facing platform contract.

After migration:
- Engine code outside a narrow, documented allowlist does not name SDL types, constants, functions, or C bindings.
- Windowing, events, timing, file access, and audio-device operations go through the platform contract.
- SDL3 remains the only backend. No second backend and no runtime backend switching is added.
- GPU rendering remains SDL_GPU-based, but core code uses engine-facing renderer and platform types rather than SDL declarations.
- Existing game-facing APIs and observable behavior remain unchanged.
- Each step is independently buildable, testable, and revertible.

The objective is a real dependency boundary, not merely moving SDL imports into differently named files.

## 2. Non-goals

This migration does not redesign the renderer or shaders, change asset formats, add gameplay or physics features, integrate the generic asset cache, change the public API in `game/`, or make Bairava an independently consumable Zig package or module. The package work is a follow-on milestone (section 12).

## 3. Architectural contract

```text
game/
  |
  v
core/ and engine systems
  |
  +----> platform/platform.zig ----> platform/sdl/
  |
  +----> renderer/ ----------------> SDL_GPU implementation
  |
  +----> assets/, audio/, input/, text/, ui/, ...
```

Rules:
1. `platform/types.zig` contains platform-facing value types and opaque handles. It imports neither SDL nor engine systems.
2. `platform/platform.zig` defines stable SDL-free signatures. It forwards to the SDL backend but does not expose backend signatures.
3. `platform/sdl/` owns SDL initialization, event translation, window and audio handles, timing, and SDL file APIs.
4. `input/` owns semantic input state and applies platform-neutral events.
5. `audio/` owns engine-level sounds, voices, and playback policy. The SDL backend owns device and stream interaction and SDL-specific conversion and decoding.
6. `renderer/` owns rendering-facing values such as the clear color and GPU format mapping.
7. `core/` coordinates systems and does not call SDL directly.
8. Opaque-handle casts live only inside `platform/sdl/`.

## 4. Current state (snapshot)

**SDL identifiers by file.** Counts are lines matching SDL identifiers in the snapshot grep, so they are approximate.

| File | Lines | What it does with SDL |
|---|---|---|
| `core/context.zig` | 11 | GPU device type, GPU texture formats and support check, asset and save file I/O |
| `core/runtime.zig` | 9 | Base path, frame clock, idle delay, `SDL_FColor` clear color, GPU idle wait |
| `core/lifecycle.zig` | 8 | `SDL_Init` and `SDL_Quit`, window, settings read, swapchain format |
| `core/event.zig` | 6 | Event polling, quit, F11 and F3 keycodes |
| `renderer/renderer.zig` | 8 | Render passes; `SDL_FColor` parameter |
| `renderer/shader.zig` | 19 | Shader formats and creation |
| `renderer/sprite.zig` | 84 | SDL_GPU buffers, pipelines, draws |
| `renderer/texture.zig` | 50 | SDL_GPU textures, samplers, transfers |
| `text/font.zig` | 4 | `SDL_GPUDevice` in font signatures |
| `logging/log.zig` | 2 | `SDL_GetTicksNS` for timestamps |
| `assets/loaders/image.zig` | 5 | `SDL_LoadFile` in both loaders |

**Consumed events.** The live code consumes exactly these SDL events: `SDL_EVENT_QUIT`, `SDL_EVENT_KEY_DOWN` (with the repeat flag), `SDL_EVENT_KEY_UP`, `SDL_EVENT_MOUSE_MOTION`, `SDL_EVENT_MOUSE_BUTTON_DOWN`, and `SDL_EVENT_MOUSE_BUTTON_UP`. `Input` uses only the left mouse button. No wheel or window-resize events are consumed, because the window's pixel size is queried every frame. Confirm this on the branch.

**Readable and writable locations.** The base path is the executable's folder. Settings (`settings.txt`) are read from it. The log (`Semkootru.log`) is written to it through `lifecycle.openLog`. The save file is written with `ctx.writeFile` and read with `ctx.readFile` in `game/game.zig`, and both resolve to the same folder. The level map is read with `ctx.readFile` in `game/level.zig`. Because the base path is the executable's folder, asset reads and save reads and writes currently land in the same directory.

**Frame order today.** `runtime.run` calls `SDL_GetBasePath`, then `lifecycle.openLog`, then `Session.start`, which reads settings, calls `SDL_Init`, and creates the window, GPU, and audio. Each frame then measures time, drains events (quit, F11, and F3 are handled, and every event also goes to `Input`), syncs held state from the keyboard state, runs fixed-step updates (with `Input.latch` before each step), updates audio, draws, and presents.

**Key identity.** Bindings already resolve through SDL scancodes in `platform/sdl/input.zig`. F3 and F11 are the only keycode comparisons (`core/event.zig`).

## 5. Decisions

### D1. Forwarding contract
Use explicit forwarding declarations in `platform/platform.zig`. Do not publicly re-export SDL implementation functions. The forwarding signatures are the contract, and they use platform-owned types only.

### D2. Platform types
`platform/types.zig` holds the minimal required types: `Scancode`, `MouseButton`, `Event`, `PixelSize`, `Error`, `max_full_path`, and the opaque handles `Window`, `AudioDevice`, and `AudioStream`. It holds no SDL names and no engine-system imports. GPU types are not defined here. They come from `platform.gpu` (D9).

### D3. Ownership of keys
Keep the engine's `Key` in `engine/input/`, as the revision prefers. Platform events carry a minimal physical-key type, `Scancode`, defined in `platform/types.zig`. It lists the 26 physical keys the engine can receive: the 24 keys `Key` lists today, plus `f3` and `f11`. The SDL backend maps SDL scancodes to `Scancode`. `engine/input/input.zig` maps `Scancode` to `Key` and back. Actions and gameplay bindings stay in `game/controls.zig`.

This keeps the platform layer free of engine imports, at the cost of two short lists that must agree. A sync test checks that every `Key` maps to a `Scancode` and back. If you prefer one shared list, see open decision 1.

### D4. Keyboard mapping
Use scancodes for every key. Current bindings already resolve through scancodes, so this extends the existing convention to F3 and F11 instead of changing bindings. Key-down events carry the repeat flag, and presses ignore auto-repeat as they do today. F3 and F11 match only non-repeating key-downs. Verify movement, F3, and F11 on a non-US layout rather than assuming behavior is unchanged.

### D5. Timing
Keep SDL timing behind `platform.clock`. Expose `nowNs()` and `sleepMs()`. Revisit standard-library timing only after the pinned Zig toolchain is upgraded and tested.

### D6. File access uses explicit locations
`platform.files` takes a location with each call:
- `.packaged` is read-only. It resolves relative to `baseDir()` and holds shipped assets and the level map.
- `.beside_executable` holds settings, the log, and save data. It preserves today's behavior.

Reads are allowed from both locations. Writes are accepted only for `.beside_executable`, and that location is a named compatibility path, not a permanent write policy. Installed application directories may not be writable, so a user-data location should be decided separately (open decision 2).

The game-facing API does not change. `Context.readFile` keeps reading `.packaged`, and `Context.writeFile` keeps writing `.beside_executable`. Today both resolve to the same folder, so the split lives in names and in the write path. The save file is read through `readFile`, so its read and write must move together when a user-data location is approved.

Log paths are built with `files.absolutePath(.beside_executable, name, buf)`, so core never builds paths from raw SDL output. Path and read functions must work before `platform.init()`, because settings are read before SDL initializes today.

Writes must be routed through `platform.files` and nothing else, so grepping for SDL file calls finds every write.

### D7. Logging clock injection
Logging receives a clock through `logging.setClock(fn () u64)`, which `runtime.run` calls before the first log line. Before injection, timestamps print as `0`, and a test pins that behavior. The logger never imports the platform layer.

### D8. Audio split
Engine audio owns `Sound`, voices, and playback policy. `Sound` stores the allocator that owns its samples, and `Sound.deinit` frees with that allocator. The SDL backend owns device and stream operations, format conversion, and WAV decoding, which is exposed as a bytes-in `decodeWav(allocator, bytes)`. IMA sidecar decoding is platform-independent and stays in `audio/ima.zig`. Both WAV and sidecar bytes come from `platform.files`, not from SDL file APIs.

### D9. GPU boundary and allowlist
Core does not import SDL because the renderer uses SDL_GPU.

Core uses `platform.gpu.Device`, `platform.gpu.TextureFormat`, and `platform.gpu.waitIdle`, plus the existing `platform.gpu.Gpu` and `platform.gpu.Frame` lifecycle surface. The GPU aliases and wait function are explicitly forwarded from `platform/sdl/gpu.zig`; core names no SDL identifiers. The renderer owns `renderer.Color`, GPU format mapping (compression to GPU format), and support checks. SDL clear-color construction moves into the renderer.

The allowlist is file-specific, and every entry carries a reason:
- `platform/sdl/**`: the SDL implementation.
- `platform/platform.zig`: explicit forwarders from the engine contract to the SDL backend.
- `renderer/renderer.zig`: render passes and command-buffer calls use SDL_GPU types.
- `renderer/shader.zig`: SDL_GPU shader creation and format flags.
- `renderer/sprite.zig`: SDL_GPU pipelines, buffers, and draws.
- `renderer/texture.zig`: SDL_GPU textures, samplers, and transfer buffers.
- `tests.zig`: imports SDL backend modules so their platform tests are included; it names no SDL C types.

Do not allow all of `renderer/` or `text/` by default. The four renderer backend files account for most remaining SDL names. Moving them under `platform/sdl/` would shrink the allowlist to one directory, but it is a structural change, so it stays out of this plan.

## 6. Target layout

```text
src/engine/platform/
  platform.zig       SDL-free engine-facing contract and forwarders
  types.zig          Scancode, MouseButton, Event, PixelSize, Error, opaque handles
  sdl/
    sdl.zig          SDL C import
    init.zig         SDL init and shutdown
    window.zig       SDL window implementation
    input.zig        SDL event translation, held-key sampling, scancode table
    clock.zig        SDL clock and delay
    files.zig        SDL base path and file I/O, with locations
    audio.zig        SDL audio device, streams, decode and convert
    gpu.zig          SDL_GPU device aliases and waitIdle

src/engine/input/
  input.zig          Key, Key/Scancode table, Input.apply(Event)

src/engine/audio/
  audio.zig          engine audio API, Sound ownership, load and play
  voices.zig         voice management
  ima.zig            platform-independent IMA sidecar decoder
```

This is a target shape, not a requirement to create duplicate files where equivalent modules already exist.

## 7. Migration steps

Each step is one commit. At the end of every step, run `zig build` and `zig build test`. If a step fails, stop and fix it before proceeding.

### Step 0: Baseline and boundary report

1. Record the branch and commit being migrated.
2. Run `zig build` and `zig build test` on the development machine and record the results.
3. Record CI results for Linux, macOS, and Windows. Mark platforms that could not run as unverified. Do not assume success.
4. Add a warning-only boundary scanner to CI on Ubuntu. It is a grep-based step with no Windows or macOS dependency.
5. The scanner reports file and line for `SDL_` and `SDLK_` identifiers, SDL type names (`SDL_Window`, `SDL_Event`, `SDL_GPU*`, `SDL_Audio*`, `SDL_FColor`), direct imports of `sdl.zig`, `@cImport`, and `c.` namespace references. Match the last as `(^|[^.A-Za-z_])c\.[A-Za-z_]` so that `std.c.` is not counted.
6. Mark each hit as allowed or not against the D9 allowlist. Report allowed hits separately, so the warning list shows only real violations.

**Done when:** the baseline is recorded and the warning report reproduces locally and in CI.

### Step 1: Verify and remove unreachable legacy files

The 31 root-level files below are candidates, not an unconditional deletion list. An import-graph walk from `main.zig` and `tests.zig` shows none is reachable. They are `animation.zig`, `asset_cache.zig`, `assets.zig`, `atlas.zig`, `audio.zig`, `audio_voices.zig`, `camera.zig`, `debug_overlay.zig`, `engine.zig`, `entity.zig`, `frame_history.zig`, `hash_map.zig`, `ima.zig`, `image.zig`, `input.zig`, `loaded_atlas.zig`, `log.zig`, `math.zig`, `profile.zig`, `renderer.zig`, `sdl.zig`, `settings.zig`, `shader.zig`, `sprite.zig`, `string.zig`, `texture.zig`, `tilemap.zig`, `tilemap_draw.zig`, `ui.zig`, `vector.zig`, and `view.zig` under `src/engine/`.

1. Re-check imports, build scripts, generated code, scripts, docs, tests, and tooling on the current branch.
2. Check git history and uncommitted work for each candidate.
3. Confirm no path-based or tooling dependency remains.
4. Delete only files proven obsolete.
5. Keep the commit deletion-only. Move or refactor anything still needed in a separate commit.

**Done when:** build and tests pass, and the commit contains only verified deletions.

### Step 2: Platform event contract

The event contract must preserve every event that engine and game code consume today. The minimum set, from the snapshot, is quit, key down with repeat, key up, mouse motion, and mouse button down and up. Add wheel or resize only if the branch consumes them.

```zig
pub const MouseButton = enum { left, right, middle };

pub const Event = union(enum) {
    quit,
    key_down: struct { scancode: Scancode, repeat: bool },
    key_up: struct { scancode: Scancode },
    mouse_motion: struct { x: f32, y: f32 }, // window points
    mouse_button_down: MouseButton,
    mouse_button_up: MouseButton,
};
```

Do not silently discard quit events. Unknown SDL events may be ignored. Currently consumed events may not be.

Implementation:
1. Add `Scancode`, `MouseButton`, and `Event` to `platform/types.zig`.
2. In `platform/sdl/input.zig`, split pure translation, `translate(*const c.SDL_Event) ?Event`, from polling, `poll() ?Event`. Polling drains `SDL_PollEvent` and skips events that do not map. The scancode table and the existing SDL-event tests stay in this file.
3. `platform.zig` forwards `events.poll()` and `events.isHeld(scancode)`.
4. In `engine/input/input.zig`, keep `Key`, add the `Key`/`Scancode` table, and add `Input.apply(Event)`. It calls the existing `keyDown`, `keyUp`, `moveMouse`, and `leftButton` methods. Non-left buttons are ignored, as today.
5. Held-state sampling stays separate. Once per frame, after the drain, `runtime` loops over `Key` and calls `input.setHeld(key, platform.events.isHeld(scancodeOf(key)))`.
6. `core/event.zig` drains `platform.events.poll()`. It handles `quit`, and it handles F11 (non-repeating key-down, toggles fullscreen) and F3 (non-repeating key-down, toggles the overlay) by scancode. Everything else goes to `Input.apply`.
7. Document frame order at the top of `input/input.zig`: events, then held-state sampling, then update steps (latch before each step), then draw. Presses and releases accumulate in `Input` between update steps, so a frame with no update step keeps them.
8. Test translation without a window: each event type, the repeat flag, unknown events returning `null`, and a sync test that the `Key`/`Scancode` table covers every `Key`.

**Done when:** no `SDL_Event` or SDL key constant appears outside `platform/sdl/`, and the event and input tests cover the consumed set.

### Step 3: Opaque window handle

1. Define `Window` as an opaque platform handle in `types.zig`.
2. Keep SDL window pointers private to `platform/sdl/window.zig`.
3. Make `Session`, event coordination, and runtime use `*platform.Window`.
4. Keep all conversions between the opaque handle and `*c.SDL_Window` inside the SDL backend.
5. `Gpu.init` accepts `*platform.Window` and performs the SDL conversion inside `platform/sdl/gpu.zig`.

**Done when:** `SDL_Window` appears only in `platform/sdl/`, and window operations compile through the contract.

### Step 4: Centralize initialization and shutdown

1. Add `platform/sdl/init.zig` with platform `init()` and `shutdown()`.
2. Preserve startup order: settings and the base path are read before SDL initialization, and stay available before it unless separately proven otherwise.
3. Video, window, and GPU initialization failures remain fatal, as today.
4. Audio subsystem and device initialization failure remains nonfatal. Log a warning and allow silent gameplay.
5. Audio teardown closes only the device and streams it owns. It does not call `SDL_Quit` or tear down the subsystem.
6. Call `platform.shutdown()` once, after audio, GPU, and window resources are released.

The startup order is `init` (settings read, `platform.init`), then window, GPU, and audio device. The shutdown order is audio device, batches, target, GPU, window, then `platform.shutdown`.

**Done when:** `SDL_Init`, `SDL_Quit`, and `SDL_InitSubSystem` appear only in `platform/sdl/init.zig`, the startup order is documented, and a missing audio device still starts the game.

### Step 5: Clock and logging

1. Add `platform/sdl/clock.zig` and forward `nowNs()` and `sleepMs()`.
2. Replace the direct SDL timing calls in `runtime.zig`.
3. Remove the SDL import from `logging/log.zig`. Add `setClock`, and have `write` use it for timestamps.
4. `runtime.run` calls `logging.setClock(platform.clock.nowNs)` before `lifecycle.openLog`, so the first log line is timestamped.
5. Test pre-injection behavior (timestamps print as `0`) and verify that timestamps stay consistent with the runtime clock after injection.

**Done when:** `logging/log.zig` has no platform or SDL dependency, and `runtime.zig` makes no direct SDL timing calls.

### Step 6: File access and ownership

1. Add `platform/sdl/files.zig` with `baseDir()`, `read(allocator, location, path)`, `write(location, path, bytes)`, and `absolutePath(location, path, buf)`.
2. `read` returns bytes owned by the caller's allocator. The SDL buffer is freed inside the backend.
3. Reads return `NotFound` only when the path does not exist, and `ReadFailed` for any other failure. Check existence with SDL's path-info API before loading, and confirm that function on SDL 3.4.2. Compressed-variant loading treats only `NotFound` as an absent variant and propagates everything else.
4. Writes are accepted only for `.beside_executable`. Other write attempts return an error.
5. Route settings reads, `Context.readFile`, and `Context.writeFile` through the platform file API, following D6.
6. Change image loading to accept bytes. `loadRgba8(path)` becomes `decodeRgba8(bytes)`. `loadCompressed(path, ...)` goes away, and callers read the bytes and call the existing `parseCompressed`. The stb decode already works from memory.
7. Keep image decoding independent of SDL.
8. Test that allocator ownership holds, that a missing file returns `NotFound`, that an existing file's bytes match, and that writes to `.packaged` are rejected. Test `decodeRgba8` with `@embedFile` on a small asset, so the test needs no working directory.

**Done when:** SDL file functions appear only in `platform/sdl/files.zig`, `assets/loaders/image.zig` has no SDL import, and the file and decode tests pass.

### Step 7: Audio ownership and backend split

1. Keep engine-level `Audio`, `Sound`, and voice policy in `engine/audio/`.
2. Keep SDL device and stream operations in `platform/sdl/audio.zig`.
3. Use opaque `AudioDevice` and `AudioStream` handles at the contract boundary.
4. Expose WAV decoding through `decodeWav(allocator, bytes)`, so file I/O stays in the file layer.
5. Keep IMA sidecar decoding pure and independent of SDL.
6. `Sound` stores its allocator, and `Sound.deinit` frees with it.
7. Remove public exposure of SDL audio structures, such as `Audio.format: c.SDL_AudioSpec`. Expose only an engine-level `PcmFormat` (sample rate, channels, sample kind) defined in `types.zig`.
8. Split tests. Decode tests run without a device. Conversion tests run where possible without playback hardware. Device creation and playback get a manual smoke test or a suitable CI host.

Confirm that `decodeWav` works without an initialized audio device. If it needs `SDL_Init`, the decode tests can initialize SDL without opening a device.

**Done when:** SDL audio types and functions appear only in `platform/sdl/audio.zig`, decode tests pass, and optional audio initialization stays nonfatal.

### Step 8: Remove SDL references from core and narrow the GPU boundary

1. Replace `SDL_FColor` in `core/runtime.zig` with `renderer.Color`, a plain four-float struct. `renderer.beginPass` converts it to SDL_GPU types.
2. Route GPU idle waiting through `platform.gpu.waitIdle`.
3. `core/context.zig` types its device as `platform.gpu.Device`.
4. Move GPU texture-format mapping and support checks out of `core/context.zig` and into `renderer/texture.zig`. `Context` keeps the file-loading logic.
5. `core/lifecycle.zig` types the swapchain format as `platform.gpu.TextureFormat`, and passes it to renderer constructors.
6. Inspect lifecycle, runtime, and context for SDL identifiers, imports, and `c.` references, not only direct imports.

**Done when:** no file under `core/` imports SDL, names an SDL identifier, or uses SDL C bindings, and rendering still works.

### Step 9: Enforce the boundary and document it

1. Turn the warning-only scanner into a failing CI check.
2. Use the file-specific allowlist from D9. Every exception has a documented reason. `text/font.zig` uses the platform GPU device type and is no longer an exception; `tests.zig` is allowed only to import backend modules for their test declarations.
3. The scanner checks SDL names, constants, types, direct SDL C imports, backend imports, and SDL C namespace aliases. Unrelated C integrations such as cglm and Parson are not SDL boundary violations.
4. Add a negative test. On a temporary branch, add a forbidden SDL reference to a `core/` file, confirm CI fails, then remove it.
5. Update the README architecture rules, source tree, platform and audio descriptions, and test documentation.
6. Update the build and test comments that describe SDL linking and initialization, in `build.zig` and `tests.zig`.
7. Make sure the documentation describes what CI actually enforces.

**Done when:** CI passes on the clean branch, fails on the deliberate violation, and the README rules match the enforced allowlist.

## 8. Verification matrix

Run `zig build` and `zig build test` after every step. Run CI on Linux, macOS, and Windows before merging. Mark unavailable checks as unverified.

| Area | Required check |
|---|---|
| Startup and shutdown | Window opens at the configured size; clean close releases resources |
| Input | WASD, pressed and released edges, mouse motion and buttons, click-to-world mapping |
| Window controls | F3 overlay, F11 fullscreen, quit event |
| Camera and rendering | Camera follow and zoom; textures and overlay font render |
| Timing | Fixed timestep stays stable; delay path works |
| Files | Asset and settings reads work; log and save writes use `.beside_executable` |
| Audio | Game starts without an audio device; decode tests pass |
| GPU | Run with `-Dgpu-debug=true`; validation stays clean |
| Boundary | Scanner reports no forbidden SDL references outside the allowlist |
| Tests | Tests that load `assets/` use the project-root working directory set in `build.zig` |

Manual smoke tests are required after the event, window, lifecycle, files, audio, and GPU steps. If a check cannot run in CI (such as physical audio playback), mark it manual, not passed.

## 9. Risks and mitigations

- **Event loss:** preserve quit and every consumed event, and test translation separately.
- **Input edge timing:** document and test the frame order for event edges and held-state sampling.
- **Startup order:** keep settings and the base path available before SDL initialization.
- **Writable paths:** executable directories may not be writable after installation. Separate asset reads from user-data writes, and keep the compatibility write path explicit.
- **Save coupling:** the save file is read and written through the same base-path helpers. When a user-data location is approved, both must move together.
- **SDL before init:** confirm that `SDL_GetTicksNS` and `SDL_GetBasePath` are valid before `SDL_Init` on SDL 3.4.2. If the clock is not, the first log lines print zero, which is the documented pre-injection behavior.
- **Audio failure policy:** audio initialization stays nonfatal, and subsystem shutdown stays centralized.
- **Allocator mismatch:** free sample data with the allocator that allocated it. `Sound` records that allocator.
- **Opaque casts:** keep casts inside `platform/sdl/`, and only for handles that the backend created. GPU types are aliases, not opaque casts.
- **Key lists:** `Key` and `Scancode` must agree. The sync test is the guard.
- **Keyboard layouts:** test F3, F11, and movement on a non-US layout.
- **Toolchain drift:** use only APIs supported by the pinned Zig development version.
- **False positives:** report file and line, and keep the allowlist narrow. Do not weaken checks to make CI pass.

## 10. Rollback

Each step is one commit and should be independently revertible. Revert in reverse order. Do not combine unrelated refactors with a migration step. If a correction is needed, commit it and verify it before proceeding.

## 11. Open decisions before implementation

1. **Key ownership.** The plan follows the revision's preference: `Key` stays in `engine/input/`, and platform events carry a separate `Scancode`. The alternative is one shared physical-key enum in `platform/types.zig`, re-exported from input. That is simpler, because the current `Key` already lists only physical keys and no actions. Choose one before step 2.
2. **Writable locations.** On the snapshot, settings, the log, and the save file all live beside the executable. This plan keeps that behavior behind `.beside_executable`. Confirm that the branch matches, and decide separately where user data should live, which is a follow-on decision.
3. **Renderer and font allowlist.** On the snapshot, `renderer/renderer.zig`, `shader.zig`, `sprite.zig`, and `texture.zig` need SDL_GPU names in this migration. `text/font.zig` should drop off once it uses `platform.gpu.Device`. `tests.zig` should drop off once the `colorTargetInfo` test moves into `renderer/renderer.zig`. Confirm on the branch.
4. **Consumed events.** On the snapshot, the consumed set is quit, key down with repeat, key up, mouse motion, and left mouse button down and up. Wheel and resize are not consumed. Confirm on the branch, including uncommitted changes.

These are implementation decisions, not reasons to broaden the migration.

## 12. Definition of done

- Platform contract signatures are SDL-free.
- Engine core contains no SDL imports, SDL identifiers, or C binding references.
- Remaining SDL references are inside the documented, file-specific allowlist.
- CI enforces the boundary, and the negative test proves it can fail.
- `zig build` and `zig build test` pass.
- Linux, macOS, and Windows CI pass, or unavailable platforms are explicitly marked unverified.
- The game-facing API and observable behavior remain unchanged.
- The README describes the actual architecture and the enforced rules.

**Follow-on milestone (not part of this plan):** export Bairava as an independently consumable Zig module or package, make Semkootru consume that public module, integrate the asset manager with runtime resource ownership, and validate the boundary by building a second distinct game without modifying Bairava internals.

---

## Appendix A: Changes from the previous draft

- Structure and rules follow `revision_20plan.md`.
- Current-state facts from the snapshot were added: the consumed event set, the readable and writable locations, and SDL identifier counts per file.
- The previous draft recommended moving `Key` into `platform/types.zig`. This revision keeps `Key` in `engine/input/` and adds a platform `Scancode`, per the revision's preference. Open decision 1 covers the alternative.
- File access now takes an explicit location. The previous draft's `files.read` and `files.write` had no notion of location, so the write path was implicit.
- The allowlist is file-specific. The previous draft allowed `renderer/` and `text/` directory-wide.
- Core names exactly three GPU items through `platform.gpu`. The renderer owns `Color` and format mapping.
- Step 0 runs the scanner on Ubuntu only, as warning-only, with a precise pattern for `c.` references.
- Step 1 verifies candidates before deletion. The previous draft treated the list as settled.
- Step 2 names the event set and the frame order.
- Step 9 adds the negative test and the README corrections.
- Open decisions now record what the snapshot shows.
>>>>>>> main
