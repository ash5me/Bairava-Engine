# Bairava Engine — Rendering Migration Plan

**Status:** Proposed — planning only; no implementation started  
**Target:** Replace Bairava's prebaked-only text path with a runtime glyph-rasterization and text-shaping pipeline inspired by the uploaded SDL3 GPU proof of concept.  
**Estimated effort:** **16–25 engineering days** (approximately 3–5 weeks for one developer, allowing for review and integration).  
**Repository baseline reviewed:** `ash5me/Bairava-Engine`, `main`  
**Reference reviewed:** `scripts.zip` — Zig / SDL3 GPU text-rendering proof of concept

---

## 1. Scope and interpretation

This plan intentionally migrates **text rendering**, not the entire graphics renderer.

Bairava already has a substantial SDL3 GPU renderer, sprite batching, texture handling, render targets, post-processing, lighting, camera/viewport logic, and a secondary SDL3 2D rendering path. Replacing those systems with the uploaded project would discard working engine capabilities and require a much larger reimplementation.

The proposed migration is therefore:

- Adopt **HarfBuzz** for shaping UTF-8 text into positioned glyph IDs.
- Adopt **stb_truetype** as the initial glyph rasterizer, subject to the font-format compatibility decision in Phase 0.
- Introduce a runtime glyph cache/atlas that can service text not known at build time.
- Render the resulting glyph quads through Bairava's existing `SpriteBatch` and coverage-texture path.
- Integrate the new text pipeline with the existing `Canvas`, widgets, diagnostics, and public API.
- Keep the existing SDL GPU device, command submission, render graph, sprite pipelines, lighting, post effects, and presentation logic.

> **Not in scope:** wholesale replacement of the SDL3 GPU renderer, render graph, sprite batch, texture system, camera, lighting, post-processing, tile-map rendering, or window/presentation architecture. That would need a separate estimate and plan.

## 2. What the reference project actually provides

The uploaded project is a focused proof of concept, not a drop-in replacement for Bairava's renderer.

| Area | Reference implementation | Migration implication |
|---|---|---|
| Shaping | `src/shaper.zig` calls HarfBuzz and returns glyph IDs, clusters, advances, and offsets | Reuse the shaping approach, but make font and buffer ownership suitable for repeated engine use |
| Rasterization | `src/font.zig` rasterizes glyph IDs with `stb_truetype` | Reuse the rasterization concept; confirm supported font outline formats |
| Atlas | A fixed 1024×1024 shelf-packed coverage atlas | Replace with a runtime cache that can grow or allocate additional pages |
| Glyph set | Printable ASCII plus glyphs for one hard-coded shaped Tamil string | Do not carry over this fixed-content assumption |
| Rendering | Dedicated SDL_GPU text pipeline and per-frame vertex buffer | Prefer Bairava's existing coverage texture and sprite-batch path |
| Layout | Hard-coded two-line sample; no general wrapping/layout system | Integrate with Bairava's existing text measurement and UI layout APIs |
| Animation | Per-glyph mirror/un-flip demo | Optional feature; not required for the core text migration |
| Shader formats | SPIR-V only | Reuse Bairava's existing multi-format shader build and coverage shader |
| Validation | Small CPU tests and a Tamil-font inspection script | Expand into engine-level shaping, atlas, UI, visual, and platform tests |

The reference constructs its atlas at application startup from the glyphs it already knows about. It does **not** provide an on-demand glyph cache, cache eviction, general font fallback, a complete text layout engine, or broad script/bidi handling. These are migration tasks, not features that can simply be copied.

## 3. Current Bairava touchpoints

The main existing areas to preserve or migrate are:

