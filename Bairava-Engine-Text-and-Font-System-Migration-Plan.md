# Bairava Engine — Text and Font System Migration Plan

**Status:** Proposed — planning document only; no implementation performed by this document  
**Scope:** Merge the runtime text/shaping pipeline (Architecture 1) with the multi-source font system (Architecture 2)  
**Repository reviewed:** `ash5me/Bairava-Engine` default branch  
**Target:** A unified text system that supports hand-authored bitmap fonts, the existing prebaked coverage fonts, runtime-rasterized outline fonts, and optional MSDF fonts while continuing to use Bairava's existing renderer and `SpriteBatch`.

---

## 1. Executive decision

The two architectures should be merged. They describe different responsibilities and should not become separate text engines.

- **Architecture 1 remains the text-processing backbone:** UTF-8 input, shaping, glyph IDs and clusters, glyph lookup, text layout, and submission through Bairava's renderer.
- **Architecture 2 becomes the font-source and glyph-rendering subsystem:** font importing, bitmap atlases, coverage glyphs, MSDF atlases, and selection of the appropriate sampling/shader path.

The result is one public text API and one layout system, backed by multiple font providers and rendering modes.

### Required outcome

A game should be able to select a font asset without having to know how glyphs are stored or rendered. The text system should be able to use:

1. **Hand-authored bitmap fonts** — imported atlas plus glyph metadata; nearest sampling; intended for pixel fonts.
2. **Existing prebaked coverage fonts (`.bfnt`)** — retain the current offline TTF/OTF-to-coverage workflow and loading compatibility.
3. **Runtime coverage fonts** — outline font face, HarfBuzz shaping, on-demand glyph rasterization and a dynamic coverage atlas.
4. **MSDF fonts** — outline font converted offline to an MSDF atlas and drawn with a dedicated distance-field shader.

These are font-source/rendering paths inside one system, not four separate text APIs.

### Non-negotiable design rule

**Text shaping and layout must not depend on the glyph's rendering representation.** HarfBuzz should not need to know whether a shaped glyph is ultimately drawn from a bitmap atlas, a coverage atlas, or an MSDF atlas.

---

## 2. Current Bairava baseline

The plan is based on the repository's current implementation, not on an assumption that text rendering is starting from zero.

| Area | Current implementation | Migration implication |
|---|---|---|
| Font asset build | `assets/asset_manifest.txt` can define TTF/OTF font rows; the offline asset builder emits `.bfnt` v4 | Preserve this path as a working coverage-font provider |
| Font rasterization | `tools/assets/font_bake.c` uses `stb_truetype` for TrueType outlines and FreeType for OpenType CFF / hinted mono paths | Do not assume `stb_truetype` covers every format currently supported by the offline baker |
| Runtime font loading | `src/engine/text/font.zig` loads `.bfnt` and uploads an R8 coverage atlas | Evolve this into one provider behind a common font/glyph interface |
| Text input | `src/engine/text/text.c` decodes UTF-8 into codepoints | Keep UTF-8 handling; replace codepoint-only glyph selection for outline fonts with shaped glyph IDs |
| Text shaping | No HarfBuzz shaping currently | Add a shaping service and retain a simple bitmap-font mapping path where appropriate |
| Text layout | `src/engine/text/layout.zig` wraps at UTF-8 codepoint boundaries and measures through current font metrics | Upgrade to shaped advances and cluster-safe line breaking |
| UI integration | `src/engine/ui/ui.zig` exposes `Canvas`, `Ui`, text measurement, text drawing, and widgets | Preserve these engine-facing entry points where practical |
| Sprite batching | `src/engine/renderer/sprite.zig` batches consecutive quads by texture and has a coverage-run flag | Extend the run/material classification for MSDF; do not create a separate text renderer backend |
| GPU coverage rendering | `Texture.createCoverage` and the SDL_GPU coverage pipeline already draw R8 font atlases | Reuse for prebaked and runtime coverage glyphs |
| Texture filtering | SDL_GPU texture samplers currently use nearest filtering; the SDL3 2D renderer also defaults to nearest | Keep nearest for pixel fonts; introduce per-texture/per-font filtering policy for MSDF |
| Secondary renderer | Bairava can also draw through an SDL3 2D renderer path | Define MSDF behavior explicitly; that path does not currently expose the custom MSDF shader pipeline |
| UI rectangles | `Canvas.rect` currently samples a white block stored in the font atlas | Decouple rectangle drawing from the font atlas before supporting unrelated atlas formats |
| Dependencies | `stb_truetype` and FreeType are currently used by offline asset tooling / UI tests, not the runtime game | Runtime rasterization changes dependency placement and must be treated as a build and platform task |

### Existing touchpoints to preserve or adapt

- `src/engine/text/text.c` and `text.h` — current BFNT parsing helpers, UTF-8 decoding, measurement, and glyph-quad generation.
- `src/engine/text/font.zig` — runtime font ownership and R8 texture upload.
- `src/engine/text/layout.zig` — current wrapping and alignment implementation.
- `src/engine/ui/ui.zig` — `Canvas`, `Ui`, widgets, text and rectangle helpers.
- `src/engine/renderer/texture.zig` — texture abstraction and `createCoverage`.
- `src/engine/renderer/sprite.zig` — sprite queueing, run grouping, and `draw2d` / GPU drawing.
- `src/engine/renderer/backends/sdl_gpu/sprite.zig` — plain, lit and coverage pipelines.
- `src/engine/renderer/backends/sdl_gpu/texture.zig` — texture uploads and sampler creation.
- `src/engine/platform/sdl/renderer2d.zig` — secondary 2D renderer behavior.
- `tools/assets/font_bake.c` and `tools/assets/build.c` — current offline font build path.
- `build.zig`, `build.zig.zon`, `docs/dependency-policy.md`, and `docs/dependency-lock.json` — dependency and build integration.
- `docs/text.md` — current font behavior and limitations; update as phases land.

---

## 3. Goals and non-goals

