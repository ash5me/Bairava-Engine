# Dear ImGui Migration Plan

## Purpose

Replace the legacy C immediate-mode widget implementation in `src/engine/ui/` with Dear ImGui while preserving the engine-facing `Ui`, `Canvas`, font, layout and pointer APIs. The migration should make the engine suitable for inventories, settings, dialogs, scrollable lists, tables, tooltips, context menus and debugging tools.

This document is an implementation plan. It does not add Dear ImGui to the repository or alter runtime behavior until the migration phases pass their acceptance gates.

## Scope

### Included

- Semkootru Demo, Saves and Controls screens
- Existing labels, buttons, sliders and keybind widgets
- Native-view coordinate mapping and high-DPI support
- Existing font and SpriteBatch rendering
- Dear ImGui widget state and ID behavior
- C/Zig build integration and UI tests
- Inventory and menu foundations after widget parity

### Deferred

- Dear ImGui docking branch and multiple OS-level windows
- SDL platform backend integration through Dear ImGui
- Debug overlay migration until game UI parity is complete
- Game-specific inventory data, ECS integration, item rules and persistence
- Docking layouts and editor-mode workspace configuration

## Recommended architecture

Keep the public engine API stable:

```text
Game / editor code
        |
  engine.ui.Ui
        |
Dear ImGui C/C++ adapter
        |
Engine font and SpriteBatch renderer
```

The game should continue to call:

- `Ui.begin`
- `Ui.end`
- `Ui.label`
- `Ui.button`
- `Ui.slider`
- `Ui.keybind`
- `Ui.queue`

Dear ImGui and cimgui types should remain inside a private adapter. Other engine modules should not expose them through public APIs.

## Dependencies and build strategy

Pin matching versions of:

- Dear ImGui
- cimgui, if selected as the C bridge
- Their license text

Do not track moving branches. Record the pinned commits and synchronization procedure in the dependency policy.

Add build steps for:

- Dear ImGui core C++ sources
- `cimgui.cpp` when using the generated C API
- A small `extern "C"` adapter for engine-owned frame and widget operations
- Dedicated Dear ImGui UI tests

Compile-time C++ support is required either directly or through a generated C API. Zig remains responsible for the public wrapper and game-facing types.

## Existing code affected

Primary integration points:

- `src/engine/ui/ui.zig` - public UI wrapper and input mapping
- `src/engine/ui/c.zig` - C/ImGui declarations
- `src/engine/ui/imgui.c` - legacy widget implementation to remove after migration
- `src/engine/ui/imgui.h` - legacy C API to remove after migration
- `src/engine/ui/ui_draw.h` - retain the existing canvas quad format or replace it only by a committed renderer phase
- `src/game/game.zig` - Demo, Saves and Controls migration
- `src/game/config.zig` - UI font and compact layout settings
- `build.zig` - dependency and test integration
- `tests/ui/test_imgui.c` - widget behavior tests to replace or port
- `src/engine/profiling/debug_overlay.zig` - migrate only after game UI parity

## Migration phases

### Phase 0: Baseline

1. Record screenshots and behavior for Demo, Saves and Controls.
2. Run `zig build`, `zig build test`, and `zig build test-ui`.
3. Document existing pointer, slider, keybind and panel behavior.
4. Add missing tests for press/release, drag clamping, Escape cancellation, letterboxing, zoom and native viewport bounds.
5. Add a legacy backend switch if rollback is needed during the migration.

**Acceptance:** The existing behavior is captured, reproducible and tested before implementation changes.

**Estimate:** 1 day

### Phase 1: Build integration

1. Vendor pinned Dear ImGui and cimgui sources.
2. Add MIT license and dependency documentation.
3. Add C++ sources to the engine module.
4. Add the C API and cimgui sources to dedicated UI tests.
5. Add a minimal context creation/destruction test.

Do not enable docking, platform backends or game code in this phase.

**Acceptance:** A pinned implementation builds with the engine on supported desktop targets and `zig build test` remains green.

**Estimate:** 1-2 days

### Phase 2: Adapter isolation

Create a private adapter with a small `extern "C"` surface:

- Create and destroy the context
- Begin and end a frame
- Submit pointer and keyboard state
- Render a label, button, slider or custom keybind primitive
- Return Dear ImGui draw data

Dear ImGui types must not enter `ui.zig`, `game.zig`, `bairava.zig`, or public API tests.

**Acceptance:** Engine-facing code has no direct Dear ImGui API dependency.

**Estimate:** 1 day

### Phase 3: Frame lifecycle and input

Define one frame order:

```text
publish native layout
map window input to view pixels
game UI update
Dear ImGui frame end
convert draw data
queue UI sprites
submit the world pass
```

Input requirements:

- Map mouse coordinates through the presentation layout.
- Preserve left-button down, pressed and released states.
- Pass control and Escape state to keybind widgets.
- Keep slider capture across frames.
- Resolve hover, activation and pointer release consistently.
- Do not dispatch a mouse press twice from SDL and the game.

**Acceptance:** Input is correct at native resolution, zoomed resolution, high-DPI scaling and integer-mode letterboxing.

**Estimate:** 1-2 days

### Phase 4: Font and renderer integration

Choose a custom draw-data renderer over a separate Dear ImGui SDL backend for the first implementation.

The renderer must:

- Upload Dear ImGui's font atlas to an engine texture.
- Convert draw-command coordinates into native-view pixels.
- Convert draw vertices and indices to the engine's Sprite/quad representation.
- Respect clip rectangles and overlapping widget draws.
- Batch compatible quads.
- Preserve the existing UI draw z-order.
- Support dynamic font atlas rebuilds.

Add a fallback for missing or rebuilt textures. Keep the font lifecycle tied to the UI instance rather than global allocator cleanup.

