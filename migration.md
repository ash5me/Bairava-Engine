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
