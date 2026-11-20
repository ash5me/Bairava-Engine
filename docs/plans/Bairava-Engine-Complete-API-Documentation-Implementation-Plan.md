# Bairava Engine — Complete API Documentation Implementation Plan

**Status:** Implementation started; public-root export inventory in progress
**Scope:** Complete implementation, validation, hosting, and maintenance of Bairava's developer documentation  
**Repository:** `ash5me/Bairava-Engine`  
**Target documentation URL:** `https://ash5me.github.io/Bairava-Engine/` (proposed)  
**Planning baseline:** The repository structure and API boundaries discussed during the November 2026 review. Reconfirm branch names, compiler version, and build configuration before implementation.

---

## 1. Purpose and outcome

Build and maintain a public documentation website for Bairava Engine that combines:

1. **Generated API reference** — declarations, signatures, types, fields, enum values, and source documentation comments generated from the Zig public API.
2. **Developer guides** — practical explanations of engine workflows, ownership rules, lifecycle, and subsystem usage.
3. **Runnable examples** — examples compiled in CI and written against the supported public `bairava` module.
4. **Release-specific documentation** — documentation snapshots for released engine versions, plus development documentation for `main`.

The finished site should let a game developer discover an API, understand its contracts, follow a guide, and compile a representative example without reading engine internals.

This plan describes the implementation sequence and acceptance criteria; its implementation notes record verified progress and remaining work.

## 2. Guiding decisions

| Area | Decision |
|---|---|
| API extraction | Prefer Zig Autodoc only if it can represent the public package boundary; otherwise use a narrow `std.zig.Ast` extractor on the package root, with the compiler pinned |
| API boundary | Document the supported public package rooted at `src/engine/bairava.zig`; do not present internal modules as stable public API |
| Build integration | Add a dedicated `zig build docs` step that reads the authoritative public package root and does not duplicate engine module configuration |
| Handwritten content | Markdown guides maintained separately from generated API reference |
| Examples | Prefer real sample-game patterns; compile examples in CI |
| Hosting | GitHub Pages, serving static output |
| CI | Generate, validate, and publish documentation using the repository's pinned Zig toolchain |
| Versioning | Publish `dev` from `main` and immutable versioned snapshots for releases |
| Compatibility | Do not upgrade Zig or change public API solely to make documentation generation work; resolve compatibility within the supported toolchain first |

### Important Autodoc constraint

Zig's documentation generation behavior is compiler-version-dependent and may be experimental. The implementation must verify the exact behavior of the repository's pinned Zig compiler, especially for the package root's re-exports and imported modules. If the compiler cannot generate the required reference reliably, stop and make an explicit tooling decision before building the rest of the pipeline around it. Do not silently switch to an unrelated generator or publish incomplete output.

### Implementation notes (2026-11-20)

