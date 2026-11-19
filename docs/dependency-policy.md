# Dependency and version policy

Dependency versions are intentional build inputs. Do not update dependencies
from floating branches, tags, or `master` URLs in the build. A dependency
update must be reviewed as a source change, tested on the CI platform matrix,
and reflected in the version records that ship with release artifacts.

## Version sources

| Dependency | Pin and source of truth |
|---|---|
| Zig | `minimum_zig_version` in `build.zig.zon`; CI installs that exact version |
| SDL | Full Git commit and Zig package content hash in `build.zig.zon` |
| ztracy | Full Git commit and Zig package content hash in `build.zig.zon` |
| msdfgen | Full Git commit and Zig package content hash in `build.zig.zon`; source-tree hash and license in [`dependency-lock.json`](dependency-lock.json); linked only into the host asset builder |
| Slang compiler | Version in `.github/workflows/ci.yml`; per-platform archive digests in [`dependency-lock.json`](dependency-lock.json) |
| cglm, FreeType, stb, log.c, Parson | Versions, upstream references, and source-tree SHA-256 values in [`dependency-lock.json`](dependency-lock.json) |
| HarfBuzz | Version, upstream reference, and source-tree SHA-256 in [`dependency-lock.json`](dependency-lock.json); vendored under `vendor/harfbuzz-15.1.0/` (`src/` and `COPYING`) |
| msdfgen | Version 1.13.0, commit `1874bcf7d9624ccc85b4bc9a85d78116f690f35b`, MIT license, and source-tree SHA-256 in [`dependency-lock.json`](dependency-lock.json); vendored under `vendor/msdfgen-1.13/` |
| Test font (Noto Sans Tamil) | Upstream commit and tree SHA-256 in [`dependency-lock.json`](dependency-lock.json); files under `tests/fixtures/`, used only by `zig build test` |
| Test font (Chemmozhi Paranar) | SHA-256 in [`dependency-lock.json`](dependency-lock.json); file under `tests/fixtures/`, used only by `zig build test`. License accepted by the owner (see "Test fixtures") |

The lock file covers every file in the vendored dependency paths, not just
version headers. It also mirrors the Zig, Slang, SDL, and ztracy pins. The
checker compares those records to `build.zig.zon` and CI, recomputes each
vendored SHA-256, and fails on a missing or changed source. CI and release
packaging run the same checker. CI also checks the SHA-256 digest of the
platform-specific Slang archive against the official release asset digest
recorded in the lock before extracting it. For a vendored update, replace its
complete source/license set, update its version and upstream reference in the
lock, regenerate its hash using the documented algorithm in the checker, then
run the checker and full CI suite.

Vendored tree hashes include every file under directory entries and every
explicitly listed file. The checker sorts by repository-relative POSIX path and
feeds SHA-256 the 8-byte big-endian path length, UTF-8 path, 8-byte big-endian
file length, and file bytes for each entry. To keep pins identical across
Windows and Unix checkouts, text files (no NUL byte in the first 8 KiB) have
CRLF line endings normalized to LF before hashing; binary files are hashed
byte-for-byte.

For Zig packages, update the reviewed URL/commit and content hash together in
`build.zig.zon` (for example with `zig fetch --save`) and mirror both in the
dependency lock. For Slang, update the single CI version used by all operating systems, mirror
it in the lock, and refresh the official SHA-256 digests for every supported
platform archive. CI verifies both the archive and the extracted compiler
version; release packaging checks the compiler on `PATH` before building.
Verify SPIR-V, DXIL, and Metal shader compilation where supported. Do not
update generated hashes or version records without reviewing the corresponding
upstream change and license.

Raise the minimum Zig version only when the code or build requires it. Update
`build.zig.zon`, verify the CI installer resolves that exact version, and run
the full platform matrix. Security fixes should be prioritized; otherwise
review pinned dependency updates at least quarterly. Keep the prior pin in the
change history for rollback.

## Licenses and change history for HarfBuzz and stb

**HarfBuzz 15.1.0** (`vendor/harfbuzz-15.1.0/`)

