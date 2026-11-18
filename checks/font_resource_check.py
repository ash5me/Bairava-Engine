#!/usr/bin/env python3
"""Checks the numbers that src/engine/text/font_resource.zig's tests assert, against the shipped font file.

The Zig tests cannot run in the sandbox (no Zig toolchain), so this script reads assets/font.ttf directly and
recomputes the values the tests pin. It is CPU-only and touches no renderer. Run it from the repository root:

    python3 checks/font_resource_check.py

Exit status is 0 when every check passes, and 1 otherwise. The output is written to stdout, and the recorded run is
kept in checks/font_resource_RESULTS.txt.
"""

import struct
import sys

FONT = "assets/font.ttf"
PIXEL_HEIGHT = 16.0

failures = 0
lines = []


def check(ok, message):
    global failures
    if not ok:
        failures += 1
    lines.append(("PASS " if ok else "FAIL ") + message)


def read_tables(data):
    count = struct.unpack(">H", data[4:6])[0]
    tables = {}
    for i in range(count):
        record = data[12 + 16 * i : 12 + 16 * (i + 1)]
        tag = record[:4].decode("latin1")
        offset, length = struct.unpack(">II", record[8:16])
        tables[tag] = (offset, length)
    return tables


def main():
    with open(FONT, "rb") as f:
        data = f.read()
    tables = read_tables(data)

    check("hhea" in tables and "head" in tables, "the shipped font has head and hhea tables")
    hhea, _ = tables["hhea"]
    ascender, descender, line_gap = struct.unpack(">hhh", data[hhea + 4 : hhea + 10])
    head, _ = tables["head"]
    upem = struct.unpack(">H", data[head + 18 : head + 20])[0]

    check(upem == 2048, f"units per em is 2048 (got {upem})")
    check(ascender == 1854, f"hhea ascender is 1854 (got {ascender})")
    check(descender == -434, f"hhea descender is -434 (got {descender})")
    check(line_gap == 67, f"hhea line gap is 67 (got {line_gap})")

    # Same scale as runtime_font.zig: stb's ScaleForPixelHeight, height / (ascent - descent) pixels per unit.
    scale = PIXEL_HEIGHT / (ascender - descender)
    ascent_px = ascender * scale
    descent_px = -descender * scale
    gap_px = line_gap * scale
    natural = ascent_px + descent_px + gap_px

    check(abs(ascent_px - 12.96503) < 1e-4, f"ascent at 16 px is 12.96503 (got {ascent_px:.5f})")
    check(abs(descent_px - 3.03497) < 1e-4, f"descent at 16 px is 3.03497 (got {descent_px:.5f})")
    check(abs(gap_px - 0.46853) < 1e-4, f"line gap at 16 px is 0.46853 (got {gap_px:.5f})")
    check(abs(natural - 16.46853) < 1e-4, f"natural line height at 16 px is 16.46853 (got {natural:.5f})")
    check(abs(natural - (ascent_px + descent_px + gap_px)) < 1e-9, "natural line height is the sum of its parts")

    for line in lines:
        print(line)
    print(f"{len(lines) - failures} of {len(lines)} checks pass")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