| Existing file / area | Current responsibility | Planned treatment |
|---|---|---|
| `src/engine/text/text.c` and `text.h` | BFNT loading, UTF-8 decoding, measurement, and glyph-quad generation | Replace or reduce to a compatibility layer once Zig/HarfBuzz shaping is integrated |
| `src/engine/text/font.zig` | Parses prebaked BFNT data and uploads an R8 coverage atlas | Evolve into a runtime font-face and glyph-cache owner |
| `src/engine/text/layout.zig` | Word wrapping and horizontal alignment using current font metrics | Adapt to shaped runs and cluster-safe line breaking |
| `src/engine/ui/ui.zig` | `Canvas`, text drawing/measurement, rectangles, and widgets | Preserve the public-facing canvas/widget usage while changing internals |
| `src/engine/renderer/sprite.zig` | CPU-side sprite queue, sorting, batching, and coverage-run handling | Reuse; extend only where glyph-cache updates or texture-page identity require it |
| `src/engine/renderer/texture.zig` | Engine texture wrapper and coverage texture creation | Add safe dynamic coverage-atlas update/replacement support |
| `src/engine/renderer/backends/sdl_gpu/texture.zig` | SDL_GPU texture creation and upload | Implement the GPU-side atlas update path |
| `src/engine/platform/sdl/renderer2d.zig` | Secondary SDL3 2D rendering path | Preserve text rendering behavior on this path as well |
| `shaders/default.slang` | Shared sprite, font-coverage, lighting, and post shaders | Keep the coverage shader unless the new vertex contract requires a change |
| `build.zig` / `build.zig.zon` | Zig, SDL, C/C++ dependencies, and shader compilation | Integrate and pin HarfBuzz without copying the PoC build wholesale |
| `docs/text.md` | Current prebaked-font pipeline and limitations | Rewrite for runtime fonts, shaping, cache behavior, and supported scripts |

Other consumers to audit include the debug overlay, developer console, widget labels, and any game-side code that loads a `.bfnt` file or relies on current font metrics.

## 4. Target architecture

```text
UTF-8 text + font + text options
              |
              v
       Text shaping layer
          (HarfBuzz)
              |
              | glyph IDs, clusters, advances, offsets
              v
       Glyph cache lookup  <-------------------+
              |                                |
        cache miss                            cache hit
              |                                |
              v                                |
       Glyph rasterizer                        |
        (stb_truetype)                          |
              |                                |
              v                                |
       Coverage atlas/page --------------------+
              |
              | glyph UVs + shaped positions
              v
       Text layout / line placement
              |
              v
       Canvas / UI / diagnostics
              |
              v
       Bairava SpriteBatch
              |
              v
       Existing coverage pipeline and renderer
```

### Ownership rules to establish before implementation

- A loaded font owns or safely references the font bytes for as long as HarfBuzz and the rasterizer need them.
- HarfBuzz face/font objects should be reused where possible instead of recreated for every string.
- Shaped results own their temporary glyph-position arrays only for the duration needed by layout/drawing.
- Atlas pages own their CPU-side packing metadata and GPU coverage textures.
- GPU atlas writes/replacements happen on the renderer's permitted thread and obey SDL_GPU resource lifetime rules.
- A queued sprite must not reference an atlas page that can be destroyed or repurposed before the frame is submitted.
- The legacy BFNT path should remain available during migration or be removed only after all engine consumers and assets are migrated.

## 5. Migration phases

### Phase 0 — Baseline, requirements, and compatibility decisions

**Estimate: 1–2 days**

- [ ] Inventory all font-loading and text-drawing call sites in the engine, sample, tests, and game code.
- [ ] Record existing public behavior: font sizing, baseline convention, text measurement, wrapping, alignment, color/alpha, and rectangle drawing.
- [ ] Define initial supported scripts and test strings. At minimum include ASCII/Latin and Tamil.
- [ ] Decide whether the first release supports only TrueType `glyf` outlines or must retain OpenType CFF support.
- [ ] Decide initial direction/language controls and whether right-to-left/bidirectional text is part of this migration.
- [ ] Decide whether the existing `.bfnt` format remains loadable during a transition period.
- [ ] Define memory limits and an atlas growth policy (multiple pages, page growth, or bounded cache with eviction).
- [ ] Capture baseline screenshots and performance numbers for the existing UI and sample.

