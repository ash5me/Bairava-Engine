# Bairava Engine — Complete API Documentation Implementation Plan

**Status:** In progress  
**Scope:** Complete implementation, validation, hosting, and maintenance of Bairava's developer documentation  
**Repository:** `ash5me/Bairava-Engine`  
**Target documentation URL:** `https://ash5me.github.io/Bairava-Engine/` (proposed)  
**Compiler policy:** Keep the engine and documentation on the repository's pinned Zig 0.16 toolchain  
**Planning baseline:** November 2026 documentation-generation evaluation and the repository/API structure discussed during the November 2026 review

---

## 1. Purpose and outcome

Build and maintain a public documentation website for Bairava Engine that combines:

1. **Generated public API reference** — only the intentionally supported declarations exposed through Bairava's public package root, with accurate signatures and canonical public names.
2. **Developer guides** — practical explanations of engine workflows, ownership rules, lifecycle, and subsystem usage.
3. **Runnable examples** — examples compiled in CI and written against the supported public `bairava` module.
4. **Release-specific documentation** — documentation snapshots for released engine versions, plus development documentation for `main`.

The finished site should let a game developer discover an API, understand its contracts, follow a guide, and compile a representative example without needing to read engine internals.

This plan defines the complete implementation sequence. The checkpoint below records verified work; unchecked tasks remain outstanding.

### Current implementation checkpoint

- Confirmed the pinned compiler is Zig `0.16.0-dev.3142+5ccfeb926` and the game-facing import is `@import("bairava")`, rooted at `src/engine/bairava.zig`.
- The typed manifest allowlists all 87 package-root exports. The AST exporter validates root coverage, canonical-name uniqueness, and direct alias targets; a compile-time test resolves each entry through the configured engine module.
- `zig build docs` generates the public-only Markdown inventory and assembles a curated Jekyll source tree with 23 guides, navigation, search data, a landing page, 404 page, and engine/Zig/source-commit metadata. All 87 allowlisted entries are labeled experimental. Callable signatures are derived from compiler reflection; the manifest supplies summaries and selected authored contracts. The lifecycle guide embeds a compile-checked public API example.
- The manifest now carries member-contract items and a nine-area checklist for fields, methods, parameters, returns, errors, allocators, handles, callbacks, and capacities. The exporter validates checklist claims and renders outstanding `needs_review` areas. Initial member-level contracts cover `Config`, `Context`, `DrawContext`, `SpriteBatch`, texture resources/handles, scene callbacks, and navigation; this is a first tranche, not complete coverage.
- `zig build test` runs the example, public export/signature/member-checklist checks, and 16 documentation-site tests. CI generates and renders the site on Linux, then checks required pages, internal links/anchors, search targets, and implementation-detail leakage in rendered output. Local Ruby/Bundler/Jekyll reproduction is still a separate validation task.
- Original documentation prose is licensed CC BY 4.0, and a pull-request checklist covers API and documentation changes. Pages is enabled with GitHub Actions as its source. CI run `44758340333` successfully configured and deployed the site; HTTPS checks returned 200 for the project root, `/dev/`, and `/dev/api/`, and the `docs-archive` branch contains the deployed `/dev/` site. A test release snapshot and subsequent-deployment retention check remain outstanding.
- Existing release tags predate the current docs builder and are not backfilled. New release tags must use `vMAJOR.MINOR.PATCH`, match the package/API version, and include the documentation tooling.
- API coverage is not yet complete at the member-contract level: type fields, method semantics, and many ownership/error/threading details still need review and documentation. The development site is live and verified; release snapshot publishing and retention still require a test release and follow-up deployment. Do not treat this implementation as completion of the full plan.

## 2. Decisions and constraints

| Area | Decision |
|---|---|
| Engine compiler | Keep the pinned Zig 0.16 toolchain |
| Documentation compiler | Use the same pinned Zig 0.16 toolchain; do not add a Zig 0.17 docs-only compiler |
| API boundary | The supported public package rooted at `src/engine/bairava.zig` |
| API extraction | Build a narrow, Bairava-specific, manifest-driven public API exporter |
| Autodoc | Do not publish the current Autodoc output directly; retain its probe output as an evaluation artifact and use it only as an input if a reliable, testable extraction interface is established |
| Public names | Publish canonical names as game developers use them, such as `bairava.Config`; do not publish internal paths as parallel public symbols |
| Internal source | Do not publish internal source listings, source archives, internal module navigation, or internal declarations |
| Build integration | Add `zig build docs`, using the same configured engine module and dependency graph as normal builds |
| Handwritten content | Markdown guides maintained separately from the generated API reference |
| Examples | Prefer real sample-game patterns; compile examples in CI |
| Hosting | GitHub Pages, serving static output |
| CI | Validate docs and examples with the pinned Zig 0.16 toolchain; publish only after validation succeeds |
| Versioning | Publish `dev` from `main` and immutable versioned snapshots for releases |
| API changes | This documentation project does not silently redesign or break the engine's public API |

### 2.1 Why the plan changes from the previous version

The pinned Zig Autodoc probe runs through `zig build docs`, but its generated result does not enforce Bairava's desired public-only boundary. The observed output indexed both `bairava.Config` and internal declarations such as `core.engine.Config`, initially landed on `ai`, and included 674 source entries.

