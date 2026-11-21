---
title: Bairava Engine Testbed & Validation Roadmap
aliases:
  - Bairava Testbed Roadmap
  - Bairava Engine Validation Plan
tags:
  - bairava-engine
  - testing
  - validation
  - performance
  - roadmap
status: planned
created: 2026-11-21
updated: 2026-11-21
---

# Bairava Engine Testbed & Validation Roadmap

> [!abstract] Purpose
> Build a collection of small, focused sample applications that validate Bairava's systems in isolation and in combination. The testbeds should expose correctness bugs, resource-lifecycle problems, performance limits, integration failures, and weaknesses in the game-facing API before those problems appear in a larger game.

> [!important] Rendering direction
> Keep the existing SDL3-based rendering architecture. Do **not** treat replacing SDL_GPU or completing the SDL3 2D renderer as a prerequisite for this testing roadmap. Vulkan is the preferred direction for a possible future **3D rendering path**; OpenGL/OpenGL ES is not a target in this plan. Any separately approved direct-Vulkan 3D exploration must remain isolated from the existing 2D renderer; it is not a deliverable in this testbed roadmap.

## 1. Goals

The testbed suite should answer five questions:

1. **Correctness:** Does each engine subsystem behave as documented, including edge cases?
2. **Scalability:** How does the subsystem behave as object counts, assets, text, effects, and workload increase?
3. **Lifecycle safety:** Are resources created, used, unloaded, and destroyed without leaks, stale handles, use-after-free, or invalid GPU operations?
4. **Integration quality:** Can multiple engine systems work together without hidden coupling or contradictory ownership rules?
5. **Usability:** Can a game developer accomplish common tasks through the public API without reaching into engine internals?

The testbeds are engineering tools, not necessarily games. Prefer a small reproducible scenario, visible debug overlays, configurable workload parameters, deterministic input, and machine-readable results over polished presentation.

## 2. Testbed categories

Organize the suite into three layers:

| Category | Purpose | Typical output |
|---|---|---|
| Core system testbeds | Exercise one subsystem with controlled inputs | Correctness checks, limits, and performance measurements |
| Integration testbeds | Combine multiple systems in realistic gameplay conditions | Evidence that systems work together through public APIs |
| Specialized testbeds | Exercise less frequently used capabilities and lifecycle boundaries | Focused validation for lighting, audio, jobs, navigation, render-graph behavior, and SDL_GPU backend parity |

The suite has **one** small game-like integration sample: TB-07. Grow that sample into the showcase rather than creating a second adventure project later.

## Shared harness and headless validation

The common harness is part of the first implementation step. Cover lifecycle and deterministic behavior that do not need a window or GPU. Keep pure logic checks in `tests/`; use a visual testbed only when real rendering, atlas behavior, frame timing, or physical devices must be observed.

### Fixed timestep and render interpolation

**Code areas:** `src/engine/core/fixed_timestep.zig` and the application loop.

Run as headless tests using an injectable clock or controlled elapsed-time sequence:

- A large frame hitch is clamped according to the configured maximum catch-up policy.
- Spiral-of-death protection stops unbounded simulation catch-up.
- Pause/resume does not accumulate unintended simulation time.
- The same total elapsed simulation time produces the same simulation tick count when delivered through low-FPS and high-FPS frame sequences.
- Render interpolation remains bounded and does not mutate authoritative simulation state.

### Scene stack and transition lifecycle

**Code areas:** `src/engine/scene/scene.zig` and `scene_manager.zig`.

Test `push`, `pop`, and `switchTo` with instrumented scenes:

- A failed `init` leaves the previous scene active and usable.
- A newly pushed/switched scene is not updated in the middle of a transition before it is ready.
- Pop/switch operations call `deinit` exactly once for the outgoing scene.
- Entities, scene-owned assets, and callbacks are released when a scene is removed.
- Repeated transitions do not leave stale references or duplicate updates.

These are harness gates and must pass before TB-07 is built.

### Startup, persistence, crash, and shutdown checks

Keep these as automated tests or harness scenarios rather than new windowed applications:

- Startup with a missing asset root, malformed `settings.txt`, or no usable GPU/other required capability exits with a meaningful code and diagnostic log instead of hanging. Use injected capability failures for headless CI and real-device checks where hardware is available.
- Save/settings tests cover corrupt files, simulated partial writes, version migration, and settings surviving abrupt process termination. Persistence policy and save-slot format remain the game's responsibility unless Bairava explicitly owns that feature.
- Run crash-reporting checks in a child process: force a controlled assertion/failure, confirm the crash report and final log output are flushed, then launch a clean process and verify normal startup/shutdown.
- Shutdown with pending jobs must not deadlock the worker pool.
- Use a tracking allocator in the harness so tests can report outstanding allocations and distinguish expected retained caches from leaks.

### Keep unit tests out of windowed testbeds

Math, strings, hash maps, logging format, and localization catalog parsing belong in `tests/`. Extend the existing text, jobs, script, and UI test coverage there. Behavior-tree logic in `ai/behavior_tree.zig` should also be tested as unit tests. A visual lab should only be added when it validates something unit tests cannot observe, such as GPU output, glyph atlas pages, frame time, or real input devices.

---

# 3. Core system testbeds

These are the first testbeds to implement. Keep them independently runnable so failures can be localized.

## TB-01 — Sprite Rendering Stress Test

**Priority:** P0 — first wave  
**Primary systems:** `SpriteBatch`, materials, texture binding, sorting, camera, lighting

### Purpose

Establish the rendering baseline and discover CPU/GPU bottlenecks caused by sprite count, texture changes, sorting, materials, and visual effects.

### Scenarios

