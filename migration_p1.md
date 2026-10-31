# Bairava Engine — P1 Core Systems Migration Plan

> **Scope:** P1 core engine functionality  
> **Prerequisite:** P0 global acceptance gate complete  
> **Status:** Proposed — not yet implemented  
> **Target:** Make Bairava a usable, reusable 2D engine without coupling it to Semkootru.

## 1. Objective

P1 adds six core runtime capabilities:

1. General-purpose scene lifecycle and transitions.
2. Reusable 2D collision geometry, queries, and basic movement resolution.
3. Practical ECS integration using the existing generational entity world.
4. An engine-owned renderer boundary around the existing SDL GPU backend.
5. Stable asset handles and explicit cache/resource lifetime.
6. Semantic input actions with keyboard, mouse, and gamepad support.

This is an incremental migration, not a rewrite. Preserve existing behavior, add APIs alongside existing ones, migrate Semkootru only after tests pass, and remove compatibility paths in separate commits.

## 2. Entry conditions

Do not begin until P0 is complete:

- [ ] A separate consumer imports the named `bairava` Zig module.
- [ ] Game code imports only the public engine API.
- [ ] SDL implementation details are not exposed through that API.
- [ ] Allocator and resource ownership rules are documented.
- [ ] Startup and shutdown safely handle partial failure.
- [ ] Engine/game boundary checks run in CI.
- [ ] Engine and game configuration are separate.
- [ ] Recoverable errors are propagated consistently.

## 3. Baseline and design constraints

The reviewed source already contains useful foundations:

| Area | Existing implementation | P1 direction |
|---|---|---|
| Scene/world | `scene/tilemap.zig` parses layered tile maps and contains solid-tile movement/collision helpers. `game/level.zig` is Semkootru-specific. | Add a scene lifecycle above tilemap data; do not make `TileMap` the scene manager. |
| Physics | `physics/shapes.zig` defines `Point` and `Box`; tilemap uses these shapes. | Extend pure geometry and collision queries incrementally. |
| ECS | `ecs/entity.zig` provides `World(Row, layout)`, dense rows, AoS/SoA storage, generational handles, spawn/despawn/get/set. | Add iteration/system conventions without discarding this storage model. |
| Renderer | `renderer/renderer.zig` and `renderer/texture.zig` directly use SDL GPU C types. | Contain SDL GPU behind an engine-owned renderer boundary; keep SDL GPU as the only backend. |
| Assets | Registry, atlas loaders, compressed texture variants, and allocator-injected `assets/cache.zig` exist. | Add stable handles and explicit sharing/release semantics. |
| Input | `input/input.zig` tracks keyboard/mouse; `game/controls.zig` maps Semkootru actions. | Move generic mapping to engine; keep action names/defaults game-owned. |

Constraints:

- Engine code must not know about Semkootru, its player, levels, menus, or save format.
- Keep the 2D pixel-art workflow first-class.
- Use the existing fixed-update loop for deterministic input and simulation behavior.
- Avoid per-frame allocations where possible.
- Prefer explicit ownership and stable handles over long-lived raw pointers.
- Do not build speculative abstractions or editor tooling in P1.

## 4. Priority and dependency order

| Order | ID | Work item | Priority | Depends on |
|---:|---|---|---|---|
| 1 | P1.1 | Scene lifecycle and transitions | High | P0 |
| 2 | P1.2 | 2D collision geometry, queries, basic resolution | High | P0; existing shapes |
| 3 | P1.3 | ECS integration and system/query conventions | High | P0 allocator rules |
| 4 | P1.4 | Renderer/backend boundary | High | P0 public API |
| 5 | P1.5 | Stable asset handles and cache lifecycle | High | P0 ownership rules |
| 6 | P1.6 | Semantic input and gamepad support | High | P0 public API |

P1.2 and P1.3 can proceed independently after P0. Do not combine all six into one large migration.

---

# 5. Implementation tasks

## P1.1 — General-purpose scene lifecycle

**Goal:** Support multiple game scenes without making the engine understand game-specific scene content.

**Current files:** `src/engine/scene/tilemap.zig`, `src/engine/core/runtime.zig`, `src/game/level.zig`, `src/game/game.zig`.

**Suggested structure:**
```text
src/engine/scene/
  scene.zig
  scene_manager.zig
  transition.zig
  tilemap.zig
```

**Work:**