That output is useful evidence about the behavior of the current toolchain, but it is not suitable for direct publication as Bairava's curated API reference.

The solution is not to move the engine to Zig 0.17 solely for documentation. The documentation system should remain compatible with the engine's current compiler.

### 2.2 Exporter design principle

Build a **narrow exporter for Bairava's public package**, not a general-purpose Zig documentation generator.

The exporter must have an explicit allowlist of supported public symbols. It should use compiler-derived declaration/type information where the pinned toolchain exposes it reliably, and use authored metadata for canonical public names and explanatory contracts.

Do not build a general Zig parser, scrape generated HTML with fragile selectors, or treat every `pub` declaration as a supported public API.

### 2.3 Extraction strategy and fallback

During implementation, inspect the actual Zig 0.16 Autodoc artifact and compiler facilities available in the pinned toolchain. Choose and document one extraction adapter:

1. **Preferred:** consume a structured compiler-generated symbol/declaration artifact, if the probe output provides one that can be read without scraping presentation HTML.
2. **Fallback:** generate a small compiler-checked metadata artifact from the public package root and an explicit manifest, using Zig 0.16 compile-time declaration/type information to validate entries and derive available signatures.
3. If neither can produce trustworthy signatures and symbol identity, use an explicitly maintained signature field in the manifest, but require a compile-time validation harness and review it as API metadata. Do not silently infer signatures from regexes or source-text heuristics.

The selected adapter must be isolated behind a small internal interface so a future Zig upgrade can replace it without changing the manifest or website content model.

Do not proceed to full site assembly until the exporter can pass the public-boundary acceptance tests in Phase 2.

## 3. Repository areas to review

Review these areas before implementation:

- `build.zig` — engine module creation, dependencies, build options, install steps.
- `build.zig.zon` — package metadata and pinned Zig version constraints.
- `src/engine/bairava.zig` — public package root and re-exports.
- `src/engine/core/engine.zig` — central game-facing API and declarations currently re-exported.
- `docs/` — existing guides, architecture notes, ownership rules, compatibility policy.
- `sample/` and `src/game/` — existing usage patterns and candidate examples.
- `.github/workflows/` — current CI triggers, compiler setup, and artifact conventions.
- `README.md` — documentation entry points and installation instructions.

The plan assumes the game-facing import is `@import("bairava")`. Confirm this against the current build configuration before writing examples.

## 4. Target documentation information architecture

Use one site with clear separation between learning material and reference material.

```text
Bairava Engine Documentation
|
+-- Home
|
+-- Getting started
|   +-- What is Bairava?
|   +-- Requirements and supported platforms
|   +-- Installation / adding Bairava to a game
|   +-- Your first game
|   +-- Project structure
|
+-- Guides
|   +-- Application lifecycle
|   +-- Configuration and Context
|   +-- Rendering sprites
|   +-- Sprite batching and depth sorting
|   +-- Camera and viewport
|   +-- Input
|   +-- Assets, textures, and resource ownership
|   +-- Text and fonts
|   +-- Physics and collision
|   +-- Animation
|   +-- Audio
|   +-- Scenes
|   +-- UI
|   +-- Navigation and AI
|   +-- Jobs, scripting, and localization
|   +-- Diagnostics and profiling
|   +-- Packaging and distribution
|
+-- API reference
|   +-- Public package overview
|   +-- Public types and namespaces
|   +-- Functions and methods
|   +-- Errors and enums
|   +-- Experimental API (if any)
|
+-- Examples
|   +-- Minimal application
|   +-- Sprite and camera
|   +-- Input and movement
|   +-- Text and UI
|   +-- Collision and physics
|   +-- Animation and audio
|   +-- Scene transition
|
+-- Reference / project policies
|   +-- Ownership and lifetime
|   +-- API compatibility and versioning
|   +-- Renderer capabilities and limitations
|   +-- Supported asset formats
|   +-- Platform and build requirements
|
+-- Release notes / migration guides
```

Do not create a guide for every subsystem merely to fill out the navigation. Each page should answer a real developer task and be supported by current API behavior.

## 5. Phase 0 — Confirm scope and documentation contract

### Tasks

- [ ] Confirm the current default branch and target release branch/tag policy.
- [x] Confirm the exact Zig 0.16 compiler version used by local builds and CI.
- [x] Confirm the public package root and supported game-facing import.
- [ ] Inventory existing documentation and identify material to reuse.
- [ ] Identify features that are experimental, incomplete, backend-specific, or unsupported.
- [x] Define what counts as public API versus internal implementation.
- [ ] Decide the documentation license and verify licenses for copied third-party examples or assets.
- [ ] Define the site URL and GitHub Pages ownership/configuration.
- [ ] Establish a documentation review owner (the engine maintainer).
- [ ] Preserve the existing Autodoc probe output and its command/compiler metadata as an evaluation artifact; do not treat it as published documentation.

### Deliverables

- Approved documentation scope.
- Public API boundary statement.
- List of existing guides to retain, revise, or replace.
- Confirmed compiler and deployment assumptions.
- Recorded Autodoc evaluation result and known limitations.

### Acceptance criteria

