# Bairava Engine --- P3 Feature Expansion Migration Plan

**Status:** Implemented/validated in scope for the current engine runtime\
**Priority:** P3 --- Production capabilities and content workflows\
**Prerequisites:** P0 architecture/ownership contracts, P1 core systems,
and P2 diagnostics/validation/profiling are stable.

This migration is in the completed, repo-aligned state for the runtime layer: content packaging, asset validation, save/load safety, camera/view hardening, UI anchoring, and release packaging are all in place. P3.7 remains conditional and intentionally deferred unless an authoring workflow becomes a concrete requirement.

## 1. Purpose

P3 expands Bairava Engine from a stable runtime into a more complete
foundation for building and shipping games. It focuses on content
packaging, audio, persistence, presentation, UI, release automation, and
optional authoring tools.

P3 is capability-driven: implement workstreams when a real game or
workflow needs them. Do not make every candidate a mandatory subsystem.

## 2. Scope and Priority

  -----------------------------------------------------------------------
  ID                Workstream        Priority          Outcome
  ----------------- ----------------- ----------------- -----------------
  P3.1              Content pipeline  High              Reproducible,
                    and asset                           validated runtime
                    packaging                           asset packages

  P3.2              Audio system      High              Engine-level
                                                        playback, mixing,
                                                        and resource
                                                        lifecycle

  P3.3              Save/load and     High              Versioned
                    serialization                       persistence with
                                                        game-owned save
                                                        schemas

  P3.4              Camera and        Medium            Reusable 2D
                    presentation                        camera and
                    systems                             viewport
                                                        transforms

  P3.5              UI foundation     Medium            Reusable runtime
                                                        UI primitives

  P3.6              Platform          Medium            Repeatable
                    packaging and                       release builds
                    release                             for supported
                    automation                          targets

  P3.7              Scene/level       Low / Conditional Optional visual
                    editor                              authoring tool on
                                                        stable APIs
  -----------------------------------------------------------------------

Priority is a suggested order, not a commitment to implement everything.
Reorder based on the next game's needs.

## 3. P3.1 --- Content Pipeline and Asset Packaging

### Goal

Turn development assets into validated, reproducible runtime packages
while keeping source assets separate from cooked assets.

### Work

1.  Define source assets versus cooked/runtime assets.
2.  Create a manifest format with stable asset IDs, types, source paths,
    dependencies, and import settings.
3.  Build a command-line pipeline to validate, convert, pack/copy, and
    report assets.
4.  Generate atlas and animation metadata where applicable.
5.  Make outputs deterministic for identical inputs and settings.
6.  Track dependencies and report missing/invalid references.
7.  Define package layout, versioning, integrity checks, and runtime
    lookup.
8.  Keep loose-file loading available in development.

### Constraints

-   Reuse P2 validation and P1 typed asset handles.
-   Runtime loading must not depend on source asset directories or
    editor code.
-   Avoid a custom binary package format unless measurements justify it.
-   Generated outputs must be reproducible and safe to regenerate.
-   Do not add encryption/obfuscation by default.

### Acceptance

-   A clean checkout can build a runtime package using documented
    commands.
-   Invalid references fail with actionable diagnostics.
-   Runtime loads packaged assets without source paths.
-   Loose-file and packaged loading share the same public asset
    interface.
-   Unchanged inputs produce stable outputs.
-   Package format/version compatibility is documented.

## 4. P3.2 --- Audio System

### Goal

Provide a small reusable 2D game-audio layer with clear ownership and
predictable playback.

### Work

-   Review audio facilities in the project's pinned SDL3 version before
    selecting the backend design.
-   Define engine-owned audio device/output, clip, playback instance,
    and optional bus concepts.
-   Support play, pause, resume, stop, volume, looping, and completion.
-   Add master/music/SFX controls if required.
-   Integrate audio loading and lifetime with the asset/resource model.
-   Handle initialization failure and device removal/reconfiguration
    where supported.
-   Define shutdown and resource destruction order.
-   Add a sample using music and sound effects.

### Constraints

-   Keep SDL audio types behind the platform/audio backend boundary.
-   Do not expose raw device/stream pointers publicly.
-   Do not build a DAW, node graph, or advanced spatial audio system.
-   Audio callbacks must not perform blocking I/O, unsafe allocation, or
    arbitrary gameplay work.
-   Defer streaming/decoding complexity until real asset requirements
    justify it.

### Acceptance

-   Game code can play, pause, resume, stop, and adjust sound through
    engine APIs.
-   Resources follow documented ownership and cleanup rules.
-   Audio initialization failure is reported without corrupting
    unrelated runtime state.
-   Music and sound effects can be controlled independently if buses are
    implemented.
-   Logic tests and a manual playback integration test pass.
-   SDL audio types do not leak into game-facing modules.

