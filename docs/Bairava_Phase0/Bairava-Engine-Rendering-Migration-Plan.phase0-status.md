# Bairava Engine — Rendering Migration Plan

**Status:** Phase 0 awaiting two confirmations; Phase 1 in progress (HarfBuzz builds and tests on Windows; stb_truetype 1.28 integrated; HarfBuzz lock hash conflict resolved 2026-11-17 against the pinned commit; Windows `zig build test` passes after the Arial test change (user-reported 2026-11-17); the Phase 0 baseline is re-measured against Arial 7.07 with three owner decisions open, see section 15. Phase 0 closed 2026-11-17; Phase 1 CI green on Linux, Windows, and macOS (owner-reported); Phase 2 code written, including the packaged loader, awaiting `zig build test` on the owner's machine (sections 18, 19, and 20). Design note: `docs/Bairava_Phase0/design-note.md`.)  
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

**Phase 0 status:** exit criteria agreed, subject to the working assumptions in report section 6. Deliverables are in `docs/Bairava_Phase0/PHASE0_REPORT.md`. Baseline screenshots and performance numbers are blocked until the full repository is available.

**Estimate: 1–2 days**

- [x] Inventory all font-loading and text-drawing call sites in the engine, sample, tests, and game code. *(Done: `inventory/call_sites.txt`.)*
- [x] Record existing public behavior: font sizing, baseline convention, text measurement, wrapping, alignment, color/alpha, and rectangle drawing. *(Done for the C runtime: `characterization/`, 70 of 70. The Zig side was read, not run. Re-run 2026-11-16 against the uploaded `src/engine/text/text.c`: 70 checks, 0 failed, no warnings under `gcc -std=c99 -Wall -Wextra`.)*
- [x] Define initial supported scripts and test strings. At minimum include ASCII/Latin and Tamil. *(Accepted: Latin and Tamil. Corpus in report section 5.)*
- [x] Decide whether the first release supports only TrueType `glyf` outlines or must retain OpenType CFF support. *(Decided: runtime TrueType only; CFF stays prebaked. Runtime rasterizer: stb_truetype, the plan default. See report section 6.)*
- [x] Decide initial direction/language controls and whether right-to-left/bidirectional text is part of this migration. *(Decided: left to right; no RTL or bidi in this migration.)*
- [x] Decide whether the existing `.bfnt` format remains loadable during a transition period. *(Keep loading v1, v2, and v4. Required by the stb_truetype decision.)*
- [x] Define memory limits and an atlas growth policy (multiple pages, page growth, or bounded cache with eviction). *(Working assumption: four 1024² pages, then fallback, no eviction. Confirm in Phase 3. **Still awaiting your confirmation.**)*
- [ ] Capture baseline screenshots and performance numbers for the existing UI and sample. *(Blocked here: needs the full repository and a display. A raster coverage baseline was captured instead. 2026-11-17: still blocked. The baseline also depends on settling the shipped UI font identity (section 14), because the uploaded `assets/font.ttf` is not VT323.)*

**Deliverable:** short text-rendering design note, agreed compatibility matrix, and baseline test corpus.

**Exit criteria:** supported font formats, scripts, public API behavior, and fallback policy are agreed before dependency or renderer changes begin.

### Phase 1 — Dependency and build-system integration

**Estimate: 2–4 days**

Legend: `[x]` done, with evidence; `[~]` partly done; `[ ]` open.

- [~] Pin a specific HarfBuzz source revision or package version; do not track an unpinned branch. *(Version 15.1.0 and commit `3df40d9…` are in `docs/dependency-lock.json`. The uploaded lock's HarfBuzz `sha256` is `6c1fac27…`. This file previously cited `0db1ed94…` as the lock's tree hash, which is wrong for this upload. 2026-11-17: the lock hash matches the commit export. `git archive 3df40d9… src COPYING` gives 584 files whose tree hash, computed with the checker's method, is `6c1fac27…`, the lock value. `verify-dependency-commits.py --harfbuzz` returns OK against a `vendor/` tree rebuilt from that export. The repo's own vendored copy is still unchecked, because `vendor/` is absent from the upload.)*
- [x] Reuse Bairava's existing stb_truetype source/header where its version and build configuration are suitable. Avoid adding a duplicate implementation. *(`vendor/stb_truetype.h` is upstream 1.28 and the only compiled copy. The local edit is gone. The lock has one group hash, `843f1d62…`, for all six stb paths, not a per-file `truetype` hash. This file previously cited `6ad5c81a…` as a lock entry; that value is not in the lock. Commit `9600522…` recorded. 2026-11-17: the raw SHA-256 of `stb_truetype.h` at commit `9600522…` is `428cfe93…`, the value the policy expects. The vendored copy is still unchecked, because `vendor/` is absent.)*
- [~] Integrate the required HarfBuzz C API and C++ implementation into Bairava's Zig build. *(Test module only. `addHarfBuzz` compiles `vendor/harfbuzz-15.1.0/src/harfbuzz.cc` with `-std=c++11 -fno-exceptions -fno-rtti`. The shipped engine module does not link it yet; that waits for shaping in Phase 4.)*
- [~] Verify C++ runtime/linker settings for Linux, Windows, and macOS. *(Windows: `zig build` and `zig build test` pass with `module.link_libcpp = true`, Zig 0.16.0-dev.3142+5ccfeb926. 2026-11-17, Linux (sandbox): g++ 13.3 compiles `harfbuzz.cc` with the test module's flags with zero warnings, and the smoke harness links with libstdc++ and libm (`checks/hb_linux_RESULTS.txt`). The Zig build did not run: Zig is not installed, `codeberg.org` (the SDL host) is unreachable, and `vendor/` is absent. macOS not run.)*
- [x] Keep the current SDL dependency and version; do not replace it with the PoC's SDL pin. *(SDL pin in `build.zig.zon` and the lock unchanged.)*
- [~] Keep Bairava's Slang shader pipeline and its SPIR-V, optional DXIL, and optional MSL outputs. *(No shader changes. Slang 2026.20 archive pins verified. DXIL and MSL output not checked in this work; needs a Windows and macOS run.)*
- [x] Add a minimal compile/link smoke test that calls the HarfBuzz API from Zig. *(`src/engine/text/hb_smoke.zig` checks that `hb_version_string()` returns 15.1.0. `src/engine/text/hb_shape_test.zig` adds four shaping tests. Both pass on Windows in Debug.)*
- [~] Record HarfBuzz and stb licenses and pinned revisions in the dependency policy/lock documentation. *(Done: `dependency-policy.md` lists HarfBuzz, with a license and change-history section for both. Commit IDs for HarfBuzz 15.1.0 and stb 1.28 are in the lock and the policy. Checks against the vendored files are pending. The policy's stb versions (image 2.30, image_write 1.16, rect_pack 1.01) disagree with the lock's (2.32, 1.18, 1.02); 2026-11-17: the pinned stb commit has stb_image 2.32, stb_image_write 1.18, and stb_rect_pack 1.02, which matches the lock. The policy's older values are stale, or they describe older vendored copies. The vendored files decide which, and they are not in the upload.)*

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

**Font-format decision:** the reference uses stb_truetype. Its own helper warns that CFF outlines are not confirmed to work with that rasterizer. Bairava's existing prebake documentation says its CFF path is handled by FreeType. Switching to stb-only rasterization could regress fonts that currently work. Either preserve CFF rasterization through FreeType or explicitly accept and document a reduced initial font-format matrix. Preserving CFF may add effort. *Evidence (2026-11-16):* none of the shipped fonts in `assets/` is CFF. `font.ttf` (VT323) and `font2.ttf` ("November") are both TrueType `glyf`, so the stb-only choice cannot change a shipped asset. *Correction 2026-11-17:* the uploaded `assets/font.ttf` is Arial 7.07 (also TrueType `glyf`), not VT323. The CFF conclusion is unchanged. See section 14. CFF fonts supplied by games or users remain unresolved.

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

---

## 12. Progress log

Entries are dated 2026-11-16. Items marked *(user-reported)* come from build and test runs on the Windows machine, which this work could not see directly.

- **Repository re-check.** The earlier summary's deliverables (the phase1 zip, the repo-changes zip, and the updated status file with sections 12 and 13) were not in the uploads. This file was rebuilt from the repository copy. The pin checker failed on stb: the vendored truetype header was 1.26 with one unrecorded local edit, and the lock still held the upstream hash.
- **Post-processing order verified.** In `src/engine/core/runtime.zig`, the game UI and debug overlay share one world batch and one pass. The post chain runs after that pass. The `sdl2d` branch presents before the post chain, so configured effects do not apply on that path. The shipped game sets `post_effects` to empty.
- **HarfBuzz located.** It is not under `vendor/` in the upload. The uploaded checkout is HarfBuzz 15.1.0 under `tools/third_party/harfbuzz`. Its `src/` plus `COPYING` hash to `0db1ed94…` over 588 files. The earlier summary's `6c1fac27…` over 584 files does not match this tree.
- **stb 1.28 adopted (option A).** The uploaded header is v1.28 and hashes to `6ad5c81a…`, matching the earlier option-A hash. Upstream 1.28 guards the zero-denominator case with `if (denom != 0)`, so the local edit is superseded. One behavior difference: when the denominator is zero, 1.28 leaves `dy` unchanged, while the local edit set it to zero. No test reached that case.
- **C consumers compile.** `tools/assets/font_bake.c`, two Phase 0 harnesses, and `vendor/stb_truetype_impl.c` produce zero diagnostics under `-std=c99 -Wall -Wextra` with both 1.26 and 1.28.
- **Rasterization unchanged on these fonts.** The glyph bitmaps from 1.26 and 1.28 match for four fonts (`assets/font.ttf`, `assets/font2.ttf`, `tools/assets/font.ttf`, and `tools/assets/tamil.ttf`). The test covered codepoints 0x0000–0x2FFF and the Tamil block at 27 pixel heights from 4 to 64, about one million bitmaps per version. The earlier claim of one changed glyph in the PoC Latin font was not reproduced. The test went through codepoint lookup, not raw glyph IDs, and the cmap defect was not reproduced either.
- **HarfBuzz compiles and shapes.** `harfbuzz.cc` builds with g++ under upstream's flags with zero warnings. A test program shapes VT323 "AVATAR" into six monospaced glyphs. It also shapes a Tamil word into five glyphs, with the vowel sign attached by a zero-advance offset, and empty input gives length zero.
- **Zig wiring.** The first `addHarfBuzz` used a method, `linkLibCpp`, that this Zig version does not have. Checking `Build/Module.zig` showed the `link_libcpp` field, which the compile step reads, so the call was changed to that field.
- **Commit IDs supplied (2026-11-16).** HarfBuzz `3df40d9b98d6b32f0e4288d4ecfbb158ddb3a372` and stb `9600522de53973336fa033a289858a4354cbb04c` are recorded in the lock as a `commit` field, which the checker ignores. The commits are not yet verified. The stb header hash and the HarfBuzz tree comparison are described in the policy.
- **Windows build and tests (user-reported).** `zig build` and `zig build test` pass under Zig 0.16.0-dev.3142+5ccfeb926 in Debug. The test set includes the version check and the four shaping tests. *Superseded 2026-11-17:* the run below shows the monospace shaping test failing on the same machine.
- **Pin checker (user-reported, Windows).** All seven lock entries verify.
- **Continuation check (2026-11-16, `bairava.zip`).** The upload has no `vendor/` directory, no `tools/third_party/harfbuzz`, no `tools/assets/tamil.ttf`, and no stb headers. Vendored-tree hashes, the commit checks, the `hb-version.h` question, and the stb header checks cannot run from it. The sandbox has no Zig, no HarfBuzz or stb packages, and no network. Everything below was run in the sandbox.
- **Pin checker run.** `scripts/check-dependency-pins.py` verifies SDL, ztracy, Zig 0.16.0-dev.3142+5ccfeb926, Slang 2026.20, and the five Slang archive digests. All six vendored entries fail with "locked path does not exist." That is the missing `vendor/` tree, not a hash mismatch.
- **HarfBuzz lock conflict.** The lock's HarfBuzz `sha256` is `6c1fac27…`. The `0db1ed94…` value this file cited is not in the lock, and the entry above says `6c1fac27…` does not match the tree. CI runs this checker on Linux, macOS, and Windows, so whichever value is committed must match the vendored tree. The user-reported Windows pass suggests the lock on that machine differs from this upload's, or that its tree hashes to `6c1fac27…`. Confirm which lock and tree are current. Per the policy, do not change the hash without reviewing the tree.
- **stb record conflicts.** `dependency-policy.md` lists image 2.30, image_write 1.16, and rect_pack 1.01. The lock lists 2.32, 1.18, and 1.02. The policy and this file cite a lock hash of `6ad5c81a…` for truetype 1.28, but the lock has only the group hash `843f1d62…`. The policy's expected commit hash for `stb_truetype.h` is `428cfe93…`, which remains unchecked.
- **Lock entry count.** "All seven lock entries verify" does not match the upload's lock, which has six `dependencies` entries plus two Zig packages. Record what was counted.
- **Characterization re-run.** `harness.c` compiles with `gcc -std=c99 -Wall -Wextra` with no warnings and reports 70 checks, 0 failed, against `src/engine/text/text.c` in the upload. This re-runs the existing result and adds no new check.
- **Platform boundary.** `scripts/boundary_scan.py --self-test` rejects 3 of 3 negative fixtures, and `--fail` reports 0 reachable violations. Both are CI gates and both pass here.
- **Shipped fonts.** `assets/font.ttf` is VT323 (TrueType `glyf`, 584 glyphs, GSUB and GPOS present, no `kern`), which matches the VT323 assumption in `hb_shape_test.zig`. `assets/font2.ttf` is "November" (TrueType `glyf`, 247 glyphs, no GSUB or GPOS). Neither is CFF. *Corrected 2026-11-17:* the uploaded `assets/font.ttf` is Arial 7.07, not VT323, and the 584-glyph / no-kern description above does not match it. See section 14.

## 13. Decisions and open items

### Decided

1. **stb_truetype: option A.** Upstream 1.28 is vendored and the lock is updated. `PHASE0_REPORT.md` section 6 (the stay-on-1.26 decision) is superseded by this choice. That report has not been edited.
2. **HarfBuzz vendoring: under `vendor/`.** `vendor/harfbuzz-15.1.0/` holds `src/` and `COPYING`. The default build uses only `harfbuzz.cc`. `src/rust` and `src/wasm` are unused by that build, and the optional kbts subproject is disabled by default.
3. **Post-processing: effects stay over the UI.** This is the current behavior and no code change is needed. The 2D path issue below still needs its own decision.

### Assumptions awaiting your confirmation

4. The glyph cache uses four 1024² pages with no eviction, plus a `glyph_cache_full` diagnostic. Recorded for Phase 3.
5. The text migration lands before the Dear ImGui migration. One adapter owns the coverage atlas, and ImGui's font atlas becomes a client of the glyph cache. Glyph uploads for glyphs first used in a frame are recorded before the render pass that samples them. No page is destroyed while queued sprites still reference it.

### Open items

- **Shipped UI font identity (resolved 2026-11-17).** The uploaded `assets/font.ttf` is Arial 7.07, not VT323. The asset manifest builds `ui_font_9px` and `default_font_10px` from it, and the monospace shaping check fails on it. Resolved: the owner confirmed Arial 7.07 is intentional, so the asset stays. The monospace test was replaced (section 14).
- **Commit checks.** The commits are supplied (HarfBuzz `3df40d9…`, stb `9600522…`) and recorded in the lock. They haven't been checked here, because GitHub didn't resolve in search. Two checks are in the policy: the stb header's SHA-256 against the commit, and the HarfBuzz tree against `git archive`. The continuation check could not run either one, since the upload has no network and no vendored tree. Once `vendor/` is present, `scripts/verify-dependency-commits.py --harfbuzz <clone> --stb <clone>` runs both.
- **`src/hb-version.h`.** The vendored HarfBuzz tree has a generated-looking version header. If upstream doesn't track it, the vendored tree differs from the commit by that file.
- **Other stb files.** `stb_image.h`, `stb_image_write.h`, and `stb_rect_pack.h` are still unverified against any commit.
- **Linux and macOS.** Build, C++ runtime linking, and tests. Only Windows has been run.
- **Shipped engine.** HarfBuzz is linked only into the test module. It joins the engine module when shaping lands in Phase 4.
- **Sanitizer coverage.** The shaping tests cover Latin text only. Tamil and malformed UTF-8 have not run under Debug checks.
- **Rasterization coverage.** The comparison did not exercise glyph-ID rasterization, and the cmap defect was not reproduced.
- **Effects on the 2D path (deferred at your request).** Configured post effects apply on SDL_GPU but not on the `sdl2d` path. The decision is still open.
- **Blocked here.** DXIL and MSL output, baseline screenshots, and performance numbers need a Windows and macOS run with a display.
- **HarfBuzz lock hash (new).** *Resolved 2026-11-17 (section 14): the lock's `6c1fac27…` is correct.* Decide whether the lock's `6c1fac27…` or the `0db1ed94…` tree hash this file previously cited is the reviewed value. Run `check-dependency-pins.py` against the vendored tree and record the result. Do not edit the lock hash without reviewing the tree.
- **stb records (new).** *Narrowed 2026-11-17 (section 14): upstream matches the lock; the policy is the outlier unless the vendored files say otherwise.* Resolve the version conflict between the policy and the lock (2.30, 1.16, 1.01 against 2.32, 1.18, 1.02). Then check the stb headers against the lock's group hash, and the truetype header against commit `428cfe93…`.
- **Vendored tree not in this upload (new).** The checker, the Zig build, and the commit checks all need `vendor/`, and section 12 cites `tools/third_party/harfbuzz`, which is also absent. A full checkout including `vendor/` is needed.
- **Tamil font not in this upload (new).** `tools/assets/tamil.ttf` and the PoC `tools/assets/font.ttf` are absent. Tamil shaping and the Tamil fixture claims are unverified here.
- **Lock entry count (new).** Confirm what "seven lock entries" referred to.
- **Phase 0 confirmations.** Items 4 and 5 under Assumptions are still awaiting your answer.

## 14. Progress log: 2026-11-17 verification run

This run was executed in the sandbox from the uploaded `bairava.zip`. Nothing here was run on Windows or macOS. It followed the rendering plan's phases in order. Phase 0 was not advanced, because its two owner confirmations are still pending. Phase 1's exit criteria are not met, so Phase 2 was not started.

- **Plan selection.** This file tracks `Bairava-Engine-Rendering-Migration-Plan.md`, so that is the plan this run followed. `Bairava-Engine-Text-and-Font-System-Migration-Plan.md` is marked *Proposed*, its checkboxes are all empty, and its Phase 0 needs owner decisions (MSDF generator, bitmap descriptor format, fallback policy). It was not started.
- **Pin checker (sandbox).** `scripts/check-dependency-pins.py` verifies the Zig toolchain, Slang 2026.20, the five Slang archive digests, and the SDL and ztracy URLs and hashes in `build.zig.zon`. All six vendored lock entries fail with "locked path does not exist", because `vendor/` is absent from the upload. That is a missing tree, not a hash mismatch.
- **HarfBuzz commit (sandbox).** Commit `3df40d9…` was fetched from `github.com/harfbuzz/harfbuzz`; its subject is `15.1.0`. `git archive <commit> src COPYING` yields 584 files. Their tree hash, computed with the checker's method, is `6c1fac27…`, which equals the lock. The `0db1ed94…` value and the 588-file count recorded in section 12 are wrong and are superseded. `src/hb-version.h` is tracked upstream, so it is not generated, and the policy's "generated" branch does not apply. `verify-dependency-commits.py --harfbuzz` returns OK against a `vendor/` tree rebuilt from that export. This checks the export against the lock. It does not check the repo's own vendored copy, which is not in the upload.
- **stb commit (sandbox).** Commit `9600522…` was fetched from `github.com/nothings/stb`. Its `stb_truetype.h` is v1.28, and its raw SHA-256 is `428cfe93…`, the value the policy expects. At that commit `stb_image.h` is v2.32, `stb_image_write.h` is v1.18, and `stb_rect_pack.h` is v1.02, matching the lock. The policy's 2.30 / 1.16 / 1.01 are therefore stale, or they describe older vendored copies; the vendored files are needed to decide. The lock's group hash `843f1d62…` also covers two repo-authored files (`stb_image_impl.c`, `stb_truetype_impl.c`) that are not in the upload, so it cannot be checked here.
- **Linux compile and link (sandbox).** g++ 13.3.0 compiles `harfbuzz.cc` with the test module's flags (`-std=c++11 -fno-exceptions -fno-rtti`) with zero warnings under `-Wall -Wextra`. The new `checks/hb_linux_smoke.c` links with libstdc++ and libm and reproduces the assertions in `hb_smoke.zig` and `hb_shape_test.zig`. Results and commands are in `checks/hb_linux_RESULTS.txt`. This is not a Zig build. The Zig build cannot run here: Zig is not installed, `codeberg.org` is unreachable, and `vendor/` is absent.
- **Shipped UI font is not VT323 (sandbox, blocking).** `assets/font.ttf` in this upload is **Arial 7.07**. Its name table says Arial. It has 4652 glyphs, 20 distinct ASCII advance widths, and a legacy `kern` table with 909 pairs. Its advances for A, V, T, and R (1366, 1366, 1251, 1479 font units) are Arial's. Upstream VT323 2.000 from `github.com/google/fonts` (`ofl/vt323/VT323-Regular.ttf`, SHA-256 `cf4de751…`) has 587 glyphs, 1000 units per em, one ASCII advance (400), GSUB and GPOS, and no `kern` table. In `checks/hb_linux_RESULTS.txt` the monospace check fails on the uploaded file (advances 607, 607, 607, 550, 683, 740) and passes on upstream VT323 (all 410). `assets/asset_manifest.txt` builds `ui_font_9px` and `default_font_10px` from `assets/font.ttf`, so if this upload is what ships, the game's UI text renders in Arial. The VT323 descriptions in sections 12 and 13 do not describe this file, and the Phase 0 shaping and rasterization evidence that cites VT323 cannot be reproduced from it. The 2026-11-16 Windows report ("shaping tests pass", user-reported) is consistent only with the owner's local `assets/font.ttf` being VT323. Confirm with `sha256sum assets/font.ttf` on the Windows machine. The local copy's 584-glyph count also differs from upstream VT323 2.000's 587, so confirm the exact build as well as the family. The file was not replaced in this run, because the canonical copy is the owner's decision.
- **Windows test run (user-reported, 2026-11-17, Zig 0.16.0-dev.3142+5ccfeb926).** `zig build test` ran 559 of 560 tests and passed 559. One failed: `engine.text.hb_shape_test`, "VT323 is monospaced: every AVATAR advance is positive and equal", expected 607, found 550. The Windows advances match the uploaded Arial file exactly (sandbox run: 607, 607, 607, 550, 683, 740). So the local `assets/font.ttf` is that Arial file. The 2026-11-16 Windows "shaping tests pass" entry is contradicted by this run and is superseded. The other shaping tests and the HarfBuzz version test passed. The C text and imgui suites passed. The test failure is a true signal: the shipped UI font is not VT323. The test was not changed to match the font, and the font was not changed in this record. The Phase 1 Windows exit criterion (test targets build and pass) is not met. The CI workflow runs `scripts/check-dependency-pins.py` and the boundary self-test, and logs the `assets/font.ttf` SHA-256 on each OS. The fingerprint `1045956 bytes, sha256 edfbd22a…` identifies the Arial file. Phase 0 raster results name a VT323 `assets/font.ttf` of 149,688 bytes (`rasterization/vt323_9px_results.txt`). Upstream VT323 2.000 is 153,116 bytes, so it is not the same build. The owner's original VT323 is most likely the 149,688-byte file. Confirm with a size check and the CI log before restoring.
- **Decision (2026-11-17, owner): Arial is intentional.** `assets/font.ttf` stays Arial 7.07. The monospace assertion in `hb_shape_test.zig` ("VT323 is monospaced") was built on a VT323 premise that the shipped font does not meet, so it was replaced, not weakened. The replacement asserts what the shipped font does: the AV pair is kerned (the A is 607 before V and 683 alone at 16 px), and AVATAR is proportional, not all equal. The header comment now names the Arial file. The C mirror in `checks/hb_linux_smoke.c` passes all checks on the shipped font (`checks/hb_linux_RESULTS.txt`). The same mirror fails the new kerning and proportional checks on upstream VT323, which confirms the checks are specific to the shipped font.
  - *Not verified here:* the Zig change is not compiled in this sandbox, because Zig and `vendor/` are unavailable. The owner must run `zig build test` on Windows. The expected result is that the shaping suite passes (560 of 560 in the Windows run).
  - *Phase 0 evidence to re-measure:* the VT323 measurements (`docs/Bairava_Phase0/PHASE0_REPORT.md`, `shaping/shipped_ui_shaping_check.py`, `shaping/shipped_ui_shaping_results.txt`, `rasterization/vt323_9px_results.txt`, `baseline/atlas_estimate.txt`) describe a 149,688-byte VT323 build that is not shipped. They are historical evidence. Re-measure shaping across the 95 printable ASCII characters and the 14 UI strings, the 9 px mono and gray rasterization comparison, and the atlas estimate against Arial 7.07 before they serve as the Phase 0 baseline. A banner now marks the report. The TrueType-only and stb-by-default format decisions still hold, because Arial is TrueType `glyf`. The quality claims at 9 px were made for VT323 and need re-checking.
  - *Design implication to confirm:* the text draft's pixel-art premise (bitmap-first, nearest sampling, mono at 9 px) was tuned with VT323 in mind. Whether the 9 px mono Arial look is acceptable is a visual decision. Capture screenshots before accepting it (Phase 0 baseline item).
  - *Phase gate:* Phase 1's Windows criterion is open until `zig build test` passes on Windows with this change. Linux and macOS have still not been run.
- **Font asset `font2.ttf`.** Matches the 2026-11-16 description: "November", TrueType `glyf`, 247 glyphs, no GSUB or GPOS.
- **Phase gates.** Phase 1's exit criteria (builds and links on Linux, Windows, and macOS) are not met, so Phase 2 has not started. Phase 0's two owner confirmations are unchanged. The Phase 0 baseline-screenshot item remains blocked and now also depends on the font identity question above.

## 15. Phase 0 re-measurement against Arial 7.07 (2026-11-17)

**Windows gate (user-reported).** After the Arial change in section 14, `zig build test` passes on Windows. This closes the Windows part of the Phase 1 exit criterion. Linux and macOS are still open. The CI matrix (`.github/workflows/ci.yml`: ubuntu, macos, windows) will give that evidence on the next push.

**What was measured (sandbox).** The real bake (`tools/assets/build.c` and `font_bake.c`) was built in a scratch copy and run on the two shipped UI rows of `assets/asset_manifest.txt`. The current runtime loader (`src/engine/text/text.c`) measured the 14 UI strings and the glyph advances. HarfBuzz 15.1.0 shaped the same strings. Everything is in `docs/Bairava_Phase0/baseline/arial/` (README, scripts, measurements, and the two baked BFNT files with SHA-256). The bake used system FreeType 2.13 rather than the pinned 2.15.0, so the 9 px numbers should be rechecked with the pinned FreeType.

Findings:

- **Kerning sources agree.** Over printable ASCII, HarfBuzz's GPOS kern path and the classic `kern` table give the same 96 pairs with the same values. Nothing in the kerning source changes with the migration.
- **9 px mono (`ui_font_9px`).** The baked atlas has 0 kerning pairs. FreeType grid-fits every Arial kern below half a pixel to zero. Its glyph advances are whole pixels, and 17 of 95 printable glyphs differ from the unhinted advance by more than 0.5 px (max 1.5 px). Routing this font through HarfBuzz changes all 14 UI strings: the baked widths are 1.0 to 4.5 px wider. Only "Volume" has a kerning difference, the V–o pair at 0.5 px.
- **10 px gray (`default_font_10px`).** The bake sizes TrueType glyphs with stb's `stbtt_ScaleForPixelHeight`, which divides by hhea ascent minus descent (2288 units for Arial), not by units per em. A "10 px" gray font therefore has an effective em of 8.951 px. HarfBuzz at that em reproduces the baked widths of the 14 UI strings to 0.0003 px, kerning included. At a plain 10 px em, the widths would grow by 2 to 8 px.
- **The owner's `shipped_ui_shaping_check.py` is not the baseline for the shipped sizes.** It reports 13 of 14 UI strings identical, but it runs at 48 px and compares against unhinted advances, not against what the bake stores. It stays as it is. The baseline for the shipped sizes is `baseline/arial/`.
- **Doc correction.** `docs/text.md` said the shipped font has no kerning pairs. That was true of VT323 and is false of Arial. The text now states the 96 pairs and the 9 px rounding.

Decisions the owner needs before Phase 0 can exit. Each one changes the public text API or the visible UI, so none can be settled by the sandbox:

- **D1. 9 px mono glyph advances.** Keep the baked whole-pixel advances, which the BFNT format already stores, or switch to HarfBuzz's unhinted fractional advances and accept UI strings 1 to 4.5 px narrower. Recommendation: keep the baked advances for bitmap-atlas fonts and make that an explicit rule.
- **D2. Pixel-height convention for TrueType gray fonts.** Keep stb's ascent-minus-descent convention, written as an explicit compatibility scale in the new font face, or switch to em and accept that a "10 px" gray font grows by about 12%. Recommendation: keep the existing convention and document it. The plan requires one definition of pixel height, and both paths must follow it.
- **D3. Kerning in mono fonts.** The bake drops every Arial kern at 9 px. Keep that rule, which matches whole-pixel placement, or apply the fractional HarfBuzz value. Recommendation: keep the rule for mono and apply GPOS kerning for gray, which already matches the baked values under D2.

**Gate status.**

- Phase 0: the Arial measurements are recorded. The baseline screenshots still need a display. D1 to D3 need owner decisions before Phase 0 can close, because they fix the advance and scale rules that the public API depends on.
- Phase 1: the Windows criterion is met (user-reported). The Linux criterion is partly met (compile and smoke run in the sandbox; the Zig build did not run here). The macOS criterion has not been run. The CI matrix will supply both.
- Phase 2: not started. Its gate needs Phase 1 green on all three operating systems and D1 to D3 recorded.

## 16. Phase 0 decisions recorded (2026-11-17)

The owner answered D1 to D3 with the recommended options. Recorded as decided:

- **D1, 9 px mono advances.** Keep the baked whole-pixel advances. The BFNT advance table is authoritative for prebaked fonts. HarfBuzz advances apply only to runtime outline fonts. The shipped UI text does not change.
- **D2, pixel-height convention for gray TrueType fonts.** Keep the stb ascent-minus-descent scale, documented as a compatibility rule. Mono fonts keep the em convention. Runtime outline faces follow the gray rule.
- **D3, mono kerning.** Keep dropping kerns that round to zero whole pixels at the baked size.

Effect: under these three rules the shipped UI fonts keep their current advances, kerning, and widths. The migration causes no visible change to shipped text.

Resolved the same day (owner answers):

- **Q1, atlas page policy.** Four 1024² pages, no eviction, with a `glyph_cache_full` diagnostic.
- **Q2, order of the text and Dear ImGui migrations.** Text first. ImGui's font atlas becomes a client of the glyph cache.
- **Q3, runtime missing-glyph fallback.** Draw the font's `?` glyph if the font has one, otherwise nothing. Count each missing codepoint in diagnostics.

Still open, none of which blocks Phase 2: the repository has no Tamil test font, so Tamil shaping tests cannot run until Phase 4; the baseline screenshots need a display and must be captured before Phase 5; the 9 px numbers should be rechecked with the pinned FreeType 2.15.0 before Phase 5 acceptance.

Design note: `docs/Bairava_Phase0/design-note.md`. Measured baseline: `docs/Bairava_Phase0/baseline/arial/`.

## 17. Phase 0 exit gate (2026-11-17)

Checked against the rendering plan's Phase 0 exit criteria:

- Every required font source has an agreed import or runtime path: yes (design note, section 1).
- TrueType and CFF behavior is explicitly decided: yes. Runtime TrueType only; CFF stays prebaked.
- HarfBuzz and stb choices are explicit and licensable: yes, pinned and recorded in the lock. The HarfBuzz hash matches the commit export. The stb header matches the commit.
- SDL GPU and SDL3 2D behavior is documented: yes (design note, section 6). Both are acceptance targets.
- Existing behavior has baseline tests or screenshots: yes, the measured baseline in `baseline/arial/`. Screenshots are still to be captured before Phase 5.
- No unresolved design question would force a data-format or public-API rewrite: yes. D1 to D3 and Q1 to Q3 are answered.

Phase 0 is closed. Phase 1 is passing on Windows, as reported by the owner. Linux and macOS are pending in CI. Phase 2 starts when that CI is green.

## 18. Phase 2: runtime font object and glyph rasterization (2026-11-17)

Phase 1 CI is green on Linux, Windows, and macOS (owner-reported), and Phase 0 is closed, so Phase 2 has started.

**Written.** `src/engine/text/runtime_font.zig` contains:

- `RuntimeFont.init`: copies the font bytes, validates the container, initializes stb_truetype and a HarfBuzz face and font bound to the copy, and sets the HarfBuzz scale from the gray convention (D2): em = px * upem / (ascent - descent), in 26.6 units.
- `glyphMetrics(glyph_id)`: advance, bitmap offset from the pen (x) and the baseline (y, down), and bitmap size. Glyphs with no ink report zero size and need no atlas rectangle.
- `rasterize(allocator, glyph_id)`: an owned coverage bitmap, row 0 at the top. Empty glyphs return an empty slice.
- `checkFormat`: accepts TrueType glyf only. Rejects 'OTTO' (CFF), 'ttcf' (collections), and any file with a CFF table and no glyf, before any parser runs.
- Error set: InvalidFont, UnsupportedFontFormat, InvalidPixelHeight, GlyphOutOfRange, and allocator errors.

**Tests (11, in the same file, registered in `src/tests.zig`).** Shipped Arial metrics and glyph count; the HarfBuzz scale (917 in 26.6 units); the A glyph's advance (9.5524 px), bounds (11 by 11, offset -1, -11), and baseline (bottom edge at 0); A's coverage (sum 8030, peak 255); the space; 94 of 95 printable glyphs with ink; the glyph-range check; the font's own copy of its bytes; pixel-height validation (zero, negative, NaN, infinity); container rejection (empty, unrecognized, OTTO, ttcf, CFF-only table, truncated directory); and 20 create and destroy cycles under the testing allocator, which detects leaks.

**Build.** `build.zig` compiles `vendor/stb_truetype_impl.c` into the test module. The engine module is unchanged, so the shipped build does not import the new file.

**Verified here.** The measured values come from a C probe against the same stb_truetype 1.28 build and the shipped Arial file. Every Zig assertion matches a value the probe produced. The container checks match a C mirror on all six cases.

**Not verified here.** The Zig code has not been compiled. Zig is not installed, and the repository's `vendor/` tree is absent from the upload, so `zig build test` cannot run in this sandbox. The owner must run it, and CI runs the same command on all three systems.

**Not done (resolved 2026-11-17, section 19).** Loading through Bairava's packaged-file and asset conventions was not wired here. Section 19 wires it.

**Gate.** Phase 2's exit criteria are the 11 tests above passing on all three systems. If `zig build test` fails, paste the first error and the test name, and the fix will follow from there.

## 19. Phase 2: packaged loader wiring (2026-11-17, second pass)

This pass closes the open Phase 2 item "Load font files through Bairava's existing packaged-file and asset-loading conventions," and the "not wired yet" note in section 18. Phase 2 is not closed. Its exit gate is still the owner's `zig build test` run on all three systems.

**Written.**

- `src/engine/text/runtime_font.zig`:
  - `RuntimeFont.loadPackaged(allocator, reader: staging.Reader, relative, pixel_height)` reads a packaged name through the same `staging.Reader` seam the texture loader uses. The engine passes `staging.packagedReader()`. Tests pass a fixture reader.
  - The height is checked before the read, so a bad height never touches the file.
  - The face keeps the reader's allocation, so the file is copied once.
  - `fromOwned` builds the face on bytes it takes ownership of, and frees them on every failure. `init` now validates, copies, and calls `fromOwned`, so `init` and `loadPackaged` share one build path.
  - `LoadError` maps the reader's names onto the engine's: `NotFound` becomes `FileNotFound`, and `ReadFailed`, `PathTooLong`, and `OutOfMemory` pass through.
  - `max_pixel_height = 4096`. Section 18 accepted any finite height. A height of 1e9 gives a HarfBuzz scale of about 5.7e10, which does not fit a C int. That is a real defect: `@intFromFloat` panics in safe builds and is undefined behaviour in release builds. The bound's scale at 4096 px is exactly 234646, which the test pins.
  - `readFixture` now checks for a null or empty blob, and converts the C pointer with `@ptrCast` to `[*]const u8` before slicing, the same conversion `audio.zig`'s `bytesOf` uses. The section 18 version sliced the C pointer directly and had never been compiled.
- Tests: `runtime_font.zig` now has 18 tests. Section 18 had 11. Seven are new: a face built through the reader matches the direct load and the file is read once; a missing name is `FileNotFound` after one read; a bad height is refused before the read; a non-font and a CFF file read through the reader are rejected with their bytes freed; the reader's `ReadFailed` and `PathTooLong` keep their meaning; the engine's packaged reader reports a missing file as `FileNotFound`; and the packaged reader refuses a path that leaves the package folder. The pixel-height test now also covers the bound and its scale. (Section 18's gate of "11 tests" becomes 18.)
- `assets/asset_manifest.txt`: new row `ui_font_ttf file assets/font.ttf fonts/font.ttf -`. The builder copies a `file` row unchanged, so the TrueType ships at `fonts/font.ttf`. The `font` rows bake the same source to `.bfnt` as before. Cost: 1,045,956 bytes in the release. Remove the row to drop it.
- `checks/packaged_loader_mirror.c` and `checks/packaged_loader_RESULTS.txt`: a C mirror of the control flow, the validation rules, the error mapping, and the scale conversion. It reads the shipped `assets/font.ttf` directly.

**Verified here (sandbox).**

- The mirror passes, 49 checks and 0 failures, under AddressSanitizer and UBSan with leak detection, built with `-Werror`.
- From the shipped file's bytes, the mirror confirms the constants the Zig tests pin: unitsPerEm 2048, hhea ascender 1854, descender -434, and 4652 glyphs. The face loaded from those bytes has scale 917 at 16 px. The bound's scale, 234646 at 4096 px, is computed from those same metrics as literals.
- Mutation check: four planted bugs were each caught. A double free and a leak were caught by the sanitizers. A height check moved after the read, and a missing upper bound, were caught by named checks. The log lists them.
- A Python mirror of `checkManifest` accepts all 12 manifest rows, including the forward dependency `level1_spawn` → `game_prefabs`. The `file` rows fall through `check_assets.zig`'s prefab, spawn, and animation branches unchecked, as intended for a `.ttf`.
- Static checks on `runtime_font.zig`: brackets balance; the imports `../assets/staging.zig`, `../platform/platform.zig`, and `../assets/loaders/image.zig` exist; every helper called is defined; test names are unique.

**Not verified.**

- The Zig compile and the test run. The mirror shows the logic, not that the Zig builds. The owner's `zig build test` is the first real check.
- `build.zig`, `build.zig.zon`, `vendor/`, and the stb and HarfBuzz sources are absent from this upload. The new code adds no C sources and no include paths beyond the ones `runtime_font.zig` already needs. The test root already links SDL and the image loader, because `tests.zig` imports `staging.zig`.
- `zig build check-assets` and the asset build with the new row. The manifest mirror above covers the rules, not the tool.
- A file read through `staging.packagedReader()` succeeding. The tests exercise the production reader only for a missing name and an unsafe path. The test binary's base folder is not the repository's `assets/`, so a real packaged read is first exercised in a built game.

**Phase 2 checklist** (Rendering Migration Plan, Phase 2):

- [x] Runtime font object owning data, metrics, rasterizer state, and HarfBuzz state (`RuntimeFont`).
- [x] Load through the packaged-file conventions. Code and tests written; the manifest row is in. Pending the owner's run.
- [x] HarfBuzz initialized from the loaded bytes, with the gray pixel-height scale and the new bound.
- [x] Glyphs rasterized by glyph ID.
- [x] stb bounds converted to baseline and screen conventions.
- [x] Empty glyphs keep their advance and allocate no bitmap.
- [~] Error behaviour. Invalid fonts, unsupported formats, allocation failure, reader failures, and out-of-range glyph IDs all have explicit errors. Rasterization itself has no failure path: `stbtt_MakeGlyphBitmap` returns nothing, so there is no rasterization error to report.
- [x] Lifecycle tests for creation, reuse, and destruction, including 20 cycles and the error paths.

**Gate.** Phase 2 closes when `zig build test` passes on Windows, Linux, and macOS with the 18 `runtime_font.zig` tests among them, and `zig build check-assets` passes. Phase 3 does not start before then.

**Open items for engine integration** (not part of Phase 2):

- Which allocator a face uses. `docs/ownership.md` puts fonts in the asset arena, which is not freed until the run ends. A face must still be released before shutdown, and an arena's `free` does nothing.
- Whether `ui_font_ttf` ships in a release before any engine code uses the face.
- Whether the mirror should run in CI. It is a manual check today, like the other `checks/` harnesses.

## 20. First Zig compile on Windows: result and fix (2026-11-17)

**Owner's run.** `zig build test` on Windows, Debug, Zig 0.16.0-dev.3142+5ccfeb926, with the section 19 changes.

- Passed: the asset importer and converter tests, the job tests, the script tests, the imgui checks, and the text checks. The build summary reports 30 of 33 steps succeeded.
- Failed: the `test` step did not compile. Four errors, all from one import: `src/engine/text/runtime_font.zig:27`, the `@cImport` of `stb_truetype.h`. Translate-c reports `vendor/stb_truetype.h:1061`, `stbtt_GetFontNameDefault(..., size_t output_buffer_len)`: "expected ')', found an identifier". `size_t` is not defined where the header uses it.

**Effect.** `src/tests.zig` imports `runtime_font.zig`, so one failed import stops the whole Zig unit-test binary. None of its tests ran: not the runtime font tests, not the HarfBuzz shaping tests, not the earlier baseline. This is my regression. Section 19 listed the Zig compile as unverified, and this run confirmed that the change broke the build.

**Cause.** The vendored `stb_truetype.h` uses `size_t` in its declarations and includes nothing that defines it. The file was never compiled before this step. The upload did not contain `vendor/`, so I could not check the header in the earlier passes. `tools/assets/font_bake.h` already includes `<stddef.h>` before the stb header.

**Fix.** `runtime_font.zig`'s `@cImport` now includes `stddef.h` before `stb_truetype.h`. No other code changed. Each stb function the file calls (`stbtt_InitFont`, `stbtt_GetFontVMetrics`, `stbtt_ScaleForPixelHeight`, `stbtt_FindGlyphIndex`, `stbtt_GetGlyphHMetrics`, `stbtt_GetGlyphBitmapBox`, `stbtt_MakeGlyphBitmap`) and each HarfBuzz function is in the stb 1.28 and HarfBuzz 15.1 APIs the repo pins.

**Not verified.** The fix has not been compiled here, because Zig is not installed in this sandbox. Zig analyses the rest of `runtime_font.zig` only after the header translates, so the next run may show further errors in that file. The rest of the file is still unverified.

**Next run.** `zig build test`. Expect the whole unit-test binary to build and run, with the 18 `runtime_font` tests among them. If it fails, paste the first error and the test name.
