# Bairava Engine --- P2 Developer Tooling Migration Plan

**Status:** Proposed\
**Priority:** P2 --- Developer productivity and iteration speed\
**Prerequisite:** P0 architecture and ownership contracts are complete;
P1 core systems are stable.

## 1. Purpose

P2 improves the development loop: make runtime behavior observable,
catch content errors early, reduce manual asset/level work, and measure
performance before optimizing. These are productivity features, not
prerequisites for a usable runtime.

## 2. Scope and Priority

  --------------------------------------------------------------------------
  ID               Workstream                     Priority Outcome
  ---------------- ----------------- --------------------- -----------------
  P2.1             Runtime                            High Inspect frame
                   diagnostics and                         timing, scene,
                   debug overlay                           input, and
                                                           resource state

  P2.2             Asset validation                   High Detect invalid
                   and hot reload                          assets and
                                                           iterate without
                                                           restarting

  P2.3             Logging and                        High Consistent,
                   diagnostic error                        actionable
                   reporting                               startup/runtime
                                                           diagnostics

  P2.4             Tilemap and                      Medium Validate and
                   level-authoring                         author levels
                   workflow                                without
                                                           hand-editing
                                                           low-level data

  P2.5             Animation                        Medium Validate clips,
                   authoring and                           frame timing, and
                   inspection                              sprite alignment

  P2.6             Profiling and                    Medium Measure engine
                   performance                             costs before
                   baselines                               optimizing

  P2.7             Developer command                   Low Inspect and
                   console                                 control selected
                                                           development
                                                           systems
  --------------------------------------------------------------------------

Priority indicates implementation order within P2, not a requirement to
build everything immediately.

## 3. P2.1 --- Runtime Diagnostics and Debug Overlay

**Goal:** Provide a development-only view of runtime state without
coupling gameplay code to the renderer or platform backend.

**Work** - Define an engine-owned diagnostics data model. - Collect
frame delta, update time, render submission time, and frame rate. -
Expose current scene identifier and transition state. - Show input state
and active actions when enabled. - Show asset/cache counts and
resource-loading failures where available. - Add optional overlays for
collision shapes, tile boundaries, entity positions, and camera
bounds. - Add a runtime toggle and build configuration flag.

**Constraints** - Opt-in; negligible release-build overhead. - Systems
publish diagnostic snapshots; overlays do not reach into private
subsystem state. - Debug drawing uses an engine-facing interface, not
SDL GPU types. - Do not build a general editor or UI framework here.

**Acceptance** - Overlay can be toggled in a development build. - Frame
timing and current scene are accurate. - Collision geometry and tile
boundaries can be visualized. - Disabling diagnostics removes or
minimizes runtime cost. - Diagnostics do not require gameplay modules.

## 4. P2.2 --- Asset Validation and Hot Reload

**Goal:** Catch asset errors early and reload supported assets during
development without restarting.

**Work** 1. Add an asset validation pass runnable at startup or as a
build/check command. 2. Validate paths, file existence, supported
formats, atlas references, frame bounds, and duplicate identifiers. 3.
Report the asset path and invalid field/reference. 4. Define reloadable
categories; start with low-risk data assets such as atlas metadata and
animation definitions. 5. Add file-change detection behind a
development-only service. 6. Reload at a safe point, not while a
renderer or gameplay system uses an in-flight resource. 7. For GPU
resources, create the replacement first, switch references safely, then
release the old resource. 8. A failed reload must preserve the last
known-good asset.

**Constraints** - Reuse P0 allocator/ownership rules and P1 typed asset
handles. - Never expose pointers into resizable cache storage. - File
watching is a development service, not a core-runtime dependency. - Do
not reload arbitrary asset types before dependencies and destruction
order are defined. - Disable hot reload in release builds.

**Acceptance** - Validation detects missing files and invalid
atlas/frame references. - Errors identify the exact asset and reason. -
Editing a supported data asset updates a running development build. -
Failed reload preserves the previous valid asset. - GPU resources are
replaced and destroyed in a defined order. - Unsupported types are
reported clearly, not partially reloaded.

