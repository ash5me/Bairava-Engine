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
| Slang compiler | `SLANG_VERSION` in `.github/workflows/ci.yml` |
| cglm, FreeType, stb, log.c, Parson | Versions, upstream references, and source-tree SHA-256 values in [`dependency-lock.json`](dependency-lock.json) |

The lock file covers every file in the vendored dependency paths, not just
version headers. `scripts/check-vendor-pins.py` recomputes these hashes and CI
fails if the recorded source does not match. Release packaging runs the same
check before it builds or stages an artifact. To intentionally update a
vendored dependency, replace its complete source/license set, update its version
and upstream reference in the lock, regenerate its hash using the documented
algorithm in that script, then run the checker and full CI suite.

For Zig packages, update the reviewed URL/commit and content hash together in
`build.zig.zon` (for example with `zig fetch --save`), confirm the lockfile diff,
and build/test with the resulting Zig version. For Slang, update the single CI
version used by all operating systems and verify SPIR-V, DXIL, and Metal shader
compilation where supported. Do not update generated hashes or version records
without reviewing the corresponding upstream change and license.

Raise the minimum Zig version only when the code or build requires it. Update
`build.zig.zon`, verify the CI installer resolves that exact version, and run
the full platform matrix. Security fixes should be prioritized; otherwise
review pinned dependency updates at least quarterly. Keep the prior pin in the
change history for rollback.

## Release record

Release archives intentionally omit third-party source code. The packager
includes `dependency-lock.json` and writes its SHA-256 digest and path into
`release-manifest.txt`; this records the exact vendored source snapshot used by
the repository without distributing those sources in the game package. The
manifest is evidence of the repository pin, not a proof that a separately built
executable used that pin when `-SkipBuild` is used.
