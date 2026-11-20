**Current implementation status:** The common provider path, bitmap validator/loader, HarfBuzz shaping/layout, runtime atlas submission, and MSDF pipeline are implemented. This update adds CPU-backed text-resource rebuild hooks, retryable atlas dirt through successful frame submission, idle-safe font retirement, a deterministic typography reference workload, and shaping/cache/upload profiling. SDL device-loss recovery and per-copy upload confirmation remain constrained by the current platform API. Display-backed comparison and fresh cross-platform CI remain acceptance gates.

This is the implementation decision and evidence record; [text.md](../text.md) is the concise guide to current behavior.

# Bairava Engine — Text and Font System Migration Plan


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
| Existing `.bfnt`, as a BFNT compatibility adapter (temporary, D-19) | Prebaked R8 coverage atlas loaded from file. | Loaded as a provider in `FontResource`; measurement and drawing use the shared text surface and quad submission, with the old C implementation retained as a private compatibility adapter. | Nearest coverage pipeline, static atlas (not the dynamic cache). | Same coverage page through the ordinary texture path. | The adapter remains until a later, separate cleanup after every legacy consumer has migrated. |
| Runtime outline coverage (dynamic text, scalable outline fonts) | TrueType `glyf` face (D-10), rasterized on demand per glyph ID with `stb_truetype`. | HarfBuzz shaping with default features (D-16); shaped layout; glyph cache keyed by font ID, glyph ID, size, and mode; four-page R8 atlas (D-14). | Dynamic coverage pages uploaded with one frame flush before sprite submission. | The same coverage pages synchronize before 2D draws. | No CFF/CFF2 (D-10), runtime FreeType (D-11), or paragraph bidi (D-06). Missing glyphs resolve once after shaping to the same face's `?`, otherwise draw no ink. No fallback chain or eviction. |
| MSDF (scalable outline fonts, UI) | Offline msdfgen 1.13.0 at commit `1874bcf7d9624ccc85b4bc9a85d78116f690f35b` (D-17, D-25), baked as MFNT v1 from vector outlines. It is not derived from the coverage asset or a bitmap. | Same shaped glyph IDs and layout positions as the coverage path; baked metrics; common text surface. | MSDF fragment shader (median of RGB), with a clamp-to-edge linear sampler selected per texture. | Draws the coverage sibling baked from the same source font (D-18, D-24), never the raw distance field. | No runtime MSDF generation or bitmap-to-vector conversion. 1024×1024 per-font cap (D-26); the msdfgen dependency is asset-builder-only. |

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
2. **Implementation.** The Needs and Future enhancements lists. Each item is done, partly done, not started, or N/A (section 6.3).
3. **Environment.** Validation that needs a toolchain or hardware the work environment may not have (`E-xx`, section 6.4). An environment gate closes only on a recorded run.
4. **Exit gate.** The phase's exit criteria. A phase closes only when they pass, are reviewed, and are recorded here.

Gate policy: do not start a phase's implementation until its decisions are Accepted. Do not start the next phase simply because the current code compiles. A phase may be split into smaller PRs, but its gate remains mandatory.

