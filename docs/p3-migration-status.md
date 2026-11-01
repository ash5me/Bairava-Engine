# P3 migration status

This project has completed the in-scope P3 runtime work for content packaging, audio safety, save/load validation, camera/view hardening, viewport-relative UI layout, and release packaging. The remaining conditional editor/tooling item is intentionally deferred unless a concrete authoring workflow becomes required.

## Completed work

### P3.1 — Content pipeline and asset packaging
- Added manifest-driven asset validation for runtime assets and atlas metadata.
- Kept asset source inputs separate from cooked runtime outputs and validated source paths, dependencies, formats, and atlas dimensions.
- Added the build step for validating and staging packaged assets from `assets/asset_manifest.txt` and the packed atlas.
- Documented the build and runtime asset pipeline in the project docs.

Access:
- Source manifest: `assets/asset_manifest.txt`
- Atlas source: `assets/sprites.txt`
- Staged runtime assets: `zig-out/bin/assets/`

Test/validation:
- `zig build check-assets`
- `zig build asset-build`

### P3.2 — Audio system
- Hardened audio playback against invalid gains and empty sounds.
- Added defensive safeguards around voice updates and missing sample data.
- Preserved engine ownership boundaries by keeping SDL audio types behind the platform layer.

Access:
- Audio API in `src/engine/audio/audio.zig`
- Runtime usage through `Context.loadSound` and the engine audio handle flow

Test/validation:
- `zig build test`

### P3.3 — Save/load and serialization
- Added version-aware save validation and safer handling for malformed or unsupported data.
- Improved default-state checks, blank-payload rejection, and safe-write behavior.
- Added atomic replacement for save writes so the previous valid save is kept if a write fails.
- Solved the deserialization mismatch regression around nested/default state handling.

Access:
- Save logic: `src/game/save.zig`
- Atomic file handling: `src/engine/platform/sdl/files.zig`

Test/validation:
- `zig build test`

### P3.4 — Camera and presentation systems
- Hardened camera follow/zoom logic against invalid and non-finite values.
- Added guardrails for zero-sized or degenerate view/layout states.
- Added viewport fit/layout helpers for stable letterboxing and render scaling.

Access:
- Camera code: `src/engine/renderer/camera.zig`
- View/layout code: `src/engine/renderer/view.zig`

Test/validation:
- `zig build test`

### P3.5 — UI foundation
- Added viewport-relative anchoring and defensive layout sanitization.
- Updated the in-game panel to use anchored bounds instead of fixed top-left placement.
- Kept UI flow generic and game-owned while exposing safer engine primitives.

Access:
- UI layer: `src/engine/ui/ui.zig`
- In-game integration: `src/game/game.zig`

Test/validation:
- `zig build test`
- Native UI harnesses remain outside the default Zig unit-test flow and are not required for the project’s normal build validation.

### P3.6 — Platform packaging and release automation
- Added a release packaging script that builds a clean artifact in `zig-out/release`.
- Included manifest metadata such as timestamp, artifact name, and current git commit when available.
- Kept dev-only diagnostics out of the packaged runtime artifact.

Access:
- Release script: `scripts/package-release.ps1`
- Package output: `zig-out/release/`
- Manifest: `zig-out/release/release-manifest.txt`

Test/validation:
- `powershell -ExecutionPolicy Bypass -File .\scripts\package-release.ps1`
- `zig build test`

### P3.7 — Scene/level editor
- Deferred intentionally. The runtime boundary is stable, but an editor is not a required dependency for the engine or the ship path.
- This remains conditional until an actual authoring workflow or level-editing requirement is identified.

## Canonical validation commands

Use these from the repository root:

```powershell
zig build
zig build test
zig build check-assets
zig build asset-build
zig build run
zig build run-sample
powershell -ExecutionPolicy Bypass -File .\scripts\package-release.ps1
```

## Where to look

- Runtime engine code: `src/engine/`
- Game layer: `src/game/`
- Build logic: `build.zig`
- User-facing docs: `README.md`
- Asset validation docs: `docs/asset-validation.md`

## Current status

The project is in a green, runtime-focused P3 state for the implemented workstreams. The remaining editor/tooling work is intentionally left as optional scope and should only be started when there is a real authoring requirement.