1. Define a scene contract for init, update, draw, and deinit.
2. Pass only public engine context/draw APIs into scene callbacks.
3. Implement a manager that owns the active scene and its lifecycle.
4. Defer scene changes requested during update until a safe point in the main loop.
5. Define transition semantics: initially use immediate switching; add visual fades later.
6. Specify failure behavior when the next scene fails to initialize. Prefer preserving the current scene until the replacement is ready.
7. Ensure every successfully initialized scene is deinitialized exactly once.
8. Define scene-scoped resource ownership and its relationship to the asset manager.
9. Keep `TileMap` as a data/model type owned by a game scene, not as a generic scene API.
10. Migrate Semkootru's level into a sample scene only after generic manager tests pass.

**API design:** A type-erased vtable, comptime-generic manager, or tagged scene union could work. Choose one based on the current Zig toolchain and document ownership. Do not copy an illustrative API without checking its lifetime and allocator implications.

**Tests:**

- Lifecycle call order and exactly-once deinit.
- A-to-B transition and shutdown.
- Transition requested from inside update is deferred safely.
- Failed scene initialization leaves a valid documented manager state.
- Repeated transitions leak no scene-owned allocations.

**Acceptance criteria:**

- [ ] Generic scene lifecycle works without Semkootru imports.
- [ ] Scene changes occur only at a safe point.
- [ ] Failure and shutdown behavior are deterministic.
- [ ] Tilemap remains independent of scene management.
- [ ] A sample switches between two scenes.

**Out of scope:** Scene editor, scene graph hierarchy, prefabs, complex transition effects, networked scenes.

## P1.2 — Reusable 2D collision and physics foundation

**Goal:** Extend the current shape helpers into a reusable 2D collision/query module while preserving tilemap movement.

**Current files:** `src/engine/physics/shapes.zig`, `src/engine/scene/tilemap.zig`, Semkootru player movement.

**Suggested structure (keep it minimal):**
```text
src/engine/physics/
  shapes.zig
  collision.zig
  queries.zig
  world.zig
```

**Work — geometry:**

1. Keep `Point` and `Box`; add `Circle` and line segment only when required.
2. Document world units, rectangle edge semantics, and numerical tolerance.
3. Implement point/AABB, AABB/AABB, circle/circle, and circle/AABB tests.
4. Return contact information (normal, point, penetration) only for tests/response that need it.
5. Define behavior for zero/negative dimensions and non-finite values.

**Work — queries and movement:**

1. Add generic queries over explicit collider collections or a small physics world.
2. Add collision layers and masks.
3. Support static colliders first.
4. Start with a linear broad-phase scan; add a spatial index only after profiling demonstrates need.
5. Keep collision independent of SDL, rendering, tilemap, and ECS.
6. Preserve existing tilemap collision helpers and regression tests.
7. Add axis-separated or swept-AABB movement only if needed to prevent corner issues/tunneling.
8. Keep detection separate from response.
9. Do not expose gravity, friction, mass, or restitution until implemented and required.

**Tests:**

- Touching edges, overlap, separation, negative coordinates, invalid dimensions.
- Layer/mask filtering.
- Static collider queries.
- Tilemap movement against walls, corners, adjacent solids.
- Large movement steps if swept collision is implemented.
- Deterministic results for identical inputs.

**Acceptance criteria:**

- [ ] Pure geometry/query tests run without SDL.
- [ ] Existing tilemap collision behavior does not regress.
- [ ] Generic colliders work independently of tilemaps and ECS.
- [ ] Coordinate and edge conventions are documented.
- [ ] First version remains small and suitable for 2D pixel-art games.

**Out of scope:** Full rigid-body solver, 3D physics, joints, soft bodies, physics editor.

## P1.3 — ECS integration and system/query conventions

**Goal:** Make the existing entity world useful to game systems without prematurely building a heavyweight ECS framework.

**Current foundation:** `src/engine/ecs/entity.zig` provides `World(Row, layout)`, dense rows, AoS/SoA layouts, generational handles, spawn/despawn/get/set, stale-handle rejection, and swap-remove repair.

**Work:**

1. Document the row-based storage model and intended use.
2. Decide whether it meets current game use cases before considering independent component pools or archetypes.
3. Define safe iteration over component columns/rows.
4. Specify structural mutation rules: spawning/despawning during iteration, invalidation, and iteration order.
5. If needed, add a small deferred command buffer for structural changes; do not add one preemptively.
6. Define system ordering explicitly. Add a scheduler only when multiple real systems require one.
7. Keep game component types (Transform, Velocity, Health, etc.) in the game/sample, not in engine modules.
8. Demonstrate one sample system using the ECS.
9. Keep ECS optional; simple game objects may remain ordinary Zig structs.
10. Preserve allocator injection and generational handle guarantees.