**Current state:** Phases 1–8 implementation paths are present. This does not close their required visual/device acceptance items or replace fresh cross-platform CI. E-02's GPU-debug burst/synchronization run is recorded below; E-04 remains open. Text-resource rebuild helpers are scoped to a valid GPU device because the current SDL integration has no device-loss replacement hook.

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
| D-07 | Debug overlay and console font: one definition, 9 px mono, `assets/ui_font_9px.bfnt`. Defined once in `application.zig` (`default_debug_font_path`, `default_debug_font_px`); `src/game/config.zig` reads it. | Phase 1 | Accepted by direction (owner, 2026-11-18): preserve 9 px. The shared definition is implemented and consumed by game config. |
| D-08 | **Use the established AngelCode BMFont text descriptor format** for hand-authored bitmap font metadata. Parse/import it into Bairava-owned normalized structures; do not expose BMFont types as public engine API. | Phase 2 | **Accepted with change (owner, 2026-11-18)** |
| D-09 | Use `dhepper/font8x8` `font8x8_basic` as the initial 8×8 monochrome ASCII pixel-font source, pinned to commit `4876b70490600222f30bb9acd2c02868e390bb56`. Include printable ASCII U+0020–U+007E; 16 columns × 6 rows (128×48 atlas); fixed 8-pixel advance; space has no ink; `?` is the initial fallback. The repository identifies the font data as public domain. The asset is generated from the pinned commit, checked in with its notice, and validated through coverage rows packaged as `.r8`. | Phase 2 | **Accepted and implemented; asset provenance and descriptor/importer tests are recorded in Phase 2.** |
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
- **E-03, historical baseline screenshots — WAIVED WITH CAVEAT (owner decision, 2026-11-19).** The waiver covers capturing the old BFNT baseline before the `Canvas` change; it is not screenshot evidence and does not accept the new provider paths. The repository contains no baseline images, log, or commit for that visual comparison. New bitmap, runtime coverage, Tamil, MSDF, and both-renderer acceptance items remain open until their own captures are reviewed. E-04 (the SDL3 2D device run) is still open.
- **E-04, SDL3 2D renderer on a device — OPEN.** Requires `sdl2d_available` to be set (`application.zig`) and the 2D path to run. Closes: the Phase 4 and Phase 5 both-renderer items, the Phase 6 MSDF fallback, and the Phase 7 device-recreation tests.

## 6.5 N/A and conditional items

Two kinds appear here, and they are kept apart.

- **Evidence N/A.** `sample/main.zig` remains a game sample with no text calls. `sample/text_benchmark.zig` is the separate deterministic typography reference workload. Rich-text spans are out of scope (section 3).
- **Conditional items.** Optional work whose trigger is not met belongs in section 12. D-08/D-09 bitmap support is implemented. Feature overrides, non-default variable-font axes, fallback chains, bidi, eviction, and additional MSDF pages remain conditional on a concrete requirement.

## Phase 0 — Baseline audit and design decisions

**Purpose:** Remove ambiguity before changing formats, dependencies, APIs, or renderer behavior.

**Decisions to record here:** D-08, D-10 to D-15, D-17, D-18 (section 6.2). All are accepted: D-08 on 2026-11-18, the rest on 2026-11-19. **Environment:** E-03 for the baseline screenshots.

### Needs — must complete