- `COPYING` is the "Old MIT" license. It covers the HarfBuzz sources except where a subdirectory states otherwise.
- `src/ms-use/COPYING` is the MIT License, copyright Microsoft Corporation. The default build compiles only `src/harfbuzz.cc`, which does not include that code.
- The build compiles HarfBuzz as C++11 with `-fno-exceptions -fno-rtti` and links the C++ runtime. These match upstream's build settings.
- Upstream commit: `3df40d9b98d6b32f0e4288d4ecfbb158ddb3a372`, recorded in the lock. Before release, check it against the vendored tree. Export it with `git archive 3df40d9b98d6b32f0e4288d4ecfbb158ddb3a372 src COPYING`, place the output under `vendor/harfbuzz-15.1.0/`, and compare the two. If the commit does not track `src/hb-version.h`, that file is generated and should be recorded as such, not as upstream source.

**stb** (`stb_image.h` 2.30, `stb_image_write.h` 1.16, `stb_rect_pack.h` 1.01, `stb_truetype.h` 1.28)

- Each header offers two alternative licenses: MIT, and public domain (the Unlicense text). Use is permitted under either. This was checked for all four headers.
- Upstream commit: `9600522de53973336fa033a289858a4354cbb04c`, recorded in the lock for `stb_truetype.h` 1.28. Check it with `git show 9600522de53973336fa033a289858a4354cbb04c:stb_truetype.h | sha256sum`. The result should be `428cfe93520f2aed5e413a220b0db5bba5b17e2ebe5a64e4a8efa9eeeb67ec5f` if your copy is byte-identical to the commit. The other stb files in the lock entry are not yet tied to a commit.
- Change history for `stb_truetype.h`: version 1.26 (lock hash `bb97d75f…`) was replaced by upstream 1.28 (lock hash `6ad5c81a…`). The 1.26 pin is kept here for rollback. A locally edited 1.26 (hash `0a7a878f…`) was never recorded and is superseded by 1.28.

## Test fixtures

**Noto Sans Tamil** (`tests/fixtures/NotoSansTamil.ttf` and `tests/fixtures/NotoSansTamil-OFL.txt`)

- Copyright 2022 The Noto Project Authors (https://github.com/notofonts/tamil). The font is variable TrueType outlines (`glyf`) with `GSUB` and `GPOS`. It is licensed under the SIL Open Font License, Version 1.1. The license text is in `NotoSansTamil-OFL.txt`, and the font also carries it in its name table.
- Source: `ofl/notosanstamil/NotoSansTamil[wdth,wght].ttf` at the google/fonts commit `7af0d90b4d532ffa4b041937b560c6df4e7b1e95`. The repository copy is renamed to `NotoSansTamil.ttf`, and its bytes are unchanged (SHA-256 `aa3a9b321f4b0bb2c40203ffbde9af89713227866e0e13f76e5b9eeea727cf88`). `OFL.txt` at that commit is byte-identical to the copy kept here.
- Used by `src/engine/text/shaper_tamil_test.zig` only. `scripts/package-release.ps1` copies a fixed list of files and does not copy `tests/`, so the font is not in release archives.
- The lock records the tree hash of both files, and `scripts/check-dependency-pins.py` verifies it on every run.
- Replace the font only as a reviewed change: a new pinned commit, new hashes, and the expected Tamil values in `shaper_tamil_test.zig` rechecked against it.

**Chemmozhi Paranar** (`tests/fixtures/ChemmozhiParanar.ttf`)

- Version 1.000 (2011). The name table credits R. Kalaimani, 1998, and says the font was modified by ICTA (Sri Lanka) and renamed from TSCu_Paranar.
- License, as the font's own name records state it (name IDs 0 and 10): "Released Under the GNU GPL, Dec. 2002." The GPL version is not stated, and the font has no font exception.
- **Owner decision, 2026-11-18:** the owner accepted this license for use in the repository. The fixture is used by `src/engine/text/shaper_chemmozhi_test.zig` only, and `scripts/package-release.ps1` does not copy `tests/`, so it is not in release archives.
- Not approved for shipping in the game. Bundling this font in game assets or a release would make its GPL terms apply to that release, and that needs a separate owner decision.
- The file hash in the lock (`ab3de81b…`) is the pin. No upstream URL exists for the file, so there is no commit to record.

## Release record

Release archives intentionally omit third-party source code. The packager
includes `dependency-lock.json` and writes its SHA-256 digest and path into
`release-manifest.txt`. The lock records the versions and immutable package
references for all build dependencies, plus hashes for the complete vendored
source paths. The digest makes that provenance available without distributing
the vendored sources. It records repository pins, not proof that a separately
built executable used them when `-SkipBuild` is used.