- A new user can be told exactly which module is supported for game code.
- Internal implementation modules are not accidentally advertised as stable interfaces.
- Known limitations are listed rather than hidden.
- Documentation generation uses the same Zig 0.16 toolchain as the engine.

## 6. Phase 1 — Public API inventory and contract documentation

### 6.1 Inventory exports

Audit declarations intentionally exposed through `src/engine/bairava.zig`.

For each exported declaration, record:

- Canonical public name (for example, `bairava.Config`).
- Actual declaration target (for example, `core.engine.Config`).
- Kind (type, function, constant, namespace, enum, error set, or other supported declaration kind).
- Owning subsystem.
- Whether it is intentionally public.
- Whether it is stable, experimental, or internal.
- Whether it needs a doc comment.
- Relevant guide page.
- Whether its behavior is covered by tests or an example.

Review aliases and re-exports carefully. A public alias should be documented under the name game developers use, even when the underlying declaration lives in an internal file.

### 6.2 Establish the public API manifest

Create a machine-readable manifest for the documentation exporter. The exact file format can be selected during implementation (for example, Zig source declarations or JSON/TOML), but it must represent at least:

- Canonical public symbol name.
- Public package path.
- Target declaration identity.
- Declaration kind, where it can be validated.
- Visibility/stability classification.
- Short summary.
- Longer description or contract notes.
- Guide links.
- Optional notes such as backend restrictions or deprecation.

The manifest is an **allowlist**, not a list of all declarations discovered by scanning the repository.

Rules:

- Every published symbol must have an explicit manifest entry.
- Every manifest entry must resolve to an actual declaration reachable through the public package root.
- Duplicate canonical public names are an error.
- Stale entries are an error.
- Newly exported declarations do not automatically become published documentation entries; they require deliberate manifest review.
- An implementation target may be internal, but only its canonical public alias is published.
- Internal target paths must not become separate public navigation entries.

### 6.3 Document contracts, not just signatures

For every important public API, explain the parts a Zig signature cannot communicate:

- Ownership: who owns the value and who destroys it.
- Lifetime: when handles, pointers, and views become invalid.
- Allocator: which allocator is used, who supplies it, and whether allocation can occur.
- Errors: expected error cases and recovery guidance.
- Panic behavior: whether invalid use panics, asserts, or returns an error.
- Threading: main-thread restrictions, thread safety, and callback thread.
- Ordering: required initialization, update, draw, flush, and shutdown order.
- Backend constraints: SDL_GPU-only, SDL3 2D-compatible, or backend-independent behavior.
- Capacity limits: what happens at capacity and how callers can detect or avoid overflow.
- Units and coordinate spaces: pixels, world units, seconds, normalized coordinates, ground-contact coordinates, etc.

### 6.4 Public API quality gate

Do not document accidental exports as supported merely because they are `pub`.

For each questionable export, choose one:

1. Keep public and document its contract.
2. Keep public but mark experimental with an explicit stability warning.
3. Make internal in a separately reviewed API change.
4. Deprecate with a migration path.

This documentation project should not make unreviewed API-breaking changes. Any API-surface cleanup must be tracked as a separate change.

### Deliverables

- Public API inventory.
- Version-controlled public API manifest.
- Documentation-comment/metadata coverage report.
- List of unresolved API contract questions.
- Approved public/experimental/internal classification.

### Acceptance criteria

- Every intentionally public top-level export has a useful description.
- Important public methods describe ownership, errors, lifetime, and threading where applicable.
- No known internal-only declaration is presented as a supported game-facing API.
- Every symbol selected for publication has a unique canonical public name and a resolvable target.

## 7. Phase 2 — Build the Zig 0.16 public API exporter

This phase replaces the previous plan's direct Autodoc publishing approach.

### 7.1 Define exporter responsibilities

The exporter must:

1. Read the explicit public API manifest.
2. Validate each canonical public path against the configured public package root.
3. Resolve or validate the target declaration identity.
4. Obtain declaration kind and signature/type information through the selected Zig 0.16 extraction adapter.
5. Combine compiler-derived information with authored descriptions and contract metadata.
6. Emit a normalized intermediate representation (IR) containing only approved public symbols.
7. Generate the API-reference pages, navigation data, and search index from that IR.
8. Fail on missing, duplicate, stale, ambiguous, or unapproved declarations.

The exporter should not scan the repository and automatically publish every declaration marked `pub`.

### 7.2 Select and isolate the Zig 0.16 extraction adapter

Evaluate the compiler output generated by the existing `zig build docs` probe.

- [ ] Inspect the generated artifact structure and determine whether it contains a structured declaration/symbol representation suitable for extraction.
- [ ] Identify whether signatures, declaration identities, canonical paths, and documentation comments can be obtained without parsing rendered HTML.
- [ ] Determine whether source entries can be omitted from the final output.
- [ ] Record which parts of the artifact are stable enough to consume for the pinned compiler version.
- [ ] Create representative fixtures for public aliases, internal targets, functions, structs, enums, errors, and namespaces.

Preferred order:

**Adapter A — Structured Autodoc data**

Use it only if declaration metadata can be consumed from structured compiler output rather than scraped HTML. Implement a version-specific adapter for the pinned compiler output and cover it with fixture tests. Treat a Zig compiler upgrade as a point where the adapter must be revalidated.

