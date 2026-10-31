# Tilemap format and validation

The engine parses tilemaps without SDL or game modules in
[`src/engine/scene/tilemap.zig`](../src/engine/scene/tilemap.zig). The game owns level progression
and chooses the tile texture. A text map remains loadable without an editor.

## Version 1 text format

Blank lines and lines beginning with `#` are ignored. New files should begin with `version 1`.
Unversioned maps remain accepted as version 1 for compatibility.

```text
version 1
size 40 24
tileset 220
solid 1
layer ground
1 1 1 ...
...
layer decoration
...
layer foreground
...
```

- `size` is required, positive, and limited to 4,194,304 cells total.
- `tileset` is the number of 16x16 cells in the tileset. It is optional for legacy maps. If present,
  every tile and collision ID must be less than the count.
- `solid` lists the tile IDs that block movement. A cell is solid if any layer has a listed ID;
  cells outside the map are solid.
- Layers are `ground`, `decoration`, and `foreground`. Each may occur at most once; omitted layers
  are empty. Each declared layer has exactly `size` rows, each with exactly `size` entries.
- Entries are tile IDs from 0 through 254, or `.` for an empty cell. IDs address tiles left to
  right, then top to bottom in the tile image.

The engine parser rejects unsupported versions, duplicate headers/layers, malformed rows,
excessive dimensions, and IDs outside the declared tileset. Game-specific level rules stay outside
the generic map format: the sample game's `assets/maps/level1.spawn` contains `spawn COL ROW`, and
the game validates that cell against the loaded map dimensions. The game also checks the tileset
declaration and every used ID against the actual atlas region at startup and during atlas reload,
so a stale map cannot silently sample unrelated texture data.

## Inspection

`engine.tilemap.TileMap.idAt(layer, col, row)` returns the selected layer's tile ID or null for an
empty/out-of-bounds cell. `engine.tilemap.TileMap.isSolid(col, row)` reports collision metadata.
With development diagnostics enabled, F4 toggles the collision-cell and tile-grid overlays. The F2
console's `tile` command reports the ground tile and solidity under the cursor, and `layer NAME
on|off|toggle` controls visibility of the three tile layers. The engine-facing debug geometry API
also exposes camera bounds and entity markers.

`assets/maps/level1.txt` is the sample map, and its `tileset 220` declaration matches the 320x180
tile image at 16 pixels per cell. `zig build test` exercises parsing, format versioning, bounds,
layers, and collision movement without opening a window.