**Deliverable:** short text-rendering design note, agreed compatibility matrix, and baseline test corpus.

**Exit criteria:** supported font formats, scripts, public API behavior, and fallback policy are agreed before dependency or renderer changes begin.

### Phase 1 — Dependency and build-system integration

**Estimate: 2–4 days**

- [ ] Pin a specific HarfBuzz source revision or package version; do not track an unpinned branch.
- [ ] Reuse Bairava's existing stb_truetype source/header where its version and build configuration are suitable. Avoid adding a duplicate implementation.
- [ ] Integrate the required HarfBuzz C API and C++ implementation into Bairava's Zig build.
- [ ] Verify C++ runtime/linker settings for Linux, Windows, and macOS.
- [ ] Keep the current SDL dependency and version; do not replace it with the PoC's SDL pin.
- [ ] Keep Bairava's Slang shader pipeline and its SPIR-V, optional DXIL, and optional MSL outputs.
- [ ] Add a minimal compile/link smoke test that calls the HarfBuzz API from Zig.
- [ ] Record HarfBuzz and stb licenses and pinned revisions in the dependency policy/lock documentation.

**Important compatibility note:** the uploaded proof of concept targets Zig `0.17.0`, while Bairava's current `build.zig.zon` declares `0.16.0-dev.3142+5ccfeb926`. Its build script must not be copied verbatim. Treat the build API and cross-platform C++ linking as an integration task.

**Deliverable:** reproducible dependency integration and a build smoke test on the supported CI platforms.

**Exit criteria:** the engine and test targets compile and link with HarfBuzz on Linux, Windows, and macOS without changing existing renderer capabilities.

### Phase 2 — Runtime font object and glyph rasterization

**Estimate: 2–4 days**

- [ ] Define a runtime `Font`/font-face object that owns font data, metrics, rasterizer state, and HarfBuzz state.
- [ ] Load font files through Bairava's existing packaged-file and asset-loading conventions.
- [ ] Initialize HarfBuzz from the loaded font bytes and configure font scale consistently with the engine's pixel-height convention.
- [ ] Rasterize glyphs by glyph ID, not Unicode codepoint, so the rasterizer consumes HarfBuzz's output directly.
- [ ] Convert stb_truetype bitmap bounds and offsets into Bairava's baseline and screen-coordinate conventions.
- [ ] Handle empty glyphs (for example, spaces) without allocating atlas rectangles.
- [ ] Define clean error behavior for invalid fonts, unsupported outline formats, and rasterization failures.
- [ ] Add lifecycle tests for font creation, reuse, and destruction.

**Font-format decision:** the reference uses stb_truetype. Its own helper warns that CFF outlines are not confirmed to work with that rasterizer. Bairava's existing prebake documentation says its CFF path is handled by FreeType. Switching to stb-only rasterization could regress fonts that currently work. Either preserve CFF rasterization through FreeType or explicitly accept and document a reduced initial font-format matrix. Preserving CFF may add effort.

**Deliverable:** a runtime font object that can shape and rasterize a requested glyph in isolation, before atlas integration.

**Exit criteria:** unit tests verify valid glyph metrics, bitmap bounds, baseline offsets, and supported/unsupported font-format behavior.

### Phase 3 — Runtime glyph atlas and cache

**Estimate: 3–4 days**

- [ ] Replace the reference's fixed 1024×1024 atlas assumption with a cache suitable for arbitrary runtime text.
- [ ] Define a cache key, at minimum including font identity, glyph ID, and rasterization size/scale.
- [ ] Add atlas packing with padding and explicit full-page handling.
- [ ] Choose a page policy: allocate another page, grow/repack a page, or evict entries. Avoid silent glyph loss when a page fills.
- [ ] Add a safe GPU upload path for newly rasterized glyph regions or replacement pages.
- [ ] Support both SDL_GPU and the secondary SDL3 2D renderer path.
- [ ] Ensure atlas updates cannot race with queued draws or in-flight GPU work.
- [ ] Define cache lifetime and cleanup behavior when fonts are unloaded or the renderer is recreated.
- [ ] Decide how solid UI rectangles obtain a white texel. The current Canvas uses a white block in the prebaked font atlas; a glyph-only atlas must either reserve that block or move rectangle drawing to a separate primitive/texture path.
- [ ] Add cache-hit, cache-miss, atlas-page, and allocation counters for diagnostics.