**Adapter B — Compiler-checked manifest metadata**

If structured Autodoc data is insufficient, use a small Zig 0.16 helper/build artifact driven by the manifest. It should validate declaration existence and derive the type/signature information that the compiler can expose reliably. The helper should be intentionally narrow and should not attempt to parse arbitrary Zig source files.

**Adapter C — Explicit signature metadata**

Use this only if the first two adapters cannot produce trustworthy signatures. Store the signature representation in the manifest, but require:
- declaration-resolution checks against the actual public package,
- compile-time or compile-test validation for each public entry where feasible,
- review whenever the declaration changes,
- a stale-signature check or explicit review gate in CI.

Do not use regex-based source parsing as the fallback. Do not scrape Autodoc HTML as the source of truth.

### 7.3 Canonical-name and alias handling

The exporter must distinguish the name exposed to game developers from the name of the underlying declaration.

Example manifest intent:

| Canonical public name | Target declaration | Published entry |
|---|---|---|
| `bairava.Config` | `core.engine.Config` | `bairava.Config` |
| `bairava.Context` | Actual public declaration | `bairava.Context` |
| — | `core.engine.Config` | Not published separately |
| — | `core.engine.InternalState` | Not published |

If multiple public aliases intentionally refer to the same target, decide whether each alias is a supported public name. Publish only the aliases approved in the manifest and avoid duplicate/confusing pages.

### 7.4 Strict output filtering

The generated website must not contain internal-only content in any user-reachable form.

Filter or omit:

- Internal declarations not present in the manifest.
- Internal module names as public API entries.
- Internal source-file listings.
- Downloadable source archives.
- Internal module navigation.
- Internal declarations in search data or autocomplete.
- Internal declaration names in generated breadcrumbs or related-symbol links.
- Hidden pages that remain reachable through direct URLs.

The exporter should generate pages from its normalized public-only IR, not copy the full Autodoc site and merely hide unwanted navigation entries.

### 7.5 Intermediate representation

Define a small normalized IR independent of the chosen extraction adapter. Each entry should contain, as applicable:

- Canonical public path.
- Public display name.
- Declaration kind.
- Signature/type representation.
- Summary and detailed documentation.
- Parameter and return descriptions if available.
- Ownership/lifetime/error/threading/backend contract notes.
- Stability status.
- Guide/example links.
- Source target identity for validation only (not for public display unless intentionally linked).

The IR should not contain unapproved declarations. Use this same IR to generate HTML, navigation, and search data so the different outputs cannot drift apart.

#### Member-level contract checklist

The manifest distinguishes authored member contracts from coverage status. For each public type and type factory, review these areas:

- Fields: meaning, units, valid values, defaults, and mutation rules.
- Methods: purpose, preconditions, side effects, and required call order.
- Parameters and returns: meaning, ownership, lifetime, ranges, and coordinate spaces.
- Errors: triggering conditions and recovery guidance.
- Allocators, handles, and pointers: supplier, thread-safety, validity, invalidation, and release rules.
- Callbacks: timing, thread, borrowed arguments, and reentrancy expectations.
- Capacities: limit and overflow reporting behavior.

Use `documented` only when the relevant member contracts are represented in the manifest, `not_applicable` only after review, and `needs_review` when coverage is missing or partial. The generated checklist is a visible gap report; it does not imply completion merely because the exporter builds.

### 7.6 Exporter tests

Required tests:

- [ ] `bairava.Config` is present under its canonical public name.
- [ ] `core.engine.Config` is not published as a separate entry.
- [ ] Internal declarations such as `core.engine.InternalState` are absent.
- [ ] An unlisted public declaration is not automatically published.
- [ ] A manifest entry pointing to a missing declaration fails.
- [ ] A duplicate canonical public name fails.
- [ ] A stale target or changed declaration kind fails.
- [ ] Aliases resolve to the intended canonical public name.
- [ ] Internal source paths do not appear in the generated public site.
- [ ] Internal declarations do not appear in search data, navigation, or page metadata.
- [ ] No source archive or full internal source listing is copied into the public artifact.
- [ ] The generated page set is deterministic for the same source, toolchain, and manifest.
- [ ] Every public type's member checklist has no unresolved `needs_review` areas before declaring API documentation complete.
- [x] Checklist claims are validated against authored member-contract entries, and unresolved areas are included in the generated API reference.

Add a test that scans the complete final output directory, not just the visible home page.

### Deliverables

- Bairava-specific public API manifest.
- Zig 0.16 extraction adapter.
- Manifest/declaration validation.
- Normalized public-only API IR.
- Static API-reference generator.
- Automated public-boundary and artifact-leak tests.

### Acceptance criteria

- `bairava.Config` appears exactly once under the canonical public name.
- `core.engine.Config` is not exposed as a separate public API entry.
- Internal symbols, module listings, and source archives are absent from every generated artifact.
- All manifest entries resolve and all invalid/stale entries fail the build.
- No Zig 0.17 docs-only toolchain is required.
- The exporter is deliberately limited to Bairava's public package, not a general Zig parser or general-purpose documentation generator.

## 8. Phase 3 — Integrate documentation generation into the build