### Goals — required

- One stable, engine-facing text API for all supported font types.
- UTF-8 input with deterministic malformed-input behavior.
- A shaping interface that can use HarfBuzz for outline fonts and a clearly scoped simple mapper for bitmap fonts.
- Preserve glyph IDs, clusters, advances, and offsets after shaping.
- Preserve the current `.bfnt` loading path during migration.
- Import hand-drawn bitmap fonts without vectorizing them.
- Support a runtime glyph cache and dynamic coverage atlas for outline fonts.
- Add MSDF as an optional outline-font rendering path.
- Reuse Bairava's existing `SpriteBatch`, GPU device, renderer lifecycle, and asset conventions.
- Make font and texture resource lifetime safe across queued draws and in-flight GPU work.
- Test both renderer modes and define graceful behavior where feature parity is not possible.

### Non-goals for the first completed migration

- Replacing the SDL3 GPU renderer or the SDL3 2D renderer.
- Replacing `SpriteBatch` with a standalone text renderer.
- Converting hand-authored bitmap fonts into vector outlines or MSDF.
- Full bidirectional paragraph layout, Arabic joining policy, vertical writing, automatic hyphenation, or complete Unicode line-breaking conformance unless separately approved.
- Color emoji, animated glyphs, variable-font UI, or rich-text markup as requirements for the first release.
- Removing the existing `.bfnt` format merely because the new providers exist.

---

## 4. Target architecture

The content build and the runtime text flow are related, but they should be represented as separate paths.

### 4.1 Content and font-asset pipeline

```text
                         Font Asset Pipeline
                                  |
              +-------------------+-------------------+
              |                   |                   |
        Bitmap source        TTF / OTF source     TTF / OTF source
        atlas + metrics            |                   |
              |              Offline BFNT bake     Offline MSDF bake
              |              (coverage atlas)      (distance atlas)
              |                   |                   |
              +-------------------+-------------------+
                                  |
                         Packaged font assets
```

The existing BFNT bake remains a valid path. Hand-authored bitmap assets need their own importer and metadata format. MSDF generation is an offline tool step; the game should load generated MSDF assets rather than run the generator at startup.

### 4.2 Runtime text pipeline

```text
UTF-8 text + font handle + text options
                    |
                    v
             UTF-8 validation
                    |
                    v
              Text shaper
         +----------+-----------+
         |                      |
   Simple bitmap mapper     HarfBuzz shaper
   (bitmap font path)       (outline font path)
         |                      |
         +----------+-----------+
                    |
                    v
       Shaped run / glyph sequence
       glyph IDs, clusters, advances,
             offsets, font identity
                    |
                    v
             Text layout
       line breaking, line placement,
          alignment, measurement
                    |
                    v
          Glyph provider / cache
         +----------+-----------+
         |          |           |
      Bitmap     Coverage      MSDF
      atlas      atlas/cache   atlas
         |          |           |
         +----------+-----------+
                    |
                    v
           Glyph render records
     texture/page + UV + plane bounds + mode
                    |
                    v
             Text renderer
       bitmap / coverage / MSDF shader
                    |
                    v
           Bairava SpriteBatch
                    |
                    v
         Existing renderer backends
```

Shaping provides logical glyph identity and positioning. Layout decides line placement. The glyph provider resolves the visual image/atlas coordinates. Those steps may be interleaved for performance, but their responsibilities and data contracts must remain separate.

### 4.3 Font provider and render-mode matrix

| Font path | Glyph source | Shaping path | Sampling / render path | Intended use |
|---|---|---|---|---|
| Hand-authored bitmap | Imported atlas and descriptor | Simple mapper initially; advanced shaping only when data supports it | Nearest; standard RGBA or coverage pipeline according to atlas type | Pixel-art fonts |
| Existing `.bfnt` | Prebaked R8 coverage atlas | Legacy/simple mapping during transition | Nearest coverage pipeline | Existing UI and debug fonts |
| Runtime outline coverage | Runtime TTF/OTF face; rasterize cache misses | HarfBuzz | Nearest or selected coverage sampling; R8 coverage pipeline | Dynamic text and scalable outline fonts |
| MSDF | Offline-generated distance-field atlas | HarfBuzz | Linear sampling plus MSDF shader | Scalable outline fonts and UI |

**Important terminology:** the existing `.bfnt` file is a prebaked coverage atlas generated from an outline font. It is not the same source type as an artist-authored bitmap font atlas. Both may look pixel-oriented, but they have different import and metadata needs.

---

## 5. Architecture and data-contract requirements

The exact Zig declarations can change during implementation. The responsibilities below are the contract the implementation must preserve.

### 5.1 Font identity and metadata

Every loaded font must expose, at minimum:

- Stable font identity / handle.
- Source kind and rendering mode.
- Ascender, descender, line gap, line height, baseline convention, and units-per-em or pixel size as applicable.
- Character-to-glyph mapping or access to the outline font's character map.
- Fallback/missing-glyph policy.
- Ownership and lifetime rules for source bytes, HarfBuzz objects, CPU atlas metadata, and GPU texture pages.

### 5.2 Shaped glyph record

A shaped glyph must retain:

- Font identity (important when fallback is introduced).
- Glyph ID — do not assume it is the Unicode codepoint.
- Cluster value mapping the glyph back to source text.
- X/Y advances.
- X/Y offsets.
- Direction/run information needed by layout.

Do not discard clusters after shaping. They are required for safe line breaking and will be useful for selection, hit testing, and per-character effects.

### 5.3 Glyph render record

A resolved glyph image must provide:

- Font and glyph identity.
- Atlas page / texture handle.
- Atlas UV rectangle.
- Plane bounds or equivalent bearing/size data used to place the image relative to the baseline.
- Render mode: bitmap/color, coverage, or MSDF.
- Sampling policy and any MSDF distance-range metadata.

The glyph cache key must include enough information to prevent collisions. For runtime rasterized glyphs, include at least font identity, glyph ID, pixel size, and rasterization mode/hinting settings. If subpixel rasterization is ever introduced, its phase must also be part of the key.

