# Bairava Engine

Bairava is an experimental 2D game engine written in Zig, built on SDL3 and SDL_GPU. The repository includes a runnable game sample, a public-API scene sample, asset tools, focused testbeds, and subsystem documentation. See the [sample game guide](docs/semkootru.md) for game-specific instructions.

The engine and asset formats are under active development. Public APIs and file formats may change; they are not yet production-stable.

## Features

- Fixed-timestep game loop, native-resolution rendering, camera, integer and fit scaling
- SDL_GPU sprite batching, texture atlases, tile maps, lighting, post-processing, and render graph
- Manifest-driven asset builds, runtime asset registry, streaming, hot reload, and compressed texture variants
- BFNT and bitmap fonts, runtime TrueType coverage, MSDF fonts, text shaping, layout, and immediate-mode UI
- ECS-style entities, scenes, prefabs, animation, collision and physics, navigation, and AI
- Audio playback and streaming, worker jobs, scripting, localization, replay, and particles
- Input and gamepad handling, settings and saves, logging, crash reports, diagnostics, and profiling
- Public API example and runnable testbeds for subsystem and integration checks

## Requirements

- Zig `0.16.0-dev.3142+5ccfeb926` (the version pinned in `build.zig.zon`)
- Slang `slangc` on `PATH` for shader compilation
- Internet access for the first dependency fetch; fetched dependencies are pinned

Optional:

- Direct3D 12 shader output: `-Ddxil=true` and a compatible Slang compiler
- Metal shader output: `-Dmetal=true` and a compatible Slang compiler
- GPU validation: `-Dgpu-debug=true`
- Tracy profiling: `-Dtracy=true` and the Tracy 0.14.1 viewer
- ASTC texture variants: Arm `astcenc` on `PATH`

The default runtime renderer is SDL_GPU. Vulkan/SPIR-V is the default shader target; DXIL and Metal shader outputs are optional. The SDL3 2D renderer path is reserved and is not currently a selectable game renderer.

Dependencies are pinned or vendored. msdfgen and FreeType are used by the offline asset builder, not linked into the game runtime. See the [dependency policy](docs/dependency-policy.md) and [dependency lock](docs/dependency-lock.json) before changing dependencies.

## Build

Run commands from the repository root:

```sh
zig build
```

The build installs executables under `zig-out/bin/`, stages runtime assets under `zig-out/bin/assets/`, and embeds compiled shaders. To launch the included game sample, follow the [sample game guide](docs/semkootru.md).

Common build options:

```sh
zig build -Dprofile=debug
zig build -Dprofile=release
zig build -Dgpu-debug=true
zig build -Dtracy=true
zig build -Ddxil=true
zig build -Dmetal=true

zig build run-sample
zig build run-benchmark
zig build check-assets
zig build asset-build
```

`run-sample` runs a small scene built through the public engine API. `run-benchmark` runs the deterministic sprite and entity workload.

## Testbeds

Testbeds are separate runnable applications. Build and launch one with `zig build run-tbNN`; commands are run from the repository root.

| Target | Focus |
|---|---|
| `run-tb01` | Sprite rendering stress |
| `run-tb02` | Asset loading and streaming |
| `run-tb03` | Text and font rendering |
| `run-tb03-msdf-probe` | Compare an MSDF glyph baked at 16, 24, 32, and 48 px |
| `run-tb04` | Animation stress |
| `run-tb05` | Collision and physics |
| `run-tb06` | Camera and viewport |
| `run-tb07` | Top-down adventure integration |
| `run-tb08` | Isometric world |
| `run-tb09` | Platformer |
| `run-tb10` | Bullet hell stress |
| `run-tb11` | UI and localization |
| `run-tb12` | Long-running simulation |
| `run-tb13` | Lighting laboratory |
| `run-tb14` | Render graph validation |
| `run-tb15` | Audio laboratory |
| `run-tb16` | Input laboratory |
| `run-tb17` | Navigation laboratory |
| `run-tb18` | Job system laboratory |
| `run-tb19` | Resource and entity lifecycle |
| `run-tb20` | SDL_GPU backend parity smoke |
| `run-tb21` | Tilemap validation and stress |
| `run-tb22` | Particle pool and overdraw stress |
| `run-tb23` | Deterministic input replay and checkpoints |

TB-03 also has a standalone deterministic typography workload:

```sh
zig build run-text-benchmark
zig build run-tb03
```

### TB-03 MSDF comparison