- Render configurable counts: 100, 500, 1,000, 5,000, and 10,000 sprites.
- Use one texture, a small texture set, and many distinct textures.
- Mix translation, non-uniform scale, rotation, alpha, tint, and horizontal/vertical mirroring.
- Exercise Z ordering and Y-depth sorting, including equal-depth and near-equal-depth cases.
- Move and zoom the camera while the scene is heavily populated.
- Exercise parallax layers at several camera positions and zoom levels.
- Add normal maps, point lights, and shadow casters where supported.
- Test off-screen rendering and post-processing separately from the baseline scene.
- Exercise hit-flash effects and debug-draw overlays without allowing them to change sprite ordering or leak render state.

### Measurements

- Average, median, p95, and p99 CPU frame time.
- GPU frame time when reliable GPU timing is available.
- FPS, draw calls, batch count, sprites submitted, and sprites actually drawn.
- CPU time spent sorting and preparing sprite data.
- Texture/material switches and allocation counts.

### Acceptance criteria

- No missing, duplicated, or incorrectly transformed sprites at any supported workload.
- Sorting remains deterministic for equal sort keys.
- Alpha blending, tint, mirroring, scaling, and rotation match reference screenshots.
- Batch/draw-call behavior is observable and consistent with the documented batching rules.
- Extreme workloads fail or degrade predictably rather than corrupting memory or crashing.
- A baseline result file is saved for each tested configuration.

## TB-02 — Asset Loading and Streaming Test

**Priority:** P0 — first wave  
**Primary systems:** asset manifests, texture registry/cache, workers, upload queue, atlas pipeline

### Purpose

Validate resource discovery, loading, caching, upload scheduling, eviction, handle validity, and memory behavior under repeated and bursty workloads.

### Scenarios

- Load 100, 500, and 1,000 assets, using a mix of texture sizes and formats.
- Mix ordinary images, atlas-backed sprites, compressed textures, and normal maps where supported.
- Repeatedly request the same asset to test cache hits and reference counting.
- Load and unload large groups of resources in bursts.
- Saturate the upload queue and staging-memory budget deliberately.
- Exceed configured registry/cache limits and verify the documented failure behavior.
- Exercise idle-resource eviction and reload evicted resources.
- Hot-reload a texture, atlas, and font while each is actively in use; verify dependency invalidation reaches affected consumers.
- Force a reload failure and verify the last known-good asset remains usable.
- Run worker loading while the render thread continues drawing.
- Test missing files, corrupted files, unsupported formats, and interrupted loads.

### Measurements

- CPU memory and GPU memory, including peak values.
- Load/decode duration and GPU upload latency.
- Upload queue depth, staging bytes, uploads per frame, and in-flight uploads.
- Cache hit/miss rate, evictions, reference counts, and active handles.
- Failed loads and reason codes.

### Acceptance criteria

- Repeated loads return the expected resource identity or documented equivalent.
- Unloading one reference does not invalidate another live reference.
- Evicted assets can be loaded again correctly.
- Capacity and memory-budget failures are explicit and recoverable.
- Invalid or stale handles are detected according to the public API contract.
- A failed hot reload preserves the previous valid resource and does not leave dependent assets half-updated.
- Dependency invalidation updates affected consumers without reloading unrelated assets.
- No unbounded memory growth occurs during repeated load/unload cycles.
- Worker threads do not perform renderer-owned GPU operations if the architecture assigns those operations to the render thread.

## TB-03 — Text and Font Rendering Test

**Priority:** P0 — first wave  
**Primary systems:** HarfBuzz shaping, font rasterization, MSDF/coverage rendering, glyph atlas, layout, UI text

### Purpose

Validate shaping, glyph lookup, rasterization, atlas allocation, line layout, Unicode handling, fallback behavior, and rendering quality.

### Scenarios

- Render short labels, long paragraphs, wrapped text, aligned text, and rapidly changing text.
- Exercise Latin, Tamil, and other Unicode scripts available in the test assets.
- Include combining marks, ligatures, punctuation, right-to-left samples where supported, and missing glyphs.
- Use multiple fonts, font sizes, and both MSDF and grayscale coverage paths where supported.
- Request many distinct glyphs to create atlas pressure and page exhaustion.
- Repeatedly change strings, font sizes, and font handles during runtime.
- Test multiline layout, baseline alignment, line height, and fallback glyph behavior.
- Render text through the Canvas, UI, and debug-overlay paths.

### Measurements

- Shaping time, layout time, rasterization time, and GPU submission time.
- Glyph-cache hits/misses, number of glyphs, pages used, and atlas occupancy.
- Atlas-full events, fallback-glyph count, and allocation failures.
- Text dimensions and baseline/line metrics compared with expected results.

### Acceptance criteria

- Shaping and glyph placement are correct for the supported script set.
- Text does not disappear or corrupt adjacent glyphs when atlas pages fill.
- Missing-glyph behavior matches the documented fallback policy.
- Repeated rendering of cached text does not cause unbounded glyph growth.
- Canvas, UI, and debug text use consistent font metrics and ownership rules.
- Reference screenshots are checked at representative sizes and scales.

> [!warning] Important edge case
> Atlas exhaustion must have a defined behavior. The test should confirm whether the engine returns an explicit error, skips affected glyphs, uses a fallback page, or applies another documented policy. Do not silently treat a partially rendered line as a successful result.

## TB-04 — Animation Stress Test

**Priority:** P1 — first wave  
**Primary systems:** sprite clips, animation state machines, transitions, blending, skeletal hierarchy, events

### Purpose

Validate animation correctness and update cost with many concurrently animated entities and complex state transitions.

### Scenarios

- Run 100, 500, and 1,000 animated characters.
- Mix short and long clips, different frame durations, and different playback speeds.
- Trigger frequent state transitions and conditional transitions.
- Exercise blending, one-dimensional blend trees, and skeletal hierarchies where supported.
- Fire animation events at frame boundaries and during transitions.
- Test pause, resume, restart, reverse playback if supported, and entity destruction mid-animation.
- Test missing clips, invalid transitions, and invalid animation references.