**Illustrative game-owned components:**
```zig
const Transform = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };
const Row = struct {
    transform: Transform,
    velocity: Velocity,
};
```

**Tests:**

- Spawn/get/set/despawn.
- Stale handle rejection and generation increment on slot reuse.
- Swap-remove preserves moved entity handle validity.
- AoS and SoA layouts behave consistently.
- Iteration follows documented mutation rules.
- Allocation failure does not corrupt world bookkeeping.

**Acceptance criteria:**

- [ ] Existing generational guarantees remain intact.
- [ ] One sample system uses the ECS.
- [ ] Iteration and structural mutation rules are explicit.
- [ ] No SDL or game imports in ECS.
- [ ] ECS remains optional for gameplay objects.
- [ ] No unnecessary registry, archetype engine, or scheduler is introduced.

**Out of scope:** Mandatory ECS, reflection-driven registration, multithreaded scheduling, networking replication, visual inspector.

## P1.4 — Renderer/backend boundary

**Goal:** Hide SDL GPU implementation details behind engine-owned rendering APIs while retaining SDL GPU as the only backend.

**Current foundation:** `renderer/renderer.zig` and `renderer/texture.zig` directly import SDL GPU types; platform code already centralizes other SDL operations.

**Suggested structure:**
```text
src/engine/renderer/
  renderer.zig
  render_types.zig
  sprite.zig
  texture.zig
  backends/
    sdl_gpu/
      device.zig
      pass.zig
      texture.zig
      pipeline.zig
```

Adapt to the actual code. Avoid wrapper files that merely rename SDL functions.

**Work:**

1. Inventory all renderer imports of SDL C types/functions.
2. Separate engine concepts (texture, target, pass, pipeline, format, capabilities) from SDL descriptors and handles.
3. Move SDL-specific operations into a private SDL GPU backend.
4. Define only the engine operations the current runtime needs: frame/pass begin/end, texture create/destroy/upload, sprite drawing, present, and capability queries.
5. Keep camera, view mapping, sprite batching, and render ordering backend-independent.
6. Tie GPU resources to their device and enforce P0 destruction order.
7. Preserve existing shaders, pipelines, compressed texture fallback, and rendering behavior.
8. Remove raw SDL command buffers/device handles from game-facing APIs.
9. Keep backend selection internal; do not add a public backend selector until another backend exists.

**Tests:**

- Pure renderer type/value tests.
- Existing camera and sprite batch tests.
- Backend capability/format mapping tests.
- Runtime smoke test: window → device → texture upload → sprite draw → present → clean shutdown.
- Boundary check proves SDL GPU types are confined to approved backend files.

**Acceptance criteria:**

- [ ] No SDL GPU types leak through public engine APIs.
- [ ] SDL GPU implementation is private and contained.
- [ ] Existing rendering still works.
- [ ] Texture/device lifetime follows P0 ownership rules.
- [ ] No second graphics backend is implemented in P1.

**Out of scope:** Vulkan, Direct3D, Metal, OpenGL, render graph, 3D rendering, material editor.

## P1.5 — Stable asset handles and resource lifecycle

**Goal:** Let games reference loaded assets through stable engine-managed handles with clear cache, sharing, and release semantics.

**Current foundation:** `assets/registry.zig`, atlas parsing/loading, compressed texture variants, and allocator-injected `assets/cache.zig` already exist. `Context` currently provides convenience loaders.

**Suggested structure:**
```text
src/engine/assets/
  registry.zig
  cache.zig
  handle.zig
  manager.zig       # Only if needed; avoid redundant layers
  loaders/
```

**Work:**

1. Define typed asset handles (texture/audio/font/atlas as appropriate).
2. Define invalid and stale handle behavior.
3. Ensure handles remain valid when cache storage grows; never use a pointer into a resizable array as a stable handle.
4. Define cache keys, including normalized path and asset type.
5. Choose shared-resource semantics: reference-counted lease, explicit retain/release, or another documented model.
6. Ensure failed loads do not leave partially registered entries.
7. Ensure GPU assets are destroyed before the GPU device.
8. Add explicit unload/release behavior that cannot destroy an asset still in use.
9. Preserve build-time asset preprocessing and compressed texture fallback.
10. Use the P0 error policy for missing/invalid assets.
11. Add useful cache diagnostics (hits, misses, loaded count, estimated bytes where measurable).
12. Keep hot reload and asynchronous streaming out of P1.

