# Getting started

Bairava is an experimental 2D engine written in Zig. The repository includes a small sample game that imports the
engine through its supported game-facing module, `@import("bairava")`.

## Requirements

- The Zig version pinned in `build.zig.zon` (`0.16.0-dev.3142+5ccfeb926` for this checkout).
- Slang's `slangc` compiler on `PATH`.
- Internet access for the first build so Zig can fetch the pinned dependencies.

## Build and run the sample

From the repository root:

```sh
zig build run-sample
```

The sample is compiled by the normal build graph and installed at `zig-out/bin/BairavaSample`. It demonstrates a
game that imports only `bairava`, configures the engine, loads a texture, draws through a `SpriteBatch`, maps physical
controls to game actions, and switches between scenes. Use `zig build` to build Semkootru, the repository's larger
sample game.

## Explore the public API

Start with the generated [public API reference](../api/). The [sample source](https://github.com/ash5me/Bairava-Engine/tree/main/sample)
is the runnable example for lifecycle, drawing, input, assets, entities, and scenes. Other guides in this site cover
specific subsystems and their current limits.

The API is in early development and is not production-ready. Do not treat internal engine modules as stable game
interfaces; game code should import the named `bairava` module.