### 8.1 Add the documentation build step

Add a dedicated build step named `docs` to the existing build graph.

Requirements:

- Reuse the same configured engine module used by game builds.
- Reuse the same dependency graph and build options needed to analyze public declarations.
- Use the repository's pinned Zig 0.16 compiler.
- Avoid creating a second, drifting copy of the engine module configuration.
- Do not require a window, GPU device, audio device, or running game merely to generate the reference.
- Run manifest validation, metadata extraction, API-page generation, and site assembly in a deterministic order.
- Write intermediate files and final output to predictable build directories.
- Fail with a useful error if any stage fails.
- Keep generated output out of normal source control unless there is a deliberate release-artifact policy.

Expected developer workflow:

```powershell
zig build docs
```

Suggested output organization:

```text
zig-out/
  doc/
    bairava/
      index.html
      api/
      guides/
      examples/
      search/
      assets/
```

The exact folder names may change with the selected static-site assembly approach.

### 8.2 Build step behavior

The `docs` step should be composed of independently testable stages:

1. Validate the manifest schema.
2. Resolve manifest paths against the public package root.
3. Generate compiler-backed symbol/type metadata.
4. Build the public-only normalized IR.
5. Run public-boundary checks against the IR.
6. Generate API pages and search/navigation data.
7. Assemble handwritten guides and examples.
8. Run final-output leak and link checks.
9. Install the finished static site into the build output directory.

A failure in an early stage must stop later stages. Do not leave a partially generated site that could be mistaken for a successful build.

### Deliverables

- `zig build docs`.
- Reproducible static output under a predictable directory.
- Separate, testable exporter stages.

### Acceptance criteria

- Documentation generation succeeds with the pinned Zig 0.16 compiler on the supported CI environment.
- The generated reference includes the intended public API only.
- Generation does not require a live graphics/audio device.
- A clean checkout can reproduce the output.
- Any failed validation causes `zig build docs` to fail.

## 9. Phase 4 — Handwritten guides and runnable examples

### 9.1 Guide template

Each substantial guide should follow a consistent structure:

1. What the feature is for.
2. When to use it.
3. Required setup and relevant configuration.
4. Minimal working example.
5. Explanation of important calls and data flow.
6. Ownership and lifetime rules.
7. Common mistakes and troubleshooting.
8. Links to the relevant API reference.
9. Feature limitations and backend compatibility.

### 9.2 Writing order

Write the guides in this order.

**Foundation**
- [ ] Introduction and engine philosophy.
- [ ] Requirements and supported platforms.
- [ ] Installation and project setup.
- [ ] Your first game.
- [ ] Application lifecycle.
- [ ] Configuration and Context.

**Core game development**
- [ ] Rendering sprites.
- [ ] SpriteBatch, ordering, and depth sorting.
- [ ] Camera, viewport, scaling, and coordinate spaces.
- [ ] Input handling and action mapping.
- [ ] Assets, textures, manifests, and resource lifetime.
- [ ] Text rendering and font usage.
- [ ] Physics, collision, and one-way platforms.
- [ ] Animation and animation hooks.
- [ ] Audio and positional attenuation.
- [ ] Scene management and transitions.
- [ ] UI.

**Advanced systems**
- [ ] Navigation and AI.
- [ ] Jobs and threading.
- [ ] Scripting and localization.
- [ ] Diagnostics, profiling, and crash reporting.
- [ ] Packaging, deployment, and performance guidance.

### 9.3 Examples policy

- Use the public `@import("bairava")` module.
- Avoid importing `src/engine/...` implementation paths.
- Prefer small, focused examples over one giant sample.
- Keep examples compilable with the pinned Zig 0.16 compiler.
- Avoid relying on undocumented sample-only helpers.
- Include expected behavior and any required assets.
- Mark pseudocode clearly; never present pseudocode as a compiling example.
- Where an example needs a window or GPU, keep it out of the headless documentation-generation step and run it in an appropriate CI or manual validation lane.

### 9.4 Example validation

Separate examples into:

- **Compile-only examples:** can be checked without opening a window or GPU.
- **Runtime examples:** need a supported display/audio/GPU environment.
- **Illustrative snippets:** intentionally incomplete and labelled as such.

Where practical, place compile-tested examples in a dedicated examples directory and add build steps for them. Avoid copying code into Markdown and letting the copy drift; use a documented snippet-inclusion or verification approach if the documentation system supports it.

### Deliverables

- Complete getting-started path.
- Core subsystem guides.
- Advanced guides for supported subsystems.
- Compile-tested examples.
- Explicitly labelled runtime-only and illustrative examples.

### Acceptance criteria

- A new developer can create and run a minimal game by following the guide.
- Every example advertised as compilable is checked in CI.
- Guides link to the matching public API reference.
- No example teaches use of an internal-only module.

## 10. Phase 5 — Documentation structure, navigation, and presentation

### Tasks