- [x] Inventory all font load, measure, draw, and layout call sites in engine, sample, game, overlay, console, widgets, and tests. Evidence: the call-site inventory in the Phase 0 decision sheet. The sample draws no text, so its part is N/A (section 6.5).
- [~] Record current public behavior: font pixel-height rules, baseline/top-left convention, ascent/line-height, kerning, fallback glyph, UTF-8 error behavior, wrapping, alignment, color/alpha, clipping, and pixel snapping. The C characterization harness passes 70 of 70 (gcc 13.3, `-std=c11 -Wall -Wextra -pedantic`, no warnings). Zig tests cover text internals, but do not characterize all legacy public behavior; E-01 is commit-specific and requires a fresh run for current-tree CI.
- [ ] Capture reference screenshots for current UI/debug text in both GPU and SDL3 2D renderer modes. Blocked: E-03.
- [x] Define the first supported language/test corpus: Latin and Tamil, including combining marks and conjunct fixtures. Chemmozhi Paranar is accepted as a test-only GPL fixture under D-12.
- [x] Decide the initial runtime outline-font support matrix. `stb_truetype` is already present, but CFF support is currently handled by the offline FreeType bake path; do not silently regress it. → D-10. *(Done: D-10 accepted 2026-11-19. TrueType outlines only at runtime, on `stb_truetype`. CFF/CFF2 rasterization is deferred. Unsupported formats return `UnsupportedFontFormat`.)*
- [x] Decide whether runtime rasterization supports TrueType `glyf` only initially, or whether FreeType must also move into the runtime for CFF. → D-10, D-11. *(Done: D-10 and D-11 accepted 2026-11-19. TrueType `glyf` only, and FreeType is not a runtime dependency. `build.zig` links FreeType only into the asset builder and the UI test harness.)*
- [x] Decide the bitmap descriptor format: AngelCode BMFont text descriptor, normalized into Bairava-owned structures (D-08).
- [x] Decide which MSDF generator will be used, its license, version pin, supported font formats, output metadata, and asset-builder integration. → D-17/D-25. msdfgen 1.13.0 is pinned at the reviewed commit, its MIT notice is vendored, and the TrueType import path emits MFNT v1 plus a coverage sibling. Visual/device validation remains in Phase 6/8.
- [x] Decide fallback behavior for missing glyphs and whether font fallback chains are part of the first release or a later phase. → D-13. *(Done: D-13 accepted 2026-11-17. Caller-supplied fallback glyph; no font chain in the first release; mapping `?` and font chains move to Phase 7.)*
- [x] Decide the initial renderer policy for MSDF. Recommended: SDL_GPU first; the SDL3 2D renderer uses a matching prebaked coverage/bitmap fallback until it has an equivalent shader path. → D-18. *(Done: D-18 accepted 2026-11-19. No MSDF on the SDL3 2D path; coverage or bitmap glyphs there; MSDF is SDL_GPU-only.)*
- [x] Define atlas growth, maximum pages, memory budget, and whether eviction is required for the first release. → D-14. *(Done: D-14 accepted 2026-11-19. Four 1024 by 1024 R8 pages, 4 MiB; no growth beyond four; no eviction. `max_page_count` is lowered to four in `glyph_cache.zig` and the C mirror, with refusal checks.)*
- [x] Define success metrics: no visual regression for existing fonts, correct shaping fixtures, no duplicate rasterization for cache hits, and acceptable cold/hot text performance. → D-15. *(Done: D-15 accepted 2026-11-19 for the frame and text budgets. The no-visual-regression and no-duplicate-rasterization criteria are carried into the Phase 1 and Phase 4 gates.)*

### Future enhancements (optional; see section 12)

- [x] Add a deterministic typography reference scene: `sample/text_benchmark.zig`, run with `zig build run-text-benchmark`.
- [ ] Add automated screenshot comparison, if the display test harness can reliably capture the supported GPU and SDL3 2D modes.

### Deliverable

A reviewed design decision record containing: supported font formats, font-source matrix, shaping scope, renderer fallback policy, dependency plan, public API compatibility plan, cache/atlas policy, and test corpus.

### Exit gate — Phase 0 is complete only when

- [x] Every required font source has an agreed import/runtime path. *(Evidence: D-08 for bitmap fonts; D-10 and D-11 for runtime TrueType; the existing `.bfnt` prebaked path; D-17 and D-18 for offline MSDF on SDL_GPU only.)*
- [x] TrueType/CFF behavior is explicitly decided (D-10 and D-11 accepted 2026-11-19).
- [x] HarfBuzz and MSDF dependency/tooling choices are explicit and licensable. HarfBuzz 15.1.0 is locked at commit `3df40d9`; msdfgen 1.13.0 is locked at commit `1874bcf7d9624ccc85b4bc9a85d78116f690f35b`. The vendored msdfgen MIT notice and asset-builder-only boundary are recorded in the lock and dependency policy.
- [x] SDL_GPU and SDL3 2D behavior for every rendering mode is documented.
- [ ] Existing behavior has baseline tests or screenshots. The owner waived the historical screenshot capture only; no image evidence exists (E-03, section 6.4).
- [x] No unresolved design question would force a data-format or public-API rewrite in a later phase. All Phase 0 decisions are accepted (D-01 to D-06, D-08, D-10 to D-15, D-17, D-18, D-12, D-13). D-16 and D-19 were accepted on 2026-11-19 as a scope restriction and a temporary adapter, and neither forces a data-format or public-API rewrite.

---

## Phase 1 — Shared text model and compatibility boundary

**Purpose:** Establish one public text API over registry-owned providers while preserving BFNT compatibility.