## 5. P2.3 --- Logging and Diagnostic Error Reporting

**Goal:** Replace ad hoc prints and opaque startup failures with
consistent diagnostics.

**Work** - Define log levels: trace, debug, info, warning, and error. -
Include subsystem/category, message, and optional source context. -
Support console output first; add file output only if useful. -
Standardize error context at subsystem boundaries: operation,
resource/path, and relevant identifier. - Distinguish recoverable errors
from fatal initialization failures. - Ensure cleanup runs when
initialization fails partway through. - Add concise summaries for
startup and asset-validation failures.

**Constraints** - No mandatory third-party logging framework. - Avoid
expensive formatting/allocation for disabled log levels where
practical. - Do not silently swallow errors. - Preserve typed Zig error
sets; logging adds context rather than replacing errors with strings.

**Acceptance** - Subsystems use a consistent logging API. - Log
filtering is configurable by level. - Startup failures identify the
failing subsystem and operation. - Error-path tests cover cleanup where
applicable. - Release logging policy is configurable.

## 6. P2.4 --- Tilemap and Level-Authoring Workflow

**Goal:** Reduce manual level-data editing and detect tilemap mistakes
before runtime.

**Work** - Document and stabilize the tilemap data format. - Validate
dimensions, layer references, tile IDs, tileset bounds, and collision
metadata. - Add an import/conversion utility only if the chosen external
format requires it. - Separate generic tilemap data from game-specific
level rules. - Add runtime inspection for selected tile, layer
visibility, collision cells, and map bounds. - Evaluate a dedicated
editor only after data format and runtime APIs stabilize.

**Constraints** - Generic tilemap parsing/representation belongs in the
engine. - Progression, quests, triggers, and game-specific semantics
stay in the game layer. - A visual editor must not be required to load
levels. - Prefer a documented, versioned format over hidden
editor-specific state.

**Acceptance** - Invalid tilemap data is rejected with actionable
diagnostics. - A sample level loads from the documented format. -
Collision metadata and visual tile data remain consistent. - Engine
loads levels without importing game-specific level modules.

## 7. P2.5 --- Animation Authoring and Inspection

**Goal:** Make sprite animation data easier to create, validate, and
debug.

**Work** - Define/document a versioned animation data format. - Support
named clips, frame rectangles, frame durations, looping, and optional
playback metadata. - Validate frame rectangles against source
texture/atlas bounds. - Inspect current clip, frame index, elapsed frame
time, and playback state. - Add a conversion/generation tool if
animation data is currently hand-authored. - Use the engine timing model
for deterministic frame advancement.

**Constraints** - Playback primitives belong in the engine; character
state-to-animation decisions belong in gameplay. - Do not hard-code
warrior sprite or game-specific clip names in engine code. - Defer a
complex animation graph/state-machine editor.

**Acceptance** - A sample animated sprite loads from documented data. -
Invalid frame bounds/durations are reported. - Playback advances
deterministically using the engine update step. - Game code selects
clips without owning low-level frame timing.

## 8. P2.6 --- Profiling and Performance Baselines

**Goal:** Measure actual costs and establish repeatable baselines before
optimization.

**Work** - Time major runtime phases: event processing, fixed/update
step, scene update, asset work, and rendering. - Track frame-time
percentiles and worst-frame spikes in development builds. - Add
practical counters for entities, draw submissions, assets/textures, and
collision queries. - Create a repeatable benchmark scene with a
documented workload. - Record baseline measurements on a known
development configuration. - Identify bottlenecks before proposing
data-oriented rewrites or caching.

**Constraints** - Instrumentation is lightweight and optional. - Do not
use average FPS as the only performance measure. - Keep benchmark
workloads deterministic enough for comparison. - Do not optimize
speculative systems without measured bottlenecks.

**Acceptance** - Benchmark scene runs repeatedly. - Reports include
average and percentile frame times, not only FPS. - Major runtime phases
can be inspected independently. - Baseline results and machine/build
configuration are documented.

## 9. P2.7 --- Developer Command Console

**Goal:** Provide a small development-only command surface for
inspecting and changing selected runtime settings.