- [ ] Select a static-site presentation approach that can consume the public-only API IR and Markdown content.
- [ ] Do not depend on Autodoc's full source-browser navigation or source archive.
- [ ] Keep generated API reference and Markdown guide content in coherent site navigation.
- [ ] Provide a landing page explaining what Bairava is and where to start.
- [ ] Add navigation between guides, API reference, examples, and release notes.
- [ ] Add previous/next links for multi-page tutorials where useful.
- [ ] Add a visible engine version and Zig compiler version on relevant pages.
- [ ] Add clear labels for experimental, backend-specific, or unsupported features.
- [ ] Ensure code blocks are readable and copyable.
- [ ] Check keyboard navigation, contrast, responsive layout, and link accessibility.
- [ ] Add a useful 404 page.
- [ ] Add canonical URLs and page titles where supported.
- [ ] Avoid custom JavaScript or a complex frontend unless the generated reference requires it.

### Site organization

Keep authored content in a predictable location, for example:

```text
docs/
  site/
    index.md
    getting-started/
    guides/
    examples/
    reference/
      public-api-manifest.*
    releases/
```

The exact folder structure can be adapted to the chosen site assembly approach. Do not move or rename existing technical documents until their references and purpose have been reviewed.

### Search requirements

Search must be built from the normalized public-only IR and authored site content.

It must not index:

- Internal declarations.
- Internal source paths.
- Internal source-file contents.
- Raw Autodoc source entries.
- Excluded aliases or implementation symbols.

Add automated assertions against the search index, not merely the rendered search UI.

### Deliverables

- Coherent documentation navigation.
- Landing page and 404 page.
- Search index based only on approved public API and authored guide content.
- Responsive, accessible static site.

### Acceptance criteria

- A reader can move from a guide to its API entries and back.
- The site is usable on desktop and mobile.
- Experimental and backend-specific behavior is clearly identified.
- Search results obey the same public-only boundary as API pages.

## 11. Phase 6 — CI validation

Add a documentation validation job or a clearly separated stage in the existing GitHub Actions workflow.

### On pull requests

Run:

1. Install the exact Zig 0.16 version pinned by the repository.
2. Check formatting if required by the normal project workflow.
3. Run the exporter and generate API docs.
4. Validate every manifest entry against the public package root.
5. Build compile-only documentation examples.
6. Validate required generated output exists.
7. Scan the full output for internal symbol names, internal source paths, excluded module names, and source archives.
8. Validate local documentation links and search-index contents where practical.
9. Fail if a required documentation step fails.

Do not deploy public documentation from untrusted pull-request contexts.

### On pushes to `main`

- Run the same documentation checks.
- Generate the development (`dev`) documentation artifact.
- Publish it to the development documentation location only if all checks pass.

### On release tags

- Validate that the tag points to the intended release commit.
- Install the same pinned Zig 0.16 toolchain used by that release.
- Generate documentation from that exact tag/commit.
- Include the engine version and Zig compiler version in the published metadata.
- Publish an immutable version-specific snapshot.
- Update the `latest` alias only after the release documentation deploy succeeds.

### CI reliability requirements

- Pin GitHub Actions to reviewed versions or commit SHAs according to the repository's dependency policy.
- Use least-privilege workflow permissions.
- Grant Pages deployment permissions only to the deployment job.
- Avoid exposing deployment credentials to build/test steps.
- Use concurrency controls so older builds cannot overwrite newer published documentation.
- Preserve build logs and generated diagnostics when generation or deployment fails.
- Do not use a second Zig compiler version for docs.

### Deliverables

- Pull-request documentation checks.
- Main-branch development deployment.
- Release-tag documentation deployment.
- Least-privilege deployment workflow.

### Acceptance criteria

- A documentation regression blocks the relevant pull request.
- Failed builds do not replace the currently published site.
- Release docs are generated from the tagged commit, not from a later `main` checkout.
- Documentation CI uses the engine's pinned Zig 0.16 compiler.

## 12. Phase 7 — GitHub Pages hosting

### One-time repository configuration

- [x] Enable GitHub Pages for the repository.
- [x] Configure Pages to use GitHub Actions as the deployment source.
- [x] Verify repository Actions permissions.
- [x] Configure the workflow's Pages build/deploy permissions.
- [x] Confirm repository visibility is compatible with intended Pages availability.
- [x] Decide whether to use the proposed `ash5me.github.io/Bairava-Engine/` URL or a custom domain.
- [ ] If using a custom domain, configure DNS and HTTPS separately.

### Manual deployment verification gate

The first development deployment is verified. Release retention remains unverified until the remaining checks pass:

- [x] Enable GitHub Pages in repository Settings.
- [x] Select GitHub Actions as the Pages deployment source.
- [x] Confirm workflow Pages permissions and repository Actions settings.
- [x] Run a deployment from `main` and verify the `/dev/` URL over HTTPS.
- [ ] Publish a test release snapshot and verify its versioned URL.
- [ ] Run a later deployment and verify the earlier release URL remains unchanged.

### Deployment model

```text
Pull request
  -> Generate public API reference
  -> Validate manifest, examples, links, and output boundary
  -> Report checks; do not publish

Push to main
  -> Generate docs with pinned Zig 0.16
  -> Validate
  -> Publish /dev/

Release tag
  -> Generate docs from tagged commit with pinned Zig 0.16
  -> Validate
  -> Publish /<version>/
  -> Update /latest/
```

One possible URL layout:

```text
/
  -> landing page / version selector
/dev/
  -> latest main-branch docs
/latest/
  -> newest stable release
/0.2.0/
  -> Bairava 0.2.0 docs
/0.3.0/
  -> Bairava 0.3.0 docs
```