**Decisions:** D-01 to D-07 and D-19 to D-23 are accepted. Provider dispatch, measurement, layout, glyph resolution, and quad submission are implemented. Visual equivalence and device-backed renderer checks remain acceptance gates.

### Needs: implementation

- [x] Use one `FontHandle` and registry-owned `FontResource` for BFNT, bitmap, runtime coverage, and MSDF.
- [x] Normalize provider metrics and baseline conventions; `lineHeight` reads `FontResource.metrics()`.
- [x] Keep `Canvas.text`, `textWidth`, `layoutText`, and `drawTextLayout` signatures stable; dispatch internally by provider.
- [x] Separate shaping, layout, glyph resolution, and common quad submission; keep the BFNT C call private to its provider adapter.
- [x] Keep renderer and HarfBuzz internals off the game-facing API; the boundary scan enforces D-21.
- [x] Keep `glyphTextureOf` BFNT-only and engine-only; page resolution remains internal and page-aware.
- [x] Draw rectangles from the batch-owned white coverage texture, independently of any font atlas.
- [x] Keep queued page textures stable and defer font destruction until an idle-safe frame boundary.
- [x] Retain the C BFNT loader as a compatibility adapter; no public text API or supported BFNT version was removed.

### Deliverable

One provider-switched text API with no visible feature removed and no provider/resource type exposed to game code.

### Exit gate: Phase 1

- [x] Provider dispatch, boundary, ownership, and BFNT compatibility CPU/build tests pass.
- [ ] Existing UI, overlay, console, widget, clipping, tint, alpha, z-order, and snapping behavior is accepted against display-backed references (E-03/E-04).

## Phase 2 — Hand-authored bitmap font importer and renderer

**Purpose:** Preserve hand-drawn pixel fonts through a validated coverage pipeline and the common text API.

**Decisions:** D-08 and D-09 are accepted. The `coverage`/`bitmap_font` validator, builder, packaged descriptor, bitmap provider, mapper, and shared submission path are implemented.

### Needs: implementation

- [x] Parse AngelCode BMFont descriptors into normalized Bairava-owned structures with codepoint mapping, pages, metrics, and kerning.
- [x] Validate descriptor/page relationships, source PNG color type and bit depth, exact R8 byte count, package paths, dependencies, and packaged descriptor rewrites.
- [x] Package the pinned `font8x8_basic` example as a tight 8x8 grid without adding atlas padding.
- [x] Load each packaged R8 page as coverage; preserve nearest/clamp sampling and integer-pixel placement.
- [x] Use authored rectangles, offsets, fallback, and kerning; document one-glyph-per-codepoint and no complex-script shaping.
- [x] Submit bitmap records through the shared quad path, with no `Canvas.bitmapText` API.
- [ ] Verify native-resolution and integer-scale pixel identity on a display.

### Deliverable

A validated authored bitmap font usable through the common Canvas API, including its original atlas pixels.

### Exit gate: Phase 2

- [x] Validator, importer, mapper, provider, and shared renderer tests pass.
- [ ] Device-backed identity and nearest-sampling checks pass without changing unrelated textures.

## Phase 3 — HarfBuzz integration and runtime outline-font face

**Purpose:** Add the shaping foundation and load outline-font information without coupling it to a GPU atlas.

**Decisions:** D-06, D-10, D-16. **Entry:** Phase 1 and 2 implementations are integrated; their formal exit gates remain open. **Environment:** E-01.

### Needs — must implement