**Acceptance:** Font glyphs, rectangles, buttons and clip regions render correctly in the native view.

**Estimate:** 2-3 days

### Phase 5: Widget parity wrapper

Keep names and behavior compatible where practical:

| Existing API | Dear ImGui implementation |
|---|---|
| Label | Text display |
| Button | `Button`/`InvisibleButton` with fixed sizing |
| Slider | `SliderFloat` with compact sizing |
| Keybind row | Custom row using widget ID and engine control capture |
| Fixed width column | Next-window position and child region |
| Widget suffix IDs | Preserve `##` naming and stable IDs |
| Theme | Compact native-resolution style |

The keybind widget needs engine-owned listening state and must still:

- Lock other widgets while listening
- Accept the first engine control
- Cancel with Escape
- Stop listening when its row disappears
- Return no binding until a control is chosen

**Acceptance:** The existing C widget tests pass through the Dear ImGui implementation or are replaced by equivalent adapter tests.

**Estimate:** 1-2 days

### Phase 6: Semkootru migration

Use a temporary backend switch during development.

Migrate screens in this order:

1. Demo
2. Saves
3. Controls/keybinds
4. Pagination
5. Audio, save and scale controls

Use compact window sizes and native pixel styling. Verify the panel does not grow unexpectedly when the view or presentation changes.

**Acceptance:** All Semkootru screens have equivalent behavior and approved visual output while legacy behavior remains independently runnable.

**Estimate:** 1-2 days

### Phase 7: Advanced game UI foundation

Only after parity:

- Inventory grids and selectable slots
- Scrollable child regions
- Tables and equipment columns
- Tooltips and context menus
- Modal confirmations
- Tabs and nested panels
- Drag-and-drop item payloads
- Large-list clipping

Dear ImGui supplies layout and interaction primitives, while game code owns item data, ECS synchronization, save state and inventory rules.

**Acceptance:** Each new widget is backed by game-state tests and native-view visual tests.

**Estimate:** 3-7 days depending on scope

### Phase 8: Debug UI migration

After game UI parity:

1. Evaluate Dear ImGui for panels, tables, trees and console sections.
2. Retain custom graph and geometry rendering where specialized drawing is clearer.
3. Add clipped scroll regions and collapsible diagnostic sections.
4. Preserve F3/F4 visibility behavior.
5. Keep release builds free of debug UI objects.

**Acceptance:** Debug UI is smaller, readable and does not cover most of the native view at 320x180.

**Estimate:** 2-4 days

### Phase 9: Legacy removal

Remove only after all acceptance gates:

- `src/engine/ui/imgui.c`
- `src/engine/ui/imgui.h`
- Legacy UI build entries
- Legacy widget behavior switch
- Obsolete temporary C test configuration
- Obsolete API assumptions specific to fixed columns

Keep `src/engine/ui/ui.zig` as the stable public engine-facing wrapper.

**Acceptance:** One UI implementation exists, all UI tests pass, and all references to the legacy implementation are removed.

**Estimate:** 1 day

## Testing strategy

Required automation:

- `zig build test`
- `zig build test-ui`
- Asset and dependency validation
- API boundary and public-export tests
- C adapter tests
- Widget interaction tests
- Rendering/atlas tests with no GPU where practical
- Pointer mapping tests for fit, integer, zoom and high-DPI layouts

Add manual verification for:

- 320x180 game view
- 960x540 and larger window sizes
- Fit and integer scale modes
- Minimum zoom, normal zoom and maximum zoom
- Letterbox bars
- Font rebuild and dynamic glyph growth
- Keybind row listening/cancellation
- Inventory scrolling and modal behavior when implemented

## Verification gates

Do not proceed to the next phase until the current gate passes:

1. Engine builds and tests remain green.
2. Dear ImGui is isolated behind the engine adapter.
3. Native pointer and key state are correct.
4. Fonts and draw data render through the existing SpriteBatch.
5. Demo, Saves and Controls pass behavior and screenshot checks.
6. No UI draws outside the native view unless explicitly clipped.
7. Release builds exclude debug and developer UI paths.
8. Legacy implementation is removed only after parity.

## Risks

| Risk | Mitigation |
|---|---|
| C++ and generated C API version drift | Pin matching commits and dependency-lock checks |
| Separate font atlas ownership | One explicit adapter owns upload, rebuild and lifetime |
| Missing clip support | Add clip/scissor behavior before nested child windows |
| Native pixel layout differs from window pixels | Continue mapping through `view.Layout` |
| Dear ImGui defaults look wrong in pixel art | Apply compact style, palette and fixed native sizes |
| Public API accidentally exposes Dear ImGui | Keep types private behind `engine.ui.Ui` |
| Two UI implementations remain long-term | Use a temporary switch only; remove it in Phase 9 |
| Keybind semantics differ from widgets | Keep listening state in the engine adapter |

## Effort and milestone summary

| Scope | Estimate |
|---|---:|
| Build, adapter and renderer proof | 4-6 days |
| Existing widget parity | 7-10 days |
| Game UI and debug UI migration | 12-16 days |
| Inventory foundations and polished migration | 15-20 days |

The first milestone should be a single fixed button rendered through Dear ImGui, proving build integration, font atlas upload, native-coordinate hit testing and SpriteBatch rendering. The first production milestone should be full Semkootru widget parity with no legacy fallback.

## Rollback strategy

Until Phase 9:

- Keep the legacy implementation behind a compile-time backend selection.
- Preserve legacy and Dear ImGui C tests side by side.
- Use independent screenshots for each phase.
- Revert build integration rather than deleting legacy source files if the renderer phase fails.

After Phase 9, rollback should use version control rather than a maintained second implementation.