### 5.4 Separation of caches

Do not collapse all font data into one cache.

- **Font asset cache:** loaded font faces, bitmap descriptors, BFNT metadata, and MSDF asset metadata.
- **Glyph image cache:** resolved glyph render records and atlas locations.
- **Atlas page owner:** CPU packing state and GPU texture lifetime for each page.

Static bitmap, BFNT, and MSDF atlases can be pre-existing assets. Runtime coverage fonts can add glyphs on demand. The shared interface should support both without pretending their allocation lifecycles are identical.

### 5.5 Shaping policy

- Outline fonts use HarfBuzz to shape into glyph IDs, clusters, advances, and offsets.
- Basic bitmap fonts may initially use a simple Unicode-codepoint-to-glyph mapping plus their stored advances and kerning pairs.
- Do not claim complex-script shaping for a bitmap font unless its metadata actually provides the required substitutions/positioning or it is integrated through a suitable shaping-font adapter.
- HarfBuzz is a shaping engine, not a complete paragraph bidi engine. Full mixed-direction paragraph layout requires a separate bidi-resolution decision/dependency.

---

## 6. Implementation phases and exit gates

**Gate policy:** Do not start the next phase simply because the current code compiles. The phase's exit criteria must pass, be reviewed, and be recorded. A phase may be split into smaller PRs, but its gate remains mandatory.

## Phase 0 — Baseline audit and design decisions

**Purpose:** Remove ambiguity before changing formats, dependencies, APIs, or renderer behavior.

### Needs — must complete

- [ ] Inventory all font load, measure, draw, and layout call sites in engine, sample, game, overlay, console, widgets, and tests.
- [ ] Record current public behavior: font pixel-height rules, baseline/top-left convention, ascent/line-height, kerning, fallback glyph, UTF-8 error behavior, wrapping, alignment, color/alpha, clipping, and pixel snapping.
- [ ] Capture reference screenshots for current UI/debug text in both GPU and SDL3 2D renderer modes.
- [ ] Define the first supported language/test corpus. Minimum recommendation: Latin and Tamil, including combining marks and conjunct fixtures in a suitable font.
- [ ] Decide the initial runtime outline-font support matrix. `stb_truetype` is already present, but CFF support is currently handled by the offline FreeType bake path; do not silently regress it.
- [ ] Decide whether runtime rasterization supports TrueType `glyf` only initially, or whether FreeType must also move into the runtime for CFF.
- [ ] Decide how bitmap font atlases are described: select an established descriptor format or define a versioned Bairava format. Do not hard-code an undocumented sprite-sheet convention.
- [ ] Decide which MSDF generator will be used, its license, version pin, supported font formats, output metadata, and asset-builder integration.
- [ ] Decide fallback behavior for missing glyphs and whether font fallback chains are part of the first release or a later phase.
- [ ] Decide the initial renderer policy for MSDF. Recommended: SDL_GPU first; the SDL3 2D renderer uses a matching prebaked coverage/bitmap fallback until it has an equivalent shader path.
- [ ] Define atlas growth, maximum pages, memory budget, and whether eviction is required for the first release.
- [ ] Define success metrics: no visual regression for existing fonts, correct shaping fixtures, no duplicate rasterization for cache hits, and acceptable cold/hot text performance.

### Wants — useful but not blocking

- [ ] Add a small typography reference scene with Latin, Tamil, punctuation, numbers, and multiple font sizes.
- [ ] Add a script or test fixture to compare rendered screenshots at the engine's native resolution and integer scales.

### Deliverable

A reviewed design decision record containing: supported font formats, font-source matrix, shaping scope, renderer fallback policy, dependency plan, public API compatibility plan, cache/atlas policy, and test corpus.

### Exit gate — Phase 0 is complete only when

- [ ] Every required font source has an agreed import/runtime path.
- [ ] TrueType/CFF behavior is explicitly decided.
- [ ] HarfBuzz and MSDF dependency/tooling choices are explicit and licensable.
- [ ] SDL_GPU and SDL3 2D behavior for every rendering mode is documented.
- [ ] Existing behavior has baseline tests or screenshots.
- [ ] No unresolved design question would force a data-format or public-API rewrite in a later phase.

---

## Phase 1 — Shared text model and compatibility boundary

**Purpose:** Establish the common API and data contracts while the current BFNT implementation still works.

### Needs — must implement

- [ ] Introduce a common font handle/face abstraction that can represent bitmap, prebaked coverage, runtime outline, and MSDF sources.
- [ ] Define common font metrics and baseline conventions.
- [ ] Define the shaped-glyph and glyph-render-record contracts from Section 5.
- [ ] Define text options for font, size/scale, color, line spacing, alignment, wrapping width, and optional direction/script/language overrides.
- [ ] Separate text measurement, layout, glyph resolution, and draw submission into distinct responsibilities.
- [ ] Keep current `.bfnt` loading behind a legacy/prebaked coverage provider; do not rewrite the file format in this phase.
- [ ] Preserve the current `Canvas.text`, `Canvas.textWidth`, `Canvas.layoutText`, and `Canvas.drawTextLayout` behavior through wrappers or adapters where practical.
- [ ] Decouple solid-rectangle drawing from the white 2x2 texel embedded in the font atlas. Use a renderer-owned white texture or a primitive path so a font atlas is not required for rectangles.
- [ ] Define ownership rules: a queued draw cannot reference a font page that may be destroyed, repacked, or overwritten before submission completes.
- [ ] Keep renderer-specific types out of the public text API.

### Wants — useful but not blocking

- [ ] Add diagnostic counters/interfaces for loaded fonts, glyph lookups, misses, and atlas page count, even if initial counters are simple.
- [ ] Add a debug description of the active font source and rendering mode.

### Deliverable

A common text/font interface with an adapter to the existing BFNT implementation; no visible text feature is removed.

### Exit gate — Phase 1 is complete only when

