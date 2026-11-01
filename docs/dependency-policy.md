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
| Slang compiler | Version in `.github/workflows/ci.yml`; per-platform archive digests in [`dependency-lock.json`](dependency-lock.json) |
| cglm, FreeType, stb, log.c, Parson | Versions, upstream references, and source-tree SHA-256 values in [`dependency-lock.json`](dependency-lock.json) |

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
file length, and file bytes for each entry.

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

## Release record

Release archives intentionally omit third-party source code. The packager
includes `dependency-lock.json` and writes its SHA-256 digest and path into
`release-manifest.txt`. The lock records the versions and immutable package
references for all build dependencies, plus hashes for the complete vendored
source paths. The digest makes that provenance available without distributing
the vendored sources. It records repository pins, not proof that a separately
built executable used them when `-SkipBuild` is used.