### Measurements

- Animation update time per frame.
- Number of active players, state transitions, blend evaluations, and events fired.
- Allocations during steady-state playback and transition bursts.
- Missed, duplicated, or out-of-order events.

### Acceptance criteria

- Playback timing remains stable across frame-rate variation.
- Transitions and blending follow documented rules.
- Events fire exactly as specified, including at clip boundaries.
- Destroyed or replaced entities do not continue receiving animation updates or events.
- Steady-state playback does not allocate unexpectedly unless explicitly documented.

## TB-05 — Collision and Physics Test

**Priority:** P0 — first wave  
**Primary systems:** colliders, broad phase, narrow phase, triggers, raycasts, shape casts, movement resolution

### Purpose

Validate geometric correctness, query behavior, collision filtering, performance, and edge cases in the current collision/movement system.

### Scenarios

- Test 100, 500, 1,000, and 5,000 colliders.
- Mix axis-aligned boxes, rotated boxes, and circles.
- Create dense clusters with many overlapping candidates.
- Test layer/mask combinations and trigger-only objects.
- Run raycasts and box/circle shape casts at different angles and distances.
- Test objects moving quickly across thin colliders to reveal tunneling in movement/query paths.
- Test touching edges, zero-size/invalid shapes, negative scale if supported, and large coordinates.
- Move many actors through narrow corridors and around obstacles.

### Measurements

- Broad-phase candidate count and narrow-phase checks.
- Collision and query time (average and tail latency).
- Number of contacts, trigger transitions, and movement-resolution iterations.
- False positives, false negatives, and missed trigger events.

### Acceptance criteria

- Collision results match known geometric test cases.
- Filtering rules are consistent across overlaps, raycasts, and shape casts.
- Trigger enter/exit events are not duplicated or lost during normal movement.
- High-speed and boundary cases have documented, tested behavior.
- Dense scenes remain within an agreed performance budget or degrade predictably.

> [!note] Scope boundary
> This testbed validates Bairava's current collision detection and movement-resolution capabilities. It must not imply that the engine already has a full rigid-body solver, force integration, or joint simulation.

## TB-06 — Camera and Viewport Test

**Priority:** P1 — first wave  
**Primary systems:** camera, transforms, viewport sizing, render targets, screen/world conversion

### Purpose

Validate camera movement, zoom, smoothing, constraints, high-DPI behavior, resize handling, and any supported multi-view rendering.

### Scenarios

- Follow a moving target with smoothing and dead zones.
- Test camera constraints at map edges and corners.
- Zoom in/out while the target moves.
- Exercise camera shake without changing authoritative camera position or accumulating offsets across frames.
- Use debug drawing for camera bounds, dead zones, viewport edges, and world/screen coordinate checks.
- Resize the window and change drawable size/high-DPI scale.
- Test world-to-screen and screen-to-world conversions.
- Render split-screen or multiple views only if the current API supports them; otherwise record this as a capability gap rather than implementing an ad-hoc workaround.
- Exercise camera changes while off-screen targets and post effects are active.

### Measurements

- Camera update time and transform correctness.
- Viewport dimensions, drawable dimensions, and scaling ratios.
- Render-target switches and per-view rendering cost.
- Visual errors at fractional and integer scaling factors.

### Acceptance criteria

- Camera follow, smoothing, constraints, and zoom behave consistently.
- Resize and high-DPI transitions do not stretch, clip, or misalign rendering unexpectedly.
- Coordinate conversion remains consistent after resize and zoom.
- Unsupported multi-camera features are clearly recorded rather than assumed.

---

# 4. Additional focused core testbeds

These systems deserve independent stress scenarios instead of appearing only as incidental content in a larger game.

## TB-21 — Tilemap Validation and Stress Test

**Priority:** P1 — implement after the Stage 1 reliability gate  
**Code areas:** `src/engine/scene/tilemap.zig` and `src/engine/renderer/tilemap_draw.zig`.

### Scenarios

- Generate small, medium, and large maps with configurable tile counts and dimensions.
- Move the camera across map boundaries and verify tile culling at different zoom levels.
- Test multiple tile layers, visibility/order rules, and sparse/dense regions.
- Exercise animated tiles at different update rates.
- Compare tile collision with sprite collision at edges, corners, and overlapping positions.
- Test map load/unload and repeated scene transitions without retaining stale tile data.

### Measurements and acceptance criteria

- Record visible/submitted tile counts, culled tile counts, draw calls, update/draw time, and memory.
- No tiles should pop, shift, or render in the wrong layer during camera movement.
- Culling must preserve every tile intersecting the visible region and avoid submitting clearly invisible regions beyond the documented margin.
- Animated tiles advance deterministically from simulation time.
- Tile collision coordinates agree with the tilemap's documented world transform.

## TB-22 — Particle Pool and Overdraw Stress Test

**Priority:** P1 — implement after the Stage 1 reliability gate  
**Code area:** `src/engine/particles.zig`.

### Scenarios

- Spawn repeated bursts and sustained emitters at increasing particle counts.
- Destroy an emitter in the middle of a burst and verify already-emitted particles follow the documented ownership/lifetime behavior.
- Exhaust the configured maximum particle count and verify the chosen policy (drop newest, recycle oldest, clamp, or explicit error).
- Reuse pooled slots repeatedly and test reset of every per-particle field.
- Combine transparent particles with sprites, lighting, and camera movement to expose overdraw and sorting issues.

### Measurements and acceptance criteria

- Record active/pooled/free counts, spawn/drop/recycle counts, update time, draw time, and estimated overdraw where available.
- Pool reuse must not leak state from a previous particle.
- Emitter destruction must not invalidate live particles or leave orphaned allocations.
- Maximum-count behavior must be explicit, deterministic, and memory-safe.
- Stress must not cause unbounded allocations after the pool reaches steady state unless growth is explicitly configured.