## 5. P3.3 --- Save/Load and Serialization

### Goal

Provide persistence infrastructure while keeping the meaning and schema
of game progress game-owned.

### Work

1.  Define a serialization boundary for reading/writing versioned data.
2.  Separate engine configuration serialization from game-save schemas.
3.  Write safely: temporary file, flush/close, then replace the previous
    save where supported.
4.  Include schema/version identifiers and a migration strategy.
5.  Define behavior for missing, corrupt, truncated, and unsupported
    files.
6.  Let game code serialize its own progress through a documented
    interface.
7.  Add slots/metadata only when the game requires them.
8.  Test round trips, version mismatch, malformed data, and interrupted
    writes.

### Constraints

-   Never serialize raw in-memory structs, pointers, allocator state,
    ECS layout, or renderer/audio handles.
-   Persist stable identifiers and explicit fields.
-   Inventory, quests, progression, and world state remain game-owned.
-   Do not bind the engine to a serialization library/format without
    need.
-   A failed save must not destroy the last known-good save.
-   Treat save data as untrusted input; validate sizes and ranges.

### Acceptance

-   A sample game state saves and loads through the public persistence
    interface.
-   Save files carry an explicit schema/version.
-   Corrupt or unsupported files fail safely with useful diagnostics.
-   Failed writes preserve the previous valid save.
-   Game modules define save schemas without engine imports of game
    types.
-   Round-trip and failure-path tests pass.

## 6. P3.4 --- Camera and Presentation Systems

### Goal

Add reusable 2D presentation primitives for world-to-screen rendering
and common camera behavior.

### Work

-   Define an engine-owned 2D camera with position, zoom, and rotation
    only if needed.
-   Separate world, logical-render, and window/output coordinates.
-   Support camera transforms in rendering and input coordinate
    conversion.
-   Add viewport scaling and letterboxing policies.
-   Provide optional follow-target helpers with configurable smoothing.
-   Add bounds/dead zones only when justified.
-   Ensure debug overlays and collision visualization use the same
    transforms.

### Constraints

-   Camera state is engine-level; target selection and game-specific
    camera rules remain in gameplay.
-   Preserve crisp pixel-art rendering at integer scales where possible.
-   Do not hard-code one resolution or aspect ratio.
-   Defer cinematic timelines.

### Acceptance

-   A scene renders through an engine-owned camera.
-   Pointer coordinates convert consistently between screen and world
    space.
-   Viewport scaling/letterboxing is documented and tested.
-   Sprites, debug geometry, and input queries use consistent
    transforms.
-   The 320×180 logical resolution remains a supported configuration,
    not an engine-wide limitation.

## 7. P3.5 --- UI Foundation

### Goal

Provide minimal runtime UI primitives without coupling the engine to one
game's screens or visual style.

### Work

-   Define basic layout/container, text, image, button, and panel
    primitives.
-   Define anchors, sizing, and scaling relative to the logical
    viewport.
-   Add pointer interaction and keyboard/controller focus navigation.
-   Define UI input priority and consumption so gameplay does not react
    to UI interactions.
-   Support normal, focused/hovered, pressed, and disabled states.
-   Integrate fonts and textures with the asset lifecycle.
-   Build a sample menu/HUD in the game layer.

### Constraints

-   UI widgets/layout are generic; menu flow remains game-owned.
-   Do not build HTML/CSS, a desktop widget toolkit, or a complex
    declarative language.
-   Consider accessibility, localization, and navigation in API design
    even if staged.
-   Use public renderer/input/text interfaces only.

### Acceptance

-   Sample menu displays text/images and responds to pointer and
    keyboard/controller input.
-   UI can consume input before gameplay.
-   Layout adapts to supported logical viewports and scaling modes.
-   Font/texture ownership follows engine contracts.
-   Game-specific screens and navigation remain outside engine modules.

## 8. P3.6 --- Platform Packaging and Release Automation

### Goal

Make release builds reproducible and establish a truthful, tested
platform support boundary.

### Work

-   Explicitly list supported platforms/architectures; start with the
    current development target.
-   Define debug, development, and release build configurations.
-   Gate diagnostics, console, hot reload, and other dev-only features
    from release.
-   Automate asset cooking, executable build, package assembly, and
    smoke tests.
-   Document SDL/runtime dependencies and asset locations.
-   Add version/build metadata to artifacts.
-   Add CI formatting, test, and supported-target release-build checks.
-   Expand targets only after the current release process is repeatable.

### Constraints

-   Do not claim support for platforms not built and tested.
-   Keep platform startup, filesystem, and packaging behind narrow
    services.
-   No automatic updates or telemetry upload in this workstream.
-   Keep signing keys, credentials, and secrets out of source control
    and logs.

### Acceptance

