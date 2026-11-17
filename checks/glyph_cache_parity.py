#!/usr/bin/env python3
"""Regenerates checks/glyph_cache_parity.txt by matching each Zig test name to a mirror check name.

Run from the repository root:  python3 checks/glyph_cache_parity.py
A Zig test counts as mirrored when a `begin("...")` block in checks/glyph_cache_mirror.c has the same name.
Names that differ only by spelling are listed in ALIAS. Zig tests that cannot be mirrored are listed in ZIG_ONLY
with the reason. Re-run this after changing either side, and commit the regenerated file with the change.
"""
import re
import sys

ZIG_FILES = {
    "src/engine/text/glyph_cache.zig": "glyph_cache.zig",
    "src/engine/text/glyph_cache_font_test.zig": "glyph_cache_font_test.zig",
    "src/engine/renderer/glyph_atlas.zig": "glyph_atlas.zig",
}
MIRROR = "checks/glyph_cache_mirror.c"
OUT = "checks/glyph_cache_parity.txt"

# Zig spells regionCoverage in camelCase; the mirror spells the same test "region coverage".
ALIAS = {
    "glyph rows are copied to the region the cache reports, and regionCoverage keeps the page stride":
        "glyph rows are copied to the region the cache reports, and region coverage keeps the page stride",
}
ZIG_ONLY = {
    "the first glyphs of the shipped font enter one cache page, and each region holds its rasterized coverage":
        "reads the shipped font through HarfBuzz and rasterizes it with stb; the mirror has no font",
    "a glyph the cache has not seen before is rasterized and stored on demand":
        "rasterizes the shipped font with stb; the mirror has no font",
    "the atlas and its flush compile against the backend":
        "a compile check of the Zig renderer; the mirror cannot compile Zig",
}


def main():
    zig = []
    for path, short in ZIG_FILES.items():
        with open(path, encoding="utf-8") as f:
            for name in re.findall(r'^test "(.*)" \{', f.read(), re.M):
                zig.append((short, name))
    with open(MIRROR, encoding="utf-8") as f:
        mirror_names = re.findall(r'begin\("(.*)"\);', f.read())
    mirror_set = set(mirror_names)

    rows = []
    for short, name in zig:
        mapped = ALIAS.get(name, name)
        if mapped in mirror_set:
            rows.append((short, name, True, mapped if mapped != name else None))
        else:
            rows.append((short, name, False, ZIG_ONLY.get(name, "not mapped")))

    zig_mapped = {ALIAS.get(n, n) for _, n in zig}
    mirror_only = [n for n in mirror_names if n not in zig_mapped]
    mirrored = sum(1 for r in rows if r[2])
    unmapped = [r for r in rows if not r[2] and r[3] == "not mapped"]

    out = [
        "Parity map: Zig tests to mirror checks (checks/glyph_cache_mirror.c)",
        "Regenerate with: python3 checks/glyph_cache_parity.py",
        "",
        "What parity means here. The mirror re-implements the cache, the resolver, and the fallback in C, and runs them",
        "against a synthetic glyph source (fake_metrics, fake_coverage). It checks the logic: keys, counters, allocation",
        "failures, the upload rectangle, and the fallback. It does NOT check values from a real font, the GPU, or the",
        "Zig compiler. A mirrored test passing shows the logic is the same as the Zig test's. The Zig test still has to",
        "pass in Zig before it counts.",
        "",
        "Zig tests: %d. Mirrored (logic checked in C): %d. Zig only: %d." % (len(rows), mirrored, len(rows) - mirrored),
        "Mirror blocks with no Zig test of the same name: %d." % len(mirror_only),
        "",
        "%-30s | %-6s | %s" % ("Zig file", "status", "Zig test"),
        "-" * 130,
    ]
    for short, name, ok, note in rows:
        out.append("%-30s | %-6s | %s" % (short, "mirror" if ok else "ZIG", name))
        if not ok:
            out.append("%-30s | %-6s |   reason: %s" % ("", "", note))
        elif note:
            out.append("%-30s | %-6s |   mirror check: %s" % ("", "", note))
    out += ["", "Mirror blocks with no Zig counterpart by name:"]
    out += ["  - " + n for n in mirror_only]
    with open(OUT, "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")
    print("zig tests %d, mirrored %d, zig only %d, unmapped %d" % (len(rows), mirrored, len(rows) - mirrored, len(unmapped)))
    return 1 if unmapped else 0


if __name__ == "__main__":
    sys.exit(main())