## TB-23 — Deterministic Input Replay and Checkpoints

**Priority:** P1 — prerequisite for TB-12 long-run campaigns  
**Code area:** `src/engine/replay.zig`.

Replay is a determinism/diagnostics facility, not a game save system. Game persistence remains the game's responsibility.

### Scenarios

- Record input events/actions against simulation tick numbers, not render frames.
- Replay the recorded tick stream and compare deterministic checkpoints with the original live run.
- Test different render-frame rates while preserving the same simulation tick sequence.
- Include fixed random seeds and record deterministic random streams used by the scenario.
- Round-trip replay data through the engine's replay encoding/decoding path.
- Refuse incompatible replay format/version data with an explicit error rather than attempting an unsafe replay.
- Use replay to reproduce TB-09 platformer, TB-10 bullet-hell, and TB-12 long-run failures.

### Measurements and acceptance criteria

- Record replay version, seed, tick count, input-event count, checkpoint hashes, and first divergent tick.
- Replaying the same recording on the same supported deterministic configuration must produce matching checkpoint bytes/hashes.
- A version mismatch or malformed recording must fail explicitly and safely.
- Replay data must not be confused with persistent game save data or silently migrated as a save slot.

## TB-24 — Script Runtime Host Integration Test

**Priority:** P1 — automated host tests first; a visible sample only if needed  
**Code areas:** `src/engine/script.c`, `src/engine/script.zig`, and `tests/script/`.

Extend the existing script tests. One minimal scene using the public API is sufficient; do not build a separate game-like scripting showcase.

### Scenarios

- Validate host bindings and the supported script-to-engine API surface.
- Cause a script error and verify it is reported without terminating the host process or corrupting engine state.
- Exercise script time/instruction budgets and verify runaway scripts are stopped predictably.
- Reload a script and verify old state/resources are released according to the reload contract.
- Change scenes while scripts are active and verify scene-owned script state is dropped and cannot call into destroyed objects.
- Test missing bindings, wrong argument types, invalid handles, and host shutdown with active scripts.

### Measurements and acceptance criteria

- Record script execution time, budget exhaustion, error count, reload count, and active script instances.
- Script errors remain contained and produce actionable diagnostics.
- Budget enforcement prevents a runaway script from hanging the frame/process.
- Reload and scene changes do not retain stale host references or script-owned state.
- Public bindings are exercised from the sample; tests do not rely exclusively on private internals.

---

# 5. Integration testbeds

Integration testbeds combine several systems through the public game-facing API. Their purpose is to reveal failures that isolated subsystem tests cannot catch.

## TB-07 — Top-Down Adventure / Showcase Integration Test

**Priority:** P1 — first complete integration slice

This is the suite's **single** small game-like integration sample. Grow it into the final showcase; do not create a second adventure project later.

### Systems combined

- Tilemaps and sprite rendering.
- Player movement and collision.
- Camera follow and map constraints.
- Animation state machines.
- NPC interactions and UI.
- Positional audio.
- Scene transitions and asset loading.

### Scenario

Create a small explorable map containing a player, NPCs, doors, obstacles, pickups, and interactive objects. The player should move around, interact with objects, trigger animations, and transition between at least two scenes.

### Acceptance criteria

- Systems cooperate without direct access to private renderer or resource internals.
- Scene transitions release old resources and load new resources safely.
- Camera, collision, animation, UI, and audio remain correct during transitions.
- The sample can be built and run from a clean checkout using documented steps.
- It demonstrates a complete but deliberately small gameplay loop through the public API; keep content limited so the sample remains an engine-validation project.

## TB-08 — Isometric World Test

**Priority:** P1

### Systems combined

- Isometric coordinate projection.
- Tilemaps and sprite placement.
- Y-depth sorting and explicit Z ordering.
- Collision and navigation.
- Camera movement and zoom.
- Character movement around tall/overlapping objects.

### Scenario

Build a small isometric map with walls, trees, buildings, elevated-looking props, and a controllable character. The character must pass behind and in front of objects correctly.

### Acceptance criteria

- Projection and inverse coordinate conversion are consistent.
- Depth ordering produces the expected occlusion in representative cases.
- Collision/navigation coordinates remain consistent with the rendered world.
- The test documents any manual workarounds required for elevation or multi-level maps.

## TB-09 — Platformer Test

**Priority:** P1

### Systems combined

- Character movement and collision resolution.
- Jumping, landing, and moving platforms.
- Sprite animation and state transitions.
- Camera tracking.
- Particles, effects, and audio.

### Scenario

Create a short platforming level with ledges, moving platforms, hazards, slopes or one-way surfaces if supported, and checkpoints.

### Acceptance criteria

- Landing and collision behavior is repeatable at different frame rates.
- Moving-platform interactions do not cause obvious jitter or missed contacts.
- Animation states track movement states correctly.
- High-speed movement and edge cases are covered by automated or reproducible tests.

## TB-10 — Bullet Hell Stress Test

**Priority:** P1

### Systems combined

- High sprite counts.
- Object spawning/despawning.
- Collision and spatial queries.
- Animation.
- Particles and lighting.
- Audio voice management.

### Scenario

Spawn configurable waves of enemies and projectiles, including dense patterns, frequent impacts, and continuous cleanup. Include deterministic seeds so the same scenario can be replayed.

### Acceptance criteria

- Object creation/destruction does not leak resources.
- Collision and rendering workloads are measured independently and together.
- Projectiles that leave the play area are reclaimed predictably.
- Performance and dropped/limited effects are visible in a debug overlay.

## TB-11 — UI and Localization Test

**Priority:** P1

### Systems combined

- UI layout and input handling.
- Text shaping and rendering.
- Locale catalogs and fallback behavior.
- Dynamic content and asset selection.
- Keyboard/mouse/gamepad navigation where supported.