**Illustrative API only:**
```zig
const texture = try assets.loadTexture("characters/warrior.png");
const view = try assets.getTexture(texture);
renderer.drawTexture(view, destination);
assets.release(texture);
```

Adapt this to the ownership/lease model established in P0.

**Tests:**

- Duplicate requests follow the chosen sharing policy.
- Typed handles reject wrong asset types.
- Cache growth does not invalidate handles.
- Stale handles are rejected.
- Release/unload obeys lease/reference rules.
- Failed loads leave cache consistent.
- Compressed variants fall back correctly.
- GPU resources are destroyed before device shutdown.

**Acceptance criteria:**

- [ ] Games request assets without raw backend handles.
- [ ] Handles are stable across cache growth.
- [ ] Sharing, ownership, and release rules are documented.
- [ ] Existing atlas/texture workflow remains functional.
- [ ] Stale handle, duplicate load, failure, and unload tests pass.
- [ ] Build-time asset tools remain outside runtime imports.

**Out of scope:** Async streaming, network asset delivery, hot reload/watchers, editor asset browser, content-addressed build cache.

## P1.6 — Semantic input actions and gamepad support

**Goal:** Let games bind semantic actions instead of checking SDL scancodes or physical buttons directly.

**Current foundation:** `input/input.zig` tracks keyboard/mouse state; platform events translate keyboard/mouse input; `game/controls.zig` currently maps Semkootru actions.

**Suggested structure:**
```text
src/engine/input/
  input.zig
  action.zig
  mapping.zig
  gamepad.zig
```

**Phase A — Semantic actions:**

1. Preserve current keyboard/mouse physical state during migration.
2. Define game-owned action identifiers; engine must not prescribe universal actions such as `jump`, `attack`, or `save_game`.
3. Provide reusable bindings for keys and mouse buttons, with a data model that can later include gamepad buttons/axes.
4. Support pressed, released, held, and optional analog value states.
5. Define how multiple physical bindings contribute to one action.
6. Define latching with the fixed-update loop so presses are not lost or repeated when one render frame contains zero or multiple updates.
7. Move generic binding evaluation out of `game/controls.zig`; keep Semkootru action names/defaults/settings in the game.
8. Keep rebinding UI out of scope.

**Phase B — Gamepad:**

1. Extend platform-neutral input events for controller connect/disconnect, buttons, and axes.
2. Implement SDL gamepad operations only inside the SDL platform backend.
3. Use engine-owned device handles; never expose SDL gamepad handles/IDs as public API.
4. Handle hotplugging and disconnect without stale references.
5. Normalize axes and define dead-zone behavior.
6. Initially use a simple controller-selection policy (for example, first connected controller).
7. Feed controller inputs through the same semantic action evaluator.
8. Demonstrate keyboard and gamepad triggering the same action.

**Tests:**

- One key maps to an action; multiple bindings map to one action.
- Press/release edges are delivered once under fixed updates.
- Held state remains correct across render frames.
- Keyboard and gamepad can trigger the same action.
- Axis normalization/dead zone are correct.
- Disconnect invalidates the device safely.
- Semkootru defaults remain game-owned.

**Acceptance criteria:**

- [ ] Game code queries semantic actions, not SDL scancodes.
- [ ] Action names and default bindings are game-owned.
- [ ] Existing keyboard/mouse behavior does not regress.
- [ ] Edge/latch timing is documented and tested.
- [ ] Gamepad uses the same action model.
- [ ] Hotplug/disconnect is safe.
- [ ] SDL gamepad types do not leak through the public API.

**Out of scope:** Rebinding UI, split-screen/player routing, touch gestures, sensors, haptics, input replay.

---

# 6. Integration strategy

Use two consumers:

1. **Independent sample game:** proves the public engine API is reusable without Semkootru imports.
2. **Semkootru:** acts as a real-world regression client.

Recommended validation sequence:

1. Two-scene sample validates P1.1.
2. Pure collision tests and a non-tilemap collider sample validate P1.2.
3. One ECS-driven sample entity/system validates P1.3.
4. Existing render smoke test validates P1.4.
5. Duplicate texture request and stable-handle tests validate P1.5.
6. One action mapped to keyboard and gamepad validates P1.6.
7. Migrate Semkootru only where the new APIs clearly improve reuse. Keep its player, level, action names, save data, and game rules in `src/game/`.

