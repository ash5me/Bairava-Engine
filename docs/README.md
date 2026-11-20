# Documentation

Use the subsystem guides for current behavior. Plans describe proposed work or preserve implementation decisions; the text guide is the current behavioral reference.

## Engine source layout

`src/engine/` is organized by subsystem. Keep implementation modules in their owning directories (for example,
`navigation/`, `renderer/`, or `audio/`); the root is reserved for the package facade and small shared modules such as
`bairava.zig`, `capabilities.zig`, and `version.zig`. Game-specific implementations belong under `src/game/`, not
inside the engine. Avoid leaving duplicate or obsolete implementations beside their active subsystem modules.

## Core guides

- [Getting started](getting-started.md)
- [Application lifecycle](application-lifecycle.md)
- [Rendering](rendering.md)
- [Input](input.md)
- [Assets](assets.md)
- [Scenes](scenes.md)
- [AI](ai.md)
- [Animation](animation.md)
- [Asset streaming](asset-streaming.md)
- [Asset validation](asset-validation.md)
- [Audio streaming](audio-streaming.md)
- [Developer console](developer-console.md)
- [Diagnostics](diagnostics.md)
- [Jobs](jobs.md)
- [Lighting](lighting.md)
- [Localization](localization.md)
- [Logging](logging.md)
- [Navigation](navigation.md)
- [Particles](particles.md)
- [Physics and collision queries](physics.md)
- [Prefabs](prefabs.md)
- [Profiling](profiling.md)
- [Replay and saves](replay.md)
- [Scripting](scripting.md)
- [Text and fonts](text.md)
- [Tile maps](tilemap.md)

## API and project references

- The supported game-facing API is the `bairava` module rooted at `src/engine/bairava.zig`.
  `zig build docs` assembles a curated Jekyll site at `zig-out/doc/bairava/`, with the
  generated API reference at `api/index.md`. The manifest covers the package root's 87
  exports and includes compiler-derived callable type information plus a member-contract
  checklist. Member coverage is partial; GitHub Pages `/dev/` is deployed and verified, while
  release snapshot retention remains unverified. See the
  [API documentation plan](plans/Bairava-Engine-Complete-API-Documentation-Implementation-Plan-Updated.md).
- [API compatibility](api-compatibility.md)
- [Build profiles](build-profiles.md)
- [Dependency policy](dependency-policy.md)
- [Event conventions](event-conventions.md)
- [Ownership](ownership.md)
- [Platform capabilities](platform-capabilities.md)
- [Dependency lock](dependency-lock.json)
- [Engine architecture](whole-architecture.jfif)
- [Font architecture](font-architecture.png)

## Plans and audits

- [Documentation license](LICENSE.md)
- [Dear ImGui migration plan](plans/dearimgui-migration-plan.md) — proposed; not implemented.
- [Text and font migration plan](plans/text-and-font-system-migration-plan.md) — implementation decisions and evidence; see [text.md](text.md) for current behavior.
- [Architecture audit action items](plans/architecture-audit-action-items.md) — findings to verify, not confirmed defects.