### Scenario

Create an inventory, settings screen, dialogue panel, and language selector. Include strings of different lengths, supported scripts, missing translations, and dynamic values.

### Acceptance criteria

- Runtime locale switching updates translated text without restarting where supported.
- Fallback language behavior is deterministic.
- Layout remains usable with long translations and different scripts.
- Focus, navigation, and pointer interaction behave consistently.
- Localized images and sounds are marked as unsupported unless a tested content-selection mechanism exists.

## TB-12 — Long-Running Simulation Test

**Priority:** P1 — late reliability gate

Do not start the long-run campaign until TB-23 replay determinism and the TB-19 lifecycle/leak gate are passing. Short lifecycle tests remain part of Stage 1.

### Systems combined

- Scene lifecycle and transitions.
- NPCs, animation, timers, and scheduled events.
- Asset loading/unloading and cache eviction.
- Audio playback.
- Jobs/background loading.
- UI and text updates.

### Scenario

Run a deterministic simulation with repeated scene transitions, entity creation/destruction, asset bursts, changing UI, and scheduled events. Start with a 30–60 minute run, then add overnight runs for release candidates. Record deterministic checkpoints so a failure can be replayed and narrowed to a specific simulation tick.

### Acceptance criteria

- Memory usage stabilizes after warm-up, allowing for expected cache behavior.
- No monotonic growth in live handles, entities, jobs, audio voices, or GPU resources without an intentional cause.
- No stale-handle access, use-after-free, double destruction, entity-generation misuse, or shutdown deadlock.
- Replay checkpoints remain consistent for the same engine build and replay format.
- The app can close cleanly after the test and after forced error paths.
- Test output includes periodic resource snapshots for trend analysis.

---

# 6. Specialized engine testbeds

These can be developed after the core and integration suites are stable. Some validate current systems; others are exploratory.

| ID | Testbed | Main validation areas | Priority |
|---|---|---|---|
| TB-13 | Lighting Laboratory | Normal maps, point lights, shadow segments, light limits, sorting/interactions | P1 |
| TB-14 | Render Graph Validation | `render_graph.zig` pass order, target reuse/lifetime, resize, pass failure recovery | P1 |
| TB-15 | Audio Laboratory | Voices, buses, IMA decoding, streaming, device loss/reopen, cleanup | P2 |
| TB-16 | Input Laboratory | Keyboard, mouse, gamepad, input buffering, focus loss, disconnect/reconnect | P1 |
| TB-17 | Navigation Laboratory | Pathfinding, flow fields, follow steering, dynamic obstacles, many agents | P2 |
| TB-18 | Job System Laboratory | Queue saturation, cancellation if supported, synchronization, worker shutdown, errors | P1 |
| TB-19 | Resource and Entity Lifecycle Laboratory | Resource handles, entity generations, stale IDs, deferred release, repeated create/destroy | P0 |
| TB-20 | SDL_GPU 2D Backend Parity Smoke | Same scene/seed across Vulkan, D3D12, and Metal where available | P2 / hardware-gated |

## TB-13 — Lighting Laboratory

Create a controlled scene with normal-mapped sprites, overlapping point lights, shadow segments, and moving occluders. Test the documented light/shadow limits, edge cases, and visual output. Capture screenshots for each configuration and record GPU cost as light count increases.

## TB-14 — Render Graph Validation

**Code under test:** `src/engine/renderer/render_graph.zig` (validate the actual implementation, not a hypothetical general-purpose render graph).

- Verify dependency/pass order with graph fixtures and confirm invalid order/cycles are rejected according to the implementation's contract.
- Verify compatible transient targets are reused only when their lifetimes do not overlap.
- Resize the window/render targets and verify target allocation, reuse, and recreation remain correct.
- Force a pass failure. The frame must remain valid and recoverable; later submission or the documented fallback must not consume a half-written target.
- Repeat graph construction/destruction and check for leaked target metadata or backend resources.
- Record pass order, target assignment/reuse, resize events, and failed-pass diagnostics.

Do not claim arbitrary user-authored passes or multiple render targets unless those capabilities exist in `render_graph.zig` and its public API.

## TB-15 — Audio Laboratory

Test simultaneous sound effects, music streaming, bus volume, looping, positional attenuation, and cleanup when emitters or scenes are destroyed. Include WAV and IMA decode paths where supported, missing/invalid files, audio device loss and reopen/recovery. Record active voices, decode failures, underruns where measurable, and audio memory use. Verify device loss does not deadlock the application or leave stale playback handles.

## TB-16 — Input Laboratory

Show the state of every supported physical input and action mapping in an on-screen panel. Test press/release edges, held states, remapping, window focus loss/gain, gamepad removal/reconnection, and input device changes. Include input-buffer timing: verify how short presses are retained or discarded between simulation ticks, including low-FPS frames and pause/resume. Test touch only when a real touch implementation is available.

## TB-17 — Navigation Laboratory

Generate maps with open areas, narrow corridors, blocked routes, disconnected regions, and dynamically changing obstacles. Test ordinary pathfinding plus flow-field generation and follow steering where implemented. Run one agent and then many agents. Record path length, search duration, expansions, field rebuild cost, and behavior when no route exists. Test behavior-tree decision logic in unit tests under `tests/`; do not create a separate visual behavior-tree lab unless a clear rendering/debugging need emerges.

## TB-18 — Job System Laboratory

Exercise small and large jobs, queue saturation, dependencies if supported, error propagation, cancellation if supported, and shutdown while work is pending. Verify that worker threads do not access thread-affine renderer resources directly. Capture queue depth and worker utilization.

## TB-19 — Resource and Entity Lifecycle Laboratory

Stress engine-managed resources and ECS entity identity independently of gameplay.