Use a single deployment artifact containing the required versions or a controlled assembly step. Do not rely on separate concurrent deployments that overwrite one another.

### Deliverables

- Live GitHub Pages site.
- Automated development and release deployment.
- Stable version URLs.

### Acceptance criteria

- The site loads over HTTPS.
- Direct links to nested API pages work.
- The root page explains the available documentation versions.
- A failed deployment leaves the previous published site intact.

## 13. Phase 8 — Versioning and release maintenance

### Version policy

- `dev` documents the current supported public API on `main`.
- Each release gets an immutable documentation snapshot.
- `latest` points to the newest stable release.
- Old release documentation remains available for developers maintaining games on older versions.
- Release notes and migration notes are linked from the matching version.
- Every API reference records the engine version, source commit, and Zig 0.16 compiler version used to generate it.

### Release checklist

- [ ] Confirm package version and engine API version are consistent with the release policy.
- [ ] Confirm the release tag points to the intended commit.
- [ ] Run tests and documentation validation on that commit.
- [ ] Validate the public API manifest against the tagged source.
- [ ] Generate versioned API reference and guides.
- [ ] Review public API changes and migration notes.
- [ ] Publish the versioned docs.
- [ ] Update `latest`.
- [ ] Verify key URLs, canonical public names, search behavior, and examples after deployment.

Do not rewrite an existing release's documentation in place to match newer `main` behavior. If a correction is necessary, make the correction explicit and preserve the relationship to the released source.

### Deliverables

- Version selector.
- Immutable release documentation.
- Release documentation checklist.

### Acceptance criteria

- A developer using a specific Bairava release can access documentation for that release.
- `latest` never points to an unreleased development build.
- Versioned API reference corresponds to the matching source tag and compiler version.

## 14. Phase 9 — Documentation maintenance and governance

### Pull-request policy

For public API changes, require the author to consider:

- API documentation comments and manifest entries.
- Relevant guide updates.
- Example updates.
- Compatibility/migration notes.
- Experimental/stability status.
- Ownership, lifetime, error, and threading contract changes.
- Whether canonical public names or alias targets changed.

A PR template checklist can ask:

- [ ] Does this change alter the public API?
- [ ] Are public declarations documented?
- [ ] Does the public API manifest need an update?
- [ ] Are ownership/lifetime/error/threading contracts still accurate?
- [ ] Do examples or guides need updates?
- [ ] Is a migration note required?
- [ ] Does `zig build docs` pass with the pinned Zig 0.16 toolchain?
- [ ] Does the final-output public-boundary test pass?

### Documentation issue tracking

Maintain a documentation backlog with categories:

- Missing API comments or manifest descriptions.
- Incorrect or stale behavior descriptions.
- Missing examples.
- Broken links.
- Unclear ownership or lifetime contracts.
- Unsupported or ambiguous API guarantees.
- Public manifest entries that no longer match source.
- Internal symbol/source leakage in generated artifacts.
- Release/migration documentation.

### Maintenance cadence

- Review docs and manifest in every public API PR.
- Review all guides before a stable release.
- Verify exporter behavior when upgrading Zig.
- Check deployment and external links periodically.
- Remove or update documentation for deprecated features according to the deprecation policy.

### Deliverables

- Documentation contribution checklist.
- Documentation issue backlog.
- Release review procedure.
- Zig compiler upgrade verification checklist for the exporter.

## 15. Testing and acceptance matrix

| Area | Validation | Required result |
|---|---|---|
| Toolchain | Build docs using pinned Zig 0.16 | Success |
| Manifest | Validate all entries against public package root | No missing, duplicate, or stale entries |
| Public API | Inspect generated reference | Intended public exports present exactly once |
| Canonical aliases | Check aliases such as `bairava.Config` | Public alias shown; internal target not separately published |
| Internal API | Scan all generated files | No unapproved internal declaration |
| Source leakage | Scan all files and assets | No internal source listing/archive |
| Search | Inspect generated search data | Only public API and authored docs indexed |
| Contracts | Review ownership/error/threading docs | Important contracts explicit |
| Guides | Follow getting-started instructions from clean checkout | New project builds and runs |
| Examples | Compile advertised compile-only examples | All pass |
| Runtime examples | Run on supported display/device lane or manual test | Expected behavior |
| Links | Local link validation | No broken internal links |
| CI | Open a docs-changing PR | Checks run and fail on regression |
| Development deployment | Push to main | `dev` updated after successful checks |
| Release | Publish a release tag | Version snapshot matches tagged source |
| Hosting | Open root and nested URLs | HTTPS, navigation, and direct links work |
| Accessibility | Keyboard/mobile review | Content remains usable |

## 16. Suggested implementation milestones

These milestones are a recommended grouping, not calendar estimates.

### Milestone A — Public API boundary and manifest

- Scope and API boundary confirmed.
- Export inventory complete.
- Public manifest created and reviewed.
- Public comments and contracts reviewed.
- Experimental and backend-specific APIs labelled.

**Exit gate:** No unresolved critical ambiguity about what game developers are expected to call, and every intended public entry has a canonical name.

