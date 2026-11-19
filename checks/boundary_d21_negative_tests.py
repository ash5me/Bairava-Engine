#!/usr/bin/env python3
"""End-to-end checks for the D-21 section of scripts/boundary_scan.py.

Each case copies the repository to a scratch directory, makes one edit, and runs
`boundary_scan.py --fail`. Cases that add a real exposure or a HarfBuzz name must fail;
cases that add an allowed shape must pass. Run from the repository root:

    python3 checks/boundary_d21_negative_tests.py
"""
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def edit(d, rel, old, new):
    p = d / rel
    s = p.read_text(encoding="utf-8")
    if s.count(old) != 1:
        raise SystemExit(f"edit anchor not unique in {rel}: {s.count(old)}")
    p.write_text(s.replace(old, new), encoding="utf-8")


def run(d):
    r = subprocess.run([sys.executable, "scripts/boundary_scan.py", "--fail"], cwd=d,
                       capture_output=True, text=True)
    section = r.stdout[r.stdout.find("PUBLIC SURFACE"):]
    summary = [ln for ln in section.splitlines() if re.match(r"(NEW EXPOSURES|STALE DEBT|HARFBUZZ NAMES)", ln)]
    return r.returncode, summary


CASES = [
    ("N1 new pub fn exposing the registry in a debt-listed file", 1,
     ("src/engine/ui/ui.zig", 'pub const Font = @import("../text/font.zig").Font;',
      'pub const Font = @import("../text/font.zig").Font;\npub fn leak(fonts: *font_resource.Resources) void {\n    _ = fonts;\n}')),
    ("N2 HarfBuzz name in a reachable file outside the text package", 1,
     ("src/engine/core/context.zig", 'const font_registry = @import("../text/font_registry.zig");',
      'const font_registry = @import("../text/font_registry.zig");\nconst hb_probe = hb_buffer_create;')),
    ("N3 debt entry whose line was removed (stale)", 1,
     ("src/engine/ui/ui.zig", "pub const Fonts = font_resource.Resources;\n", "")),
    ("N4 private struct holding the registry (allowed)", 0,
     ("src/engine/ui/ui.zig", 'pub const Font = @import("../text/font.zig").Font;',
      'pub const Font = @import("../text/font.zig").Font;\nconst Scratch = struct {\n    fonts: *font_resource.Resources,\n};')),
    ("N5 texture staging type, not a font type (allowed)", 0,
     ("src/engine/ui/ui.zig", 'pub const Font = @import("../text/font.zig").Font;',
      'pub const Font = @import("../text/font.zig").Font;\npub fn textureStaging(s: *const staging.Staged) void {\n    _ = s;\n}')),
    ("N6 public function that takes only FontHandle (allowed)", 0,
     ("src/engine/ui/ui.zig", 'pub const Font = @import("../text/font.zig").Font;',
      'pub const Font = @import("../text/font.zig").Font;\npub fn handleOnly(font: FontHandle) FontHandle {\n    return font;\n}')),
    ("N7 public root re-exports the registry", 1,
     ("src/engine/bairava.zig", "pub const Context = engine.Context;",
      'pub const Context = engine.Context;\npub const Resources = @import("engine/text/font_resource.zig").Resources;')),
]


def main():
    failures = 0
    for name, want_fail, (rel, old, new) in CASES:
        d = Path(tempfile.mkdtemp(prefix="d21_"))
        try:
            shutil.copytree(ROOT, d, dirs_exist_ok=True)
            edit(d, rel, old, new)
            code, summary = run(d)
        finally:
            shutil.rmtree(d, ignore_errors=True)
        ok = (code != 0) == bool(want_fail)
        failures += 0 if ok else 1
        print(("PASS " if ok else "FAIL ") + f"{name}: exit {code}; " + "; ".join(summary))
    print(f"{len(CASES) - failures}/{len(CASES)} cases as expected")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