**Resource checks:**
- Create, retain, release, invalidate, and recreate textures, fonts, audio assets, and other managed objects.
- Test generation mismatches, stale handles, double release, deferred destruction, and shutdown ordering.
- Verify that a released resource cannot be accessed through an old handle, and that reusing a slot produces a new generation.

**Entity checks (`src/engine/ecs/entity.zig`):**
- Destroy an entity, then verify its stale ID is rejected even if the slot is reused.
- Test double destroy and generation boundary behavior according to the ID representation.
- Add/remove entities or components during iteration and verify the documented mutation policy (deferred mutation, safe iteration, or explicit rejection).
- Confirm destruction removes owned components and does not leave dangling references in systems.

This testbed is an early reliability gate and should become a standard regression check for lifecycle changes.

## TB-20 — SDL_GPU 2D Backend Parity Smoke

**Priority:** P2 — hardware-gated; no direct Vulkan renderer work.

The current rendering path remains SDL_GPU. SDL_GPU can select platform graphics backends; this test checks that Bairava's existing 2D scene behaves consistently when SDL_GPU is running on Vulkan, D3D12, or Metal, where each backend is available. It is **not** a from-scratch Vulkan test.

Use one identical scene, deterministic seed, assets, camera, scripted input, and workload configuration on each backend. Include representative content such as sprites with alpha/tint/rotation, text, atlas-backed assets, lighting, off-screen rendering, and the existing post-effect path where supported.

- Record the actual SDL_GPU driver/backend selected at runtime; do not infer it from the OS or shader files.
- Run Vulkan, D3D12, and Metal only on machines that actually support the relevant backend and have the required runtime/driver. Build or enable the matching shader artifacts for each backend (for example SPIR-V, DXIL, or MSL as required by the selected SDL_GPU path).
- Capture screenshots and compare against backend-specific tolerances; allow documented rasterization differences while flagging missing features, incorrect blending, broken text, invalid render targets, or shader incompatibilities.
- Compare correctness separately from performance. Record GPU, driver, OS, display mode, shader variants, build flags, and backend name.
- Treat an unavailable backend as **not run**, not pass. Do not claim cross-backend parity from a single machine/backend.
- Confirm backend selection and smoke testing do not destabilize the normal SDL_GPU 2D path.

A direct Vulkan 3D device/surface/swapchain experiment is out of scope here. Only consider it after a separate 3D-path decision; it must remain isolated from the current 2D renderer.

---

# 7. Implementation order

The order deliberately front-loads the shared harness, the first three high-value visual systems, and resource/entity identity. Do not build all genre samples before this foundation is green.

## Stage 1 — Shared harness, first visual testbeds, and lifecycle gate

- [ ] Add shared testbed startup/shutdown conventions, a tracking allocator, and structured test results.
- [ ] Add command-line/configuration selection for testbed, scenario, workload tier, and deterministic seed.
- [ ] Add reliable process exit codes and machine-readable failure summaries.
- [ ] Add headless fixed-timestep tests: hitch clamp, spiral-of-death protection, pause/resume, interpolation, and equivalent sim ticks under low/high render FPS.
- [ ] Add scene-stack tests: `push`, `pop`, `switchTo`, init-failure preservation, transition update ordering, and exact-once `deinit` cleanup.
- [ ] Add startup-failure tests for missing asset root, malformed settings, and unavailable required capabilities.
- [ ] Add save/settings tests for corrupt data, partial writes, version migration, and persistence across forced process termination.
- [ ] Add crash-report and clean-relaunch checks in a child process; verify job-pool shutdown does not deadlock.

- [x] TB-01 Sprite Rendering Stress Test.
- [x] TB-02 Asset Loading and Streaming Test, including hot reload and dependency invalidation.
- [x] TB-03 Text and Font Rendering Test.
- [x] TB-19 Resource and Entity Lifecycle Laboratory, including resource generations and ECS entity IDs.

**Stage exit condition:** The harness can run headless checks, report failures with meaningful exit codes, track allocations, and clean up after normal and injected failure paths. All four testbeds have repeatable scenarios and actionable diagnostics. Failed hot reload retains the last good asset. Stale resource handles and entity IDs are rejected. Tracking allocator/leak checks pass or have explicitly explained retained allocations.

## Stage 2 — Remaining core systems and deterministic tooling

- [ ] TB-04 Animation Stress Test.
- [ ] TB-05 Collision and Physics Test.
- [ ] TB-06 Camera and Viewport Test, including parallax, camera shake, and debug drawing.
- [ ] TB-21 Tilemap Validation and Stress Test.
- [ ] TB-22 Particle Pool and Overdraw Stress Test.
- [ ] TB-23 Deterministic Input Replay and Checkpoints.
- [ ] TB-24 Script Runtime Host Integration Test (extend `tests/script/` first).
- [ ] Add behavior-tree unit tests and other pure-logic coverage under `tests/`, not as windowed testbeds.

**Stage exit condition:** Core simulation/rendering systems have focused tests, replay can reproduce a recorded run, and script host failures/reloads are contained.

## Stage 3 — One integration slice, then targeted genre stress

- [ ] TB-07 Top-Down Adventure / Showcase Integration Test (the single game-like showcase).
- [ ] TB-08 Isometric World Test (depth sorting and projected-world interactions).
- [ ] TB-09 Platformer Test (movement resolution and moving-platform behavior).
- [ ] TB-10 Bullet Hell Stress Test (spawn/despawn, collision density, and particle pressure).
- [ ] TB-11 UI and Localization Test (visual layout and rendered glyphs; catalog logic remains unit-tested).

**Stage exit condition:** The one integration slice exercises public APIs end-to-end. Genre samples are added only after Stage 1 is green and each stresses a distinct engine behavior rather than duplicating the showcase.

## Stage 4 — Specialized systems and backend parity

