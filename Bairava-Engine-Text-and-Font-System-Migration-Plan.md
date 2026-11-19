# Bairava Engine — Text and Font System Migration Plan

**Status (updated 2026-11-19):** Phase 0 decisions D-01 through D-06, D-08, D-09, and D-12, and D-21 (2026-11-19), are accepted as recorded in section 6.2. D-22 (`FontStore` API) is accepted subject to four boundary constraints (2026-11-19). E-03 is done with caveat by owner waiver (2026-11-19; section 6.4). E-01 is passed on commit `f4abef0f7528e36658eb1d5c106d88b9f1769ded` (Windows, Linux, macOS; evidence in section 6.4). **Phase 1 provider dispatch, Phase 2 bitmap-font implementation, and the Phase 4/5 atlas submit/flush path are integrated in the current worktree.** `zig build`, `zig build test` (749/749 by direct test executable), `zig build check-assets`, and `scripts/boundary_scan.py --fail` pass on Windows. The D-21 surface scan is clear. Runtime glyph drawing now submits page-aware quads through the common path; the runtime flush runs once before either renderer path. E-02's GPU-debug burst run is recorded at `checks/glyph_atlas_gpu_validation.txt`: 600 inked glyphs, 600 new glyphs, 600 region uploads, zero full-page rewrites, zero missing 2D copies, and zero diagnostic failures. Phase 1, 2, 3, 4, and 5 exit gates remain open where their visual, 2D-renderer, or other exit evidence is still outstanding; this status does not represent a phase as closed.
**Phase 6 implementation update (2026-11-19):** msdfgen 1.13.0 is pinned and restricted to the offline asset builder. The builder emits MFNT v1 with RGBA8 MSDF and an R8 coverage sibling, enforcing D-26's 1024×1024 per-font cap. `zig build asset-build`, `zig build test` (763/763), `zig build check-assets`, `zig build -Ddxil=true -Dmetal=true`, the dependency-pin check, and the boundary scan pass on Windows. Device/visual acceptance remains open; this implementation update does not close Phase 6.

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

| Font path | Glyph source | Shared behavior (both renderers) | SDL_GPU behavior | SDL3 2D behavior | Limits and unsupported features |
|---|---|---|---|---|---|
| Hand-authored bitmap (pixel-art fonts) | Imported atlas and BMFont-style descriptor (D-08, D-09). The original bitmap is kept and is never converted to MSDF. | Codepoint mapping through the descriptor; metrics, kerning, and fallback from the descriptor; nearest sampling; common text API and `SpriteBatch` submission. | Coverage or RGBA pipeline by atlas type, nearest sampling. | Same texture path with nearest sampling. No GPU-only feature is used. | Basic mapper only: no ligatures or complex-script shaping. No MSDF. |
| Existing `.bfnt`, as a BFNT compatibility adapter (temporary, D-19) | Prebaked R8 coverage atlas loaded from file. | Loaded as a provider in the unified `FontResource` model; the file format is unchanged. Measurement routes through the Zig port `bfnt_measure.zig`, parity-checked against text.c (uncompiled in the sandbox). Drawing still runs in text.c (in progress, see Phase 5). | Nearest coverage pipeline, static atlas (not the dynamic cache). | Same R8 coverage page through the ordinary texture path. | Legacy mapping during transition. The adapter is removed in a later, separate cleanup. |
| Runtime outline coverage (dynamic text, scalable outline fonts) | TrueType `glyf` face (D-10), rasterized on demand per glyph ID with `stb_truetype`. | HarfBuzz shaping with default features (D-16); shaped layout; glyph cache keyed by font ID, glyph ID, size, and mode; the four-page R8 atlas (D-14). | Dynamic coverage pages uploaded to an SDL_GPU texture, with flush before sprite submission. | The same R8 pages in the 2D backend's own texture form, one resource only (D-14); flush on the 2D frame path (Phase 5). | No CFF or CFF2 (D-10). No runtime FreeType (D-11). Horizontal LTR only (D-06). Missing glyphs use the caller's fallback (D-13). No fallback chain and no eviction. |
| MSDF (scalable outline fonts, UI) | Offline msdfgen (target 1.13.1, pin OPEN, D-17) output from vector outlines (D-17, D-24, D-25). Not derived from the coverage asset or from any bitmap. | The same shaped glyph IDs and layout positions as the coverage path; descriptor metrics; common text API. | MSDF fragment shader (median of RGB), with linear sampling set per texture. | Not rendered. The 2D path uses the coverage or bitmap asset generated from the same source font (D-18, D-24). | SDL_GPU only (D-18). No runtime MSDF generation. No bitmap-to-vector conversion. The MSDF atlas memory limit is not yet decided (D-14 covers only the runtime coverage atlas). |

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

## 6.1 Gate model

Each phase has four parts that close separately:

1. **Decisions.** Owner choices that change a format, an API, or a dependency. They are listed in section 6.2 with an ID (`D-xx`). Code can propose a decision but cannot settle one. A phase's implementation does not start until its decisions are Accepted.
2. **Implementation.** The Needs and Wants lists. Each item is done, partly done, not started, or N/A (section 6.3).
3. **Environment.** Validation that needs a toolchain or hardware the work environment may not have (`E-xx`, section 6.4). An environment gate closes only on a recorded run.
4. **Exit gate.** The phase's exit criteria. A phase closes only when they pass, are reviewed, and are recorded here.

Gate policy: do not start a phase's implementation until its decisions are Accepted. Do not start the next phase simply because the current code compiles. A phase may be split into smaller PRs, but its gate remains mandatory.

**Current state (updated 2026-11-19).** Phase 1 and Phase 2 implementation are integrated, with their visual/device exit gates still open. Phase 3 shaping expectations have been checked against the pinned HarfBuzz tree; Phase 3 remains open until the Phase 1 and 2 exit gates are recorded. The production Session owns the runtime atlas, `FontStore` submits page-aware quads, and `runtime.zig` performs the one atlas flush before either renderer path. E-02's GPU-debug burst and synchronization run is recorded in section 6.4. E-04 and the remaining visual/exit checks are still open.

## 6.2 Decision register

Status values: **Accepted** (with the date), **Accepted by direction** (an owner instruction, recorded here), or **Open** (a proposal that is not in force). Proposals in this table are not in force until they are accepted.

Phase 1 decisions come first. They fix the font representation, the `Canvas` API boundary, and the overlay font, and Phase 5 depends on all three. Starting Phase 5 before they are resolved risks rework.