**Deliverable:** runtime cache that can add previously unseen glyphs and supply stable UVs/textures to the renderer.

**Exit criteria:** tests cover cache hits, misses, page-full behavior, repeated glyph requests, texture replacement, cleanup, and both renderer paths.

### Phase 4 — HarfBuzz shaping and glyph positioning

**Estimate: 2–3 days**

- [ ] Implement a shaping API that accepts UTF-8 text and a font, and returns glyph IDs, cluster values, advances, and offsets.
- [ ] Set or infer script, language, and direction deliberately; do not rely on the reference's `guess_segment_properties` for every engine use case.
- [ ] Convert HarfBuzz's font-unit positions to Bairava's pixel units in one well-defined place.
- [ ] Preserve cluster information through drawing so a multi-glyph cluster can be treated as a unit by future effects, selection, and hit-testing features.
- [ ] Route every supported script through shaping, including Latin, so kerning and OpenType positioning are not bypassed by a byte-per-character fast path.
- [ ] Handle malformed UTF-8 and empty input deterministically.
- [ ] Define a clear fallback behavior for missing glyphs. Multi-font fallback should be separately scoped unless required for the first release.
- [ ] Keep glyph rasterization/cache lookup separate from shaping so shaping the same string does not unnecessarily rerasterize glyphs.

**Deliverable:** reusable shaped-run API independent of the GPU renderer.

**Exit criteria:** tests verify glyph IDs, clusters, advances, and offsets for Latin and Tamil fixtures, including Tamil vowel signs and conjuncts in fonts with suitable OpenType tables.

### Phase 5 — Text layout and engine/UI integration

**Estimate: 3–4 days**

- [ ] Adapt text measurement to sum shaped advances and offsets rather than Unicode codepoint metrics.
- [ ] Update line wrapping to use measured shaped runs and break only at safe cluster/grapheme boundaries. Do not copy a codepoint-only splitter for complex scripts.
- [ ] Preserve explicit newlines, blank lines, alignment, baseline, and line-height behavior.
- [ ] Add a shaped glyph-quad submission path to `Canvas`/`SpriteBatch` using the existing coverage pipeline.
- [ ] Preserve or deliberately version the existing `Canvas.text`, `textWidth`, `layoutText`, and `drawTextLayout` API.
- [ ] Update widget labels, debug overlay, developer console, and other engine-owned text consumers.
- [ ] Preserve UI rectangle rendering independently of the font-cache implementation.
- [ ] Confirm z-order, tint, alpha blending, clipping, and pixel scaling match existing behavior.
- [ ] Keep game code from importing renderer-private or HarfBuzz-private modules.

**Deliverable:** engine-facing text drawing and measurement use the new runtime shaping pipeline without requiring game code to know about glyph IDs or atlas pages.

**Exit criteria:** the sample, widgets, console, and diagnostics render correctly through both existing renderer modes.

### Phase 6 — Regression testing, performance, and documentation

**Estimate: 3–4 days**

- [ ] Add shaping tests for Latin kerning and Tamil shaping; retain small tests for malformed UTF-8 and empty strings.
- [ ] Add glyph-cache and atlas tests for growth, saturation, and resource lifetime.
- [ ] Add tests for wrapping and alignment around cluster boundaries.
- [ ] Compare screenshots against the captured baseline for existing Latin UI and add reference images for Tamil output.
- [ ] Test dynamic strings whose glyphs were not requested previously.
- [ ] Test font loading/unloading, renderer switching, window resize, and renderer/device teardown.
- [ ] Run `zig build test`, `zig build test-ui`, asset validation, and boundary checks.
- [ ] Run CI on Linux, Windows, and macOS; verify SPIR-V everywhere and the optional DXIL/MSL shader paths remain available.
- [ ] Profile representative text-heavy frames and compare cache misses, CPU shaping time, upload cost, draw calls, and memory use.
- [ ] Rewrite `docs/text.md` and update README/API compatibility notes.
- [ ] Document supported scripts, font formats, fallback behavior, cache limits, and known limitations.