- The default branch is `main`; the pinned compiler is `0.16.0-dev.3142+5ccfeb926`. The game-facing import is `@import("bairava")`, rooted at `src/engine/bairava.zig`.
- This repository has tags `v0.1.0` and `v0.2.0`; its package version is `0.3.0`. GitHub Pages is not configured, and no repository license file is present. The proposed URL and documentation licensing decision therefore remain unconfirmed.
- The pinned compiler supports `-femit-docs`, and the build API exposes generated documentation. A browser review of the Autodoc probe showed that its search includes implementation declarations such as `core.engine.Config`, its navigation initially lands on `ai`, and its `sources.tar` contains 674 module source entries. This fails the public-boundary criterion, so Autodoc is not used for publication.
- The approved direction is a small in-repository extractor using the pinned compiler's `std.zig.Ast`, restricted to declarations in `src/engine/bairava.zig`. `zig build docs` now emits an initial Markdown inventory of 87 root exports under `zig-out/doc/bairava/index.md`; it does not follow imports, so implementation declarations and source paths are not exposed. The inventory reports zero declarations with root-level doc comments. It intentionally does not yet resolve underlying types, namespace members, or API contracts, and is not the final reference.
- Continue with the API inventory and contract audit, then expand the extractor against explicitly public declarations. Do not start site assembly, CI, or deployment until the generated reference satisfies the public-boundary and completeness criteria. Keep the engine compiler pinned.
- Researching dedicated generators found no drop-in alternative for the pinned toolchain:
  - [`baskingspot/docgen`](https://github.com/baskingspot/docgen) emits JSON or standalone HTML and follows relative imports, but its package requires Zig `0.17.0` and collects public declarations throughout the imported graph. It is not a public-export filter and has no demonstrated Windows/0.16 compatibility.
  - [`braksator/ZigDoc`](https://github.com/braksator/ZigDoc) supports HTML/Markdown and namespace traversal, but also requires Zig `0.17.0`; its `--private off` setting hides non-`pub` declarations, not public declarations in internal modules.
  - [`davidlee/zigmarkdoc`](https://github.com/davidlee/zigmarkdoc) supports Zig `0.15.2+`, but is single-file only, does not resolve imported types, and its repository has no declared license.
  - [`andrewrk/autodoc`](https://github.com/andrewrk/autodoc) is archived and was upstreamed into Zig; [`tinyzimmer/zigdoc`](https://github.com/tinyzimmer/zigdoc) is a remote-module documentation server, not a public-export filtering extractor.
  - The public-root extractor has been selected for this implementation; no docs-only compiler upgrade is approved.

## 3. Repository areas to review

Review these areas before implementation:

- `build.zig` — engine module creation, dependencies, build options, install steps.
- `build.zig.zon` — package metadata and pinned Zig version constraints.
- `src/engine/bairava.zig` — public package root and re-exports.
- `src/engine/core/engine.zig` — central game-facing API.
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
|   +-- Generated public API
|   +-- Types and namespaces
|   +-- Functions and methods
|   +-- Errors and enums
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
- [ ] Confirm the exact Zig compiler version used by local builds and CI.
- [ ] Confirm the public package root and supported game-facing import.
- [ ] Inventory existing documentation and identify material that can be reused.
- [ ] Identify features that are experimental, incomplete, backend-specific, or unsupported.
- [ ] Define what counts as public API versus internal implementation.
- [ ] Decide the documentation license and verify licenses for any copied third-party examples or assets.
- [ ] Define the site URL and GitHub Pages ownership/configuration.
- [ ] Establish a documentation review owner (the engine maintainer).

### Deliverables

- Approved documentation scope.
- Public API boundary statement.
- List of existing guides to retain, revise, or replace.
- Confirmed toolchain and deployment assumptions.

### Acceptance criteria

- A new user can be told exactly which module is supported for game code.
- Internal implementation modules are not accidentally advertised as stable interfaces.
- Known limitations are listed rather than hidden.

## 6. Phase 1 — Public API inventory and contract documentation

### 6.1 Inventory exports

Audit all declarations reachable from `src/engine/bairava.zig`.

For each exported declaration, record:

- Name and kind (type, function, constant, namespace, enum, error set).
- Owning subsystem.
- Whether it is intentionally public.
- Whether it is stable, experimental, or internal.
- Whether it needs a doc comment.
- Relevant guide page.
- Whether its behavior is covered by tests or an example.

Review re-exports carefully. A public alias should have a useful description even when its implementation is declared in another file.

### 6.2 Document contracts, not just signatures

For every important public API, explain the parts a Zig signature cannot communicate:

- Ownership: who owns the value and who destroys it.
- Lifetime: when handles, pointers, views, and resources become invalid.
- Allocator: which allocator is used, who supplies it, and whether allocation can occur.
- Errors: expected error cases and recovery guidance.
- Panic behavior: whether invalid use panics, asserts, or returns an error.
- Threading: main-thread restrictions, thread safety, and callback thread.
- Ordering: required initialization, update, draw, flush, and shutdown order.
- Backend constraints: SDL_GPU-only, SDL3 2D-compatible, or backend-independent behavior.
- Capacity limits: what happens at capacity and how callers can detect or avoid overflow.
- Units and coordinate spaces: pixels, world units, seconds, normalized coordinates, ground-contact coordinates, etc.

### 6.3 Public API quality gate

Do not document accidental exports as supported merely because they are `pub`.

For each questionable export, choose one:

1. Keep public and document its contract.
2. Keep public but mark experimental with an explicit stability warning.
3. Make internal in a separately reviewed API change.
4. Deprecate with a migration path.

This documentation project should not make unreviewed API-breaking changes. Any API-surface cleanup must be tracked as a separate change.

### Deliverables

- Public API inventory.
- Documentation-comment coverage report.
- List of unresolved API contract questions.
- Approved public/experimental/internal classification.

### Acceptance criteria

- Every intentionally public top-level export has a useful description.
- Important public methods describe ownership, errors, lifetime, and threading where applicable.
- No known internal-only declaration is presented as a supported game-facing API.

## 7. Phase 2 — Generated API reference and build integration

### 7.1 Verify compiler support

- [x] Check `zig build --help` and the pinned compiler's documentation-generation support.
- [x] Confirm the exact `-femit-docs` behavior for the pinned version.
- [x] Confirm how the build system exposes the configured module's documentation artifact.
- [x] Confirm whether documentation is generated for declarations re-exported by `bairava.zig`.
- [x] Confirm imported public modules and external dependencies resolve correctly.
- [ ] Confirm the generated output is complete and can be opened as a static site.
- [x] Record any compiler-specific caveats in the implementation notes.

### 7.2 Implement the documentation build step

Add a dedicated build step named `docs` to the existing build graph. The current
step produces a root-export inventory; it is an intermediate milestone, not the
complete API reference.

Requirements:

- Reuse the same configured `bairava` module used by game builds.
- Reuse the same dependency graph and build options needed to analyze public declarations.
- Avoid creating a second, drifting copy of the engine module configuration.
- Do not require a window, GPU device, audio device, or running game merely to generate reference docs.
- Write output to a predictable build directory, for example `zig-out/doc/bairava/`.
- Ensure a clean build regenerates the complete output.
- Fail with a useful error if documentation generation fails.
- Keep generated output out of normal source control unless there is a deliberate release-artifact policy.

Expected developer workflow:

```powershell
zig build docs
```

The exact build API and output installation mechanism must follow the pinned Zig compiler; do not copy build-system code from a different Zig release without checking compatibility.

### 7.3 Generated API reference review

Inspect the generated site for:

- Public package/module landing page.
- Re-exported types and namespaces.
- Struct fields and enum values.
- Function and method signatures.
- Error sets and return types.
- Documentation comments and intra-doc links.
- Search/navigation behavior.
- Readability on desktop and mobile.
- Accidental exposure of private or implementation-only declarations.

If the compiler's generated output cannot meet the navigation or search requirements, first assess whether the missing behavior is an Autodoc limitation or a source-comment/API-organization issue. Avoid adding a second generator unless there is a clear, documented need.

### Deliverables

- `zig build docs`.
- Generated reference output under a predictable directory.
- Reviewed API reference.
- Notes on compiler-specific behavior.

### Acceptance criteria

- Documentation generation succeeds with the pinned compiler on the supported CI environment.
- The generated reference includes the intended public API.
- It does not require a live graphics/audio device.
- A clean checkout can reproduce the output.

## 8. Phase 3 — Handwritten guides and runnable examples

### 8.1 Guide template

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

### 8.2 Writing order

Write the guides in this order:

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

### 8.3 Examples policy

- Use the public `@import("bairava")` module.
- Avoid importing `src/engine/...` implementation paths.
- Prefer small, focused examples over one giant sample.
- Keep examples compilable with the pinned Zig version.
- Avoid relying on undocumented sample-only helpers.
- Include expected behavior and any required assets.
- Mark pseudocode clearly; never present pseudocode as a compiling example.
- Where an example needs a window or GPU, keep it out of the headless documentation-generation step and run it in an appropriate CI or manual validation lane.

### 8.4 Example validation

Create a clear separation between:

- **Compile-only examples:** can be checked without opening a window or GPU.
- **Runtime examples:** need a supported display/audio/GPU environment.
- **Illustrative snippets:** intentionally incomplete and labelled as such.

Where practical, place compile-tested examples in a dedicated examples directory and add build steps for them. Avoid copying code into Markdown and letting the copy drift; use a documented snippet-inclusion or verification approach if the documentation system supports it.

### Deliverables

- Complete getting-started path.
- Core subsystem guides.
- Advanced guides as supported by the engine.
- Compile-tested examples.
- Explicitly labelled runtime-only and illustrative examples.

### Acceptance criteria

- A new developer can create and run a minimal game by following the guide.
- Every example advertised as compilable is checked in CI.
- Guides link to the matching API reference.
- No example teaches use of an internal-only module.

## 9. Phase 4 — Documentation structure, navigation, and presentation

### Tasks

- [ ] Choose the presentation approach that works with the generated Autodoc output.
- [ ] Keep generated API reference and Markdown guide content in a coherent site navigation.
- [ ] Provide a landing page explaining what Bairava is and where to start.
- [ ] Add navigation between guides, API reference, examples, and release notes.
- [ ] Add previous/next links for multi-page tutorials where useful.
- [ ] Add a visible compiler version and engine version on relevant pages.
- [ ] Add clear badges or text for experimental, backend-specific, or unsupported features.
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
    releases/
```

The exact folder structure can be adapted to the chosen site assembly approach. Do not move or rename existing technical documents until their references and purpose have been reviewed.

### Deliverables

- Coherent documentation navigation.
- Landing page and 404 page.
- Responsive, accessible static site.

### Acceptance criteria

- A reader can move from a guide to its API entries and back.
- The site is usable on desktop and mobile.
- Experimental and backend-specific behavior is clearly identified.

## 10. Phase 5 — CI validation

Add a documentation validation job or a clearly separated stage in the existing GitHub Actions workflow.

### On pull requests

Run:

1. Install the exact Zig version pinned by the repository.
2. Check formatting if required by the normal project workflow.
3. Generate API docs.
4. Build compile-only documentation examples.
5. Validate required generated output exists.
6. Check local documentation links where practical.
7. Fail if a required documentation step fails.

Do not deploy public documentation from untrusted pull-request contexts.

### On pushes to `main`

- Run the same documentation checks.
- Generate the development (`dev`) documentation artifact.
- Publish it to the development documentation location if all checks pass.

### On release tags

- Validate that the tag points to the intended release commit.
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
- Preserve build logs when generation or deployment fails.

### Deliverables

- Pull-request documentation checks.
- Main-branch development deployment.
- Release-tag documentation deployment.
- Least-privilege deployment workflow.

### Acceptance criteria

- A documentation regression blocks the relevant pull request.
- Failed builds do not replace the currently published site.
- Release docs are generated from the tagged commit, not from a later `main` checkout.

## 11. Phase 6 — GitHub Pages hosting

### One-time repository configuration

- [ ] Enable GitHub Pages for the repository.
- [ ] Configure Pages to use GitHub Actions as the deployment source.
- [ ] Verify repository Actions permissions.
- [ ] Configure the workflow's Pages build/deploy permissions.
- [ ] Confirm the repository's public/private visibility is compatible with the intended Pages availability.
- [ ] Decide whether to use the proposed `ash5me.github.io/Bairava-Engine/` URL or a custom domain.
- [ ] If using a custom domain, configure DNS and HTTPS separately.

### Deployment model

```text
Pull request
  -> Generate docs
  -> Validate docs and examples
  -> Report checks; do not publish

Push to main
  -> Generate docs
  -> Validate
  -> Publish /dev/

Release tag
  -> Generate from tagged commit
  -> Validate
  -> Publish /<version>/
  -> Update /latest/
```

The final URL layout should be stable and documented. One possible layout is:

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

## 12. Phase 7 — Versioning and release maintenance

### Version policy

- `dev` documents the current supported public API on `main`.
- Each release gets an immutable documentation snapshot.
- `latest` points to the newest stable release.
- Old release documentation remains available for developers maintaining games on older versions.
- Release notes and migration notes are linked from the matching version.

### Release checklist

- [ ] Confirm package version and engine API version are consistent with the release policy.
- [ ] Confirm the release tag points to the intended commit.
- [ ] Run tests and documentation validation on that commit.
- [ ] Generate versioned API reference.
- [ ] Review public API changes and migration notes.
- [ ] Publish the versioned docs.
- [ ] Update `latest`.
- [ ] Verify key URLs and examples after deployment.

Do not rewrite an existing release's documentation in place to match newer `main` behavior. If a correction is necessary, make the correction explicit and preserve the relationship to the released source.

### Deliverables

- Version selector.
- Immutable release documentation.
- Release documentation checklist.

### Acceptance criteria

- A developer using a specific Bairava release can access documentation for that release.
- `latest` never points to an unreleased development build.
- Versioned API reference corresponds to the matching source tag.

## 13. Phase 8 — Documentation maintenance and governance

### Pull-request policy

For public API changes, require the author to consider:

- API documentation comments.
- Relevant guide updates.
- Example updates.
- Compatibility/migration notes.
- Experimental/stability status.
- Ownership, lifetime, error, and threading contract changes.

A PR template checklist can ask:

- [ ] Does this change alter the public API?
- [ ] Are public declarations documented?
- [ ] Are ownership/lifetime/error/threading contracts still accurate?
- [ ] Do examples or guides need updates?
- [ ] Is a migration note required?
- [ ] Does the generated API reference build?

### Documentation issue tracking

Maintain a documentation backlog with categories:

- Missing API comments.
- Incorrect or stale behavior descriptions.
- Missing examples.
- Broken links.
- Unclear ownership or lifetime contracts.
- Unsupported or ambiguous API guarantees.
- Release/migration documentation.

### Maintenance cadence

- Review docs in every public API PR.
- Review all guides before a stable release.
- Verify examples when upgrading Zig.
- Check deployment and external links periodically.
- Remove or update documentation for deprecated features when the deprecation policy requires it.

### Deliverables

- Documentation contribution checklist.
- Documentation issue backlog.
- Release review procedure.

## 14. Testing and acceptance matrix

| Area | Validation | Required result |
|---|---|---|
| Toolchain | Build docs using pinned Zig | Success |
| Public API | Inspect generated reference | Intended public exports present |
| Re-exports | Check package-root aliases | Correct names and comments visible |
| Internal API | Inspect generated pages | Internal-only implementation not advertised as supported |
| Contracts | Review ownership/error/threading docs | Important contracts explicit |
| Guides | Follow getting-started instructions from clean checkout | New project builds and runs |
| Examples | Compile advertised compile-only examples | All pass |
| Runtime examples | Run on supported display/device lane or manual test | Expected behavior |
| Links | Local link validation | No broken internal links |
| CI | Open a docs-changing PR | Checks run and fail on regression |
| Deployment | Push to main | `dev` updated after successful checks |
| Release | Publish a release tag | Version snapshot matches tagged source |
| Hosting | Open root and nested URLs | HTTPS, navigation, and direct links work |
| Accessibility | Keyboard/mobile review | Content remains usable |

## 15. Suggested implementation milestones

These milestones are a recommended grouping, not calendar estimates.

### Milestone A — Public API ready for documentation

- Scope and API boundary confirmed.
- Export inventory complete.
- Public comments and contracts reviewed.
- Experimental and backend-specific APIs labelled.

**Exit gate:** No unresolved critical ambiguity about what game developers are expected to call.

### Milestone B — Generated reference integrated

- Autodoc behavior verified against the pinned compiler.
- `zig build docs` implemented.
- Generated output reviewed.
- No graphics/audio device needed for generation.

**Exit gate:** A clean checkout can generate a complete public API reference.

### Milestone C — Guides and examples complete

- Getting-started path written.
- Core subsystem guides written.
- Examples compile in CI.
- Advanced guides cover supported subsystems and limitations.

**Exit gate:** A developer can build a small game without relying on internal source imports or undocumented assumptions.

### Milestone D — CI and hosting live

- PR validation enabled.
- `main` deployment enabled.
- GitHub Pages configured.
- Root and nested URLs verified.

**Exit gate:** Documentation is automatically published and regressions are caught before publication.

### Milestone E — Release documentation operational

- Versioned release snapshots implemented.
- `latest` alias controlled.
- Release checklist adopted.
- Migration notes linked to releases.

**Exit gate:** Every new stable release can publish matching documentation repeatably.

## 16. Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Pinned Zig compiler has incomplete Autodoc behavior | Missing or unusable API pages | Verify the exact compiler early; document limitations and make an explicit tooling decision |
| Re-export comments do not appear as expected | Public package root looks undocumented | Test re-export behavior and document aliases at the public boundary |
| Public API contains undocumented contracts | Users misuse ownership/lifetime or call order | Audit contracts before publishing |
| Guides drift from source behavior | Incorrect examples and user frustration | Compile examples and review docs with API PRs |
| Internal implementation becomes mistaken for supported API | Accidental compatibility promises | Generate from the public root and review exported surface |
| GPU/window requirements break docs CI | Unreliable documentation builds | Keep reference generation and compile-only examples headless |
| Main and release deployments race | Wrong version appears at a URL | Use one controlled deployment artifact and concurrency controls |
| Old release docs are overwritten | Users cannot find matching docs | Publish immutable version paths |
| API changes without migration guidance | Upgrade friction | Add API-change checklist and release migration notes |

## 17. Definition of done

The documentation project is complete when all of the following are true:

- [ ] `zig build docs` generates the public API reference using the repository's pinned Zig toolchain.
- [ ] The reference accurately represents the supported public `bairava` package.
- [ ] Public declarations have useful comments and important contracts are explained.
- [ ] Internal implementation is not presented as stable game-facing API.
- [ ] Getting-started and core guides cover the normal game-development workflow.
- [ ] Advertised compilable examples are built in CI.
- [ ] Documentation validation runs on pull requests.
- [ ] `main` automatically publishes development documentation.
- [ ] Release tags publish immutable, matching documentation snapshots.
- [ ] `latest` points to the newest stable release.
- [ ] GitHub Pages serves the site over HTTPS with working nested links.
- [ ] The repository has a repeatable documentation contribution and release checklist.

## 18. Explicit non-goals

Unless separately approved, this project does not include:

- Redesigning or refactoring Bairava's public API.
- Making internal modules public just to improve documentation coverage.
- Changing the supported Zig compiler version.
- Replacing the engine's build system.
- Building a custom documentation server or backend.
- Promising that experimental APIs are stable.
- Documenting every private implementation detail.
- Rewriting all existing project documentation without first reviewing its purpose.
- Treating generated API pages as a replacement for tutorials, examples, or migration notes.

---

## Recommended execution order

Implement the milestones in order: **API boundary and contracts → generated reference → guides and tested examples → CI validation → GitHub Pages → release versioning and maintenance.**

The most important quality rule is that the documentation must describe the supported public API and its real behavior—not merely expose every declaration the compiler can see.