- [x] Pin HarfBuzz to an explicit version/commit and record it in dependency policy and lock data. Lock entry present: HarfBuzz 15.1.0, commit `3df40d9`, in `docs/dependency-lock.json`, with evidence `checks/pinned_harfbuzz_15.1.0_dump.txt`. The dump uses the engine's LTR, explicit-script, explicit-language, default-feature, monotone-grapheme calls and `f32(units)/64` plus negated Y conversion. It includes Latin, Noto Sans Tamil, and Chemmozhi Paranar values. This evidence pins shaping values; it does not close the Phase 3 exit gate.
- [~] Integrate HarfBuzz into Bairava's actual Zig/C/C++ build for Linux, Windows, and macOS. Do not copy another project's Zig build script or dependency versions blindly. Linked into the engine module (`build.zig`, `configureEngineModule`) and the test module. The pinned cross-platform build/test matrix now passes at E-01 commit `f4abef0f7528e36658eb1d5c106d88b9f1769ded`; phase completion still depends on the remaining Phase 3 code/test exit criteria and the Phase 1/2 entry gates.
- [x] Reuse the existing `stb_truetype` source where suitable; do not add a duplicate copy. One `vendor/stb_truetype_impl.c` is shared by every module that uses it.
- [x] Create a runtime outline-font face that owns or safely references the font bytes for as long as HarfBuzz and the rasterizer require them. `RuntimeFont` copies the bytes. Test: the font keeps its own copy.
- [x] Reuse HarfBuzz face/font objects; do not create them per string or per frame. One face and font per `RuntimeFont`, and one buffer per `Shaper`.
- [x] Define units and scaling from font units to Bairava pixels in one place. `RuntimeFont.init` sets the scale. `shaper.zig` `unitsToPixels` converts.
- [x] Implement the shaping call with explicit direction, script, language, and feature handling. Script and language are caller-set. Direction is fixed to left to right (D-06). Features are HarfBuzz defaults (D-16).
- [x] Return glyph IDs, clusters, advances, and offsets in an engine-owned shaped-run structure. The run stores font identity once (D-03).
- [x] Handle empty strings, malformed UTF-8, zero-width/non-rendering glyphs, and missing-glyph results deterministically. Tests in `shaper.zig` and `shaped_layout.zig`.
- [x] Test Latin kerning/GPOS behavior and Tamil shaping with fonts that contain the required OpenType tables. The combining-overline values, five Noto Sans Tamil numeric tests, and Chemmozhi conjunct/fallback values match the pinned 15.1.0 dump. This CPU evidence does not close the Phase 3 exit gate.
- [x] Keep shaping tests CPU-only; they must not require a GPU device or window.

### Font-format constraint

The current offline path supports TrueType through stb and CFF through FreeType. The runtime path must make an explicit choice:

- **Initial restricted runtime:** use stb for supported TrueType outlines and retain the current offline BFNT/FreeType path for fonts needing CFF support; or
- **Broader runtime:** integrate FreeType at runtime for rasterization/font access where necessary.

Do not advertise all TTF/OTF formats as supported merely because HarfBuzz can parse/shapes them. Shaping support and glyph rasterizer support are separate capabilities.

### Future enhancements (optional; see section 12)

- [-] Add configurable OpenType feature tags for callers who need to disable/enable specific substitutions or positioning. Conditional on D-16 (section 6.5). *(N/A by D-16, accepted 2026-11-19: the first release uses HarfBuzz defaults. Feature configuration, if needed later, goes into the shaping options and does not change the cache, atlas, `FontStore`, `SpriteBatch`, or renderer.)*
- [x] Add language/script overrides for diagnostics and tests. `Options.script` and `Options.language` are caller-set (`shaper.zig`).

### Deliverable

A CPU-only shaping service and reusable runtime outline-font face. No glyph atlas or renderer changes are required to prove this phase.

### Exit gate — Phase 3 is complete only when

- [x] HarfBuzz builds and links on all supported CI platforms. Evidence: E-01 GitHub Actions run #112, commit `f4abef0f7528e36658eb1d5c106d88b9f1769ded`.
- [ ] Tests verify glyph IDs, clusters, advances, and offsets for Latin and Tamil fixtures against the pinned HarfBuzz version. The pinned dump and fixture values are checked in and reviewed; keep this exit item open until the Phase 1 and 2 exit gates are formally recorded.
- [x] Font data and HarfBuzz objects survive repeated shaping calls and are released correctly. Shaper reuse and create/destroy cycle tests, under a leak-checking allocator.
- [x] Unsupported font-format/rasterizer combinations fail explicitly rather than rendering blank glyphs silently. `checkFormat` tests in `runtime_font.zig`.
- [x] HarfBuzz objects/types do not leak into the public game-facing API. The game and samples import no text internals, and HarfBuzz is used only inside the text package.