| ID | Decision | Needed before | Status |
|---|---|---|---|
| D-01 | **One public `FontHandle` backed by a registry-owned `FontResource` tagged union** for bitmap, BFNT coverage, runtime coverage, and MSDF providers. The registry owns provider resources; game-facing code uses the handle and does not know the provider. | Phase 1 | **Accepted (owner, 2026-11-18)** |
| D-02 | **Opaque registry-issued `FontId` (`u64`)**. Zero is invalid; IDs are never reused during the process lifetime; stale handles fail explicitly; exhaustion fails rather than wrapping. | Phase 1 | **Accepted with clarification (owner, 2026-11-18)** |
| D-03 | Store font identity once on `ShapedRun`, not on every `Glyph`, until a font-fallback chain exists. | Phase 1 | **Accepted (owner, 2026-11-18)** |
| D-04 | `Canvas.rect` must use a renderer-owned 2×2 white texture, created independently of font resources and atlas pages. | Phase 1 | **Accepted (owner, 2026-11-18)** |
| D-05 | Preserve existing `Canvas.text`, `textWidth`, `layoutText`, and `drawTextLayout` signatures; change internals through adapters. New functionality is additive; do not require game code to manage glyph IDs or atlas pages. | Phase 1 (required by Phase 5) | **Accepted (owner, 2026-11-18)** |
| D-06 | First release is horizontal LTR only; no RTL or paragraph bidi. Script and language remain explicit caller-controlled options, with compatibility defaults `Latn` and `en`; do not guess them. Tamil callers specify `Taml` and `ta`. | Phase 1 | **Accepted with clarification (owner, 2026-11-18)** |
| D-07 | Debug overlay and console font: one definition, 9 px mono, `assets/ui_font_9px.bfnt`. Defined once in `application.zig` (`default_debug_font_path`, `default_debug_font_px`); `src/game/config.zig` reads it. | Phase 1 | Accepted by direction (owner, 2026-11-18): preserve 9 px. Code verified at 9 px in this upload (`application.zig:40`, read by `config.zig:108`), owner-confirmed 2026-11-18. |
| D-08 | **Use the established AngelCode BMFont text descriptor format** for hand-authored bitmap font metadata. Parse/import it into Bairava-owned normalized structures; do not expose BMFont types as public engine API. | Phase 2 | **Accepted with change (owner, 2026-11-18)** |
| D-09 | Use `dhepper/font8x8` `font8x8_basic` as the initial 8×8 monochrome ASCII pixel-font source, pinned to commit `4876b70490600222f30bb9acd2c02868e390bb56`. Include printable ASCII U+0020–U+007E; 16 columns × 6 rows (128×48 atlas); fixed 8-pixel advance; space has no ink; `?` is the initial fallback. The repository identifies the font data as public domain. The asset still must be generated/imported, checked in, and covered by descriptor/importer tests. | Phase 2 | **Accepted; asset generated 2026-11-19 from the pinned commit (see the Phase 2 sandbox progress block). Page route decided 2026-11-19 (`coverage` rows, `.r8`); the D-09 asset contract is in the Phase 2 sandbox progress block.** Generate the asset only from the pinned commit `4876b70490600222f30bb9acd2c02868e390bb56`, verified by its SHA, with its license notice. Do not substitute another revision. Phase 2 remains blocked until this is done. |
| D-10 | **Runtime outline formats: TrueType outlines only.** Runtime rasterization stays on the existing `stb_truetype` path. CFF/CFF2 outline rasterization is deferred. Unsupported outline formats are rejected with an explicit error (`UnsupportedFontFormat`), and the engine never substitutes a glyph silently. Variable fonts use their default instance. | Phase 0 exit; Phase 3 | **Accepted (2026-11-19)** |
| D-11 | **FreeType is not a runtime dependency.** It is a build-time dependency only where the font asset pipeline requires it. The selected MSDF generator's font-import extension uses FreeType, so FreeType may be a toolchain dependency; it is not shipped or linked into the game runtime. | Phase 0 exit | **Accepted (2026-11-19)** |
| D-12 | Scripts and test corpus: Latin and Tamil. **Chemmozhi Paranar may remain in the distributed repository only as a test fixture**, with its exact upstream license text/version, copyright and modification attribution, provenance, and hash retained. It must not be silently included in game assets, binaries, or release packages. Any downstream redistribution must comply with the actual GPL version attached to the font. | Phase 0 exit | **Accepted with test-only restriction (owner, 2026-11-18)** |
| D-13 | Missing runtime glyphs resolve once, after shaping, to the same face's recorded `?` glyph. If that face has no `?`, draw no ink. Do not add a font fallback chain unless real content requires a second face; any chain must preserve shaping clusters. | Phase 0 exit; Phase 4; Phase 7 | **Implemented per Phase 7 requirement; CPU tests cover unmapped codepoints, invalid glyph IDs, and no-`?` behavior.** |
| D-14 | **Atlas memory ceiling: 4 MiB for the runtime coverage atlas per session**, as four 1024×1024 R8 pages. No automatic page growth beyond four, and no eviction. Exhaustion produces the existing explicit failure path (`AtlasFull`, counted). CPU staging and shadow copies are reported separately from the GPU figure. No additional 4 MiB allowance for SDL3 2D. No simultaneous duplicate atlas allocation for different renderers. A backend may use its own representation within the same ceiling, but separate backend resources must not coexist as duplicate full atlas copies. | Phase 0 exit; Phase 4; Phase 5 | **Accepted (2026-11-19; amended 2026-11-19)** |
| D-15 | **Performance targets.** 60 FPS, a 16.67 ms frame. Text subsystem budget: ≤ 1.0 ms CPU time at p95 in a defined steady-state workload of 2,000 visible glyphs. No steady-state per-frame allocations. Batching avoids per-glyph draw calls. Cold glyph rasterization and atlas uploads are measured separately from steady-state submission. These are acceptance targets, not a claim that current hardware has passed them. | Phase 0 exit; Phase 7 | **Accepted (2026-11-19)** |
| D-16 | **OpenType features: HarfBuzz's default feature set in the first release.** Script and language remain caller-configurable as designed. No feature-configuration API is added now. If feature configuration is needed later, it is added to the shaping options and does not change the glyph cache, atlas, `FontStore`, `SpriteBatch`, or renderer. This is a scope restriction, not an architectural reversal. | Phase 3 | **Accepted (2026-11-19)** |
| D-17 | **MSDF generator: msdfgen 1.13.0**, pinned to commit `1874bcf7d9624ccc85b4bc9a85d78116f690f35b`; the dependency's MIT license ships with the vendored source. The build configuration and dependency boundary are recorded in D-25. | Phase 0 exit; Phase 6 | **Accepted by owner direction (2026-11-19)** |
| D-18 | **MSDF on the SDL3 2D renderer: none in the first release.** The 2D path uses a coverage or bitmap glyph asset generated from the same source font (D-24). MSDF rendering is SDL_GPU-only, because MSDF reconstruction needs a median-of-RGB fragment operation that SDL's 2D geometry API does not provide. Custom GPU render state is a separate capability, not a hidden requirement of the SDL3 2D backend. | Phase 0 exit; Phase 6 | **Accepted (2026-11-19)** |
| D-19 | **Old C text path: retained temporarily as a BFNT compatibility adapter.** Keep the ability to load existing BFNT assets. Adapt their data into the unified font-resource and provider model. Route drawing, measurement, shaping, and layout through the common text API. Do not keep a second, independent C text-rendering pipeline indefinitely. Remove the adapter later, as a separate cleanup, once all consumers and assets have migrated. BFNT is one font provider, not a separate text engine. | Phase 8 | **Accepted (2026-11-19)** |
| D-20 | BFNT metrics for `FontMetrics`: a BFNT font's descent is `line_height` minus `ascent`, and its line gap is zero, because the file stores neither. This changes no file format and only affects `FontMetrics`. | Phase 1 | **Accepted (owner, 2026-11-18)** |
| D-21 | **Public API boundary: the strict gate is retained.** No HarfBuzz type and no internal font-resource type (`FontResource`, `Resources` or any `Registry` instance, a provider type, `font.zig`'s `Font`, or `c.ui_font`) may appear in a game-facing interface: an export of `bairava.zig`, a `Context` or `Canvas`/`Ui` signature, or a field or return type that game code can reach. The gate is not amended to allow either type. Game code holds `FontHandle` only. Enforced by the D-21 section of `scripts/boundary_scan.py`. The debt list `D21_DEBT` is empty: no exposure is allowed (owner decision, 2026-11-19). | Phase 1 | **Accepted by owner direction (2026-11-19). Debt list emptied by owner direction (2026-11-19): no allowances.** |
| D-22 | **`FontStore` API.** The session's opaque `FontStore` owns font resources. Game-facing code reaches fonts only through `FontHandle` and the `FontStore` methods. Accepted subject to four boundary constraints: (1) `FontStore` owns font resources; (2) game-facing APIs expose `FontHandle` and plain `FontMetrics`, not internal font resources; (3) HarfBuzz and SDL types remain hidden from game-facing code; (4) the strict D-21 scanner enforces the boundary, with `D21_DEBT` empty. | Phase 1 | **ACCEPTED, subject to four boundary constraints (owner, 2026-11-19).** Acceptance is not Phase 1 completion and does not pass the D-21 implementation gate. |
| D-23 | **SpriteBatch shape: explicit Z ordering is the contract.** (1) `SpriteBatch.Options.z` is the depth or layer the caller supplies. (2) Sprites with equal Z keep their insertion order. (3) `SpriteBatch` does not infer depth from entity positions or `feet_y`. (4) The world or rendering layer computes position-based depth and supplies the resulting Z. (5) Explicit ordering stays available for background, world, and foreground elements. `Canvas.queue` and `Ui.queue` keep the `(batch, z)` signature. No change to the existing SpriteBatch contract, and no automatic sorting by entity position. | Phase 1 (item 378); Phase 5 | **Accepted (2026-11-19)** |
| D-24 | **Asset pipeline outputs.** For each outline source font, asset import generates a separate coverage-font asset from that same source font. It is not derived from the generated MSDF texture. Outputs: an MSDF asset for SDL_GPU shader-based rendering; a coverage/bitmap glyph asset for SDL3 2D ordinary texture rendering. Bitmap fonts keep their original bitmap representation and are not forced through MSDF conversion. | Phase 5 (2D asset); Phase 6 (MSDF asset) | **Accepted (2026-11-19)** |
| D-25 | **MSDF dependency boundary and generation pipeline.** msdfgen 1.13.0 is pinned at commit `1874bcf7d9624ccc85b4bc9a85d78116f690f35b` (D-17). The offline builder compiles the core and `ext/import-font` sources, with vendored FreeType 2.15.0; it does not compile msdfgen into the game. SVG, PNG, and variable-font support are disabled; TinyXML2, libpng, Skia, and OpenMP are not linked. The upstream MIT `LICENSE.txt` ships with the vendored source. The existing stb_rect_pack algorithm reserves a rectangle per glyph; the importer loads each outline, generates the floating-point three-channel MSDF, converts it to the packed RGBA8 atlas, and bakes the matching R8 coverage sibling. The importer does not write into the coverage atlas. | Phase 0 exit; Phase 6 | **Accepted and implemented (2026-11-19)** |
| D-26 | **MSDF atlas pixel format, memory ceiling, and packer.** The baker packs with the existing stb_rect_pack algorithm and converts msdfgen's floating-point, three-channel output to RGBA8. Each font atlas is limited to 1024×1024: 4 MiB RGBA8 MSDF plus 1 MiB R8 coverage sibling, 5 MiB combined per font. Reject generation if the glyphs do not fit; never truncate glyphs or grow the atlas. This is a per-font cap, not a global budget across loaded fonts. D-14 covers only the runtime coverage atlas. The runtime coverage cache uses shelf packing. | Phase 6 | **Accepted by owner direction (2026-11-19)** |
| D-27 | **Phase 2 descriptor contract.** The on-disk source descriptor is the BMFont text file (D-08). Phase 2 adds no separate Bairava disk format. The normalized in-memory `Font` in `src/engine/text/bmfont.zig` is the versioned contract, with an explicit `schema_version`, starting at 1. The importer converts BMFont data into it. A compiled Bairava format is deferred until loading performance, packaging, or runtime constraints show a real need. | Phase 2 | **Accepted (owner, 2026-11-19)** |
| D-28 | **Phase 2 kerning strictness.** A kerning pair that names a glyph the font does not map is an import error. It is never dropped silently. The error reports the pair, the line it came from, and the unmapped BMFont `id`, which is the codepoint. Bairava has no separate glyph index yet (Phase 2, item 2). | Phase 2 | **Accepted (owner, 2026-11-19)** |

## 6.3 Status markers

- `[x]` done, with the evidence in the item.
- `[~]` partly done. The item names what is missing.
- `[ ]` not done. Nothing blocks it except the work itself, unless the item says `Blocked: D-xx` or `Blocked: E-xx`.
- `[-]` N/A. The item gives the reason and its evidence. N/A is not work left over, and it does not hold a gate open.

An item is N/A only by evidence (for example, a file that never calls the text API) or by an accepted decision. Difficulty is never a reason. An item that is not N/A and not done is incomplete, and it stays open until it is done or the plan changes.

## 6.4 Environment gates

These gates need a toolchain or hardware the work environment may not have. Each one closes only on a recorded run: a CI job link, a log file, or a screenshot path, tied to the commit it ran on. Sandbox evidence (CPU tests, C mirrors, characterization harnesses, static checks) is recorded, but it does not close an environment gate. An owner waiver is different: it is recorded as a waiver, with its caveat, and is not counted as a run (see E-03).

- **E-01, pinned toolchain and CI — PASSED.** GitHub Actions run [#112](https://github.com/ash5me/Bairava-Engine/actions/runs/44223038398), commit `f4abef0f7528e36658eb1d5c106d88b9f1769ded`, used Zig `0.16.0-dev.3142+5ccfeb926`. Linux job [ubuntu-latest](https://github.com/ash5me/Bairava-Engine/actions/runs/44223038398/job/134529366519), Windows job [windows-latest](https://github.com/ash5me/Bairava-Engine/actions/runs/44223038398/job/134529366769), and macOS job [macos-latest](https://github.com/ash5me/Bairava-Engine/actions/runs/44223038398/job/134529366794) all completed successfully. Each job passed development, debug, and release builds, asset checks/importer CLI checks, and unit/UI tests; macOS also passed its Metal shader build. This closes the pinned-toolchain compile/CI evidence for the code at that SHA, including the Phase 3 HarfBuzz build/test check. It does **not** close Phase 4's GPU burst/synchronization gate, Phase 5's flush/device/visual checks, or any phase implementation exit. E-01 evidence is commit-specific; rerun it after relevant code changes.
- **E-02, GPU device with validation — PASSED (Windows, 2026-11-19).** `zig build run -Dgpu-debug=true`, with the diagnostic enabled, ran on a display with an SDL_GPU device. Evidence: `checks/glyph_atlas_gpu_validation.txt`. The burst resolved 600 inked glyphs, all 600 new, and the shared flush uploaded 600 regions with zero whole-page rewrites; the run reported zero failures and zero missing 2D copies, with no GPU validation errors. The burst's expected whole-page upload was superseded by the synchronization fix: overflow now spills individual rectangles, and only explicit full-page uploads cycle the destination. This closes E-02's GPU-debug burst/synchronization run, not the Phase 4/5 exit gates or E-04's SDL3 2D device run.
- **E-03, reference screenshots — DONE WITH CAVEAT (owner waiver, 2026-11-19).** Capture on the current BFNT path, in both renderer modes, before any `Canvas` change: `ui_font_9px` text, the debug overlay, and the widgets. Closes: the Phase 0 baseline, the Phase 1 comparison, the Phase 5 visual exit, and Phase 8. *Caveat:* the owner marked this gate done. The repository records no screenshot, log, or commit for the visual comparison, so this is a waiver and not a recorded run. The waiver closes the gate only. The capture items that name E-03 stay `[ ]` until their own images are recorded, and the repository holds no evidence for either renderer mode. E-04 (the SDL3 2D device run) is still open.
- **E-04, SDL3 2D renderer on a device — OPEN.** Requires `sdl2d_available` to be set (`application.zig`) and the 2D path to run. Closes: the Phase 4 and Phase 5 both-renderer items, the Phase 6 MSDF fallback, and the Phase 7 device-recreation tests.

## 6.5 N/A and conditional items

Two kinds appear here, and they are kept apart.

- **Evidence N/A.** Marked `[-]` in the item. The sample scene's text migration: `sample/main.zig` and `sample/benchmark.zig` draw textures only and call no text API. Owner direction (2026-11-18): mark it N/A rather than leave it as unfinished work. Rich-text spans are also N/A, because they are a non-goal in section 3.
- **Conditional items.** Their status depends on a decision that is still open, so they stay `[ ]` with a note until the decision is Accepted. D-08 is accepted; the BMFont importer remains implementation work. Configurable OpenType features are N/A for the first release by D-16 (accepted 2026-11-19). Variable-font axis selection depends on D-10. Multiple MSDF atlas pages depend on the asset corpus.

## Phase 0 — Baseline audit and design decisions

**Purpose:** Remove ambiguity before changing formats, dependencies, APIs, or renderer behavior.

**Decisions to record here:** D-08, D-10 to D-15, D-17, D-18 (section 6.2). All are accepted: D-08 on 2026-11-18, the rest on 2026-11-19. **Environment:** E-03 for the baseline screenshots.

### Needs — must complete

- [x] Inventory all font load, measure, draw, and layout call sites in engine, sample, game, overlay, console, widgets, and tests. Evidence: the call-site inventory in the Phase 0 decision sheet. The sample draws no text, so its part is N/A (section 6.5).
- [~] Record current public behavior: font pixel-height rules, baseline/top-left convention, ascent/line-height, kerning, fallback glyph, UTF-8 error behavior, wrapping, alignment, color/alpha, clipping, and pixel snapping. C runtime: `docs/Bairava_Phase0/characterization/harness.c` passes 70 of 70 (gcc 13.3, `-std=c11 -Wall -Wextra -pedantic`, no warnings). The Zig side has not been run (E-01).
- [ ] Capture reference screenshots for current UI/debug text in both GPU and SDL3 2D renderer modes. Blocked: E-03.
- [x] Define the first supported language/test corpus: Latin and Tamil, including combining marks and conjunct fixtures. Chemmozhi Paranar is accepted as a test-only GPL fixture under D-12.
- [x] Decide the initial runtime outline-font support matrix. `stb_truetype` is already present, but CFF support is currently handled by the offline FreeType bake path; do not silently regress it. → D-10. *(Done: D-10 accepted 2026-11-19. TrueType outlines only at runtime, on `stb_truetype`. CFF/CFF2 rasterization is deferred. Unsupported formats return `UnsupportedFontFormat`.)*
- [x] Decide whether runtime rasterization supports TrueType `glyf` only initially, or whether FreeType must also move into the runtime for CFF. → D-10, D-11. *(Done: D-10 and D-11 accepted 2026-11-19. TrueType `glyf` only, and FreeType is not a runtime dependency. `build.zig` links FreeType only into the asset builder and the UI test harness.)*
- [x] Decide the bitmap descriptor format: AngelCode BMFont text descriptor, normalized into Bairava-owned structures (D-08).
- [~] Decide which MSDF generator will be used, its license, version pin, supported font formats, output metadata, and asset-builder integration. → D-17. *(Partly: D-17 accepted 2026-11-19, msdfgen target 1.13.1 (pin OPEN, D-17); v1.13 is a research reference only. Still open: the license check at the pinned revision, the supported font formats, the output metadata, and the asset-builder integration. The sandbox cannot fetch the source.)*
- [x] Decide fallback behavior for missing glyphs and whether font fallback chains are part of the first release or a later phase. → D-13. *(Done: D-13 accepted 2026-11-17. Caller-supplied fallback glyph; no font chain in the first release; mapping `?` and font chains move to Phase 7.)*
- [x] Decide the initial renderer policy for MSDF. Recommended: SDL_GPU first; the SDL3 2D renderer uses a matching prebaked coverage/bitmap fallback until it has an equivalent shader path. → D-18. *(Done: D-18 accepted 2026-11-19. No MSDF on the SDL3 2D path; coverage or bitmap glyphs there; MSDF is SDL_GPU-only.)*
- [x] Define atlas growth, maximum pages, memory budget, and whether eviction is required for the first release. → D-14. *(Done: D-14 accepted 2026-11-19. Four 1024 by 1024 R8 pages, 4 MiB; no growth beyond four; no eviction. `max_page_count` is lowered to four in `glyph_cache.zig` and the C mirror, with refusal checks.)*
- [x] Define success metrics: no visual regression for existing fonts, correct shaping fixtures, no duplicate rasterization for cache hits, and acceptable cold/hot text performance. → D-15. *(Done: D-15 accepted 2026-11-19 for the frame and text budgets. The no-visual-regression and no-duplicate-rasterization criteria are carried into the Phase 1 and Phase 4 gates.)*

### Wants — useful but not blocking

- [ ] Add a small typography reference scene with Latin, Tamil, punctuation, numbers, and multiple font sizes.
- [ ] Add a script or test fixture to compare rendered screenshots at the engine's native resolution and integer scales.

### Deliverable

A reviewed design decision record containing: supported font formats, font-source matrix, shaping scope, renderer fallback policy, dependency plan, public API compatibility plan, cache/atlas policy, and test corpus.

### Exit gate — Phase 0 is complete only when

- [x] Every required font source has an agreed import/runtime path. *(Evidence: D-08 for bitmap fonts; D-10 and D-11 for runtime TrueType; the existing `.bfnt` prebaked path; D-17 and D-18 for offline MSDF on SDL_GPU only.)*
- [x] TrueType/CFF behavior is explicitly decided (D-10 and D-11 accepted 2026-11-19).
- [~] HarfBuzz and MSDF dependency/tooling choices are explicit and licensable. *(HarfBuzz 15.1.0 is locked at commit `3df40d9`. MSDF target is msdfgen 1.13.1 (D-17, pin OPEN). Its license is MIT per the upstream license text and package metadata (2026-11-19). The 1.13.1 tag's `LICENSE.txt`, the API, the CMake options, and the dependency graph are still to be confirmed. v1.13 is a research reference only.)*
- [x] SDL_GPU and SDL3 2D behavior for every rendering mode is documented.
- [ ] Existing behavior has baseline tests or screenshots (E-03 is done with caveat by owner waiver, 2026-11-19; see section 6.4).
- [x] No unresolved design question would force a data-format or public-API rewrite in a later phase. All Phase 0 decisions are accepted (D-01 to D-06, D-08, D-10 to D-15, D-17, D-18, D-12, D-13). D-16 and D-19 were accepted on 2026-11-19 as a scope restriction and a temporary adapter, and neither forces a data-format or public-API rewrite.

---

## Phase 1 — Shared text model and compatibility boundary

**Purpose:** Establish the common API and data contracts while the current BFNT implementation still works.

**Decisions:** D-01 to D-07 are accepted. **Implementation status:** provider-switched FontStore metrics, measurement, BFNT submission, outline loading, and the explicit runtime-draw-unavailable result are implemented and compile in this worktree. `scripts/boundary_scan.py --fail` reports zero D-21 exposures. Runtime draw submission and renderer integration remain open. **Environment:** E-01 is passed for the recorded commit; E-03 is done with caveat by owner waiver, so the baseline comparison is not evidenced.

### Needs — must implement

- [~] Introduce a common font handle/face abstraction that can represent bitmap, prebaked coverage, runtime outline, and MSDF sources. *(Partly, sandbox, 2026-11-18: `FontId`, `FontHandle`, and `Registry(T)` are in `src/engine/text/font_registry.zig`, with 9 Zig tests registered in `src/tests.zig`, and a C mirror at 41/41 in `checks/font_registry_RESULTS.txt`. Second pass, same day: `FontResource` in `src/engine/text/font_resource.zig` is the tagged union over `bfnt_coverage` and `runtime_coverage`, held in `Resources = Registry(FontResource)`, with `metricsFor` and `release`. Not done: the `bitmap` variant (Phase 2) and the `msdf` variant (Phase 6), and `Canvas` now holds `*FontStore` and a `FontHandle` (sandbox, 2026-11-19, D-22). Zig is not compiled in the sandbox.)*
- [~] Define common font metrics and baseline conventions. *(Sandbox, 2026-11-18: `FontMetrics` and `FontResource.metrics()` in `font_resource.zig` give ascent, descent, line gap, and natural line height in pixels for both providers. They are unrounded, and a BFNT descent is derived (D-20, accepted). Tests check a runtime face at 16 px against `checks/font_resource_RESULTS.txt`, and a constructed BFNT font. Rounding stays with the Phase 5 consumers, as `text.c` does it. Zig is not compiled in the sandbox.)*
- [~] Define the shaped-glyph and glyph-render-record contracts from Section 5. Blocked: D-03. *(Partly, sandbox, 2026-11-18: `ShapedRun.font_id` is added, and a Zig test in `shaper.zig` enforces that `Glyph` has no font id. The glyph cache key, `Cache.removeFont`, the resolver, `glyph_records.Options`, and `renderer/glyph_check.zig` now use `FontId` (`u64`), as D-02 specifies; the cache hash folds the high 32 bits in. Zig is not compiled in the sandbox. The C mirror is at 2200 checks (2026-11-19, after the D-14 refusal check), 22 of 22 mutants caught, and the parity map has 50 Zig tests, 47 mirrored. Not done: the `glyph_records` build still draws from a caller-supplied id rather than a registry handle, `Canvas` and `Ui` now hold a `FontHandle` (sandbox, 2026-11-19).)*
- [~] Define text options for font, size/scale, color, line spacing, alignment, wrapping width, and optional direction/script/language overrides. *(Sandbox, 2026-11-18: `TextOptions` in `font_resource.zig`, with the D-06 defaults `Latn` and `en`, a one-value `Direction` for left to right only, and `shaperOptions()`. `scale`, `line_spacing`, and `color` are fields only. No consumer reads them until Phase 5.)*
- [ ] Separate text measurement, layout, glyph resolution, and draw submission into distinct responsibilities. *(Draw submission contract: D-23. `Canvas` and `Ui` keep the batch and an explicit `z`; depth is supplied by the caller.)*
- [~] Keep current `.bfnt` loading behind a legacy/prebaked coverage provider; do not rewrite the file format in this phase. *(Sandbox, 2026-11-18: `FontResource.bfnt_coverage` wraps the unchanged `font.Font`. The loader in `font.zig` is not changed. The store inserts BFNT fonts through `Resources` (sandbox, 2026-11-19, D-22). Not done: the loader's own path, which is unchanged.)* *(D-19, accepted 2026-11-19: BFNT stays as a compatibility provider and adapter. Measurement now goes through `bfnt_measure.zig` (2026-11-19, uncompiled; `checks/bfnt_measure_RESULTS.txt`). Drawing still calls `text.c`, and routing it through the common text API is open in Phase 5.)*
- [~] Preserve the current `Canvas.text`, `Canvas.textWidth`, `Canvas.layoutText`, and `Canvas.drawTextLayout` behavior through wrappers or adapters where practical. The handle move is done in the sandbox (2026-11-19): `Canvas` and `Ui` hold `*FontStore` and a `FontHandle`, and `context.loadFont` inserts through the store (D-22). The public signatures are unchanged (D-05), and the rectangle change in the decoupling item above is internal. Not compiled. Still open: the device and screenshot checks (E-02, E-03, E-04).
- [~] Decouple solid-rectangle drawing from the white 2x2 texel embedded in the font atlas. Use a renderer-owned white texture or a primitive path so a font atlas is not required for rectangles. *(Partly, sandbox, 2026-11-18. C side: `ui_quad` has a `solid` flag, set by `ui_quad_push_solid` and by `imgui.c` `fill()`, and glyphs set it to 0. Zig side, third pass: `SpriteBatch.white` is a 2x2 coverage texture that the batch creates in `init` and frees in `deinit`, as `flat_normal` is. `queueQuads` draws a solid quad from it and ignores the quad's `src`. With no white texture, a solid quad falls back to the font's block. Not done: device checks on SDL_GPU and the SDL3 2D path (E-02, E-04), and reference screenshots (E-03). The font atlas still contains the white block, because the C side and the fallback use it.)*
- [~] Define ownership rules: a queued draw cannot reference a font page that may be destroyed, repacked, or overwritten before submission completes. *(Partly, sandbox, 2026-11-18: the registry's rules are written in the `font_registry.zig` header: `Registry(T)` owns each value until `remove`, `deinit` frees only the table, `get` pointers are valid until the next `insert` or `remove`, and a handle is valid only for the registry that issued it. The `Resources` release and failed-insert rules are in the `font_resource.zig` header. Not done: the queued-draw and atlas-page rule, which needs the GPU path and Phase 5's flush wiring.)*
- [~] Keep renderer-specific types out of the public text API. *(Partly, sandbox, 2026-11-19: `FontStore.glyphTexture` is now the engine-only `glyphTextureOf`, so no `FontStore` method names a renderer type. `Canvas.queue` and `Ui.queue` still take `*sprite.SpriteBatch` with an explicit `z`. D-23 accepts that as the submission contract, so those parameters are within scope and no further change is needed here. Not compiled.)*
- [x] One definition of the debug overlay font, 9 px mono (D-07, accepted by owner direction). The source of truth is `application.zig` (`default_debug_font_path`, `default_debug_font_px`), read by `src/game/config.zig`. Evidence (owner-confirmed 2026-11-18): `application.zig:40` is `default_debug_font_px: f32 = 9`, and `config.zig:108` reads it. The 10 px default described in earlier notes is not in this upload, so no reconciliation is needed.

### Wants — useful but not blocking

- [~] Add diagnostic counters/interfaces for loaded fonts, glyph lookups, misses, and atlas page count, even if initial counters are simple. *(Partly, sandbox, 2026-11-19: `FontStore.stats()` counts loaded fonts by provider. Glyph lookups, misses, and atlas pages are counted in `glyph_cache.Stats`, but `FontStore` does not reach that cache, and the bfnt path makes no glyph-cache lookups. Not compiled; not shown in the overlay.)*
- [~] Add a debug description of the active font source and rendering mode. *(Partly, sandbox, 2026-11-19: `FontStore.describe(handle)` returns the source and the mode. Not compiled; the debug overlay does not display it yet.)*

### Deliverable

A common text/font interface with an adapter to the existing BFNT implementation; no visible text feature is removed.

### Exit gate — Phase 1 is complete only when

- [ ] Existing UI and debug text renders and measures the same as the captured baseline (E-03). The sample draws no text and is excluded (section 6.5).
- [x] Existing `.bfnt` v1/v2/v4 compatibility behavior remains covered by tests (where those versions are supported by the current loader). *(2026-11-19: v2 has explicit coverage in `tests/ui/test_text.c`, `check_v2_format`, and no longer depends on v1 and v4 passing. The repository has no v2 `.bfnt` file, and the baker writes only v4, so the test writes a v2 file from the documented layout. It checks the header, the glyph and kerning fields, the default fallback, the drawn quads and widths, and the rejections specific to v2. An earlier check that labeled version 2 'unsupported' was in fact rejecting a v2 file for its 48-byte header length, so it now uses version 5. The Zig wrapper in `font.zig` has no version logic and calls the same C loader. Results and the mutation check are in `checks/bfnt_v2_RESULTS.txt`. `zig build test-ui` was not run, because the sandbox has no Zig, so the owner's pinned run still needs to confirm it.)*
- [ ] Rectangle drawing works without referencing a font atlas. D-04 is accepted (2026-11-18). Blocked: E-03 and the device checks (E-02, E-04).
- [ ] New interfaces compile without exposing SDL, HarfBuzz, or internal font-resource types to game-facing code (D-21). E-01 passed on the recorded CI commit, but this Phase 1 interface work remains unimplemented.
- [x] D-21 holds on the public surface. `D21_DEBT` is empty (owner decision, 2026-11-19: no allowances). `scripts/boundary_scan.py --fail` reports zero reachable violations, zero known exposures, and zero new exposures in this worktree. `zig build` and the test suite compile the public surface. D-22 FontStore: ACCEPTED, subject to four boundary constraints. This closes only the API-boundary item, not the remaining Phase 1 visual/device gates.
- [x] Resource ownership and shutdown order are documented and tested. *Evidence: `docs/ownership.md` states the store-owned font rule, the released-after-GPU-idle shutdown order, and the borrowing rules for `Canvas` and `Ui`. The tests are in `src/engine/text/font_store.zig` (store owns on insert, destroy releases each font once, failed insert releases the new font, id exhaustion releases the new font, discard releases nothing) and `src/engine/text/font_lifecycle_test.zig` (`Canvas` and `Ui` deinit leave the font alive; session shutdown waits for the GPU, then releases fonts, then tears down the device, checked with a fake GPU). Owner ran `zig build test`: passed (2026-11-19). Commit hash: waived by owner direction (2026-11-19). The C mirror in `checks/font_lifecycle_mirror.c` is supporting evidence only.*

---

## Phase 2 — Hand-authored bitmap font importer and renderer

**Purpose:** Add the first-class path for pixel fonts that are already hand-drawn as bitmap glyphs.

**Decisions:** D-08 and D-09 are accepted. **Implementation status:** integrated provisionally in the current worktree; the Phase 1 entry gate is still open, as are Phase 2's native-resolution/integer-scale visual gate and other exit evidence. The owner-requested work adds manifest validation, packaged bitmap-font loading, and submission through the shared Canvas/SpriteBatch path. `zig build check-assets`, `zig build asset-build`, `zig build`, and all 747 tests pass on Windows. `font8x8_basic.r8` is 6,144 bytes, and the packaged descriptor names that `.r8`; no visual identity comparison has been run. **Entry:** Phase 1 must close first (section 7); this work does not claim that condition is met. **Environment:** E-03 is required for the pixel-accuracy check at native resolution and integer scales.

### Needs — must implement

- [~] Add a versioned bitmap-font asset descriptor containing glyph mapping, atlas page, source rectangle, advance, bearing/offset, baseline/line metrics, and optional kerning pairs. *(Partly, sandbox, 2026-11-19: `bmfont.zig` parses the BMFont text descriptor (D-08) into a normalized `Font` with those fields. The versioned contract is the normalized `Font`, schema version 1 (D-27). No on-disk Bairava format is added in Phase 2.)*
- [~] Support mapping Unicode codepoints to glyph entries. Keep glyph IDs distinct from codepoints internally even if the first format maps one codepoint to one glyph. *(Partly, sandbox, 2026-11-19: `Font.glyphFor` maps a codepoint by binary search. `Glyph` has no separate glyph ID yet.)*
- [x] Import atlas image data without vectorizing it or sending it through MSDF generation. `coverage` builds raw R8 pages; the runtime uploads them with `createCoverage`.
- [x] Validate atlas bounds, duplicate codepoints, invalid metrics, missing pages, malformed descriptors, and missing fallback glyphs during asset build. BMFont checks are wired into the content pass; `zig build check-assets` accepts the D-09 rows.
- [x] Implement the D-09 `check-assets` rules: exact overflow-checked `.r8` length; grayscale 8-bit source PNG; matching dimensions; quoted, safe source basenames; dependency kind/use; source/output folder locality; and packaged `.fnt` page rewrite checks.
- [x] Support monochrome/alpha glyph atlases using the coverage path. Color bitmap glyphs remain out of scope.
- [x] Use nearest-neighbor sampling for pixel bitmap fonts and round destinations to whole pixels.
- [x] Define atlas padding/edge handling: use authored rectangles and offsets, add no atlas padding, and rely on the existing nearest/clamp sampler.
- [x] Add a basic bitmap mapper with one glyph per UTF-8 codepoint, fallback, kerning, byte-offset clusters, and documented limits for ligatures and complex scripts.
- [x] Draw through the common text API and existing `SpriteBatch`; no bitmap-specific Canvas API was added.
- [x] Add the D-09 example asset. Mapper/store tests cover punctuation fallback, spaces, kerning, authored offsets, and page selection; the native-resolution visual comparison remains an exit gate.

### Wants — useful but not blocking

- [x] Support multi-page bitmap font atlases in the descriptor and page-aware SpriteBatch queuing.
- [ ] Support importing a common external bitmap-font descriptor if it is a good fit and has no unacceptable license/format constraints. Conditional on D-08 (section 6.5).
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

### Sandbox progress (2026-11-19): BMFont descriptor import (Phase 2, provisional)

**Entry.** The Phase 2 entry condition (Phase 1 closed) is not met. The work below is CPU-only and touches no renderer, `Canvas`, `Ui`, or public API. It is marked provisional under section 6.1, as the Phase 5 notes were.

**Landed (Zig, not compiled in the sandbox):** `src/engine/text/bmfont.zig`. It parses an AngelCode BMFont text descriptor into Bairava-owned `Font`, `Glyph`, `Kerning`, and `Page` structures. Accepted tags are `info`, `common`, `page`, `chars`, `char`, `kernings`, and `kerning`; any other tag is rejected. A descriptor needs `info`, `common`, `page`, and `chars`; `kernings` is optional. Validation covers page ids and count, the `chars` and `kernings` counts, codepoint validity and uniqueness, glyph page and atlas bounds, metric ranges, kerning uniqueness and mapping, and the fallback glyph (default `?`, D-09). Nineteen Zig tests in `bmfont.zig` are registered in `src/tests.zig`, and six more in `src/engine/assets/bmfont_check.zig`. The normalized `Font` carries `schema_version`, which is 1 (D-27).

**Model.** `checks/bmfont_model.py` runs 20 cases against a Python port of the same algorithm and the page checks: 19 parser cases, and one page case that groups six assertions. It reports 20 of 20 passing (`checks/bmfont_model_RESULTS.txt`). A broken check is reported as six failures. A deliberately wrong expectation is reported as a failure, so the harness can fail. The model checks the algorithm against the test expectations. It does not run the Zig code.

**Decisions used.** D-08 (BMFont text descriptor, normalized into Bairava structures), D-09 (fallback `?`), and the owner's Phase 2 decisions D-27 and D-28, recorded in section 6.2.

**Blocked.** Phase 2 stays blocked until the D-09 example asset is generated from the pinned `font8x8` commit, verified by SHA, and its license notice is included (owner decision, 2026-11-19).

**Page images.** `src/engine/assets/bmfont_check.zig` checks each page image against `scaleW` and `scaleH`. It reads the size from the PNG header with the existing `validate.pngSize`, and it reports a missing image, a wrong size, a page-count mismatch, and any descriptor error with its line. Issues go into the same `validate.Report` the other asset checks use. The caller reads the page files, so the check does no file I/O.

**Not done.** Decoding the atlas image and the coverage upload; wiring the page check into `check-assets`, which needs a BMFont row kind in the asset manifest (open for the owner); the bitmap provider and its `FontResource` variant; a glyph ID separate from the codepoint; nearest sampling; applying the parsed padding; the draw path; the mapper adapter that the text path calls; and the D-09 example asset, which needs the font8x8 source fetched at the pinned commit. The sandbox has no network access.

**Owner decisions (2026-11-19).** D-27: the BMFont text file is the on-disk descriptor, and the normalized `Font` with `schema_version` 1 is the contract; no Bairava disk format is added. D-28: an unmapped kerning pair is an error that names the pair, its line, and the missing id. The code now does both.

**Glyph id.** The diagnostic reports BMFont's `id`, which is the codepoint, because Bairava has no separate glyph index yet. A glyph whose rectangle extends past the atlas is still an error.

**Open for the owner.** (1) Decided 2026-11-19: the `bitmap_font` and `coverage` row kinds in the D-09 asset contract. Not yet implemented. (2) Whether Phase 2 needs a glyph index separate from the codepoint (item 2). The diagnostic reports BMFont's `id` until you decide. (3) The D-09 asset, under Blocked.

**Phase 1 evidence.** The owner reports that `zig build test` works on Windows after the text.c flag (2026-11-19). No commit or log has been recorded for that run, so no Phase 1 gate closes on it.

### Sandbox progress (2026-11-19, D-09 asset and manifest decisions): Phase 2, provisional

**Entry.** The Phase 2 entry condition (Phase 1 closed) is still not met. This pass changes no renderer, `Canvas`, `Ui`, or public API.

**D-09 asset generated.** `assets/fonts/font8x8_basic.png`, `assets/fonts/font8x8_basic.fnt`, and `assets/fonts/font8x8_basic.NOTICE.txt` come from `scripts/gen_font8x8_asset.py`, run on `font8x8_basic.h` at commit `4876b70490600222f30bb9acd2c02868e390bb56`. The source's SHA-256 is `49d8df366296b203ca3211bc0672cf2a762135bf12710735b6292756b19dffd5`, and the generator refuses any other source. The PNG is 8-bit grayscale, 128 by 48, with binary coverage (0 or 255). The descriptor puts glyph data in the red channel (`chnl=4`, `redChnl=0`). Checks, recorded in `checks/font8x8_basic_RESULTS.txt`: an independent PNG decode; 6,016 glyph pixels compared against the source table, with 0 mismatches; the descriptor accepted by `checks/bmfont_model.py` at a 128 by 48 page and rejected at 128 by 64; the model self-test at 20 of 20; and the generator reproduces the three files byte for byte. The Zig parser was not compiled. The Python model mirrors it and is supporting evidence only.

**Owner decisions recorded here.** The owner accepted two items in this session (2026-11-19). The first is the `bitmap_font` manifest row kind: its dependencies name declared `coverage` rows (see the page-route decision below), every page must resolve, each page's size must equal `scaleW` and `scaleH`, and a multi-page descriptor resolves every page. **Correction, same date:** the descriptor is not copied unchanged. The builder rewrites it as the D-09 asset contract describes. The second is glyph identity: the BMFont `id` is the codepoint, with no separate `glyph_index`. These two answer the "open for the owner" items above.

**Page route: decided 2026-11-19 (option B).** The original accepted wording said the page images are declared image assets. An `image` row, however, builds RGBA8 plus BC1, BC3, and ASTC variants (`tools/assets/build.c`, `build_texture_variants`), and the R8 coverage spec cannot come from those. The options are:
- (A) Keep each page as an `image` row. This matches the accepted wording, but it yields colour and BC variants instead of R8, and the descriptor's `file="font8x8_basic.png"` no longer names an output file.
- (B) Add a coverage page kind, for example `coverage`, that copies the grayscale PNG through or converts it to a raw R8 file, and let `bitmap_font` dependencies name those rows. This matches the R8 spec. It widens the accepted wording slightly.

Owner decision: (B). Option (A) is rejected. The row kinds, the builder dispatch, and the `check-assets` wiring are specified in the contract below and are not yet written.

**D-09 asset contract (accepted 2026-11-19).** The owner confirmed these rules. The descriptor rewrite is the one exception to the earlier accepted wording, and it replaces the "copied unchanged" text above.

Rules:
- Coverage output extension is `.r8` (raw R8 bytes, no header).
- Bitmap-font descriptor output extension is `.fnt`.
- Every coverage page a descriptor references must reside in the descriptor's folder.
- Coverage rows are leaf assets. They cannot declare dependencies.
- A `bitmap_font` row declares its coverage rows as dependencies, so dependency tracking and build ordering work.

Pipeline:
1. Grayscale PNG → raw R8 `.r8` (`coverage` row).
2. BMFont descriptor → validated and rewritten `.fnt` (`bitmap_font` row). The builder parses and validates the descriptor, verifies that all referenced coverage pages exist in the same folder, and rewrites their filenames to the corresponding packaged `.r8` output filenames. The remaining descriptor content, including glyph metrics, advances, dimensions, and channel metadata, is preserved.
3. The `bitmap_font` row references its coverage rows through `dependencies`.
4. Coverage rows cannot declare dependencies.
5. `check-assets` validates extensions, folder locality, page references, dimensions, the fallback glyph, and output consistency.

Implementation notes (confirmed 2026-11-19):
- The checked-in `assets/fonts/font8x8_basic.fnt` keeps `file="font8x8_basic.png"`. That is the source form. The rewrite applies only to the packaged output.
- Rewritten `file=` values are bare filenames. They resolve against the packaged descriptor folder, because the pages share that folder.
- Raw R8 has no header, so `check-assets` checks each `.r8` file's byte length against `scaleW` × `scaleH` from its descriptor.
- `tools/assets/build.c` now dispatches both row kinds (see the D-09 builder dispatch block). `src/engine/assets/validate.zig` still rejects them, and `zig build check-assets` runs in CI, so the rows stay out of `asset_manifest.txt` until that changes. Illustrative rows, not yet in the manifest:

```
font8x8_basic_page coverage assets/fonts/font8x8_basic.png fonts/font8x8_basic.r8 -
font8x8_basic bitmap_font assets/fonts/font8x8_basic.fnt fonts/font8x8_basic.fnt font8x8_basic_page
```

**check-assets requirements for the D-09 contract (confirmed 2026-11-19).**

R8 coverage pages:
- Each `.r8` file referenced by a descriptor must be exactly `scaleW` × `scaleH` bytes. For D-09 that is 128 × 48 = 6,144 bytes.
- The check computes that product with overflow-safe multiplication and fails on overflow before comparing sizes.
- The format is one byte per pixel, with no row padding or alignment bytes, no mipmaps, and no additional image data.
- The source grayscale PNG's width must equal `scaleW`, and its height must equal `scaleH`. A PNG has no single size value, so the comparison is per axis.

Descriptor page resolution:
- Each `page` entry's `file=` value is a bare filename in the quoted form BMFont requires, for example `page id=0 file="font8x8_basic.r8"`.
- check-assets rejects a `file=` value that is empty, is `.` or `..`, or contains `/`, `\`, or `:`.
- The filename must equal the packaged output name of a coverage row that the `bitmap_font` row declares as a dependency.
- The runtime resolves the filename relative to the `.fnt` descriptor's folder. The same-folder rule makes that resolution deterministic.

**FMA check, C side.** `checks/bfnt_fp_contract_repro.c`, built with gcc 13.3 and `-mfma`. With `text.c` compiled under `-ffp-contract=fast`, the replay gives 3 mismatches in 456 comparisons. The first is at font 0, corpus 5, scale 1.5, where `text.c` gives `0x427DCCCD` and the port gives `0x427DCCCA`. With `-ffp-contract=off`, it gives 0 mismatches. This confirms the diagnosis above and shows that the `text_c_flags` change addresses the C side. The Zig test has still not run in the sandbox.

**Uploaded run, commit f417b4d.** The uploaded `build.zig` already contains `-ffp-contract=off`, and the uploaded `zig-build-test.log` still records exit -1 with no failure text. If the flag fixes the float-bit failure, that failure does not explain the -1, and the log has no other failure text. The wrapper should save stderr and the real exit code. The owner should then rerun the root test module on a commit that contains the flag.

**Not done (as of this block; the builder dispatch was done in the next block).** The `bitmap_font` row kind, the builder dispatch, the page checks in `check-assets`, the bitmap provider and its `FontResource` variant, nearest sampling, the padding policy, the draw path, and the mapper adapter. Any Zig or C written for these would be uncompiled in the sandbox.

---

### Sandbox progress (2026-11-19, D-09 builder dispatch): Phase 2, provisional

**Scope.** The builder side of the D-09 contract: the `coverage` and `bitmap_font` row kinds in `tools/assets/build.c`. Zig `check-assets` is not changed here. The Phase 1 entry condition is still not met. This is provisional work, and it changes no renderer, `Canvas`, `Ui`, or public API.

**Builder.** `valid_kind` accepts a `coverage` row only with a `.png` source that is 8-bit grayscale by its IHDR, a `.r8` output, and `-` dependencies. It accepts a `bitmap_font` row only with a `.fnt` source and output and at least one dependency. `process_bitmap_font` runs before any output is written. It requires one `common` line with `scaleW`, `scaleH`, and `pages`, and one `page` line per page id, each with a bare quoted `file=`. It matches each page to exactly one declared coverage row, by the basename of that row's source. It requires every coverage row to share the descriptor's source folder and output folder, requires every coverage row to be used, and requires each page PNG to be `scaleW` × `scaleH`. Coverage rows are decoded and written before any `bitmap_font` row. The descriptor is then written with each `file=` set to the packaged `.r8` basename, and nothing else on any line changes. Each `.r8` must be exactly `scaleW` × `scaleH` bytes, checked with overflow-safe multiplication.

**Choices to confirm.** (1) A coverage row that no page uses is rejected. The contract did not say either way. (2) A page matches its coverage row by the PNG's basename, which is what the descriptor's `file=` names. The rewritten value is the `.r8` basename.

**Evidence (sandbox, gcc 13.3, `-std=c11 -Wall -Wextra`, zero warnings).**
- `tools/assets/test_tools.py` passes with three new tests. `test_bitmap_font_d09` builds the real D-09 asset. The `.r8` is 6,144 bytes and equals the PNG's values, decoded by an independent decoder. The `.fnt` differs from the source only on the page line. `test_bitmap_font_two_pages` checks a two-page font. `test_bitmap_font_rejections` runs 13 bad inputs. Each fails with a builder message, and each leaves no output directory behind.
- The project's real manifest still builds all 12 existing assets.
- `checked_mul_size` is checked directly, with a harness that includes `build.c`. It covers the overflow boundary.

**Sandbox differences.** The builder was compiled against the system FreeType headers, not the pinned `vendor/freetype-2.15.0`. Zig is not installed in this sandbox, so no Zig was compiled.

**Not done.**
- `src/engine/assets/validate.zig` has a closed list of kinds: `image`, `audio`, `wav`, `font`, `map`, `file`. `zig build check-assets` would reject `coverage` and `bitmap_font` rows, and CI runs that command (section 8.4). The D-09 rows therefore stay out of `assets/asset_manifest.txt` until `validate.zig` and the `check-assets` wiring accept them.
- The Zig page checks in `check-assets` (the `bmfont_check.zig` wiring).
- The builder checks descriptor structure, page wiring, and dimensions. Glyph metrics and kerning are still validated only by `bmfont.zig`.
- The bitmap provider and its `FontResource` variant, nearest sampling, the padding policy, the draw path, and the mapper adapter.

---

## Phase 3 — HarfBuzz integration and runtime outline-font face

**Purpose:** Add the shaping foundation and load outline-font information without coupling it to a GPU atlas.

**Decisions:** D-06, D-10, D-16. **Entry:** Phases 1 and 2 closed (section 7). **Environment:** E-01.

### Needs — must implement

- [~] Pin HarfBuzz to an explicit version/commit and record it in dependency policy and lock data. Lock entry present: HarfBuzz 15.1.0, commit `3df40d9`, in `docs/dependency-lock.json`, with evidence `checks/pinned_harfbuzz_15.1.0_dump.txt`. The dump uses the engine's LTR, explicit-script, explicit-language, default-feature, monotone-grapheme calls and `f32(units)/64` plus negated Y conversion. It includes Latin, Noto Sans Tamil, and Chemmozhi Paranar values. This evidence pins shaping values; it does not close the Phase 3 exit gate.
- [~] Integrate HarfBuzz into Bairava's actual Zig/C/C++ build for Linux, Windows, and macOS. Do not copy another project's Zig build script or dependency versions blindly. Linked into the engine module (`build.zig`, `configureEngineModule`) and the test module. The pinned cross-platform build/test matrix now passes at E-01 commit `f4abef0f7528e36658eb1d5c106d88b9f1769ded`; phase completion still depends on the remaining Phase 3 code/test exit criteria and the Phase 1/2 entry gates.
- [x] Reuse the existing `stb_truetype` source where suitable; do not add a duplicate copy. One `vendor/stb_truetype_impl.c` is shared by every module that uses it.
- [x] Create a runtime outline-font face that owns or safely references the font bytes for as long as HarfBuzz and the rasterizer require them. `RuntimeFont` copies the bytes. Test: the font keeps its own copy.
- [x] Reuse HarfBuzz face/font objects; do not create them per string or per frame. One face and font per `RuntimeFont`, and one buffer per `Shaper`.
- [x] Define units and scaling from font units to Bairava pixels in one place. `RuntimeFont.init` sets the scale. `shaper.zig` `unitsToPixels` converts.
- [~] Implement the shaping call with explicit direction, script, language, and feature handling. Provide sensible defaults but allow the caller or text system to set them deliberately. Script and language are caller-set. Direction is fixed to left to right (D-06). Features are HarfBuzz defaults (D-16).
- [~] Return glyph IDs, clusters, advances, and offsets in an engine-owned shaped-run structure. Glyphs and width are returned. The run has no font identity (D-03) and no direction field.
- [x] Handle empty strings, malformed UTF-8, zero-width/non-rendering glyphs, and missing-glyph results deterministically. Tests in `shaper.zig` and `shaped_layout.zig`.
- [~] Test Latin kerning/GPOS behavior and Tamil shaping with fonts that contain the required OpenType tables. Kerning and Tamil clusters are tested. The combining-overline values and all five Noto numeric tests match the pinned 15.1.0 dump. Numeric Chemmozhi KSSA, Latn fallback, vowel O, anusvara, and word shapes are now pinned too. This verification does not depend on GPU output and does not close Phase 3; the Phase 1 and Phase 2 exit gates remain open.
- [x] Keep shaping tests CPU-only; they must not require a GPU device or window.

### Font-format constraint

The current offline path supports TrueType through stb and CFF through FreeType. The runtime path must make an explicit choice:

- **Initial restricted runtime:** use stb for supported TrueType outlines and retain the current offline BFNT/FreeType path for fonts needing CFF support; or
- **Broader runtime:** integrate FreeType at runtime for rasterization/font access where necessary.

Do not advertise all TTF/OTF formats as supported merely because HarfBuzz can parse/shapes them. Shaping support and glyph rasterizer support are separate capabilities.

### Wants — useful but not blocking

- [-] Add configurable OpenType feature tags for callers who need to disable/enable specific substitutions or positioning. Conditional on D-16 (section 6.5). *(N/A by D-16, accepted 2026-11-19: the first release uses HarfBuzz defaults. Feature configuration, if needed later, goes into the shaping options and does not change the cache, atlas, `FontStore`, `SpriteBatch`, or renderer.)*
- [x] Add language/script overrides for diagnostics and tests. `Options.script` and `Options.language` are caller-set (`shaper.zig`).

### Deliverable

A CPU-only shaping service and reusable runtime outline-font face. No glyph atlas or renderer changes are required to prove this phase.

### Exit gate — Phase 3 is complete only when

- [x] HarfBuzz builds and links on all supported CI platforms. Evidence: E-01 GitHub Actions run #112, commit `f4abef0f7528e36658eb1d5c106d88b9f1769ded`.
- [ ] Tests verify glyph IDs, clusters, advances, and offsets for Latin and Tamil fixtures against the pinned HarfBuzz version. E-01 confirms the CI test suite passes at the recorded commit; review the fixture assertions and expected values before marking this phase item complete.
- [x] Font data and HarfBuzz objects survive repeated shaping calls and are released correctly. Shaper reuse and create/destroy cycle tests, under a leak-checking allocator.
- [x] Unsupported font-format/rasterizer combinations fail explicitly rather than rendering blank glyphs silently. `checkFormat` tests in `runtime_font.zig`.
- [x] HarfBuzz objects/types do not leak into the public game-facing API. The game and samples import no text internals, and HarfBuzz is used only inside the text package.

---

## Phase 4 — Runtime coverage rasterizer, glyph cache, and dynamic atlas

**Purpose:** Implement Architecture 1's on-demand glyph path while keeping static bitmap/BFNT/MSDF assets as separate providers.

**Decisions:** D-13, D-14. **Entry:** Phase 3 closed. **Environment:** E-01 passed on the recorded commit; E-02 and E-04 remain required for GPU/device validation.

### Needs — must implement

- [x] Implement a rasterizer interface that consumes a font face and glyph ID and returns a coverage bitmap plus bitmap bounds/bearing information.
- [x] Implement the initial `stb_truetype` rasterizer for the approved TrueType outline subset. Add runtime FreeType only if Phase 0 selected it for broader format support.
- [x] Do not rasterize by Unicode codepoint after shaping; rasterize the glyph IDs returned by the shaper.
- [x] Treat spaces and other empty glyph images correctly: they keep their advances but do not consume atlas rectangles.
- [x] Define the glyph-cache key using font identity, glyph ID, pixel size, and rasterization settings.
- [x] Add atlas pages with packing padding, page-full behavior, growth limits, and clear allocation failure behavior.
- [x] Add a GPU upload/update path for atlas pages. Region uploads use the runtime atlas textures; overflow spills changed rectangles instead of rewriting a live page.
- [x] Ensure uploads occur on the renderer-permitted thread and before a draw samples the changed region. One shared flush runs in the frame command buffer before either renderer submission path.
- [~] Ensure a queued SpriteBatch run cannot outlive or refer to a replaced atlas page. Pages stay stable through atlas deinit, which follows the idle wait; SDL3 2D and dedicated lifetime-test coverage remain open.
- [x] Define an initial eviction policy. It is acceptable to use bounded page growth first, provided memory limits and failure behavior are explicit; eviction can be a later enhancement.
- [x] Preserve the existing static `.bfnt` provider. It should not need to use the dynamic atlas.
- [x] Add cache hit/miss, rasterization count, page count, and allocated-byte counters.

### Wants — useful but not blocking

- [x] Batch multiple glyph misses and upload them together instead of issuing one GPU upload per glyph.
- [x] Add a warm-up/preload API for known dialogue/UI strings. It takes glyph IDs, as `resolve` does, so warming a string waits for Phase 5 shaping.
- [ ] Reuse one upload buffer across flushes instead of creating one per changed page (performance; measure first with the glyph check counters).
- [ ] Add LRU or another measured eviction policy after a stable page-growth implementation exists.

### Deliverable

A runtime outline font can request an unseen glyph, rasterize it once, upload it into a coverage atlas, cache it, and reuse it on later draws.

### Exit gate — Phase 4 is complete only when

- [x] Repeated requests for the same font/glyph/size produce cache hits and do not rasterize again.
- [x] Cache keys distinguish different fonts, sizes, and rasterization modes.
- [x] Atlas-full, allocation-failure, and resource-destruction tests pass.
- [x] GPU upload/update synchronization is validated under GPU debugging. E-02 passed; the 600-glyph overflow uploaded regions without a whole-page rewrite.
- [~] Both renderer modes have defined and tested coverage-font behavior.
- [~] No queued draw can sample a destroyed or repurposed atlas page.

### Status (2026-11-17): resolver, modes, fallback, decisions, and mirror parity

**Legend:** `[x]` means the code exists and a CPU test covers it. `[~]` means the code exists, but it is verified only by reading, or it needs a GPU or window run. `[ ]` means not done. The numbering in this plan is authoritative. The source comments that say "Phase 3" are legacy.

**Caveat (updated 2026-11-19).** The C mirror (`checks/glyph_cache_mirror.c`) models the resolver, raster modes, and fallback. E-01 remains compile/test evidence only. E-02 is now recorded separately in section 6.4 and does not close the Phase 4/5 exit gates. The mirror runs 2191 checks with 0 failures; the original 1828 still pass unchanged, and 21 planted mutants are caught. Its parity with Zig is at the level of logic against a synthetic glyph source. Of 49 Zig tests in the cache, font-test, and atlas files, 46 have a mirror check of the same logic (`checks/glyph_cache_parity.txt`). Parity is not claimed for real-font values, the GPU, or Zig compilation.

**Decisions accepted (2026-11-17).**
1. The raster mode is explicit in `resolve`. Gray is the only mode produced. Mono returns `UnsupportedRasterMode`. The mono variant stays in the cache key, so gray and mono entries cannot collide. An unsupported mode fails; it never falls back to gray.
2. The caller supplies the fallback glyph ID. The resolver does not choose a fallback.
3. A glyph is missing when its ID is at least the font's glyph count. The field is `RuntimeFont.glyph_count`, which holds the face's glyph count from HarfBuzz. Glyph 0 is valid (`.notdef`) and gets no special treatment in the cache or the resolver.
4. Mapping `?` through the character map, and the fallback policy, are deferred to Phase 7.
5. The SDL3 2D renderer path is a Phase 5 task (accepted 2026-11-17). Phase 4 does not wait for a device run of the 2D path.

**Phase 7 hand-off.** Phase 7 decides: how `?` is mapped through the character map; what to draw when `?` is unavailable (nothing, or another fallback); and how missing-glyph diagnostics are reported. The `missing_glyphs` counter exists, but no reporting channel does yet. The existing `missing_codepoints` counter counts codepoints the text layer could not map. It stays distinct from `missing_glyphs`, which counts glyph IDs past the font's end.

**Zig changes in this pass:**
- `glyph_cache.zig`: a `missing_glyphs` counter and `noteMissingGlyph()`, a test that a zeroed key is gray, and a test that a gray and a mono key sharing a probe chain stay apart.
- `glyph_resolver.zig`: `resolve` takes a raster mode. Only gray is supported. Other modes fail with `UnsupportedRasterMode` before the cache is consulted. `resolveWithFallback` handles glyph IDs at or past the font's glyph count. The caller supplies the fallback, each missing request is counted once, and the missing glyph is never stored.
- `glyph_cache_font_test.zig`: tests for mode refusal, gray and mono separation, the fallback cases, glyph 0, the glyph-count boundary, and consistency between the resolved metrics, the cache entry, the pending upload rectangle, and the stored coverage.

**Mirror and checks in this pass:** 21 new test functions, 331 new checks. The synthetic glyph 0 has ink, like `.notdef`. Two new mutants (`MUT_ZERO_IS_MISSING` and `MUT_MISSING_OFF_BY_ONE`) break the missing-glyph rule and are caught. `checks/glyph_cache_parity.py` regenerates the Zig-to-mirror map. `checks/glyph_cache_RESULTS.txt` records the runs.

**GPU check (2026-11-17).** `renderer/glyph_check.zig` draws runtime text through the atlas and logs its counters. `lifecycle.zig` creates it when `glyph_check.enabled` is set, and `runtime.zig` calls it after the game and overlay queue sprites, before the sprite upload. The flag is off by default. It has not been compiled or run.

**Still open:**
- [~] GPU upload and update synchronization under GPU debugging. A run with `-Dgpu-debug=true` on 2026-11-17 drew 1190 frames with validation on, and the log showed no validation errors. Still open: the whole-page path. The burst in `renderer/glyph_check.zig` exercises it, and its log must report one whole-page upload.
- [ ] Both renderer modes on a device. Moved to Phase 5 (decision 5 below). The 2D frame branch in `runtime.zig` does not call the atlas flush yet. Phase 5 adds that call, and then the 2D path runs on a device.
- [~] No queued draw samples a destroyed or repurposed page. This holds by design. Phase 5 must keep `Cache.clear` and `Atlas.deinit` behind a GPU-idle wait.
- [ ] LRU eviction (optional "Wants"; not started). The warm-up API is done; see the warm-up pass below.
- [ ] Whole-page uploads rewrite resident texels. A page is marked for a full upload when more than `max_pending` (512) regions change between flushes. That upload rewrites texels that frames in flight may read, with the same bytes. The output does not change, but the no-write-after-read argument in `glyph_cache.zig` and `glyph_atlas.zig` does not cover this path. Check it under GPU sync validation. If validation flags it, upload only the new texels on the overflow path.

**Numbering.** The source comments in `glyph_cache.zig` and `glyph_atlas.zig` still say "Phase 3 of the rendering migration plan". They are legacy and were left as they are. `glyph_resolver.zig` uses this plan's numbering.

**Warm-up pass (2026-11-17, second pass).** `glyph_resolver.warm` caches a list of glyph IDs before their first draw. Each glyph goes through `resolveWithFallback`, so the mode, fallback, and counter rules match a single draw. `WarmStats` reports the glyphs rasterized, already cached, and substituted. The C mirror runs 32 new checks (2191 in all, 0 failures, under ASan and UBSan, built with `-std=c99 -Werror`). All 21 planted mutants are caught, including two new ones that break the warm-up checks. The parity map lists 49 Zig tests, 46 of them mirrored. The pinned Zig CI compile/test result is recorded under E-01; this does not close E-02.

Proposed, not yet accepted: warm-up stops at the first error and returns it, and the glyphs before that one stay cached. It does not skip the failed glyph. When the atlas is full, later glyphs would be refused too, so going on would only add rasterization work. The owner should accept or reject this rule.

Corrected: the frames-in-flight comments in `glyph_cache.zig` and `glyph_atlas.zig` said no later write touches a glyph's texels. That is false for a whole-page upload, which overflow of the pending list forces. The comments now say so, and the path is an open GPU-sync item above.

**Next:** Phase 5 connects `resolve`, `resolveWithFallback`, and `warm` to `Canvas` and the text consumers, calls `Atlas.flush` before the sprite upload, and adds the 2D flush call so the 2D path runs on a device. Phase 4 closes when `zig build test` passes on Windows, Linux, and macOS, and the burst run is clean: one whole-page upload is logged, and validation reports no errors.

**D-14 conformance (sandbox, 2026-11-19):** `max_page_count` is lowered from 64 to four in `glyph_cache.zig`, and `MAX_PAGE_COUNT` in the C mirror likewise. Both refuse a fifth page. The mirror runs 2200 checks with 0 failures under ASan and UBSan, recorded in `checks/glyph_cache_RESULTS.txt`. The Zig change is not compiled.

---

## Phase 5 — Shaped text layout and engine/UI integration

**Purpose:** Connect HarfBuzz output to the glyph providers and make the new text system usable throughout Bairava.

**Decisions:** D-01 to D-07 (Phase 1). D-05 is required by the Canvas migration. **Entry:** Phases 1 to 4 closed. **Environment:** E-02, E-03, E-04 (E-01 is passed on the recorded commit).

### Needs — must implement

- [x] Shape a complete text run before measuring it for line placement. Use shaped advances/offsets rather than summing codepoint widths. *(Done, CPU: `shaped_layout.zig` shapes each candidate line before measuring it, and keeps each line's own shaped glyphs. `shaper_tamil_test.zig` covers Tamil.)*
- [x] Carry clusters through layout and only split lines at approved cluster/grapheme boundaries. Do not reuse the current codepoint-only long-word splitter for complex shaped runs. *(Done for shaped runs, CPU: a word splits only at cluster starts, and a ligature that spans graphemes is never split. `layout.zig` keeps the codepoint splitter for static BFNT and bitmap providers.)*
- [x] Define line-break policy for the first release. Start with explicit newlines and supported whitespace breaks; add full Unicode line-break conformance only as a separately scoped capability. *(Done: the policy is written in the `shaped_layout.zig` header. Known limit: a combining mark directly after a space.)*
- [~] Preserve baseline, ascent/descent, line height, blank-line, alignment, and pixel-snapping behavior for existing UI fonts. *(Partly: `glyph_records.zig` uses the legacy formulas (rounded line top, rounded ascent, one rounding per glyph), and its tests check them for the runtime font. The existing UI fonts are not yet compared against screenshots, which needs a device.)*
- [x] Produce glyph render records from the appropriate provider after shaping/layout: bitmap mapping and runtime coverage use page-aware records; static BFNT stays in its private C adapter.
- [x] Add a common glyph-quad submission path supporting texture page, UV, plane bounds, tint/alpha, and render mode. Runtime/bitmap records are submitted to the UI quad list and resolve to stable atlas page textures before sprite submission.
- [x] Preserve or deliberately version `Canvas.text`, `textWidth`, `layoutText`, and `drawTextLayout` so game code does not have to manage glyph IDs or atlas pages. D-05 is accepted; the existing signatures remain.
- [x] Migrate the debug overlay, developer console, widgets, and game-owned text call sites. The overlay, console, and game use `Canvas`/`Ui`; C widget callbacks now dispatch measurement and drawing through `FontStore`. Device visual acceptance remains tracked below (E-03/E-04).
- [-] Sample scene: N/A. `sample/main.zig` and `sample/benchmark.zig` draw textures only and call no text API (checked in this pass; section 6.5).
- [ ] Preserve clipping, z-order, tint, alpha blending, pixel snapping, and integer viewport scaling. Verification: E-03.
- [x] Keep rectangle drawing independent from font resources. The batch-owned white texture serves solid quads; they do not sample a font atlas.
- [x] Keep shaping, layout, and glyph cache tests separable from GPU visual tests. *(Done: the three new modules import no renderer or platform module, and the harness compiles and runs them without SDL.)*
- [ ] Generate the SDL3 2D coverage/bitmap glyph asset from the same source font at asset import (D-24), never from the MSDF texture. Keep a single atlas resource under the D-14 ceiling, with no second concurrent copy.

### Wants — useful but not blocking

- [ ] Add text-run inspection to diagnostics: source range, glyph IDs, clusters, advances, selected font, and render mode.
- [ ] Add baseline and line-box debug visualization.
- [~] Add an explicit text-measurement result that includes width, height, line count, and baseline-related metrics. *(Partly: `Layout` gives width, height, and line count. Baseline metrics are not yet exposed.)*

### Deliverable

UI widgets, the developer console, and the debug overlay use the shared text system. The sample draws no text and is N/A (section 6.5). Outline fonts are shaped by HarfBuzz and rendered through the coverage path. Bitmap fonts continue to use their own provider but the same API/layout system.

### Exit gate — Phase 5 is complete only when

- [x] Existing text consumers work without importing private text/renderer internals. The build, tests, and D-21 boundary scan pass.
- [~] Latin and Tamil reference strings render with correct glyph order, positioning, and cluster behavior. *(Shaping and layout are CPU-verified for Latin and Tamil in the repo. The Tamil font was approved and checked in on 2026-11-18, and its tests are registered. Glyph order on screen is not verified.)*
- [~] Measurements and wrapping match rendered results. *(CPU: width equals the sum of glyph advances, measure equals shape, and record pens use shaped advances. Rendered results need a device.)*
- [x] Long strings, blank lines, missing glyphs, malformed UTF-8, and empty glyphs have deterministic behavior. *(Done, CPU-tested: long words, blank lines, glyph 0 for unmapped characters, malformed UTF-8, and zero-ink spaces.)*
- [~] The old BFNT path still passes visual and compatibility tests. *(Partly: the Phase 0 characterization harness passes 70 of 70 against the unchanged `text.c`, with no warnings. Visual tests need a device.)*
- [ ] Both existing renderer modes behave according to the agreed support matrix.

### Status (2026-11-18): shaping, shaped layout, and glyph records

**Legend:** as in Phase 4. Only CPU results are claimed here, and they were run in the sandbox against the code in this upload.

**Landed (new files, CPU-only):**
- `shaper.zig`: the shaping service of Phase 3. It runs HarfBuzz on the face a `RuntimeFont` owns, reuses one buffer per shaper, and returns engine-owned `Glyph` records (glyph ID, byte cluster, advances, offsets, in pixels). Script and language are explicit, defaulting to `Latn` and `en`, and never guessed. Direction is forced to left to right. A character the font does not map shapes to glyph 0. `measure` runs the same shaping and summation as `shape`, so the two widths match exactly.
- `shaped_layout.zig`: wrapping and alignment over shaped runs. It keeps the line rules of `layout.zig`. Each candidate line is shaped before it is measured, so a line measures what it draws. A word wider than the line splits only at grapheme starts. Each glyph's cluster is an absolute byte offset in the source text.
- `glyph_records.zig`: turns a layout into glyph render records, resolved through the Phase 4 cache and resolver. Placement follows `text.c`: a fractional pen moved by shaped advances, one rounding per glyph, a rounded baseline per line, and no record for a glyph without ink.
- `runtime_font.zig`: the HarfBuzz `cImport` is now `pub`, so the shaper and the face name the same types. Nothing else in that file changed.
- `tests.zig`: registers the three CPU test modules. The repo's own `zig build test` now runs them.
- `shaper_tamil_test.zig`: five Tamil corpus tests, registered in `tests.zig`. They use `tests/fixtures/NotoSansTamil.ttf`, approved and recorded on 2026-11-18 (see Decisions below).

**What was run, and with what:**
- Pinned toolchain: Zig `0.16.0-dev.3142+5ccfeb926`.
- Cross-platform evidence: E-01 GitHub Actions run #112 on commit `f4abef0f7528e36658eb1d5c106d88b9f1769ded`; Ubuntu, Windows, and macOS jobs all passed their build, asset-check, and unit/UI-test steps. Per-job links are recorded in section 6.4.
- This supersedes the earlier sandbox-only limitation below for compile/test validation. The standalone sandbox harness results remain useful supplemental evidence, not the E-01 gate.
- Mutation checks: one fault per mutant, seeded in the scratch copy and checked for a real assertion failure, not a compile error. Shaped layout: no cluster rebase (1 failure, `expected 3, found 0`), a boundary at every byte (1 failure), and an ignored fit check (2 failures). Glyph records: an unrounded ascent (1 failure, `expected 2, found 1.965`), an unkerned pen (2 failures, `expected 9, found 10`), and an unrounded line top (1 failure, `expected 3, found 2.6`). The repo copy was restored after each run.

**Findings from running the code:**
- The Phase 3 shaping service had not been built. Phase 5 needed it, so it was built here as the first step.
- The Phase 4 Zig code had never been compiled. It compiles and passes under Zig 0.16.0 with the stand-in above.
- With Noto Sans Tamil, the conjunct க்ஷ shapes to one ligature glyph with cluster 0, and that glyph spans two graphemes. Under `Latn` the same nine bytes give three glyphs. So the explicit script is what decides the shaping, and the Phase 0 decision not to guess is necessary.
- With the same font, the vowel sign O on க gives three glyphs, all in one cluster. A Tamil word's clusters are exactly its grapheme starts.

**Current status (updated 2026-11-19):** The runtime draw path now resolves shaped glyph records into the common UI quad list, with page-aware texture selection. The Session owns the atlas, and `runtime.zig` performs one flush after game/overlay/diagnostic queuing and before either renderer path. E-02's GPU-debug burst run is recorded in section 6.4. This does not close Phase 5; SDL3 2D device validation (E-04) and the visual compatibility checks remain open.

**Still open (Phase 5 is not complete):**
- Validate the SDL3 2D path, text appearance, clipping, z-order, and reference screenshots on a device (E-03/E-04).
- Preserve existing `Canvas` signatures and BFNT widget compatibility; C widget labels now use provider callbacks for BFNT, bitmap, and runtime coverage fonts.
- The sample draws no text and is N/A (section 6.5).
- `docs/text.md` is not rewritten. That belongs to Phase 8.
- Shaping features are not configurable, and the Wants items are not started.

**Decisions (approved by the owner, 2026-11-18):**
1. **Tamil fixture: done.** `tests/fixtures/NotoSansTamil.ttf` and its OFL license file are checked in, from google/fonts commit `7af0d90b4d532ffa4b041937b560c6df4e7b1e95`, with bytes unchanged. The license is recorded in `docs/dependency-policy.md` ("Test fixtures"). The lock has a new entry with tree hash `75c12e3d397b0f7abf68fec99befd428ae2bf638ecb2232fd1b106da7a4c5e15`, and `scripts/check-dependency-pins.py` verifies it. `shaper_tamil_test.zig` is registered in `tests.zig`. In the upload, the checker still fails on the six `vendor/` entries, which are absent from the upload. Its output is otherwise identical to the original upload's.
2. **Line-break policy: accepted,** including its limit. A combining mark directly after a space starts the next line. A test pins that behavior, so a change to it will be visible.
3. **Glyph fallback: unchanged.** A glyph ID past the font's end still draws the fallback, as in Phase 4. Whether `?` maps through the character map is still a Phase 7 decision.
4. **E-01 pinned Zig build/test matrix: passed.** The earlier sandbox-only limitation is superseded by GitHub Actions run #112 at commit `f4abef0f7528e36658eb1d5c106d88b9f1769ded`. Windows, Linux, and macOS results and job links are recorded in section 6.4. The sandbox boundary scan (`scripts/boundary_scan.py --fail`) also reported zero reachable violations. This does not close E-02, E-03, or E-04.


### Owner status correction (2026-11-18)

The following implementation status is authoritative and overrides any implication elsewhere in this document that Phase 1 or Phase 2 code has already been written:

- **Phase 1 implementation: not started.** D-01 through D-06 and D-07 are decisions, not completed code. The rectangle path and font identity work still need implementation. Preserve the 9 px debug-font default. The `config.zig` and `application.zig` disagreement is resolved in this upload: both are 9 px (owner-confirmed 2026-11-18).
- **Phase 2 implementation: not started.** D-08 and D-09 are decisions only. The BMFont importer/descriptor validation and the selected 8×8 example asset still need to be created, registered, and tested.
- **Phase 3:** tests and shaping code exist; the pinned cross-platform CI evidence is now recorded under E-01. This does not waive the formal phase-entry dependency on Phases 1 and 2.
- **Phase 4:** cache/atlas/resolver work and the production flush are integrated. E-02 passed with the overflow-safe region-spill burst; the SDL3 2D and remaining lifetime/visual checks are still open.
- **Phase 5:** runtime glyph submission, provider-based widget measurement/drawing, and the shared GPU/SDL3 2D flush are integrated. SDL3 2D device behavior and visual compatibility checks remain open.
- **Sample scene migration:** N/A. `sample/main.zig` and `sample/benchmark.zig` draw textures only and call no text API.
- **Findings:** (1) `build.zig` line 204 links HarfBuzz into the shipped engine module. The comment at line 595 already says the engine module links HarfBuzz as well (`configureEngineModule`), so no change is needed in this upload. Owner-confirmed 2026-11-18. (2) Debug font defaults: `config.zig` and `application.zig` are both 9 px in this upload, which is the accepted value. Owner-confirmed 2026-11-18. (3) The sample scene has no text call sites, so there is nothing to migrate there.

These are status and scope corrections, not evidence that implementation work is complete.

### Implementation status correction (2026-11-19)

This update supersedes the implementation statuses above for the current worktree; it does not close a phase:

- **Phases 1 and 2:** provider dispatch, outline and bitmap insertion, manifest/descriptor validation, and the common Canvas-facing APIs are integrated. Their visual and device exit gates remain open.
- **Phase 3:** numeric shaping expectations were verified against pinned HarfBuzz 15.1.0; its exit remains gated on Phases 1 and 2.
- **Phase 4:** the production atlas is session-owned, overflow spills individual changed regions, and the shared flush is wired before either renderer submission path. The E-02 run is recorded in section 6.4; E-04 and remaining Phase 4 exit checks remain open.
- **Phase 5:** runtime glyph records now reach the common quad submission path. Existing APIs remain in place; broader visual compatibility and the SDL3 2D path remain unverified.

### Sandbox progress (2026-11-18): Phase 1 contract, partial

This note records work done in the sandbox. It does not change the owner status above, and Phase 1 remains open until the owner accepts a status change and the Phase 1 exit gate passes.

**Landed (CPU code, Zig not compiled in the sandbox):**
- `src/engine/text/font_registry.zig` (new): `FontId` (`u64`, zero invalid, never reused, `FontIdExhausted` at the top of the range), `FontHandle`, and `Registry(T)` with insert, get, and remove. It imports only `std`. Nine Zig tests, registered in `src/tests.zig`.
- `src/engine/text/shaper.zig`: `ShapedRun.font_id` (D-03), `Shaper.font_id`, and `Shaper.initWithFontId`. `Shaper.init` keeps its signature and delegates with the invalid id, so existing callers are unchanged. Three Zig tests.
- `checks/font_registry_mirror.c` and `checks/font_registry_RESULTS.txt`: 41 of 41 checks pass under `-Werror`, ASan, and UBSan. Five planted bugs each fail the checks written for them. The mirror does not compile the Zig.
- `ui_quad` gains a `solid` flag (`src/engine/ui/ui_draw.h`). `ui_quad_push` sets it to 0 for glyphs. The new `ui_quad_push_solid` sets it to 1. `imgui.c` `fill()` and `Canvas.rect` use the solid path. Behaviour is unchanged: `checks/ui_solid_check.c` passes 20 of 20, and `checks/ui_quad_dump.c` prints identical output for the original upload and this tree across a five-frame widget scenario with a click and a slider drag. The UI test harness in `tests/ui` needs `vendor/`, which is absent from the upload, so it was not run in the sandbox. The owner ran it locally; see the owner run below.
- Font ids widened from `u32` to `FontId` (`u64`) in `glyph_cache.zig`, `glyph_resolver.zig`, `glyph_records.zig`, and `renderer/glyph_check.zig`. The cache hash folds the high 32 bits into the 32-bit mix, so ids that differ only above bit 31 still spread across slots. Equality compares the whole id. One new Zig test, mirrored in `checks/glyph_cache_mirror.c` (2199 checks, was 2191). 22 of 22 mirror mutants caught, including the new `MUT_FONT_TRUNCATED`. Parity: 50 Zig tests, 47 mirrored.

**Verified in the sandbox, unchanged:**
- The Phase 0 characterization harness: 70 of 70, no warnings.
- `checks/glyph_cache_mirror.c`: 2191 checks, 0 failures, under ASan and UBSan.
- `scripts/boundary_scan.py --fail`: 0 reachable violations. Its self-test: 3 of 3.
- `scripts/check-dependency-pins.py`: fails only on the six `vendor/` entries absent from the upload, as documented in the Phase 1 notes above.

**Not done, with the reason:**
- **`FontResource` tagged union and the Canvas and UI migration (D-01, D-05).** These touch `ui.zig`, `imgui.c`, and `runtime.zig`. They need a compile and the E-03 screenshot baseline.
- **Rectangle decoupling, renderer half (D-04).** The C side is done (see Landed). The 2×2 white block lives in every font atlas (`tools/assets/font_bake.c:205, 360`; `src/engine/text/text.c:200`). `Canvas.rect` (`src/engine/ui/ui.zig:141, 149`), the C widget path (`src/engine/ui/imgui.c:52`), and `queueQuads` all draw from the font texture. Decoupling needs a renderer-owned white texture on both SDL_GPU and the SDL3 2D path, and per-quad texture selection. Checking it needs a device (E-02, E-04).
- **A Zig test for the registry's out-of-memory rule: written, not compiled in the sandbox.** `font_registry.zig` now has a test that uses `std.testing.FailingAllocator` with `fail_index = 0`, the pattern `glyph_cache.zig` and `allocators.zig` already use. It checks that a failed insert stores nothing and spends its id, and that the next attempt issues id 2 whether or not its allocation succeeds. The owner's `zig build test` is the first check of it.

**Owner local run (2026-11-18): not a CI gate run.** Platform: Windows, in PowerShell at `D:\repo\Bairava-Engine`. Toolchain: `zig version` prints `0.16.0-dev.3142+5ccfeb926`, the pinned toolchain in section 6.4. Branch: `text-migration`, up to date with `origin/text-migration`. HEAD: reported as commit `9e8039d`. `git status` reports a clean working tree and `git diff --stat` is empty, so the tree that was built and tested is HEAD, and the changes in the zip are committed. Console results: `zig build test` succeeds (owner report), and `zig build test-ui` printed `imgui: all checks passed` and `text: all checks passed`. The `test-ui` run exercises the `solid` change in `imgui.c` and the unchanged text path, through the repository's own C UI tests with real fonts. This is a local record, not a CI run, and it does not close E-01, which is tied to commit `f4abef0`. Two things would make it gate evidence: a saved log of these commands, and a CI run for `9e8039d`. The branch is pushed, so CI may already have run on it. A link to a passing run for all three platforms would use the E-01 record format. Not yet reported: `scripts/check-dependency-pins.py`, `scripts/boundary_scan.py --fail`, and `zig build check-assets`.

**Gates:** nothing here closes E-02, E-03, or E-04. The owner's local run above covers the Zig build, the Zig unit tests, and the C UI tests for this tree on the pinned toolchain. It does not close E-01, which is tied to commit `f4abef0`, or any device gate.

### Sandbox progress (2026-11-18, second pass): FontResource, metrics, and TextOptions

This note records the second pass on Phase 1 in the sandbox. The owner status above still governs, and the Phase 1 exit gate remains open.

**Landed (CPU code; Zig not compiled in the sandbox):**
- `src/engine/text/font_resource.zig` (new): `Provider`; `FontResource`, a tagged union over `bfnt_coverage` and `runtime_coverage` with `provider`, `deinit`, and `metrics`; `FontMetrics`; `Resources = Registry(FontResource)` with `metricsFor` and `release`; `Direction`, which has one value, `ltr` (D-06); and `TextOptions` with `shaperOptions()`. Seven Zig tests, registered in `src/tests.zig`.
- `src/engine/text/runtime_font.zig`: `RuntimeFont.line_gap` stores the hhea line gap, in font units, for `FontMetrics`. No other field or behavior changed.
- `build.zig`: the root test module gets the `src/engine/ui` include path and `src/engine/text/text.c`, so the BFNT provider's C import and its deinit link in `zig build test`.
- `checks/font_resource_check.py` and `checks/font_resource_RESULTS.txt`: 10 of 10 checks pass. The script reads `assets/font.ttf` directly. It confirms the hhea values (ascender 1854, descender -434, line gap 67, 2048 units per em) and the values the Zig tests assert at 16 px: ascent 12.96503, descent 3.03497, line gap 0.46853, natural line height 16.46853.

**Not done, with the reason:**
- The `bitmap` and `msdf` variants. They belong to Phases 2 and 6, which have not started.
- The `Canvas` and UI migration (D-05). It touches `ui.zig`, and it needs a compile and the E-03 baseline.
- Rectangle decoupling, renderer half (D-04). It needs a device.
- Loading into `Resources`. Nothing calls it yet. The first caller is the Canvas migration.
- Rounding of metrics. `FontMetrics` is unrounded, and Phase 5 consumers round the way `text.c` does.

**Convention (accepted by the owner, 2026-11-18, recorded as D-20):** a BFNT font's descent is derived as `line_height` minus `ascent`, and its line gap is zero, because the file stores neither. `bfntMetrics` in `font_resource.zig` already does this, so no code change follows from the decision.

**Verification:** `python3 checks/font_resource_check.py` gives 10 of 10 (sandbox).

**Owner local run (2026-11-18, Windows): `zig build test` FAILED.** The log shows 30 of 33 steps and 13 of 13 tests passing. The job, asset importer, imgui, text, and script tests passed. The root test module failed to compile with three errors: `src/engine/ui/c.zig` could not find `imgui.h`. It was reached from `src/engine/text/font_resource.zig`, which holds the BFNT provider, and from the BFNT metrics test. An earlier note recorded this run as a pass. That note was wrong, and it has been corrected here.

**Fix:** `build.zig` gives the root test module the `src/engine/ui` include path and compiles `src/engine/text/text.c`, as `configureEngineModule` does for the engine. In gcc, `text.c` compiles with `-Wall -Wextra -pedantic` and needs only libc, and `imgui.h` parses as C with that include path.

**Owner local rerun (2026-11-18, Windows): `zig build test` and `zig build` both reported as succeeding.** This is an owner report without a saved log or a commit hash, so it is recorded as reported and not as evidence. `zig build` does not compile `font_resource.zig`, which nothing in the application imports. That file is covered only by `zig build test`. To count as evidence, the run needs its commit hash and a saved log. Until then, the Phase 1 test gate stays open. This run does not close E-01, E-02, E-03, or E-04.


**Owner local run (2026-11-19, Windows): `zig build test` exited with code 0.** The owner reported the exit code after running the command in PowerShell. Earlier the same day, a run printed `failed command` for `test.exe` with no failing test named, and that failure is not explained. The commit and a saved log for the exit-0 run have not been reported. Recorded as reported, not as evidence. The same run printed `text: all checks passed`, from the C text harness that `zig build test` also runs. Whether that harness included the BFNT v2 changes was not confirmed.
The commit and a saved log have not been reported for any run. Until a passing log is recorded, the Phase 1 test gate stays open. These runs are not CI gate runs, and they do not close E-01, E-02, E-03, or E-04.


### Sandbox progress (2026-11-18, third pass): Canvas rectangles (D-04)

This note records the first slice of the Canvas migration. The owner status above still governs, and the Phase 1 exit gate remains open.

**Landed (Zig and CPU; not compiled in the sandbox):**
- `src/engine/renderer/sprite.zig`: `SpriteBatch.white`, a 2x2 coverage texture at full coverage. `SpriteBatch.init` creates it from the device the way it creates `flat_normal`, and `deinit` releases it. `createCoverage` sets the coverage flag, so solid fills use the same pipeline as before.
- `src/engine/ui/ui.zig`: `queueQuads` draws a solid quad (`solid` set) from `batch.white` and ignores the quad's `src`. With `batch.white` null, a solid quad falls back to the font's white block. Three tests cover a fill on the white texture, a glyph followed by a fill, and the fallback.

**Unchanged:** the public signatures of `Canvas.text`, `textWidth`, `layoutText`, `drawTextLayout`, and `rect`, and of `Canvas.create` and `Ui.init`. The C side is unchanged, and glyph quads still sample the font atlas.

**Not done, with the reason:**
- Moving the font from `*Font` to a `FontHandle` in the registry. This changes game-facing code, and it needs a decision on which module owns the registry. It is the next slice.
- Device checks on SDL_GPU and the SDL3 2D path (E-02, E-04).
- Visual checks against reference screenshots (E-03).

**Behavior note:** fills and glyphs now break draw runs at each texture change, so a frame that mixes them can issue more draw calls. The sampled coverage values are the same, so the output should match. E-03 confirms it, and the debug overlay shows the draw-call count.

### Sandbox progress (2026-11-19): D-21 with no allowances

This note records sandbox work. The owner status above still governs. The sandbox has no Zig toolchain, so nothing here is compiled.

**Owner decision (2026-11-19):** `D21_DEBT` is empty. No exposure is allowed. The exposures are fixed in code, not listed as debt.

**Scanner, strengthened first.** Before this change, the gate could not see some exposures. It did not follow a re-export under a clean name into the file it names, and it did not judge a private type alias. Under the strengthened gate, the original upload shows **9** exposures, not 7. The seven listed in `D21_DEBT` are `context.zig:182`, `context.zig:457`, `ui.zig:20`, `ui.zig:24`, `ui.zig:85`, `ui.zig:91`, and `ui.zig:201`. Two were not listed: `text/font.zig:16` (`Font.baked`, a `c.ui_font` field) and `text/font.zig:19` (`Font.deinit`). Both were reachable through the old `ui.Font` re-export. The plan's Phase 1 notes already recorded one earlier miss (`Canvas.fonts`). These are a second and third. The strengthened scanner also flagged `font_resource.zig:118` (`metricsFor`). That was a scanner error: a single-line declaration ran on into the next function body. It is fixed, and a self-test pins it. `metricsFor` is not reachable from game code.

**Landed (Zig; not compiled):**
- `src/engine/text/font_store.zig` (new). `FontStore` is an opaque type. Its methods take a `FontHandle` and return widths, heights, quad lists, texture pointers, or C widget state. Its state is a private struct in that file. The engine-only functions (`create`, `destroy`, `discard`, `count`, `insertBfnt`) sit outside the type and are not re-exported by `bairava.zig`.
- `ui.zig`: the `Font` and `Fonts` re-exports are gone. `Canvas.fonts` and the `create` and `init` parameters are `*FontStore`. The `Canvas` text, measurement, layout, and queue signatures are unchanged (D-05). The `Canvas` layout-validation test moved here from `engine_api_test.zig`, because building a store is an engine-internal step.
- `context.zig`: `fonts` is `*font_store.FontStore`. `fontOf` is removed, because nothing called it. `loadFont` passes the upload to `insertBfnt`, which releases the font if the insert fails.
- `lifecycle.zig`, `debug_overlay.zig`, `engine_api_test.zig`, `tests.zig`: updated for the new type. `game.zig` and `runtime.zig` are unchanged, because `ctx.fonts` keeps its call shape.
- `scripts/boundary_scan.py`: `D21_DEBT = []`. Re-export following and private-alias judgment added (see the scanner note above). `checks/boundary_d21_negative_tests.py`: anchors moved off removed lines; N3 tests a stale entry in an empty list; N8 and N9 cover the two holes above.

**Verified in the sandbox (scanner and Python only):**
- `scripts/boundary_scan.py --fail` on this tree: 0 known, 0 new, 0 stale, 0 HarfBuzz names outside `src/engine/text/`. Exit 0.
- `scripts/boundary_scan.py --self-test`: 3 of 3 fixtures, 4 of 4 cases.
- `checks/boundary_d21_negative_tests.py`: 9 of 9 cases.
- On the original upload, the strengthened scanner exits 1 with 9 exposures, 7 listed and 2 not.

**Not verified:**
- Owner run of `zig build test` on Windows (2026-11-19, after this change). It reported one compile error, in the `font_store.zig` test helper: the `Texture` literal `.{}` lacked four required fields (`gpu_state`, `width`, `height`, `has_upload_fence`). Fixed here with `fixtures.texture(1, 1)`, the helper the other tests use. The same literal was already in the original `ui.zig` tests, so those tests were broken if they ever ran. The fix is not yet rerun. The run's summary reported 13 of 13 tests passed for the root, and the second root (`engine_api_test.zig`) does not appear in the output, so its status is unknown.
- Coverage gap. `tests.zig` does not import `ui.zig`, and no build step runs `ui.zig`'s Zig tests, so the layout test that moved there has not run. Those tests call `imgui.c` functions, which the test root does not link, so running them needs a build change. That is a decision for the owner.
- `FontStore.initWidgets` is compiled only by the app build, through `Ui.init`. The owner's next run should be `zig build` as well as `zig build test`.
- The E-03 visual baseline. The draw path keeps the same quads and texture choices, but the owner should check the debug overlay and the widget screen before accepting the change.

**Accepted as D-22, subject to four boundary constraints (owner, 2026-11-19).** The opaque `FontStore` API and its handle-only method set are accepted. The constraints: `FontStore` owns font resources; game-facing APIs expose `FontHandle` and plain `FontMetrics`, not internal font resources; HarfBuzz and SDL types stay hidden from game-facing code; and the strict D-21 scanner enforces the boundary with `D21_DEBT` empty. This acceptance does not, by itself, mean Phase 1 is complete or that the D-21 implementation gate has passed. D-21 stays `[ ]`.

**Remaining limit of the gate.** It is text-based. It does not resolve a field or parameter type through a local name that is not a re-export, and a private alias is judged only when it is a top-level type alias in a surface file. A type can still be hidden behind a name the scanner cannot see. Review remains necessary.

---

---

### Sandbox progress (2026-11-19, fourth pass): diagnostics surface

This note records sandbox work on Phase 1 items 383 and 384. The owner status above still governs. The sandbox has no Zig toolchain, so the Zig changes here are not compiled.

**Landed (Zig; not compiled):**
- `src/engine/text/font_store.zig`: `FontStore.stats()` returns `Stats`, the number of fonts and their count by provider (`bfnt_coverage`, `runtime_coverage`). `FontStore.describe(handle)` returns `Description`, the source (`bfnt_prebaked` or `runtime_outline`) and the mode (`prebaked_coverage` or `gray_coverage`). Both are plain values. The stats walk the registry's entries, so no separate counter can drift from the stored fonts. Two tests cover an empty store and a stored bfnt font.

**Verified in the sandbox (scanner and Python only):**
- `scripts/boundary_scan.py --fail`: 0 known, 0 new, and 0 stale exposures; 0 HarfBuzz names outside `src/engine/text/`. Exit 0.
- `scripts/boundary_scan.py --self-test`: 3 of 3 fixtures and 4 of 4 cases. `checks/boundary_d21_negative_tests.py`: 9 of 9 cases.

**Not done, with the reason:**
- Glyph lookups, misses, and atlas page count. These exist in `glyph_cache.Stats`, but `FontStore` does not hold the cache, and the bfnt path makes no glyph-cache lookups. Item 383 stays `[~]` until the renderer side reports them through the store or the debug overlay.
- Display of the description in the debug overlay. Item 384 stays `[~]`. That needs a device check (E-03).
- Insertion of runtime fonts. `FontStore` can count and describe them, but it has only `insertBfnt`. The runtime path is tested through `FontResource` tests.

**Correction to the coverage-gap note in the third pass above.** That note says the test root does not link `imgui.c`. In this upload, `build.zig` links `src/engine/ui/imgui.c` into the test module (line 620, with the include path on line 616). The note is out of date for this upload. The owner's Windows run of `zig build test`, after the `ui.zig` import was moved inside the test block, is the check that settles it.

---

### Owner local run (2026-11-19, Windows): one failing test, cause found and fixed in the sandbox

The owner's `zig build test` at `D:\repo\Bairava-Engine` (Zig `0.16.0-dev.3142+5ccfeb926`) ran the root test module with 713 of 714 passing. The only failure is `engine.text.bfnt_measure`, "the BFNT measurement port returns the same float bits as text.c": expected `1115540685`, found `1115540682` (`0x427DCCCD` from text.c, `0x427DCCCA` from the port). `engine_api_test.zig` reported 13 of 13, so 726 of 727 tests passed overall. The C harnesses in the same run passed (job, asset importer, script, text, imgui).

**Cause.** Reproduced in C with `checks/bfnt_fp_contract_repro.c`, using the Zig test's inputs, the same values as the owner's log, and the same loop order. When text.c is compiled for an FMA-capable target, Clang and GCC fuse `width += kerning * scale` and `width += xadvance * scale` into single-rounding multiply-adds. The Zig port never fuses. With fusion, text.c and the port disagree in 3 of 456 comparisons; without it, they agree in all 456. The Linux mirror passed earlier only because it was built without FMA.

**Fix (uncompiled).** `build.zig` compiles `text.c` with `-ffp-contract=off` at all four sites, through one `text_c_flags` array: the UI test harness, the engine module, the asset builder, and the test module. `bfnt_measure.zig` names the flag in its header. This is a compile setting, not a format, API, or dependency change, so it adds no entry to section 6.2. It makes the bit-for-bit parity hold on every target, which is what the port was written to guarantee.

**Acceptance.** The owner reruns `zig build test` on the commit containing this change. The sandbox has checked the arithmetic only. It has not compiled the build change, so this does not close any environment gate. E-01 needs a CI run on that commit.

## Phase 6 — MSDF asset generation and rendering path

**Purpose:** Add scalable outline-font rendering without replacing bitmap or coverage rendering.

**Decisions:** D-17, D-18. **Entry:** Phase 5 closed. **Environment:** E-01 (SPIR-V, DXIL, and MSL builds), E-04.

### Needs — must implement

- [ ] Integrate the selected MSDF generator as an offline asset-build tool, with a pinned version and reviewed license. D-17 is accepted (2026-11-19). Target msdfgen 1.13.1 (D-17, pin OPEN). License: MIT per the upstream master text (2026-11-19); the 1.13.1 tag's `LICENSE.txt` still needs confirming. Blocked: the 1.13.1 tag's API, CMake options, and dependency graph, and the vendored source (D-25). Open: the final pixel format and packer (D-26). Its output is the SDL_GPU asset under D-24.
- [ ] Define a versioned MSDF asset descriptor containing font identity/metrics, glyph IDs, atlas page, atlas bounds, plane bounds, pixel range/distance range, and any generator parameters required at runtime.
- [ ] Generate MSDF from supported vector outlines. Do not make bitmap-to-vector conversion part of the normal asset pipeline.
- [ ] Validate the generator's handling of corners, small counters, thin strokes, punctuation, and the chosen font corpus.
- [ ] Add an MSDF font importer/loader that returns the same glyph-render-record interface as the bitmap and coverage providers.
- [ ] Add an MSDF fragment shader using the selected distance-field interpretation and correct screen-space range calculation.
- [ ] Extend the GPU sprite pipeline/run classification so normal sprites, coverage glyphs, and MSDF glyphs select the correct shader. A single `coverage: bool` is insufficient once MSDF is added; use an explicit render/material mode.
- [ ] Add per-texture sampling policy. The current global nearest sampler should remain for pixel art; MSDF assets need their validated sampling mode (normally linear) without changing unrelated textures.
- [ ] Extend shader generation/embedding for SPIR-V and the optional DXIL/MSL targets.
- [ ] Define SDL3 2D renderer behavior. Recommended initial policy: MSDF is rendered on SDL_GPU; an MSDF asset also supplies a prebaked coverage/bitmap fallback for the SDL3 2D renderer. If no fallback exists, report the unsupported mode clearly rather than sampling MSDF as ordinary RGBA. Blocked: D-18. D-18 (accepted 2026-11-19) rules out MSDF on this path, so coverage or bitmap glyphs are used there. Resolved by D-24: the coverage/bitmap fallback is generated separately from the same source font, never from the MSDF texture.
- [ ] Test the same outline font through runtime coverage and MSDF at small, medium, and large sizes. Blocked: E-02, E-04.
- [ ] Keep pixel fonts on the bitmap path even when their style resembles a vector outline.

### Wants — useful but not blocking

- [ ] Add MSDF atlas visualization tooling to inspect RGB distance channels and glyph rectangles.
- [ ] Compare atlas sizes, visual quality, memory, and draw performance against the coverage path.
- [ ] Support multiple MSDF atlas pages if the asset corpus requires them. Conditional on the corpus (section 6.5).

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

**Decisions:** D-13 (fallback chain and `?`), D-14 (memory), D-15 (performance targets). **Environment:** E-02 and E-04 for lifetime and recreation tests.

### Needs — must implement

- [x] Finalize runtime missing-glyph behavior: resolve to the same face's `?` once after shaping, or draw no ink if absent. No font chain is added without a real string that needs a second face.
- [x] Define unload behavior for queued draws: invalidate the handle immediately and retain the font allocation/resources until session shutdown after the GPU-idle wait.
- [x] Preserve the fixed runtime atlas ceiling and explicit `AtlasFull` error; text quad-list exhaustion also returns `QuadListFull` instead of silently reporting success.
- [ ] Test renderer/device recreation, upload failure, asset reload, repeated font load/unload, and shutdown ordering. CPU ownership and fallback tests pass, but device-backed cases remain blocked on E-02/E-04; `SDL_UploadToGPUTexture` does not return an upload status.
- [ ] Ensure a cache miss cannot cause unsafe atlas mutation during a draw already submitted to the GPU.
- [ ] Document that full bidi paragraph processing is separate from HarfBuzz shaping; add a bidi dependency/phase only if the engine's target language requirements need it.

### Wants — optional enhancements

- [ ] Subpixel positioning for smooth UI typography, only if it does not undermine pixel-font rendering.
- [ ] Variable-font axis selection. Conditional on D-10 (section 6.5).
- [-] Rich-text spans with multiple fonts/styles in one paragraph. N/A: rich text is a non-goal (section 3).
- [ ] Font prewarming based on localization bundles or known dialogue.
- [ ] LRU cache eviction if telemetry shows page growth is too expensive.

### Deliverable

A stable font runtime with predictable fallback, memory limits, lifetime behavior, and diagnostics.

### Exit gate — Phase 7 is complete only when

- [x] Missing glyph and fallback behavior is covered by automated tests.
- [ ] Font and atlas lifetime tests pass under repeated load/unload and renderer shutdown/recreation.
- [x] Memory ceilings and cache exhaustion behavior are documented and observable.
- [ ] No known use-after-free or in-flight GPU resource hazard remains.
- [ ] Any deferred Unicode/bidi/font-format limitations are documented in the public text guide.

**Implementation note:** Runtime `?` fallback is tested for an unmapped codepoint, an out-of-range glyph id, and a font without `?`. `Context.unloadFont` retires resources until the session's shutdown idle wait; a CPU test verifies that the resource remains allocated after handle invalidation. Shutdown now waits for GPU idle before releasing GPU owners, including when no frame was submitted, then destroys batches and atlas textures before the remaining font/shaping objects. Device recreation, an injected upload failure, and display-backed lifetime validation are still open; do not treat this phase as complete.

---

## Phase 8 — Cutover, regression suite, documentation, and cleanup

**Purpose:** Make the unified system the supported path without prematurely deleting compatibility code.

**Decisions:** D-19. **Environment:** E-01, E-03, E-04.

### Needs — must complete

- [ ] Run the full test suite: `zig build test`, `zig build test-ui`, `zig build check-assets`, and the repository's boundary/dependency checks. Blocked: E-01, E-03.
- [ ] Run asset-builder tests for bitmap, BFNT, and MSDF inputs, including malformed and unsupported assets.
- [ ] Run CI on Linux, Windows, and macOS; verify the supported shader targets and C/C++ dependency linkage. Blocked: E-01.
- [ ] Compare screenshots against Phase 0 baselines for existing UI, debug overlay, console, and widgets. Blocked: E-03, E-04.
- [ ] Add visual reference tests for bitmap fonts, Latin shaping, Tamil shaping, and MSDF at multiple sizes.
- [ ] Profile cold-cache and warm-cache text workloads: shaping time, rasterization count, upload cost, cache hit rate, draw calls, memory, and frame time. Blocked: E-02.
- [ ] Rewrite `docs/text.md` to explain font formats, asset authoring, rendering modes, supported shaping, sampling, fallback, and limitations.
- [ ] Update README asset-pipeline notes and public API documentation.
- [ ] Update dependency policy/lock records for HarfBuzz and the MSDF generator (and runtime FreeType if selected).
- [x] Decide the status of old C text code: keep it as a BFNT compatibility adapter or remove it only after all consumers have migrated and compatibility tests prove it is unused. → D-19. Accepted 2026-11-19: kept temporarily as a BFNT compatibility adapter. Removal is a later, separate cleanup once every consumer and asset has migrated.
- [ ] Preserve old `.bfnt` assets or provide a deterministic migration tool before changing/removing a format. *(Under D-19, BFNT loading is kept, so the format does not change. A migration tool is needed only if the format is changed.)*

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
| 1 | Shared model and compatibility | One font/text contract over existing BFNT | D-01 to D-07 are Accepted; implementation required. E-03 is waived with caveat, and its baseline comparison is not evidenced |
| 2 | Bitmap importer and renderer | First-class hand-authored pixel fonts | D-08 and D-09 are Accepted; Phase 1 must close, then importer/asset and visual tests must pass |
| 3 | HarfBuzz and runtime font face | CPU shaping service | Cross-platform dependency build and shaping fixtures pass (E-01) |
| 4 | Runtime rasterizer and glyph cache | On-demand coverage glyphs | Cache, upload, atlas lifetime, and synchronization tests pass |
| 5 | Shaped layout and UI integration | New text system used by engine consumers | Latin/Tamil layout, measurement, and UI regression tests pass |
| 6 | MSDF generation and renderer | Optional scalable outline path | Shader, sampling, visual, and secondary-renderer fallback tests pass |
| 7 | Fallback and hardening | Predictable runtime behavior | Memory, lifetime, missing-glyph, and error behavior are covered |
| 8 | Cutover and documentation | Supported unified subsystem | Full CI, visual baselines, docs, and dependency records pass |

**Decision order.** D-01 to D-07 define the Phase 1 contract; Phase 1's provider/API work is integrated, but its visual/device gates remain open. D-08 and D-09 define the Phase 2 descriptor and example asset; Phase 2's owner-requested implementation is integrated provisionally despite the still-open Phase 1 entry gate, and its visual gate remains open. Phase 5 depends on the Phase 1 API/font/rectangle decisions and the required preceding phase gates. Work written ahead of those implementation gates remains provisional (section 6.1).

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
- [ ] `Canvas`, widgets, console, and diagnostics use the common API. The sample draws no text and is N/A (section 6.5).
- [ ] Every decision in section 6.2 is Accepted or changed, with a date.
- [ ] Every environment gate in section 6.4 has a recorded run.
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