-   A clean environment produces a documented release artifact.
-   Artifact includes required runtime dependencies and cooked assets.
-   Dev-only systems are excluded or explicitly gated.
-   CI builds/tests the supported target.
-   Version and build configuration are identifiable.
-   Installation, launch, and asset lookup are documented.

## 9. P3.7 --- Scene/Level Editor (Conditional)

### Goal

Add visual authoring only after scene, tilemap, asset, and runtime data
contracts are stable.

### Work

-   Begin with a read-only inspector using public engine APIs.
-   Inspect scenes, entities, tilemaps, and asset references.
-   Add editing only for a small supported set of properties.
-   Define validation and undo/redo before destructive editing.
-   Store authored data in documented, versioned formats.
-   Keep editor-only state separate from runtime data.
-   Decide whether the editor is a separate executable or optional
    development module.

### Constraints

-   Conditional: do not start merely because an editor sounds useful.
-   Runtime must never depend on editor code.
-   Do not expose private ECS storage or renderer internals.
-   Defer visual scripting and node graphs.
-   Reuse P2 diagnostics and asset validation.

### Acceptance

-   Read-only inspector handles a representative sample project.
-   Changes are validated before writing.
-   Runtime loads authored data without editor dependencies.
-   Undo/redo exists before broad editing operations.
-   Invalid edits cannot irrecoverably corrupt source assets.

## 10. Recommended Implementation Sequence

1.  **P3.1 Content pipeline and packaging** --- establish reproducible
    source-to-runtime assets.
2.  **P3.2 Audio system** --- add a major game capability using existing
    ownership/backend boundaries.
3.  **P3.3 Save/load and serialization** --- add persistence without
    coupling engine internals to game data.
4.  **P3.4 Camera and presentation** --- build on renderer and viewport
    contracts.
5.  **P3.6 Platform packaging and release automation** --- make the
    current target reliably shippable.
6.  **P3.5 UI foundation** --- move earlier if the next game needs
    menus/HUD.
7.  **P3.7 Scene/level editor** --- start only when repeated authoring
    pain justifies it.

Suggested commit milestones:

-   `feat(content): add deterministic asset cooking and packaging`
-   `feat(audio): add engine audio playback interface`
-   `feat(save): add versioned persistence boundary`
-   `feat(camera): add 2d camera and viewport transforms`
-   `build(release): automate packaged release artifacts`
-   `feat(ui): add minimal runtime UI primitives`
-   `feat(editor): add read-only scene and tilemap inspector`

## 11. Cross-Cutting Requirements

Every P3 workstream must satisfy:

-   **Layering:** engine modules never import game modules; editor code
    is not a runtime dependency.
-   **Ownership:** follow P0 allocator, lifetime, and cleanup contracts.
-   **Backend isolation:** SDL-specific types remain behind
    platform/backend boundaries.
-   **Stable interfaces:** use public engine types and handles, not
    internal storage.
-   **Data safety:** validate external files, save data, and imported
    assets.
-   **Build modes:** development/editor capabilities are gated from
    release unless intentionally enabled.
-   **Testing:** unit-test data/logic and integration-test
    platform-dependent behavior.
-   **Documentation:** document formats, compatibility, build commands,
    and failure behavior.

## 12. Global P3 Acceptance Gate

P3 is complete when the selected workstreams---not necessarily every
candidate---meet their acceptance criteria:

-   Runtime assets can be built through a documented, repeatable
    pipeline.
-   Audio playback and resource lifetime are stable if audio is in
    scope.
-   Save data is versioned, validated, and safely written if persistence
    is in scope.
-   Camera/viewport transforms are consistent across rendering and input
    if presentation is in scope.
-   UI uses public engine interfaces and keeps game-specific flow in the
    game layer if UI is in scope.
-   At least one supported release target can be built and launched
    reproducibly.
-   Editor/tooling remains optional and cannot become a runtime
    dependency.
-   No P3 workstream violates P0/P1 architecture boundaries.

## 13. Explicitly Out of Scope

Defer unless a concrete requirement emerges:

-   3D rendering and physics.
-   Network multiplayer, rollback, and deterministic lockstep.
-   Embedded scripting, mod loading, and plugin ABI.
-   Cloud saves, account systems, and online services.
-   Automatic updates and telemetry upload.
-   Full visual scripting or node-graph editor.
-   Advanced animation graph editor and cinematic timeline.
-   Complex spatial audio/DSP graph/audio authoring suite.
-   Multiple graphics backends solely for architectural purity.
-   Console/mobile support without target hardware and a defined product
    need.

## 14. Next Milestone After P3

After P3, validate the engine with a real vertical slice: one
representative game level using input, rendering, collision, animation,
audio, UI, save/load, and a packaged release build.

Use that vertical slice to identify genuine gaps before defining P4.
Advanced tooling, additional platforms, performance specialization,
networking, and extensibility should be proposed only when supported by
evidence from a real game workload.