---

## Phase 4 — Runtime coverage rasterizer, glyph cache, and dynamic atlas

**Purpose:** Implement Architecture 1's on-demand glyph path while keeping static bitmap/BFNT/MSDF assets as separate providers.

**Decisions:** D-13, D-14. **Entry:** Phase 3 implementation is integrated; its formal exit gate remains open. E-02 and E-04 remain required for GPU/device validation.

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

### Future enhancements (optional; see section 12)

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

## Phase 5 — Shaped text layout and engine/UI integration

**Purpose:** Connect HarfBuzz output to the glyph providers and make the new text system usable throughout Bairava.

**Decisions:** D-01 to D-07 (Phase 1). D-05 is required by the Canvas migration. **Entry:** Phase 1 to 4 implementations are integrated; formal exit gates remain open. **Environment:** E-02, E-03, E-04.

### Needs — must implement

- [x] Shape a complete text run before measuring it for line placement. Use shaped advances/offsets rather than summing codepoint widths. *(Done, CPU: `shaped_layout.zig` shapes each candidate line before measuring it, and keeps each line's own shaped glyphs. `shaper_tamil_test.zig` covers Tamil.)*
- [x] Carry clusters through layout and only split lines at approved cluster/grapheme boundaries. Do not reuse the current codepoint-only long-word splitter for complex shaped runs. *(Done for shaped runs, CPU: a word splits only at cluster starts, and a ligature that spans graphemes is never split. `layout.zig` keeps the codepoint splitter for static BFNT and bitmap providers.)*
- [x] Define line-break policy for the first release. Start with explicit newlines and supported whitespace breaks; add full Unicode line-break conformance only as a separately scoped capability. *(Done: the policy is written in the `shaped_layout.zig` header. Known limit: a combining mark directly after a space.)*
- [~] Preserve baseline, ascent/descent, line height, blank-line, alignment, and pixel-snapping behavior for existing UI fonts. *(Partly: `glyph_records.zig` uses the legacy formulas (rounded line top, rounded ascent, one rounding per glyph), and its tests check them for the runtime font. The existing UI fonts are not yet compared against screenshots, which needs a device.)*
- [x] Produce glyph render records from the appropriate provider after shaping/layout: bitmap mapping and runtime coverage use page-aware records; static BFNT stays in its private C adapter.
- [x] Add a common glyph-quad submission path supporting texture page, UV, plane bounds, tint/alpha, and render mode. Runtime/bitmap records are submitted to the UI quad list and resolve to stable atlas page textures before sprite submission.
- [x] Preserve or deliberately version `Canvas.text`, `textWidth`, `layoutText`, and `drawTextLayout` so game code does not have to manage glyph IDs or atlas pages. D-05 is accepted; the existing signatures remain.
- [x] Migrate the debug overlay, developer console, widgets, and game-owned text call sites. The overlay, console, and game use `Canvas`/`Ui`; C widget callbacks now dispatch measurement and drawing through `FontStore`. Device visual acceptance remains tracked below (E-03/E-04).
- [x] Add a sample typography scene covering bitmap, BFNT, Latin, Tamil, and MSDF providers (`run-text-benchmark`).
- [ ] Preserve clipping, z-order, tint, alpha blending, pixel snapping, and integer viewport scaling. Verification: E-03.
- [x] Keep rectangle drawing independent from font resources. The batch-owned white texture serves solid quads; they do not sample a font atlas.
- [x] Keep shaping, layout, and glyph cache tests separable from GPU visual tests. *(Done: the three new modules import no renderer or platform module, and the harness compiles and runs them without SDL.)*
- [x] Generate the SDL3 2D coverage sibling from the same outline source at asset-build time, never from MSDF texture data (D-24).

### Future enhancements (optional; see section 12)

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

## Phase 6 — MSDF asset generation and rendering path

**Purpose:** Add scalable outline-font rendering without replacing bitmap or coverage rendering.

**Decisions:** D-17, D-18. **Entry:** Phase 5 implementation is integrated; its formal exit gate remains open. **Environment:** E-01 (SPIR-V, DXIL, and MSL builds), E-04.

### Needs — implementation status

- [x] Pin msdfgen 1.13.0 and its MIT license; link it only into the offline asset builder (D-17, D-25).
- [x] Define and load MFNT v1 with metrics, glyph IDs, fallback, plane bounds, UVs, `pixel_height`, and `pxRange`.
- [x] Generate MSDF from supported outlines and bake the coverage sibling separately. Reject assets exceeding the 1024×1024 per-font cap.
- [x] Submit MSDF records through the shared text API and use the median shader with screen-space range calculation.
- [x] Use a per-texture clamp-to-edge linear sampler only for MSDF; coverage, pixel art, and unrelated textures remain nearest-filtered.
- [x] Compile/embed SPIR-V by default and optional DXIL/MSL when selected.
- [x] SDL3 2D draws the coverage sibling generated from the same source font. It never samples raw MSDF channels.
- [ ] Visually validate corners, counters, thin strokes, punctuation, and enlarged MSDF against coverage references on both renderer paths (E-03/E-04).
- [x] Keep hand-authored pixel fonts on their bitmap/coverage path; do not vectorize them.

### Future enhancements (optional; see section 12)

- [ ] Add MSDF atlas visualization tooling to inspect RGB distance channels and glyph rectangles.
- [ ] Compare atlas sizes, visual quality, memory, and draw performance against the coverage path.
- [ ] Support multiple MSDF atlas pages if the asset corpus requires them. Conditional on the corpus (section 6.5).

### Deliverable

An outline font can be generated offline into an MSDF asset, loaded at runtime, shaped by HarfBuzz, and drawn by the SDL_GPU MSDF pipeline. The secondary renderer has an explicit fallback behavior.

### Exit gate — Phase 6

The implementation and CPU/build pieces are in place, but the phase remains open until display-backed references verify MSDF at native and enlarged sizes on SDL_GPU and its coverage sibling on SDL3 2D. CI is configured to compile SPIR-V on every platform, DXIL on Windows, and MSL on macOS; successful matrix runs remain required evidence.

---

## Phase 7 — Font fallback, robustness, and production hardening

**Purpose:** Keep font resources predictable across missing glyphs, unloads, upload retries, and shutdown.

**Decisions:** D-13 to D-15. Full GPU-device loss recovery is outside the current SDL integration; retained CPU bytes and explicit text-resource recreation helpers are implemented for a supported resource rebuild while the device is valid.

### Needs: implementation

- [x] Resolve runtime missing codepoints and `.notdef` once to the same face's `?`; draw nothing if absent. Do not add a fallback chain without real content requiring it.
- [x] Invalidate unloaded handles immediately, retain their resources through queued submission, then collect after GPU idle. Normal runtime collection waits only when retired resources exist.
- [x] Retain CPU atlas bytes for BFNT, bitmap, MSDF, and runtime pages; expose engine-side rebuild operations that require GPU idle and stable device ownership.
- [x] Preserve fixed atlas limits and explicit `AtlasFull` / `QuadListFull` behavior.
- [x] Report transfer-buffer creation/mapping and frame-submission failures; preserve pending atlas regions until successful submission so they retry.
- [x] Keep cache misses from rewriting live glyph texels; overflow spills regions, while explicit full-page writes use cycling uploads.
- [x] Document LTR-only shaping and the absence of paragraph bidi. Add bidi support only if target-language requirements require it.
- [ ] Exercise recreation, renderer switching, unload-while-queued, and shutdown with device-backed tests on supported hardware.
- [x] Document SDL's `SDL_UploadToGPUTexture` limitation: it returns no per-copy status, so the engine cannot claim detection of an individual copy failure.

### Deliverable

A bounded font runtime with explicit failure behavior, retryable atlas submission, safe retirement, and profiling counters.

### Exit gate: Phase 7

- [x] Missing-glyph fallback, atlas bounds, and CPU ownership rules have automated coverage.
- [x] Normal unloads are reclaimed after a safe idle point; shutdown waits before releasing GPU owners.
- [ ] Device-backed recreation, both renderer paths, and no-use-after-free acceptance pass.
- [x] Unicode and format limitations are documented in `docs/text.md`.

## Phase 8 — Cutover, regression suite, documentation, and cleanup

**Purpose:** Keep the unified API as the supported path while retaining BFNT compatibility until migration evidence permits removal.

**Decisions:** D-19. Cross-platform CI and visual acceptance remain required.

### Needs: implementation and acceptance

- [x] Keep BFNT and MFNT compatibility covered by parser/importer tests; BFNT v3 remains rejected.
- [x] Document bitmap, BFNT coverage, runtime coverage, and MSDF behavior, sampling, fallback, limits, and 2D fallback in `docs/text.md`.
- [x] Record the msdfgen pin, MIT notice, and asset-builder-only boundary in dependency documentation.
- [x] Add a deterministic typography reference workload for bitmap, BFNT, shaped Latin, Tamil, and MSDF, plus text-specific shaping/cache/upload profiling.
- [x] Run `zig build`, `zig build test`, `zig build test-ui`, `zig build check-assets`, and `zig build asset-build` on the current Windows worktree; all completed successfully in this pass.
- [ ] Pass CI on Linux, Windows, and macOS; verify SPIR-V on every job, DXIL on Windows, MSL on macOS, and C/C++ dependency linkage.
- [ ] Capture and accept native/integer-scale references in SDL_GPU and SDL3 2D; verify the median shader, coverage sibling, aliasing/smoothness difference, and nearest sampling on non-font textures.
- [ ] Record real cold/warm font workload measurements on display hardware; the scene reports shaping, cache, atlas, upload, draw-call, and frame data.
- [x] Keep the old C path as a private BFNT compatibility adapter until all consumers and assets have migrated.

### Deliverable

A documented and regression-tested multi-source text system with display-backed evidence and supported CI coverage.

### Exit gate: migration

- [ ] Required CI jobs pass on Linux, Windows, and macOS.
- [ ] Phase 0 references and both renderer paths are accepted, or intentional differences are documented.
- [x] Bitmap, BFNT, runtime coverage, and MSDF providers share the public Canvas API.
- [x] Runtime text supports unseen glyphs and repeated cache hits.
- [ ] Lifetime/recreation checks and visual acceptance pass; no known GPU resource hazard remains.
- [x] API and dependency documentation match implemented behavior.

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

**Decision order.** D-01 to D-07 define the Phase 1 contract; provider/API implementation is complete, with visual/device gates open. D-08 and D-09 define the Phase 2 descriptor and example asset; importer and provider implementation is complete, with the pixel-identity gate open. Phase 5 depends on the required preceding acceptance gates; completed implementation does not substitute for visual/device evidence.

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

## 12. Future enhancements

These items are optional or conditional, do not block the migration, and should be promoted to required work only when supported by real content or profiling evidence:

- Subpixel positioning, if it improves outline UI without undermining pixel-font output.
- Variable-font axis selection, if a shipped asset needs non-default instances.
- Configurable OpenType features, if a real text use case needs changes from HarfBuzz defaults.
- Bidi paragraph processing and broader Unicode line breaking, if RTL or additional language requirements are adopted.
- A multi-face fallback chain, only if a real string cannot be served by one face; itemize script runs and keep clusters intact.
- LRU atlas eviction, only if telemetry shows the fixed four-page ceiling is insufficient.
- Multiple MSDF pages, only if the authored font corpus exceeds the current per-font atlas cap.
- MSDF atlas visualization and external BMFont authoring previews, if asset debugging needs them.
- Upload-buffer reuse, only if profiling shows per-flush staging allocation is material.
- Rich-text spans remain a non-goal unless the public text scope changes.
