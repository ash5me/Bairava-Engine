# Prefabs

Prefabs are named entity templates. The game's prefab file defines them, and the level metadata places them
by name. Each placement spawns one entity in the game's ECS world, and the entity draws its prefab's tile.

## The prefab file

`assets/prefabs.txt` holds one statement per line. `#` starts a comment, and blank lines are ignored.

```
prefab marker
tile 39
```

- `prefab <name>` starts a template. A name uses lowercase letters, digits, and `_`, and is at most 32 bytes.
- `tile <id>` names the tile the template draws: an index into the level's tileset, counted left to right and
  then down, the same as the tile layers. Each template needs exactly one `tile` line.

Any other line is an error. The file holds at most 64 templates.

## Level metadata

`assets/maps/level1.spawn` holds the level's game metadata. It has one `spawn` line and any number of `place` lines:

```
spawn 20 12
place marker 3 3
place marker 36 3
```

- `spawn <col> <row>` is the cell where the player starts. It is required, and it appears once.
- `place <prefab> <col> <row>` spawns one entity from the named template on that cell. A level holds at most 4096
  placements.

The file keeps its `.spawn` name for now, although it also holds placements.

## Checks

- `zig build check-assets` parses the prefab file, and checks the level metadata against the map's size and the
  prefab names. The metadata must depend on the `game_prefabs` asset in `assets/asset_manifest.txt`.
- At startup the game checks that every prefab's tile exists in the tileset, and it stops if one does not. An
  atlas reload that would break a prefab's tile is rejected, and the current atlas stays in use.
- Unknown prefab names, cells outside the map, and malformed lines are all errors.

## Limits

- The only component is `tile`. A placed entity draws its tile and blocks nothing, so the player walks through it.
- Placed entities are not saved. Loading the level spawns them again from the metadata.
- The prefab file and the level metadata are read at startup only. Edits take effect after a restart.
- The example `marker` tile is a placeholder. It was chosen for contrast with the ground, not for its art.
