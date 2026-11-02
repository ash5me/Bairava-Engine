# Engine API versioning and compatibility

The engine API version describes the source-level public API exported by the `bairava` module.
Consumers can inspect its numeric components at compile time or runtime:

```zig
const engine = @import("bairava");

comptime {
    if (engine.version.major != 0) @compileError("this example targets the 0.x API");
}
```

The current version is **0.1.0**. Its definition is in [`src/engine/version.zig`](../src/engine/version.zig);
keep it in sync with the package version in [`build.zig.zon`](../build.zig.zon).

## Compatibility rules

The engine is pre-1.0.0, so its minor versions may introduce breaking API changes. For every
`0.minor.patch` version:

- A **patch** release fixes bugs without intentionally breaking documented public API or behavior.
- A **minor** release may add APIs or make breaking changes. Review its migration notes before
  upgrading; there is no compatibility promise between minor versions.
- The **major** component remains zero until the API is ready for its first stable release.

After 1.0.0, the engine will follow Semantic Versioning: patch releases remain compatible, minor
releases add functionality compatibly, and breaking public API or behavior changes require a major
release. Deprecations should be documented and retained until a permitted breaking release.

These rules apply to the documented source API exported from `bairava`, not internal modules or
Zig's binary ABI. The minimum supported Zig compiler remains independently pinned in
`build.zig.zon`; an engine API version does not promise compatibility with other Zig compiler
versions or build configurations.

## Data formats are independent

An engine API version is not a save-file or asset-format version. Data formats have their own
version fields and compatibility rules, independent of engine releases:

- Game saves: `save_version` in [`src/game/save.zig`](../src/game/save.zig).
- Animation clips, machines, and skeletons: the `animation`, `machine`, and `skeleton` headers in
  [`docs/animation.md`](animation.md).
- Tile maps: the `version` header in [`docs/tilemap.md`](tilemap.md).
- IMA ADPCM audio: the BRAD version byte decoded by
  [`src/engine/audio/ima.zig`](../src/engine/audio/ima.zig).

Changing an on-disk representation must be handled under that format's version, not by relying on
the engine API version. Each reader must continue to accept documented compatible versions or
explicitly reject unsupported or malformed data; it must not silently interpret an unknown format
as the current one. A release may change the API without changing formats, or change a format
without changing the public API.