- [ ] TB-13 Lighting Laboratory.
- [ ] TB-14 Render Graph Validation using `render_graph.zig`.
- [ ] TB-15 Audio Laboratory, including IMA decode and device loss/reopen.
- [ ] TB-16 Input Laboratory, including input-buffer timing.
- [ ] TB-17 Navigation Laboratory, including flow fields and follow steering.
- [ ] TB-18 Job System Laboratory.
- [ ] TB-20 SDL_GPU 2D Backend Parity Smoke on machines with the corresponding Vulkan, D3D12, or Metal backend available.

**Stage exit condition:** Specialized systems have explicit failure-path coverage. Backend parity is recorded only for backends actually exercised on supported hardware; unavailable backends remain not run.

## Stage 5 — Long-running reliability campaign

- [ ] TB-12 Long-Running Simulation Test, first 30–60 minutes, then overnight/release-candidate runs.
- [ ] Replay any failure using TB-23 and preserve the first divergent tick/checkpoint.
- [ ] Compare tracking-allocator and resource/entity snapshots across the run; verify steady-state behavior after warm-up.

**Stage exit condition:** Replay and leak/lifecycle gates are already green; long-running runs complete without unexplained resource growth, stale identities, shutdown deadlocks, or unreproducible state corruption.

---

# 8. Standard measurement and reporting

Every testbed should expose a common set of metrics wherever applicable.

| Category | Metrics to capture |
|---|---|
| Runtime | FPS, average frame time, p50/p95/p99 frame time, uptime |
| CPU | Main-thread time, subsystem time, worker utilization |
| GPU | GPU frame time when available, draw calls, batches, render-target switches |
| Memory | Process RAM, peak RAM, GPU memory if measurable, allocation counts/bytes |
| Assets | Loaded resources, cache hits/misses, evictions, upload queue depth, staging bytes |
| Rendering | Submitted/drawn sprites, texture/material switches, effect count |
| Text | Glyph count, cache utilization, atlas pages, shaping/layout/rasterization time |
| Physics | Broad-phase candidates, narrow-phase checks, query time, contacts/events |
| Audio | Active voices, streamed assets, underruns/dropped voices where measurable |
| Lifecycle | Live handles, entities, jobs, resources created/destroyed, stale-handle errors |
| Stability | Crashes, assertions, warnings, validation errors, failed operations |

## Workload tiers

Every stress-capable testbed should support at least three configurable tiers:

| Tier | Purpose | Expected behavior |
|---|---|---|
| Normal | Representative gameplay workload | Meets the target performance and correctness budget |
| Heavy | Several times the expected gameplay workload | Remains correct and responsive within a defined degradation budget |
| Extreme | Deliberately exceeds expected operating limits | Produces controlled, diagnosable failure or graceful degradation; must not corrupt memory or hang indefinitely |

Workload counts should be command-line or configuration options where practical. Avoid hard-coding only one stress level.

## Result artifact format

Save a result bundle for important runs. A practical folder structure is:

```text
validation/
  testbeds/
    TB-01-sprite-rendering/
      README.md
      configs/
      results/
        <date>-<commit>-<machine>/
          summary.md
          metrics.json
          stdout.log
          stderr.log
          screenshots/
```

At minimum, each result should record:

- Testbed ID and scenario name.
- Full Git commit SHA.
- Build mode and relevant build options.
- Operating system and version.
- CPU, GPU, driver, and RAM.
- Display resolution and refresh rate where rendering is involved.
- Test configuration, workload tier, and random seed.
- Start/end time and duration.
- Pass/fail result and known deviations.
- Logs, screenshots, and metrics.

Do not compare performance numbers across machines without recording the hardware and graphics driver. Prefer comparing the same machine and configuration across commits.

---

# 9. Acceptance and regression policy

A testbed is not complete just because it opens a window. Each testbed should have:

- [ ] A documented purpose and explicit non-goals.
- [ ] A deterministic baseline scenario.
- [ ] At least one normal and one stress workload.
- [ ] A visible diagnostic overlay or machine-readable metrics.
- [ ] Correctness checks or reference screenshots.
- [ ] A documented expected failure mode for invalid inputs and exhausted limits.
- [ ] Reproducible build and run instructions.
- [ ] A saved baseline result tied to a full commit SHA.
- [ ] A clear list of known limitations.

For every engine bug found:

1. Reproduce it in the smallest relevant testbed.
2. Save the failing configuration, logs, and screenshot if visual.
3. Add a regression check before or alongside the fix.
4. Re-run the relevant testbed and neighboring integration tests.
5. Save the passing result against the fix commit.

## Suggested test execution levels

| Frequency | Tests |
|---|---|
| Every relevant code change | Unit tests and the focused testbed scenario |
| Pull request / merge | Core smoke tests and affected integration tests |
| Nightly | Stress tiers, replay determinism, repeated resource/entity lifecycle tests; long-running simulation only after TB-19 and TB-23 gates pass |
| Release candidate | Full testbed suite on supported desktop targets, graphics validation, clean shutdown, showcase game smoke test |

The exact CI schedule can be adjusted to available hardware and runtime cost. Do not mark device-dependent GPU tests as passed based only on compilation or a headless environment.

---

# 10. Suggested repository organization

Keep the sample suite discoverable and separate from engine implementation details. One possible structure is:

```text
examples/
  testbeds/
    TB-01-sprite-rendering/
    TB-02-asset-streaming/
    TB-03-text-fonts/
    TB-04-animation/
    TB-05-collision/
    TB-06-camera-viewports/
    TB-07-top-down-adventure/       # the single integration sample / showcase
    TB-08-isometric-world/
    TB-09-platformer/
    TB-10-bullet-hell/
    TB-11-ui-localization/
    TB-12-long-running-simulation/
    TB-13-lighting/
    TB-14-render-graph/
    TB-15-audio/
    TB-16-input/
    TB-17-navigation/
    TB-18-job-system/
    TB-19-resource-entity-lifecycle/
    TB-20-sdl-gpu-backend-parity/
    TB-21-tilemaps/
    TB-22-particles/
    TB-23-replay-determinism/
    TB-24-script-runtime/

validation/
  testbeds/
    ... result bundles ...
```

