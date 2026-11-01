# Build profiles

Use `-Dprofile=<name>` to select a named preset. `development` is the default.
The profile sets the default optimization mode and the defaults for development
tools and GPU validation; explicit options can override those defaults.

| Profile | Optimization | Development tools | GPU validation | Intended use |
|---|---|---|---|---|
| `development` | `Debug` | On | Off | Normal local work: overlay, diagnostics, console, and hot reload |
| `debug` | `Debug` | Off | On | Minimal runtime with Debug checks and SDL GPU validation |
| `release` | `ReleaseFast` | Off | Off | Packaged player builds |

Assertions and the default log threshold follow Zig's optimization mode, not the
profile name. `Debug` and `ReleaseSafe` check assertions and default to debug
logs; `ReleaseFast` and `ReleaseSmall` compile assertions out and default to
info logs. The settings file can still override the runtime log threshold.

## Examples

```powershell
zig build run
zig build run -Dprofile=debug
zig build -Dprofile=release
zig build -Dprofile=release -Doptimize=ReleaseSafe
zig build run -Dprofile=development -Ddev-tools=false -Dgpu-debug=true
zig build run -Dprofile=development -Dtracy=true
zig build run -Dprofile=release -Ddxil=true
zig build run -Dprofile=release -Dmetal=true
powershell -ExecutionPolicy Bypass -File .\scripts\package-release.ps1
```

`-Doptimize`, `-Ddev-tools`, and `-Dgpu-debug` override the corresponding
profile defaults. Bare `--release` selects `ReleaseFast`; an explicit
`-Doptimize` takes precedence. Tracy, DXIL, and Metal remain opt-in, orthogonal
build features. `-Ddxil=true` and `-Dmetal=true` embed additional shader
targets; they do not force the runtime to select that backend.

The release script builds with the `release` profile unless `-Profile` selects
another preset. With `-SkipBuild`, the script packages existing files and
records the selected profile as supplied by the caller; it cannot verify how
those files were compiled.
