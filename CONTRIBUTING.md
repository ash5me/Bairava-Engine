# Contributing

Thanks for helping improve Bairava Engine. The engine is experimental and its public API and asset formats may change; please review the relevant guide and compatibility policy before proposing changes.

## Development setup

Work from the repository root and use the Zig version in `build.zig.zon` (`0.16.0-dev.3142+5ccfeb926` at the time of writing). Install Slang's `slangc` compiler and put it on `PATH`. The first build may need internet access to fetch the pinned Zig dependencies.

```sh
zig build
```

See the root [README](README.md) for platform-specific options and run targets.

## Making a change

1. Check the existing implementation, tests, and guide for the area you are changing.
2. Keep changes focused. Follow local naming, formatting, ownership, error-handling, and API patterns.
3. Add or update tests for behavior changes and update the relevant documentation for user-visible or public API changes.
4. Do not edit generated output under `zig-out/`. Update its source inputs and regenerate it with the documented build command.
5. Keep dependencies pinned. For dependency changes, follow [the dependency policy](docs/dependency-policy.md) and update the lock records and verification accordingly.

For Zig formatting, run `zig fmt` on the Zig files you changed:

```sh
zig fmt src/path/to/changed_file.zig sample/path/to/changed_file.zig
```

Do not run it over the whole repository unless the change intentionally reformats all affected files.

## Validation

Run the narrowest relevant checks while iterating. Before submitting a code change, run the checks that apply to it; the following cover the core build, tests, assets, dependency pins, and platform boundaries:

```sh
zig build
zig build test
zig build test-ui
zig build check-assets
python scripts/check-dependency-pins.py
python scripts/boundary_scan.py --self-test
python scripts/boundary_scan.py --fail
```

For documentation changes, generate and validate the documentation when applicable:

```sh
zig build docs
```

The CI workflow also builds debug and release profiles and checks supported platform shader targets. State which relevant commands passed and call out anything not run in your pull request description.

## Pull requests

- Explain the problem and the intended behavior change.
- Include focused tests or reproduction steps for fixes and features.
- Note API, asset-format, dependency, and migration implications.
- Include screenshots or other visual evidence when changing rendering or UI behavior.
- Keep generated files, build output, and unrelated cleanup out of the change.

When changing the public `bairava` API, update its manifest/reference, document ownership and error contracts, and add or update API tests and compile-checked examples as appropriate.