- [ ] Existing sample/UI/debug text renders and measures the same as the captured baseline.
- [ ] Existing `.bfnt` v1/v2/v4 compatibility behavior remains covered by tests (where those versions are supported by the current loader).
- [ ] Rectangle drawing works without referencing a font atlas.
- [ ] New interfaces compile without exposing SDL or HarfBuzz types to game-facing code.
- [ ] Resource ownership and shutdown order are documented and tested.

---

## Phase 2 — Hand-authored bitmap font importer and renderer

**Purpose:** Add the missing first-class path for pixel fonts that are already hand-drawn as bitmap glyphs.

### Needs — must implement

- [ ] Add a versioned bitmap-font asset descriptor containing glyph mapping, atlas page, source rectangle, advance, bearing/offset, baseline/line metrics, and optional kerning pairs.
- [ ] Support mapping Unicode codepoints to glyph entries. Keep glyph IDs distinct from codepoints internally even if the first format maps one codepoint to one glyph.
- [ ] Import atlas image data without vectorizing it or sending it through MSDF generation.
- [ ] Validate atlas bounds, duplicate codepoints, invalid metrics, missing pages, malformed descriptors, and missing fallback glyphs during asset build.
- [ ] Support monochrome/alpha glyph atlases using the coverage path. If color bitmap glyphs are included, use the normal RGBA sprite path and preserve their authored color.
- [ ] Use nearest-neighbor sampling for pixel bitmap fonts and preserve integer-pixel destination placement by default.
- [ ] Define atlas padding/edge handling so neighboring glyphs cannot bleed when sampled or scaled.
- [ ] Add a basic bitmap shaper/mapper that looks up the font's codepoint mapping and stored kerning; explicitly document its limits for ligatures and complex scripts.
- [ ] Draw through the common text API and existing `SpriteBatch`; do not make a separate bitmap-text public API.
- [ ] Add an example font asset authored as a bitmap atlas and exercise punctuation, spaces, missing glyphs, baseline offsets, and kerning.

### Wants — useful but not blocking

- [ ] Support multi-page bitmap font atlases in the descriptor, even if the first example uses one page.
- [ ] Support importing a common external bitmap-font descriptor if it is a good fit and has no unacceptable license/format constraints.
- [ ] Provide an atlas preview or validation report showing glyph rectangles and baseline positions.

### Deliverable

A developer can add a hand-drawn bitmap font through the asset pipeline and use it through `Canvas`/the common text API.

### Exit gate — Phase 2 is complete only when

- [ ] The imported pixel font is visually identical to its source atlas at native resolution and integer scales.
- [ ] Nearest sampling is used without changing the sampling policy of unrelated textures.
- [ ] Metrics, spaces, kerning, fallback, and baseline tests pass.
- [ ] Atlas descriptor validation fails cleanly on malformed input.
- [ ] Bitmap text batches through the same renderer submission path as existing text/sprites.
- [ ] No vectorization or MSDF conversion is required for a hand-authored bitmap font.

---

## Phase 3 — HarfBuzz integration and runtime outline-font face

**Purpose:** Add the shaping foundation and load outline-font information without coupling it to a GPU atlas.

### Needs — must implement

- [ ] Pin HarfBuzz to an explicit version/commit and record it in dependency policy and lock data.
- [ ] Integrate HarfBuzz into Bairava's actual Zig/C/C++ build for Linux, Windows, and macOS. Do not copy another project's Zig build script or dependency versions blindly.
- [ ] Reuse the existing `stb_truetype` source where suitable; do not add a duplicate copy.
- [ ] Create a runtime outline-font face that owns or safely references the font bytes for as long as HarfBuzz and the rasterizer require them.
- [ ] Reuse HarfBuzz face/font objects; do not create them per string or per frame.
- [ ] Define units and scaling from font units to Bairava pixels in one place.
- [ ] Implement the shaping call with explicit direction, script, language, and feature handling. Provide sensible defaults but allow the caller or text system to set them deliberately.
- [ ] Return glyph IDs, clusters, advances, and offsets in an engine-owned shaped-run structure.
- [ ] Handle empty strings, malformed UTF-8, zero-width/non-rendering glyphs, and missing-glyph results deterministically.
- [ ] Test Latin kerning/GPOS behavior and Tamil shaping with fonts that contain the required OpenType tables.
- [ ] Keep shaping tests CPU-only; they must not require a GPU device or window.

### Font-format constraint

The current offline path supports TrueType through stb and CFF through FreeType. The runtime path must make an explicit choice:

- **Initial restricted runtime:** use stb for supported TrueType outlines and retain the current offline BFNT/FreeType path for fonts needing CFF support; or
- **Broader runtime:** integrate FreeType at runtime for rasterization/font access where necessary.

Do not advertise all TTF/OTF formats as supported merely because HarfBuzz can parse/shapes them. Shaping support and glyph rasterizer support are separate capabilities.

### Wants — useful but not blocking

- [ ] Add configurable OpenType feature tags for callers who need to disable/enable specific substitutions or positioning.
- [ ] Add language/script overrides for diagnostics and tests.

### Deliverable

A CPU-only shaping service and reusable runtime outline-font face. No glyph atlas or renderer changes are required to prove this phase.

### Exit gate — Phase 3 is complete only when

- [ ] HarfBuzz builds and links on all supported CI platforms.
- [ ] Tests verify glyph IDs, clusters, advances, and offsets for Latin and Tamil fixtures.
- [ ] Font data and HarfBuzz objects survive repeated shaping calls and are released correctly.
- [ ] Unsupported font-format/rasterizer combinations fail explicitly rather than rendering blank glyphs silently.
- [ ] HarfBuzz objects/types do not leak into the public game-facing API.

---

## Phase 4 — Runtime coverage rasterizer, glyph cache, and dynamic atlas

**Purpose:** Implement Architecture 1's on-demand glyph path while keeping static bitmap/BFNT/MSDF assets as separate providers.

### Needs — must implement