**Deliverable:** tested migration with updated documentation and recorded performance results.

**Exit criteria:** all required CI checks pass, existing UI regressions are resolved, target-language screenshots are accepted, and the known limitations are documented.

---

## 6. Effort summary

| Phase | Estimate |
|---|---:|
| 0. Baseline and decisions | 1–2 days |
| 1. Dependency/build integration | 2–4 days |
| 2. Runtime font and rasterization | 2–4 days |
| 3. Glyph atlas/cache | 3–4 days |
| 4. HarfBuzz shaping | 2–3 days |
| 5. Layout and engine/UI integration | 3–4 days |
| 6. Testing, performance, documentation | 3–4 days |
| **Total** | **16–25 days** |

This is an engineering-effort estimate for one developer. It assumes the existing Bairava GPU rendering path remains in place, the first milestone targets Latin and Tamil, and the scope does not include a complete bidi implementation, advanced font fallback, or rich text/markup.

### Potential additions to the estimate

| Additional requirement | Planning impact |
|---|---|
| Preserve OpenType CFF support if the stb path cannot rasterize the required fonts | Additional integration and testing; decide in Phase 0 |
| General multi-font fallback across scripts | Additional design, font selection, shaping, and layout work |
| Full bidirectional paragraph layout (for mixed RTL/LTR text) | Separate bidi resolution and line-layout work; HarfBuzz alone is not the whole bidi solution |
| Variable-font axes, color fonts, vertical writing, or complex rich-text markup | Separate scope |
| Port the reference's per-glyph mirror animation as a supported engine text effect | Optional feature; not included in the core estimate |
| Replace Bairava's complete rendering backend rather than only text rendering | Separate project; previous rough estimate was 40–60 engineering days |

## 7. Key risks and mitigation

| Risk | Why it matters | Mitigation |
|---|---|---|
| Zig version mismatch | Reference uses Zig 0.17; Bairava declares a Zig 0.16 development snapshot | Adapt dependency integration to Bairava's build API; do not copy the reference build script |
| C++ and platform linking | HarfBuzz is built from C++ sources in the reference | Prove Linux, Windows, and macOS linking in Phase 1 before depending on it |
| Font-format regression | The reference flags CFF as unconfirmed for stb_truetype, while Bairava currently documents CFF support through FreeType | Preserve FreeType support or explicitly narrow supported formats before migration |
| Fixed atlas assumptions | Reference atlas is built for a known set of glyphs and can return `AtlasFull` | Implement a cache/page strategy and test exhaustion explicitly |
| GPU resource lifetime | Dynamic atlas updates interact with in-flight frames and queued sprites | Define ownership and synchronization before implementing updates |
| Secondary renderer drift | Bairava has an SDL3 2D path in addition to SDL_GPU | Treat both paths as acceptance targets; do not validate only Vulkan/GPU rendering |
| UI primitive coupling | Existing rectangle drawing uses a white region in the font atlas | Preserve a reserved white texel or decouple solid rectangles from font textures |
| Layout correctness | Shaped clusters can contain multiple glyphs and cannot safely be split like ordinary UTF-8 codepoints | Keep cluster boundaries through wrapping and tests |
| API compatibility | Game code may rely on current font loading and layout behavior | Keep adapters/legacy BFNT loading until consumers are migrated |

## 8. Recommended implementation order and milestones

