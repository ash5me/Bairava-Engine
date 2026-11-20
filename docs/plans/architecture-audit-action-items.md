# Bairava Engine — Architecture Audit Action Items

**Audit reference:** First-pass static review of `main` at commit `52f60b42c3e38c883799753bbf452f80ed346552` (`culling`, 2026-11-20).

**Purpose:** Identify unnecessary module coupling, decisions that restrict game developers, resource-lifetime problems, scalability limits, and weaknesses in the public API.

> This is an action plan, not a statement that every item is a confirmed defect. Validate each finding against current code and tests before changing the architecture. The initial review was static and did not include a complete import-graph analysis or runtime profiling.

## Priority summary

| Priority | Area | Goal |
|---|---|---|
| High | Renderer/backend separation | Keep renderer-facing APIs independent of concrete backend implementations where practical. |
| High | Resource lifetime and scene ownership | Let games manage resource residency and release resources safely. |
| Medium | `Context` responsibilities | Avoid making `Context` an unnecessarily broad service locator. |
| Medium | Capacity and failure policies | Make limits visible and choose deliberate overflow behavior. |
| Medium | Public API usability | Ensure a game can be built using only the supported public API. |

---

## 1. Module dependency audit

- [ ] Generate an import/dependency graph for all Zig modules under `src/engine/`.
- [ ] Identify circular dependencies and report the exact import paths involved.
- [ ] Identify modules with unusually high fan-in or fan-out; review whether they have too many responsibilities.
- [ ] Identify dependencies that cross unrelated subsystems (for example, navigation depending on rendering).
- [ ] Identify direct SDL/SDL_GPU imports outside the platform and backend layers.
- [ ] Check whether core algorithms can compile and run without SDL or a GPU.
- [ ] Record each confirmed coupling issue with source locations, impact, and a proposed boundary.

**Files to begin with:**

- `src/engine/core/context.zig`
- `src/engine/core/lifecycle.zig`
- `src/engine/renderer/sprite.zig`
- `src/engine/renderer/texture.zig`
- `src/engine/renderer/backends/sdl_gpu/`
- `src/engine/platform/`

**Review rule:** Broad dependencies are acceptable in composition-root code such as lifecycle/startup. Subsystems should not depend on unrelated subsystems without a clear reason.

## 2. Renderer and backend separation — High priority

- [ ] Trace the complete dependency path from `SpriteBatch` and `Texture` to SDL_GPU and SDL3 2D.
- [ ] Determine which parts of sprite batching, sorting, vertex preparation, and texture metadata can be independent of the GPU backend.
- [ ] Decide whether Bairava intends to support multiple interchangeable rendering backends, or only one primary backend with platform-specific presentation support.
- [ ] If multiple backends are a real goal, define the smallest backend interface needed by the renderer.
- [ ] Keep backend-specific types out of game-facing public APIs.
- [ ] Add CPU-only tests for renderer preparation and ordering where GPU access is unnecessary.
- [ ] Document backend-specific capabilities and unsupported behavior.
- [ ] Prototype a backend replacement or fake backend and record how many unrelated modules must change.

**Starting locations:**

- `src/engine/renderer/sprite.zig`
- `src/engine/renderer/texture.zig`
- `src/engine/renderer/renderer.zig`
- `src/engine/renderer/backends/sdl_gpu/`
- `src/engine/platform/`

**Known point to verify:** `Texture` contains SDL_GPU state and SDL3 2D texture state, while `SpriteBatch` calls the SDL_GPU backend directly. Determine whether this is an acceptable single-engine implementation detail or an obstacle to the intended backend strategy.

## 3. Resource lifetime and scene ownership — High priority

- [ ] Inventory all resource types and document who creates, owns, retains, releases, and destroys each one.
- [ ] Trace asset lifetimes across scene push, pop, switch, and shutdown.
- [ ] Confirm which asset types can be unloaded before engine shutdown.
- [ ] Decide whether scenes should hold resource handles or scene-scoped asset references.
- [ ] Evaluate early unloading for directly loaded textures, atlases, fonts, and sounds.
- [ ] Define resource residency policies for assets that must persist across scene transitions.
- [ ] Check whether memory budgets include decoded staging data, CPU copies, and GPU allocations.
- [ ] Test failed loads, partial initialization, scene replacement, stale handles, and shutdown ordering.
- [ ] Add tests that verify resources are released exactly once and are not destroyed while queued work still references them.