# 7. Suggested commit sequence

| Commit | Scope | Required checks |
|---|---|---|
| `feat(scene): add scene lifecycle manager` | P1.1 | Lifecycle, transition, failure tests |
| `feat(physics): add reusable 2d collision queries` | P1.2 | Geometry/query and tilemap regression tests |
| `feat(ecs): define system iteration conventions` | P1.3 | Handle, layout, iteration, mutation tests |
| `refactor(renderer): isolate sdl gpu backend` | P1.4 | Render smoke test and SDL boundary scan |
| `feat(assets): add stable typed asset handles` | P1.5 | Cache, stale-handle, unload, GPU lifetime tests |
| `feat(input): add semantic actions and gamepad support` | P1.6 | Latching, mapping, hotplug, input integration tests |

Keep each commit buildable and independently reviewable. Do not hide prerequisite P0 API changes inside a large P1 feature commit; document and commit them separately.

# 8. P1 global acceptance gate

P1 is complete only when:

- [ ] A sample game switches between two independently implemented scenes.
- [ ] Scene init/update/draw/deinit and failed transitions are tested.
- [ ] Generic collision queries work without tilemap or ECS dependencies.
- [ ] Existing tilemap movement/collision remains correct.
- [ ] ECS has a documented, tested system iteration pattern.
- [ ] ECS remains optional for game objects.
- [ ] SDL GPU is behind an engine-owned renderer boundary.
- [ ] No SDL GPU types leak through the public API.
- [ ] Asset handles remain valid across cache growth and reject stale references.
- [ ] Asset sharing and release semantics are tested.
- [ ] Semantic keyboard/mouse actions work through the engine API.
- [ ] A gamepad can trigger the same actions and disconnect safely.
- [ ] The independent sample uses Bairava without importing Semkootru.
- [ ] Existing supported CI targets, tests, and runtime smoke tests remain green.

# 9. Risks and implementation notes

1. **Zig toolchain:** The repository uses a Zig 0.16 development snapshot. Verify APIs against the checked-in toolchain before adopting examples.
2. **Scene ownership:** Do not store pointers to movable scene values. Choose a stable allocation/type-erasure strategy and document who destroys each scene.
3. **Scene transitions:** Never deinitialize the active scene from inside its own update/draw callback. Queue transitions and process them at a safe point.
4. **Physics scope:** A small tested 2D collision/query system is more valuable than an incomplete general-purpose rigid-body solver.
5. **ECS scope:** The current ECS is row-oriented; do not describe it as an archetype ECS or add independent component pools without a measured requirement.
6. **Renderer scope:** A clean boundary does not require multiple backends. SDL GPU remains the only backend in P1.
7. **Asset handles:** A handle must not be a pointer into a resizable cache array.
8. **GPU lifetime:** Asset cache teardown must occur before GPU device teardown.
9. **Input timing:** Design edge semantics around fixed updates; event pumping and multiple simulation steps can otherwise lose or duplicate presses.
10. **Gamepad portability:** Translate SDL IDs/handles to engine-owned identities in the platform backend.
11. **Performance:** Avoid per-frame allocations in scene updates, collision, ECS iteration, and action evaluation unless measured and justified.
12. **Compatibility:** Keep Semkootru working at each checkpoint; remove old APIs only after all consumers/tests use replacements.

# 10. Explicitly out of scope for P1

- Scene editor, scene graph hierarchy, prefab system.
- Full rigid-body/3D physics, joints, soft bodies.
- Mandatory ECS, reflection-driven registration, multithreaded scheduler.
- Vulkan, Direct3D, Metal, OpenGL, render graph, 3D rendering.
- Asset hot reload, asynchronous streaming, network asset delivery.
- Tilemap/animation editors.
- Input rebinding UI, split-screen routing, haptics, sensors.
- Particles, lighting, post-processing.
- Scripting, networking, replay, plugin architecture.

# 11. Definition of done

P1 is done when Bairava provides reusable scene lifecycle, 2D collision queries, practical ECS integration, a contained SDL GPU renderer, stable asset handles, and semantic keyboard/gamepad input — all usable by an independent sample game through the public engine API.

P1 succeeds through reliable contracts and demonstrated reuse, not by matching the feature count of a commercial engine.

**Next milestone after P1:** P2 developer tooling and productivity: asset hot reload, debug console, tilemap/animation editing, and expanded profiling. Do not begin editor-scale tooling until P1 runtime APIs and ownership contracts are stable.