The focused MSDF probe writes rendered source/destination rectangle metadata to `zig-out/bin/TB-03-msdf-scale-probe.json`. Capture the comparison window, then export the matching atlas crops, separate RGB channel images, and UV/render metadata:

```sh
zig build run-tb03-msdf-probe
python scripts/msdf_probe.py --report zig-out/bin/TB-03-msdf-scale-probe.json --assets zig-out/bin/assets --output zig-out/msdf-probe
```

The four font sizes are baked as separate MFNT assets so the generator and shader can be investigated independently. See the [TB-03 validation roadmap](Bairava-Engine-Testbed-and-Validation-Roadmap.md).

## Assets

Asset sources and manifests:

- `assets/asset_manifest.txt` declares packaged files, fonts, maps, and other runtime assets.
- `assets/sprites.txt` declares sprite sources for the atlas.
- `assets/animations/`, `assets/maps/`, `assets/scripts/`, and `assets/prefabs.txt` contain game data.

The asset build validates inputs, generates runtime asset indexes, packs the sprite atlas, and prepares supported texture/audio variants. Generated output belongs under `zig-out/`; edit source assets and manifests instead of generated files.

```sh
zig build check-assets
zig build asset-build
zig build asset-import -- path/to/sprite.png my_sprite
zig build asset-keyer -- path/to/sprite.png path/to/sprite_keyed.png
```

The texture loader chooses a GPU-supported variant, falling back through ASTC, BC3, BC1, RGBA8, and source-image decoding as available. Font assets include prebaked coverage, authored bitmap coverage, runtime TrueType coverage, and offline-baked MSDF. BFNT and MSDF assets must be loaded at their baked pixel height. See [assets](docs/assets.md), [asset streaming](docs/asset-streaming.md), and [text and fonts](docs/text.md).

## Architecture

Game code should import the public package root at `src/engine/bairava.zig`; avoid depending on engine-private implementation files. The engine separates game-facing types and lifecycle from its SDL platform implementation.

- The game loop updates at a fixed timestep and renders interpolated frames.
- The default logical view is 320x180 pixels; the camera and world use native/world pixel coordinates.
- The world is rendered to a native-resolution target and scaled to the window.
- SDL_GPU owns renderer-specific pipelines, buffers, shaders, and transfers.
- Runtime asset names resolve through a manifest-backed registry; packaged files are staged beside the executable.

## Project layout

```text
build.zig                 Zig build graph and runnable targets
build.zig.zon             Package metadata and dependency pins
src/main.zig              Game sample entry point
src/game/                 Game sample systems and configuration
src/engine/               Engine implementation and public package root
sample/                   Public API sample, benchmarks, and TB-01 through TB-23
tests/                    Test fixtures and test support
tools/                    Host-side asset and documentation tools
assets/                   Source assets and manifests
shaders/                  Slang shader sources
docs/                     User guides, API references, and plans
checks/                   Validation evidence and parity checks
scripts/                  Build, validation, release, and development scripts
vendor/                   Vendored dependencies and license notices
```

## Documentation and support

- [Documentation index](docs/README.md)
- [Getting started](docs/getting-started.md)
- [Sample game guide](docs/semkootru.md)
- [Application lifecycle](docs/application-lifecycle.md)
- [Rendering](docs/rendering.md)
- [Text and fonts](docs/text.md)
- [API compatibility](docs/api-compatibility.md)
- [Dependency policy](docs/dependency-policy.md)
- [Contributing guide](CONTRIBUTING.md)

Optional Tracy zones can be enabled with `zig build -Dtracy=true`.

## Tests and CI

Run the relevant checks from the repository root:

```sh
zig build
zig build test
zig build test-ui
zig build check-assets
zig build docs
python scripts/check-dependency-pins.py
python scripts/boundary_scan.py --self-test
python scripts/boundary_scan.py --fail
```

The test target covers Zig engine/game and public API tests, C text/UI tests, asset tools, jobs, and scripting. CI builds Windows, macOS, and Linux; it also checks debug/release profiles and the platform shader outputs supported by each runner. The main tests do not require launching the game or opening a GPU window.

## Release packaging

On Windows, create a release package with:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\package-release.ps1
```

The package is written to `zig-out/release/` and includes the executable, packaged assets, documentation, and release manifest.

## License

The Bairava Engine project is licensed under the [MIT License](LICENSE). Third-party dependencies and assets retain their own licenses; see the notices in `vendor/` and the [dependency policy](docs/dependency-policy.md). Original documentation prose and illustrations are licensed separately under [CC BY 4.0](docs/LICENSE.md).