**Starting locations:**

- `docs/ownership.md`
- `src/engine/assets/manager.zig`
- `src/engine/assets/cache.zig`
- `src/engine/core/context.zig`
- `src/engine/core/lifecycle.zig`
- `src/engine/scene/scene_manager.zig`
- `src/engine/text/font_store.zig`

**Known point to verify:** The ownership documentation says named texture handles can be unloaded early, while directly loaded textures, atlases, fonts, and sounds remain until the run ends. The scene manager also documents that scene-loaded assets remain in memory after the scene closes.

## 4. `Context` responsibilities — Medium priority

- [ ] Inventory every field and public method on `Context`.
- [ ] For each method, identify the subsystem that owns the underlying behavior.
- [ ] Identify call sites where a subsystem takes `Context` but only needs one small service or capability.
- [ ] Decide which dependencies should be passed as narrower interfaces or explicit parameters.
- [ ] Keep `Context` as the convenient game-facing facade where that convenience is valuable.
- [ ] Avoid splitting `Context` merely to reduce line count; split only where it improves testing, ownership, or API clarity.
- [ ] Add tests showing that selected subsystems can be used without constructing the full runtime context.

**Starting location:** `src/engine/core/context.zig`

**Questions:** Is `Context` becoming a service locator? Does adding a subsystem require unrelated modules to import it? Can independent systems be tested without a full `Context` fixture?

## 5. Capacity, policy, and failure behavior — Medium priority

- [ ] Search the engine for fixed capacities, limits, hardcoded defaults, panic paths, `catch unreachable`, and silent fallback behavior.
- [ ] For every limit, record its value, memory/performance rationale, whether it is configurable, and what happens when it is reached.
- [ ] Decide which limits should be configurable, queryable, or fixed implementation constraints.
- [ ] Prefer explicit error/overflow results for recoverable runtime conditions; reserve panics for broken invariants or programmer errors.
- [ ] Ensure limits and failure behavior are documented in the public API.
- [ ] Add boundary tests for exactly-at-limit and over-limit behavior.

**Search terms:**

```text
max_
capacity
@panic
std.debug.panic
catch unreachable
hardcoded
```

**Known points to verify:**

- Sprite lighting has fixed per-frame limits for point lights and shadow segments; exceeding them panics.
- Audio declares a maximum of 32 simultaneous voices.
- Check whether these limits are exposed to callers and whether the overflow behavior is suitable for games.

## 6. Renderer capability and texture-format policy — Medium priority

- [ ] Revisit `Context.stageFormats()` and its decision to disable ASTC, BC3, and BC1 variants.
- [ ] Determine whether the restriction is still necessary while SDL3 2D is reserved/unavailable.
- [ ] Decide whether format selection should depend on the active renderer, build configuration, or device capabilities.
- [ ] Ensure the chosen policy does not create incompatible texture representations during backend switching.
- [ ] Add tests for format selection and fallback behavior.
- [ ] Document the trade-off between compression, memory use, load time, and renderer compatibility.

**Starting location:** `src/engine/core/context.zig` (`stageFormats`).

## 7. Public API and caller-freedom audit — Medium priority

- [ ] Start from `src/engine/bairava.zig` and `src/engine/core/engine.zig`; inventory what game code can access.
- [ ] Identify useful capabilities available only through private engine modules.
- [ ] Check whether public types expose SDL, GPU, or other implementation-specific types.
- [ ] Identify defaults that callers cannot override and decide whether each is an intentional engine policy.
- [ ] Check whether callers can provide custom policies or implementations where that is an intended extension point.
- [ ] Check whether capacities are visible and whether their overflow behavior is controllable.
- [ ] Identify assumptions that bias the engine toward one genre or the Semkootru sample game's design.
- [ ] Build a small game using only the public `bairava` module; do not import private engine files.
- [ ] Record every workaround, missing public capability, or engine modification needed by that game.
- [ ] Turn recurring workarounds into candidate public APIs only when they represent general engine needs.

**Starting locations:**

- `src/engine/bairava.zig`
- `src/engine/core/engine.zig`
- `src/game/game.zig`
- `docs/api-compatibility.md`

## 8. Change-impact and replaceability tests