This is a suggested organization, not a requirement to create all directories immediately. Each testbed should remain a normal, buildable Bairava example and should not require private engine imports unless the test explicitly targets an internal subsystem. If an internal-only harness is necessary, label it clearly as an engine validation tool rather than a game-facing example.

---

# 11. Important design principles

> [!success] Prefer observable behavior
> A testbed should expose enough diagnostics to explain *why* a failure occurred, not merely show that the frame rate dropped or the window crashed.

> [!success] Test limits deliberately
> Exercise configured capacities, queue limits, atlas exhaustion, invalid handles, missing files, and shutdown with pending work. Boundary behavior is part of the engine API.

> [!success] Keep scenarios deterministic
> Use fixed random seeds, scripted input, known assets, and repeatable scene setup. Determinism makes regression analysis much easier.

> [!success] Validate through public APIs
> Integration testbeds should behave like real games. Avoid private renderer or resource access as a shortcut; it can hide problems in the game-facing API.

> [!warning] Do not turn every testbed into a benchmark contest
> Performance is important, but correctness, resource ownership, error behavior, and developer usability are equally important. Record performance numbers without optimizing prematurely.

> [!warning] Separate current capability from future exploration
> Mark features as supported, partially supported, experimental, or unsupported. SDL_GPU backend parity is a 2D validation exercise; it is not evidence that Bairava has a direct Vulkan renderer or a 3D renderer.

---

# 12. First implementation sprint

The first sprint is the shared harness plus TB-01, TB-02, TB-03, and TB-19. Do not begin the genre samples or long-run campaign yet.

## Harness tasks

- [ ] Define shared startup/shutdown and test-result conventions.
- [ ] Add a tracking allocator and leak summary.
- [ ] Add command-line/configuration options for testbed, scenario, workload tier, and random seed.
- [ ] Add meaningful process exit codes and structured logs.
- [ ] Implement headless fixed-timestep tests.
- [ ] Implement scene-stack transition and teardown tests.
- [ ] Add failure-injection coverage for startup, save/settings writes, crash reporting, and shutdown with pending jobs.
- [ ] Record full commit SHA, OS, CPU/GPU, driver, build options, test parameters, and result path.

## First testbeds

- [x] TB-01 Sprite Rendering Stress Test.
- [x] TB-02 Asset Loading and Streaming Test, including hot reload/dependency invalidation.
- [x] TB-03 Text and Font Rendering Test.
- [x] TB-19 Resource and Entity Lifecycle Laboratory.

## Sprint exit criteria

- The harness can run headless lifecycle/timestep checks and visual testbeds independently.
- All four testbeds expose reproducible scenarios with normal, heavy, and extreme workloads where applicable.
- Asset reload failure preserves the previous good asset.
- Stale resource handles and stale entity IDs are rejected; double-destroy behavior is defined.
- The tracking allocator reports no unexplained growth/leaks after repeated create/use/destroy cycles.
- Results include commit and machine metadata, logs, and screenshots where visual output matters.

---

# 13. Decision log and scope notes

| Topic | Decision |
|---|---|
| Current 2D renderer | Keep the existing SDL3-based rendering architecture; no backend replacement is required by this roadmap |
| SDL3 2D renderer | Do not make completing it a prerequisite for the testbed suite |
| Future 3D API direction | Vulkan is preferred; do not target OpenGL or OpenGL ES |
| Existing 2D backend validation | Test SDL_GPU backend parity (Vulkan/D3D12/Metal where available); do not build a second direct-Vulkan 2D path |
| Direct Vulkan scope | A 3D device/renderer proof of concept requires a separate future decision and is not part of this testbed roadmap |
| Physics scope | Validate the current collision/movement system; full rigid-body physics remains a separate feature decision |
| Multi-camera scope | Test what the current API supports and document gaps; do not assume simultaneous multi-viewport support |
| Testbed style | Small, independent, reproducible, measurable samples; not all need to be polished games |
| Showcase | TB-07 is the single small top-down adventure and integration showcase; do not create a second adventure project |
| Headless coverage | Fixed timestep, scene stack, persistence failure paths, crash reporting, startup failure, and pure logic stay in automated tests/harness code rather than windowed labs |
| Long-run gate | TB-12 begins only after TB-23 replay determinism and TB-19 lifecycle/leak checks pass |

---

# 14. Final definition of done

The Bairava Testbed Suite is mature when:

- [ ] The shared harness covers fixed timestep, scene transitions, tracking allocation, startup failure, crash reporting, persistence failure paths, and clean exit codes.
- [ ] Core systems have independent correctness and stress testbeds, including dedicated tilemap and particle tests.
- [ ] Integration testbeds demonstrate realistic public-API usage, with TB-07 serving as the single small showcase.
- [ ] Replay determinism and resource/entity identity are validated before long-running campaigns.
- [ ] Workload tiers and common measurements are available.
- [ ] Important results are tied to commit SHAs and machine metadata.
- [ ] Critical regressions are reproducible and have regression checks.
- [ ] Supported-platform claims are backed by actual device runs.
- [ ] A small showcase game can be built without relying on private engine internals.
- [ ] SDL_GPU 2D backend parity has been checked on actual Vulkan/D3D12/Metal-capable machines where available; untested backends are not marked passed.
- [ ] Any future direct Vulkan 3D exploration remains explicitly separate from current 2D renderer stability.

> [!summary] Recommended starting point
> Build the shared harness, then implement **TB-01 Sprite Rendering**, **TB-02 Asset Loading/Streaming** (including hot reload), **TB-03 Text/Font Rendering**, and **TB-19 Resource/Entity Lifecycle** as the first reliability gates.