### Milestone B — Zig 0.16 exporter and boundary enforcement

- Existing Autodoc probe artifact inspected.
- Extraction adapter selected and documented.
- Bairava-specific exporter implemented.
- Public-only normalized IR generated.
- Alias, stale-entry, duplicate-entry, and internal-leak tests pass.

**Exit gate:** A clean checkout can generate a public-only API reference with Zig 0.16, and the full generated output passes the boundary scan.

### Milestone C — Build integration and generated reference

- `zig build docs` implemented.
- Generated output reviewed.
- Generation is headless.
- Output is deterministic for the same source, toolchain, and manifest.

**Exit gate:** Documentation generation is a repeatable build step and fails on invalid metadata or public-boundary violations.

### Milestone D — Guides and examples complete

- Getting-started path written.
- Core subsystem guides written.
- Examples compile in CI.
- Advanced guides cover supported subsystems and limitations.

**Exit gate:** A developer can build a small game without relying on internal source imports or undocumented assumptions.

### Milestone E — CI and hosting live

- PR validation enabled.
- `main` deployment enabled.
- GitHub Pages configured.
- Root and nested URLs verified.

**Exit gate:** Documentation is automatically published and regressions are caught before publication.

### Milestone F — Release documentation operational

- Versioned release snapshots implemented.
- `latest` alias controlled.
- Release checklist adopted.
- Migration notes linked to releases.

**Exit gate:** Every new stable release can publish matching documentation repeatably.

## 17. Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Zig 0.16 Autodoc output has no suitable structured declaration data | Direct artifact extraction is unreliable | Use a compiler-checked manifest metadata adapter; do not scrape rendered HTML |
| Zig compile-time reflection does not expose all required signature detail | Signatures could be incomplete or misleading | Use explicit reviewed signature metadata with compiler-backed declaration validation as a controlled fallback |
| Public aliases resolve to internal declaration names | Internal names leak into the API reference | Store canonical public names in the manifest and render only those names |
| Public API contains undocumented contracts | Users misuse ownership/lifetime or call order | Audit contracts before publishing |
| Guides drift from source behavior | Incorrect examples and user frustration | Compile examples and review docs with API PRs |
| Internal implementation becomes mistaken for supported API | Accidental compatibility promises | Allowlist manifest; never publish all discovered `pub` declarations |
| Hidden internal content remains in search or static assets | Public boundary is bypassed | Generate every output from public-only IR and scan the complete final artifact |
| GPU/window requirements break docs CI | Unreliable documentation builds | Keep reference generation and compile-only examples headless |
| Main and release deployments race | Wrong version appears at a URL | Use one controlled deployment artifact and concurrency controls |
| Old release docs are overwritten | Users cannot find matching docs | Publish immutable version paths |
| API changes without migration guidance | Upgrade friction | Add API-change checklist and release migration notes |
| Zig upgrade breaks exporter assumptions | Documentation generation fails or changes output | Pin Zig 0.16; add explicit exporter revalidation to any future compiler-upgrade work |

## 18. Definition of done

The documentation project is complete when all of the following are true:

- [x] `zig build docs` generates the public API reference using the repository's pinned Zig 0.16 toolchain.
- [ ] The reference accurately represents the supported public `bairava` package.
- [x] The public API manifest is explicit, reviewed, and checked against real declarations.
- [x] Canonical public names are used; internal implementation paths are not published as alternate public entries.
- [x] Internal source listings, source archives, internal navigation, and internal search entries are absent.
- [ ] Public declarations have useful descriptions and important contracts are explained.
- [x] Internal implementation is not presented as stable game-facing API.
- [x] Getting-started and core guides cover the normal game-development workflow.
- [x] Advertised compilable examples are built in CI.
- [x] Documentation validation runs on pull requests.
- [ ] `main` automatically publishes development documentation.
- [ ] Release tags publish immutable, matching documentation snapshots.
- [ ] `latest` points to the newest stable release.
- [ ] GitHub Pages serves the site over HTTPS with working nested links.
- [x] The repository has a repeatable documentation contribution and release checklist.
- [x] No separate Zig 0.17 documentation toolchain is required.

## 19. Explicit non-goals

Unless separately approved, this project does not include:

- Redesigning or refactoring Bairava's public API.
- Making internal modules public just to improve documentation coverage.
- Upgrading the engine or documentation toolchain from Zig 0.16 to Zig 0.17.
- Replacing the engine's build system.
- Building a general-purpose Zig parser or general-purpose Zig documentation generator.
- Scraping Autodoc's rendered HTML as the authoritative source of API metadata.
- Publishing Autodoc's complete source-browser output as the Bairava API reference.
- Building a custom documentation server or backend.
- Promising that experimental APIs are stable.
- Documenting every private implementation detail.
- Rewriting all existing project documentation without first reviewing its purpose.
- Treating generated API pages as a replacement for tutorials, examples, or migration notes.

---

## Recommended execution order

Implement the milestones in order:

**Public API boundary and manifest → Zig 0.16 exporter → `zig build docs` → guides and tested examples → CI validation → GitHub Pages → release versioning and maintenance.**

The most important quality rule is that the published reference must describe only the supported public Bairava API, using the names game developers actually call, and must not leak internal declarations or source listings.