- [ ] Prototype replacing the renderer implementation and record all files that must change.
- [ ] Prototype replacing asset file loading and record all affected modules.
- [ ] Verify audio can be disabled or unavailable without breaking unrelated gameplay systems.
- [ ] Run physics, collision, navigation, and AI tests without a window or GPU.
- [ ] Verify a game can use the public API without depending on internal implementation details.
- [ ] For each prototype, distinguish necessary integration changes from accidental coupling.

## 9. Performance and scalability questions

- [ ] Benchmark with approximately 10,000 entities.
- [ ] Benchmark with approximately 10,000 queued sprites.
- [ ] Benchmark large numbers of collision queries and moving colliders.
- [ ] Look for hidden O(n²) paths in common update/draw operations.
- [ ] Identify allocations in frequently executed code and determine whether they can be moved to setup or reused buffers.
- [ ] Measure behavior when asset and staging budgets are nearly full.
- [ ] Verify the engine degrades gracefully when a workload exceeds a configured budget.
- [ ] Ensure diagnostics let developers identify CPU, GPU, memory, and asset-loading bottlenecks.

## 10. Reliability, determinism, and portability

- [ ] Verify fixed-step simulation and replay determinism with repeatable test inputs.
- [ ] Test malformed assets, scripts, and configuration data; confirm they fail safely with useful errors.
- [ ] Test worker/main-thread handoff and resource access for races.
- [ ] Test startup failure at each initialization stage and verify cleanup.
- [ ] Test scene transitions and shutdown while resources are in use.
- [ ] Verify unsupported GPU/audio capabilities are reported clearly and handled according to policy.
- [ ] Check for Windows-only assumptions and verify platform-specific paths on Windows, Linux, and macOS.
- [ ] Verify device-loss and GPU-resource recreation behavior; document unsupported recovery paths explicitly.

## 11. API usability and long-term maintainability

- [ ] Review API naming and behavior consistency across subsystems.
- [ ] Verify ownership and lifetime requirements are clear at each public API boundary.
- [ ] Check that errors identify the failing asset, operation, or subsystem.
- [ ] Confirm public API changes follow `docs/api-compatibility.md`.
- [ ] Confirm save formats, animation formats, tile maps, and font formats have independent versioning rules.
- [ ] Check dependency pins, source hashes, and license notices.
- [ ] Verify documentation matches actual implementation and current supported behavior.
- [ ] Verify CI exercises all supported platforms and relevant build profiles.
- [ ] Identify obsolete compatibility code and decide when it can be removed safely.

---

## 12. Findings register

Use one entry per confirmed finding. Do not record a suspicion as a defect until it has supporting evidence.

| ID | Finding | Files / modules | Category | Severity | Evidence / reproduction | Impact | Proposed fix | Regression test | Status |
|---|---|---|---|---|---|---|---|---|---|
| ARCH-001 |  |  | Coupling / API / ownership / policy / performance / reliability |  |  |  |  |  | Open |

### Severity guide

- **Critical:** Prevents intended engine use or risks data loss, corruption, or systemic failure.
- **High:** Blocks a major intended use case or makes subsystem replacement impractical.
- **Medium:** Creates recurring workarounds or restricts common game designs.
- **Low:** Primarily affects maintainability, consistency, or convenience.

## 13. Suggested execution order

1. Complete the module dependency graph and public API inventory.
2. Review renderer/backend boundaries and `Context` responsibilities.
3. Audit ownership, resource residency, and scene transitions.
4. Inventory limits, hardcoded policies, panic paths, and fallback behavior.
5. Run public-API-only and change-impact prototypes.
6. Run scalability, reliability, determinism, and portability tests.
7. Prioritize confirmed findings, implement fixes, and add regression tests.
8. Repeat the audit after significant architectural milestones.

## Audit completion criteria

- [ ] Every major engine subsystem appears in the dependency inventory.
- [ ] Every confirmed high-severity finding has an owner, proposed fix, and regression test.
- [ ] Public API usability has been demonstrated with a game that imports only the public engine module.
- [ ] Resource ownership and scene-transition behavior are documented and tested.
- [ ] Fixed capacities and failure policies are documented and boundary-tested.
- [ ] Supported platforms pass the relevant build and test matrix.
- [ ] The final report distinguishes confirmed defects, accepted trade-offs, and deferred improvements.