**Work** - Add a minimal command parser and command registry. - Start
with read-only commands: `help`, `scene`, `entities`, `assets`, and
`performance`. - Add safe controls such as toggling diagnostics and
collision visualization. - Validate arguments and return clear errors. -
Route commands through public engine services, not subsystem internals.

**Constraints** - This is not a scripting language. - Commands must be
explicitly registered. - State-changing commands are development-only
and documented. - No arbitrary memory access, unrestricted filesystem
mutation, or code execution.

**Acceptance** - Console lists commands and usage. - Invalid
commands/arguments produce useful messages. - Commands use supported
engine APIs. - Console is absent or disabled in normal release builds.

## 10. Recommended Implementation Sequence

1.  **P2.3 Logging and diagnostic errors** --- establishes the feedback
    channel for later tools.
2.  **P2.1 Runtime diagnostics and debug overlay** --- makes runtime
    state observable.
3.  **P2.6 Profiling and baselines** --- measures costs before
    optimization.
4.  **P2.2 Asset validation and hot reload** --- validate first, then
    safely reload selected data assets.
5.  **P2.4 Tilemap and level-authoring workflow** --- stabilize the data
    contract before considering an editor.
6.  **P2.5 Animation authoring and inspection** --- build on validated
    asset/atlas workflows.
7.  **P2.7 Developer command console** --- integrate existing
    diagnostics behind a small command surface.

Suggested commit-sized milestones:

-   `feat(log): add engine logging and error context`
-   `feat(debug): add runtime diagnostics overlay`
-   `feat(profiling): add frame timing and benchmark counters`
-   `feat(assets): validate asset manifests and atlas metadata`
-   `feat(assets): add safe development hot reload`
-   `feat(tilemap): add tilemap validation and inspection`
-   `feat(animation): add validated animation data and inspection`
-   `feat(dev): add development command console`

## 11. Cross-Cutting Requirements

Every P2 feature must satisfy:

-   **Layering:** game code uses public engine APIs; engine code never
    imports game modules.
-   **Ownership:** allocators, resource ownership, and cleanup follow P0
    contracts.
-   **Backend isolation:** SDL-specific types remain behind the
    platform/backend boundary.
-   **Testability:** parsing, validation, state transitions, and command
    handling are testable without opening a window where practical.
-   **Build modes:** development-only features are explicitly gated and
    add no unintended release overhead.
-   **Failure behavior:** diagnostics explain failures without hiding
    the original error.
-   **Documentation:** each public API and asset format receives concise
    usage documentation.

## 12. Global P2 Acceptance Gate

P2 is complete when:

-   Developers can understand startup/runtime failures from consistent
    logs.
-   A development build exposes useful runtime state and debug geometry.
-   Asset validation catches common content errors before gameplay.
-   At least one supported asset category can be safely hot-reloaded.
-   Tilemap and animation data have documented, validated workflows.
-   Performance can be measured with a repeatable benchmark.
-   Development commands use public engine interfaces and are excluded
    from normal release builds.
-   No P2 feature introduces a dependency from engine code back into
    game code.

P2 does **not** require a full editor, scripting system, plugin system,
multiple graphics backends, or a complete content pipeline.

## 13. Explicitly Out of Scope

Defer until there is a demonstrated need:

-   Full visual scene/tilemap editor.
-   Full animation graph editor.
-   General-purpose scripting or embedded language runtime.
-   Runtime mod/plugin loading.
-   Network multiplayer, rollback, and replay systems.
-   Asset streaming and asynchronous dependency graphs.
-   Multiple graphics backends.
-   Advanced profiling integrations or telemetry upload.
-   Automated asset optimization/compression pipeline.
-   General-purpose UI framework.
-   End-user developer console.

## 14. Next Milestone After P2

After P2, evaluate P3 based on actual project needs. Candidate areas
include content pipeline automation and packaging, a scene/level editor,
audio expansion, save/load and serialization, camera/UI/presentation
systems, and platform packaging/release tooling.

Do not promote these to commitments until P2 exposes concrete workflow
bottlenecks and the engine's public contracts are stable.