- [x] Implement a rasterizer interface that consumes a font face and glyph ID and returns a coverage bitmap plus bitmap bounds/bearing information.
- [x] Implement the initial `stb_truetype` rasterizer for the approved TrueType outline subset. Add runtime FreeType only if Phase 0 selected it for broader format support.
- [x] Do not rasterize by Unicode codepoint after shaping; rasterize the glyph IDs returned by the shaper.
- [x] Treat spaces and other empty glyph images correctly: they keep their advances but do not consume atlas rectangles.
- [x] Define the glyph-cache key using font identity, glyph ID, pixel size, and rasterization settings.
- [x] Add atlas pages with packing padding, page-full behavior, growth limits, and clear allocation failure behavior.
- [~] Add a GPU upload/update path for atlas pages. The current texture API creates sampled textures but does not provide a dynamic glyph-region update contract.
- [~] Ensure uploads occur on the renderer-permitted thread and before a draw samples the changed region.
- [~] Ensure a queued SpriteBatch run cannot outlive or refer to a replaced atlas page. Retire pages only after the relevant GPU work is safe.
- [x] Define an initial eviction policy. It is acceptable to use bounded page growth first, provided memory limits and failure behavior are explicit; eviction can be a later enhancement.
- [x] Preserve the existing static `.bfnt` provider. It should not need to use the dynamic atlas.
- [x] Add cache hit/miss, rasterization count, page count, and allocated-byte counters.

### Wants — useful but not blocking

- [x] Batch multiple glyph misses and upload them together instead of issuing one GPU upload per glyph.
- [ ] Add a warm-up/preload API for known dialogue/UI strings.
- [ ] Add LRU or another measured eviction policy after a stable page-growth implementation exists.

### Deliverable

A runtime outline font can request an unseen glyph, rasterize it once, upload it into a coverage atlas, cache it, and reuse it on later draws.

### Exit gate — Phase 4 is complete only when

- [x] Repeated requests for the same font/glyph/size produce cache hits and do not rasterize again.
- [x] Cache keys distinguish different fonts, sizes, and rasterization modes.
- [x] Atlas-full, allocation-failure, and resource-destruction tests pass.
- [ ] GPU upload/update synchronization is validated under GPU debugging.
- [~] Both renderer modes have defined and tested coverage-font behavior.
- [~] No queued draw can sample a destroyed or repurposed atlas page.

### Status (2026-11-17): resolver, modes, fallback, decisions, and mirror parity

**Legend:** `[x]` means the code exists and a CPU test covers it. `[~]` means the code exists, but it is verified only by reading, or it needs a GPU or window run. `[ ]` means not done. The numbering in this plan is authoritative. The source comments that say "Phase 3" are legacy.

**Caveat.** The sandbox has no Zig toolchain, no vendored HarfBuzz, and no network. The Zig changes were desk-checked but not compiled, so the owner must run `zig build test`. The C mirror (`checks/glyph_cache_mirror.c`) models the resolver, the raster modes, and the fallback. It runs 2159 checks with 0 failures. The original 1828 still pass unchanged, and 19 planted mutants are caught. Its parity with the Zig code is at the level of logic, against a synthetic glyph source. Of 45 Zig tests in the cache, font-test, and atlas files, 42 have a mirror check of the same logic (`checks/glyph_cache_parity.txt`). Parity is not claimed for real-font values, for the GPU, or for Zig compilation.

**Decisions accepted (2026-11-17).**
1. The raster mode is explicit in `resolve`. Gray is the only mode produced. Mono returns `UnsupportedRasterMode`. The mono variant stays in the cache key, so gray and mono entries cannot collide. An unsupported mode fails; it never falls back to gray.
2. The caller supplies the fallback glyph ID. The resolver does not choose a fallback.
3. A glyph is missing when its ID is at least the font's glyph count. The field is `RuntimeFont.glyph_count`, which holds the face's glyph count from HarfBuzz. Glyph 0 is valid (`.notdef`) and gets no special treatment in the cache or the resolver.
4. Mapping `?` through the character map, and the fallback policy, are deferred to Phase 7.

**Phase 7 hand-off.** Phase 7 decides: how `?` is mapped through the character map; what to draw when `?` is unavailable (nothing, or another fallback); and how missing-glyph diagnostics are reported. The `missing_glyphs` counter exists, but no reporting channel does yet. The existing `missing_codepoints` counter counts codepoints the text layer could not map. It stays distinct from `missing_glyphs`, which counts glyph IDs past the font's end.

**Zig changes in this pass:**
- `glyph_cache.zig`: a `missing_glyphs` counter and `noteMissingGlyph()`, a test that a zeroed key is gray, and a test that a gray and a mono key sharing a probe chain stay apart.
- `glyph_resolver.zig`: `resolve` takes a raster mode. Only gray is supported. Other modes fail with `UnsupportedRasterMode` before the cache is consulted. `resolveWithFallback` handles glyph IDs at or past the font's glyph count. The caller supplies the fallback, each missing request is counted once, and the missing glyph is never stored.
- `glyph_cache_font_test.zig`: tests for mode refusal, gray and mono separation, the fallback cases, glyph 0, the glyph-count boundary, and consistency between the resolved metrics, the cache entry, the pending upload rectangle, and the stored coverage.

**Mirror and checks in this pass:** 21 new test functions, 331 new checks. The synthetic glyph 0 has ink, like `.notdef`. Two new mutants (`MUT_ZERO_IS_MISSING` and `MUT_MISSING_OFF_BY_ONE`) break the missing-glyph rule and are caught. `checks/glyph_cache_parity.py` regenerates the Zig-to-mirror map. `checks/glyph_cache_RESULTS.txt` records the runs.