1. **M0 — Architecture decisions approved:** Phase 0 complete; supported formats/scripts and compatibility policy are written down.
2. **M1 — Dependencies build everywhere:** HarfBuzz is pinned and linked on all CI platforms; existing builds still pass.
3. **M2 — CPU text pipeline works:** font loading, shaping, glyph rasterization, and unit tests work without opening a window.
4. **M3 — GPU glyph cache works:** new glyphs can be inserted and rendered without rebuilding the whole application.
5. **M4 — Engine integration complete:** Canvas, widgets, diagnostics, console, and both renderer paths use the new system.
6. **M5 — Migration accepted:** regression suite, screenshots, profiling, CI, and documentation are complete.

The critical path is dependency integration → runtime font ownership → glyph cache and shaping → Canvas/UI integration → regression validation. Shaping and atlas work can proceed partly in parallel after the font ownership contract is agreed.

## 9. Rollout and removal of the old path

- Work on a dedicated feature branch; do not replace `main` during the exploratory phase.
- Keep the existing BFNT loader available while the new pipeline is integrated, preferably behind an explicit compatibility path rather than silent format guessing.
- Migrate engine-owned fonts and sample/game consumers before changing the default loading path.
- Compare outputs using the same fonts, pixel sizes, UI scenes, and renderer modes.
- Remove the legacy BFNT runtime path only after repository-wide call-site and asset searches show it is no longer required and the compatibility decision is documented.
- Retain the offline font-baking tool only if another supported workflow still needs it; otherwise remove it in a separate cleanup change after migration acceptance.

## 10. Definition of done

- [ ] Runtime font loading works for the agreed font formats.
- [ ] HarfBuzz shaping is used for all supported text runs, including Latin.
- [ ] Tamil vowel signs and conjuncts render with correct glyph substitution and positioning for fonts that contain the required shaping tables.
- [ ] Previously unseen glyphs can be rasterized, cached, and rendered at runtime.
- [ ] Atlas growth/page exhaustion and GPU resource lifetime are handled explicitly.
- [ ] Text measurement, wrapping, alignment, baseline, and newline behavior are covered by tests.
- [ ] Existing Canvas, widgets, diagnostics, and console behavior is preserved or intentionally versioned.
- [ ] Both SDL_GPU and SDL3 2D renderer paths pass visual/regression tests.
- [ ] Existing lighting, post-processing, render graph, sprite batching, and shader-format capabilities remain intact.
- [ ] Linux, Windows, and macOS CI pass.
- [ ] Documentation states supported scripts, font formats, fallback policy, and remaining limitations.
- [ ] No legacy code or asset format is removed before its consumers have been migrated.

---

## 11. Source files reviewed

### Uploaded reference project (`scripts.zip`)

- `README.md`
- `build.zig`, `build.zig.zon`
- `src/main.zig`
- `src/shaper.zig`
- `src/font.zig`
- `src/renderer_gpu.zig`
- `shaders/text.slang`
- `tools/check_tamil_font.py`
- `third_party/hb_translate.h`, `third_party/stb_translate.h`

### Bairava Engine (`main`)

- `README.md`, `build.zig`, `build.zig.zon`
- `src/engine/renderer/renderer.zig`
- `src/engine/renderer/render_graph.zig`
- `src/engine/renderer/render_types.zig`
- `src/engine/renderer/sprite.zig`
- `src/engine/renderer/texture.zig`
- `src/engine/renderer/backends/sdl_gpu/backend.zig`
- `src/engine/renderer/backends/sdl_gpu/sprite.zig`
- `src/engine/renderer/backends/sdl_gpu/texture.zig`
- `src/engine/text/font.zig`, `src/engine/text/layout.zig`, `src/engine/text/text.c`, `src/engine/text/text.h`
- `src/engine/ui/ui.zig`
- `src/engine/core/context.zig`, `src/engine/core/engine.zig`
- `src/engine/platform/sdl/gpu.zig`
- `shaders/default.slang`
- `docs/text.md`

**Planning note:** estimates should be revised after Phase 0 confirms font-format requirements, whether mixed-direction text is required, and whether the existing CFF behavior must be preserved.