**Still open:**
- [ ] GPU upload and update synchronization under GPU debugging (needs the owner's device).
- [~] Both renderer modes on a device. The plan2d and flush logic is tested on the CPU only.
- [~] No queued draw samples a destroyed or repurposed page. This holds by design. Phase 5 must keep `Cache.clear` and `Atlas.deinit` behind a GPU-idle wait.
- [ ] Warm-up API and LRU eviction (optional "Wants"; not started).

**Numbering.** The source comments in `glyph_cache.zig` and `glyph_atlas.zig` still say "Phase 3 of the rendering migration plan". They are legacy and were left as they are. `glyph_resolver.zig` uses this plan's numbering.

**Next:** Phase 5 connects `resolve` and `resolveWithFallback` to `Canvas` and the text consumers, and calls `Atlas.flush` before the sprite upload. Phase 4 closes when `zig build test` passes on Windows, Linux, and macOS, and the two GPU items are checked on a device.

---

## Phase 5 — Shaped text layout and engine/UI integration

**Purpose:** Connect HarfBuzz output to the glyph providers and make the new text system usable throughout Bairava.

### Needs — must implement

- [ ] Shape a complete text run before measuring it for line placement. Use shaped advances/offsets rather than summing codepoint widths.
- [ ] Carry clusters through layout and only split lines at approved cluster/grapheme boundaries. Do not reuse the current codepoint-only long-word splitter for complex shaped runs.
- [ ] Define line-break policy for the first release. Start with explicit newlines and supported whitespace breaks; add full Unicode line-break conformance only as a separately scoped capability.
- [ ] Preserve baseline, ascent/descent, line height, blank-line, alignment, and pixel-snapping behavior for existing UI fonts.
- [ ] Produce glyph render records from the appropriate provider after shaping/layout: bitmap mapping, static BFNT, or runtime coverage cache.
- [ ] Add a common glyph-quad submission path supporting texture page, UV, plane bounds, tint/alpha, and render mode.
- [ ] Preserve or deliberately version `Canvas.text`, `textWidth`, `layoutText`, and `drawTextLayout` so game code does not have to manage glyph IDs or atlas pages.
- [ ] Migrate the debug overlay, developer console, widgets, sample scene, and game-owned text call sites.
- [ ] Preserve clipping, z-order, tint, alpha blending, pixel snapping, and integer viewport scaling.
- [ ] Keep rectangle drawing independent from font resources.
- [ ] Keep shaping, layout, and glyph cache tests separable from GPU visual tests.

### Wants — useful but not blocking

- [ ] Add text-run inspection to diagnostics: source range, glyph IDs, clusters, advances, selected font, and render mode.
- [ ] Add baseline and line-box debug visualization.
- [ ] Add an explicit text-measurement result that includes width, height, line count, and baseline-related metrics.

### Deliverable

The sample, UI widgets, developer console, and debug overlay use the shared text system. Outline fonts are shaped by HarfBuzz and rendered through the coverage path. Bitmap fonts continue to use their own provider but the same API/layout system.

### Exit gate — Phase 5 is complete only when

- [ ] Existing text consumers work without importing private text/renderer internals.
- [ ] Latin and Tamil reference strings render with correct glyph order, positioning, and cluster behavior.
- [ ] Measurements and wrapping match rendered results.
- [ ] Long strings, blank lines, missing glyphs, malformed UTF-8, and empty glyphs have deterministic behavior.
- [ ] The old BFNT path still passes visual and compatibility tests.
- [ ] Both existing renderer modes behave according to the agreed support matrix.

---

## Phase 6 — MSDF asset generation and rendering path

**Purpose:** Add scalable outline-font rendering without replacing bitmap or coverage rendering.

### Needs — must implement

- [ ] Integrate the selected MSDF generator as an offline asset-build tool, with a pinned version and reviewed license.
- [ ] Define a versioned MSDF asset descriptor containing font identity/metrics, glyph IDs, atlas page, atlas bounds, plane bounds, pixel range/distance range, and any generator parameters required at runtime.
- [ ] Generate MSDF from supported vector outlines. Do not make bitmap-to-vector conversion part of the normal asset pipeline.
- [ ] Validate the generator's handling of corners, small counters, thin strokes, punctuation, and the chosen font corpus.
- [ ] Add an MSDF font importer/loader that returns the same glyph-render-record interface as the bitmap and coverage providers.
- [ ] Add an MSDF fragment shader using the selected distance-field interpretation and correct screen-space range calculation.
- [ ] Extend the GPU sprite pipeline/run classification so normal sprites, coverage glyphs, and MSDF glyphs select the correct shader. A single `coverage: bool` is insufficient once MSDF is added; use an explicit render/material mode.
- [ ] Add per-texture sampling policy. The current global nearest sampler should remain for pixel art; MSDF assets need their validated sampling mode (normally linear) without changing unrelated textures.
- [ ] Extend shader generation/embedding for SPIR-V and the optional DXIL/MSL targets.
- [ ] Define SDL3 2D renderer behavior. Recommended initial policy: MSDF is rendered on SDL_GPU; an MSDF asset also supplies a prebaked coverage/bitmap fallback for the SDL3 2D renderer. If no fallback exists, report the unsupported mode clearly rather than sampling MSDF as ordinary RGBA.
- [ ] Test the same outline font through runtime coverage and MSDF at small, medium, and large sizes.
- [ ] Keep pixel fonts on the bitmap path even when their style resembles a vector outline.

### Wants — useful but not blocking

- [ ] Add MSDF atlas visualization tooling to inspect RGB distance channels and glyph rectangles.
- [ ] Compare atlas sizes, visual quality, memory, and draw performance against the coverage path.
- [ ] Support multiple MSDF atlas pages if the asset corpus requires them.

### Deliverable

An outline font can be generated offline into an MSDF asset, loaded at runtime, shaped by HarfBuzz, and drawn by the SDL_GPU MSDF pipeline. The secondary renderer has an explicit fallback behavior.

### Exit gate — Phase 6 is complete only when

- [ ] The same shaped glyph IDs and layout positions are used by coverage and MSDF paths.
- [ ] MSDF text remains visually stable across the agreed size range and avoids unacceptable corner/detail artifacts.
- [ ] MSDF sampling is configured independently from pixel-art nearest sampling.
- [ ] SPIR-V builds pass and optional DXIL/MSL shader paths compile where supported.
- [ ] SDL3 2D renderer fallback behavior is tested and documented.
- [ ] Hand-authored bitmap fonts are not modified or vectorized to use MSDF.

---

## Phase 7 — Font fallback, robustness, and production hardening

**Purpose:** Make the unified system reliable for real game content and changing runtime text.

### Needs — must implement

- [ ] Finalize missing-glyph behavior for each font provider: fallback glyph, explicit missing-glyph marker, or a reported unsupported character.
- [ ] Add a basic ordered font fallback chain if multi-language game content requires more than one font. Fallback selection must preserve clusters and shaping correctness; do not split a shaping cluster across fonts blindly.
- [ ] Define behavior for font unloading while text layouts or queued draws still reference it.
- [ ] Define cache and atlas memory ceilings and observable failure behavior.
- [ ] Test renderer/device recreation, texture upload failure, asset reload, repeated font load/unload, and shutdown ordering.
- [ ] Ensure a cache miss cannot cause unsafe atlas mutation during a draw already submitted to the GPU.
- [ ] Document that full bidi paragraph processing is separate from HarfBuzz shaping; add a bidi dependency/phase only if the engine's target language requirements need it.

### Wants — optional enhancements

- [ ] Subpixel positioning for smooth UI typography, only if it does not undermine pixel-font rendering.
- [ ] Variable-font axis selection.
- [ ] Rich-text spans with multiple fonts/styles in one paragraph.
- [ ] Font prewarming based on localization bundles or known dialogue.
- [ ] LRU cache eviction if telemetry shows page growth is too expensive.

### Deliverable

A stable font runtime with predictable fallback, memory limits, lifetime behavior, and diagnostics.

### Exit gate — Phase 7 is complete only when

- [ ] Missing glyph and fallback behavior is covered by automated tests.
- [ ] Font and atlas lifetime tests pass under repeated load/unload and renderer shutdown/recreation.
- [ ] Memory ceilings and cache exhaustion behavior are documented and observable.
- [ ] No known use-after-free or in-flight GPU resource hazard remains.
- [ ] Any deferred Unicode/bidi/font-format limitations are documented in the public text guide.

---

## Phase 8 — Cutover, regression suite, documentation, and cleanup

**Purpose:** Make the unified system the supported path without prematurely deleting compatibility code.

### Needs — must complete

- [ ] Run the full test suite: `zig build test`, `zig build test-ui`, `zig build check-assets`, and the repository's boundary/dependency checks.
- [ ] Run asset-builder tests for bitmap, BFNT, and MSDF inputs, including malformed and unsupported assets.
- [ ] Run CI on Linux, Windows, and macOS; verify the supported shader targets and C/C++ dependency linkage.
- [ ] Compare screenshots against Phase 0 baselines for existing UI, debug overlay, console, and widgets.
- [ ] Add visual reference tests for bitmap fonts, Latin shaping, Tamil shaping, and MSDF at multiple sizes.
- [ ] Profile cold-cache and warm-cache text workloads: shaping time, rasterization count, upload cost, cache hit rate, draw calls, memory, and frame time.
- [ ] Rewrite `docs/text.md` to explain font formats, asset authoring, rendering modes, supported shaping, sampling, fallback, and limitations.
- [ ] Update README asset-pipeline notes and public API documentation.
- [ ] Update dependency policy/lock records for HarfBuzz and the MSDF generator (and runtime FreeType if selected).
- [ ] Decide the status of old C text code: keep it as a BFNT compatibility adapter or remove it only after all consumers have migrated and compatibility tests prove it is unused.
- [ ] Preserve old `.bfnt` assets or provide a deterministic migration tool before changing/removing a format.

### Wants — useful but not blocking

- [ ] Publish a font-authoring guide with examples for bitmap, BFNT coverage, and MSDF assets.
- [ ] Add a benchmark scene comparing text paths under the same content and display settings.

### Deliverable

A documented, tested, multi-source text/font system with an explicit supported-feature matrix and no regression in existing game rendering.

### Exit gate — migration is complete only when

- [ ] All required CI jobs pass.
- [ ] All Phase 0 visual baselines are accepted or intentional differences are documented.
- [ ] All four required font paths work through the same public text API.
- [ ] Runtime text works with unseen glyphs and repeated cache hits.
- [ ] No renderer replacement or unrelated rendering subsystem rewrite was needed.
- [ ] Documentation and dependency records match the actual implementation.

---

## 7. Recommended implementation order at a glance

| Order | Phase | Primary result | Must be true before proceeding |
|---:|---|---|---|
| 0 | Baseline and decisions | Agreed capability and compatibility matrix | All format, shaping, renderer, and dependency decisions resolved |
| 1 | Shared model and compatibility | One font/text contract over existing BFNT | Existing text is unchanged and public API boundary is stable |
| 2 | Bitmap importer and renderer | First-class hand-authored pixel fonts | Atlas and metadata validation plus visual pixel-accuracy tests pass |
| 3 | HarfBuzz and runtime font face | CPU shaping service | Cross-platform dependency build and shaping fixtures pass |
| 4 | Runtime rasterizer and glyph cache | On-demand coverage glyphs | Cache, upload, atlas lifetime, and synchronization tests pass |
| 5 | Shaped layout and UI integration | New text system used by engine consumers | Latin/Tamil layout, measurement, and UI regression tests pass |
| 6 | MSDF generation and renderer | Optional scalable outline path | Shader, sampling, visual, and secondary-renderer fallback tests pass |
| 7 | Fallback and hardening | Predictable runtime behavior | Memory, lifetime, missing-glyph, and error behavior are covered |
| 8 | Cutover and documentation | Supported unified subsystem | Full CI, visual baselines, docs, and dependency records pass |

This order is deliberate: bitmap fonts become usable early; HarfBuzz and runtime coverage are introduced without destabilizing the current UI; MSDF is added only after the shared shaping/layout/provider contracts are proven.

---

## 8. Cross-cutting test strategy

### 8.1 Test assets

Maintain a small checked-in test corpus with:

- A hand-authored pixel font atlas and descriptor, including punctuation, digits, spaces, and a fallback glyph.
- Existing `.bfnt` v4 UI/debug assets and representative legacy BFNT fixtures supported by the loader.
- A TrueType outline font suitable for Latin shaping and kerning tests.
- A font with appropriate Tamil OpenType shaping tables and known expected output.
- An outline font baked to MSDF for visual comparison against coverage rendering.
- Missing-glyph and malformed-font/descriptor fixtures.

### 8.2 CPU tests

- UTF-8 valid/invalid decoding.
- Codepoint mapping and missing-glyph resolution.
- HarfBuzz output: glyph IDs, clusters, advances, offsets, direction, script, and language.
- Font metrics and baseline conversion.
- Bitmap descriptor parsing and validation.
- Glyph-cache keys, hit/miss behavior, atlas packing, and page exhaustion.
- Line wrapping at cluster-safe boundaries and measurement consistency.
- Resource ownership and font destruction.

### 8.3 Renderer / visual tests

- Bitmap font at native resolution and integer-scaled output.
- Existing mono and gray BFNT text.
- Runtime coverage text with cold and warm glyph caches.
- MSDF text at small, medium, and large sizes.
- Correct tint/alpha, clipping, z-order, and batching.
- SDL_GPU and SDL3 2D behavior for every supported mode/fallback.
- Renderer switching, window resize, GPU upload completion, and shutdown.

### 8.4 Regression commands

At minimum, preserve the repository's existing checks and add any new font-specific targets:

```sh
zig build test
zig build test-ui
zig build check-assets
zig build asset-build
python scripts/check-dependency-pins.py
python scripts/boundary_scan.py --fail
```

Run the supported CI platform matrix before declaring the migration complete. The dependency/build phase must prove HarfBuzz and any MSDF tooling can be built or invoked reproducibly on the supported development platforms.

---

## 9. Major risks and explicit mitigations

| Risk | Why it matters | Mitigation / decision |
|---|---|---|
| Treating bitmap fonts as outline fonts | Vectorizing hand-drawn pixels can alter their intended shapes | Keep bitmap import as its own first-class provider; do not route it through MSDF |
| Glyph ID/codepoint confusion | HarfBuzz may return glyph IDs that differ from Unicode codepoints | Cache and rasterize by font identity + glyph ID; retain clusters for source mapping |
| CFF regression | Current offline pipeline has a FreeType CFF path; stb runtime support is not equivalent | Decide supported formats in Phase 0; keep BFNT/FreeType path or integrate FreeType at runtime |
| Shaping/layout conflation | Codepoint-based wrapping can split shaped clusters | Shape runs first; layout from advances and break only at safe boundaries |
| HarfBuzz mistaken for complete Unicode layout | HarfBuzz shapes runs but does not by itself resolve paragraph bidi or all line-breaking behavior | Scope direction/bidi and line-break policy explicitly; add separate components if required |
| Dynamic atlas mutation during rendering | GPU may still be sampling a page when CPU code repacks or replaces it | Use frame-safe uploads, stable page lifetime, and deferred destruction |
| Current sampler is globally nearest | MSDF requires a different, tested filtering policy | Add sampler policy per texture/material; do not change pixel-art defaults globally |
| MSDF on SDL3 2D path | Existing 2D renderer path has no equivalent custom MSDF shader path | Provide prebaked coverage/bitmap fallback or explicitly gate MSDF on SDL_GPU |
| Existing rectangle depends on font atlas | New atlas sources may not contain a white texel | Decouple primitive rectangles in Phase 1 |
| Build-system and platform complexity | HarfBuzz introduces C/C++ and platform-linking work; MSDF adds a host tool | Pin dependencies, prove cross-platform builds early, and keep asset generation offline |
| Premature removal of BFNT | Existing assets and UI may still depend on BFNT behavior | Keep a compatibility adapter until all consumers and fixtures are migrated |

---

## 10. Final acceptance checklist

The migration is accepted when all of the following are true:

- [ ] One public text API supports bitmap, BFNT coverage, runtime coverage, and MSDF-backed fonts.
- [ ] Bitmap assets preserve hand-authored pixels and use nearest sampling.
- [ ] Existing BFNT assets continue to load or have a verified conversion path.
- [ ] Outline text is shaped through HarfBuzz and glyphs are resolved by glyph ID.
- [ ] Shaped clusters, advances, and offsets survive into text layout.
- [ ] Runtime coverage glyphs are rasterized on cache misses and reused on cache hits.
- [ ] MSDF is generated offline and uses its own shader/sampling policy.
- [ ] The SDL3 2D renderer has an explicit, tested fallback for MSDF assets.
- [ ] Text layout and glyph rendering remain independent subsystems.
- [ ] `Canvas`, widgets, console, diagnostics, and sample code use the common API.
- [ ] Atlas lifetime, GPU upload synchronization, font unloading, and cache limits are tested.
- [ ] Existing visual baselines and the full supported CI matrix pass.
- [ ] `docs/text.md`, dependency records, and public API documentation describe the actual implementation.

## 11. Final recommendation

Adopt the merged architecture, but migrate incrementally:

1. Stabilize the shared font/text contracts and preserve BFNT.
2. Add hand-authored bitmap font import and nearest rendering first.
3. Integrate HarfBuzz and an outline-font face.
4. Add runtime coverage rasterization and a glyph cache.
5. Move layout and all engine text consumers onto shaped runs.
6. Add MSDF as an optional offline asset/rendering path.
7. Harden fallback, resource lifetime, renderer parity, and tooling.

**Architecture 1 is the text engine. Architecture 2 supplies the font formats and glyph-rendering strategies.** Keeping that boundary is what allows Bairava to gain richer typography without losing pixel-font fidelity or rewriting its renderer.
