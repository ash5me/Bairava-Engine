#!/usr/bin/env python3
"""Upper-bound atlas size for a font's whole inked glyph set at a given pixel size.

Uses glyf bounds, adds 2 px padding per cell, and adds 15% for packing loss. The runtime cache holds
only the glyphs that are requested, so real usage is at or below these figures.
Usage: python3 atlas_estimate.py font.ttf [pixel_height]
"""
import math, sys
from fontTools.ttLib import TTFont

def estimate(path, px=48.0, pad=2, pack_loss=0.15):
    f = TTFont(path)
    upem = f["head"].unitsPerEm
    s = px / upem
    glyf = f["glyf"]
    n, area, biggest = 0, 0, (0, 0)
    for name in f.getGlyphOrder():
        g = glyf[name]
        if g.numberOfContours == 0:
            continue
        w = math.ceil((g.xMax - g.xMin) * s) + pad
        h = math.ceil((g.yMax - g.yMin) * s) + pad
        area += w * h
        n += 1
        biggest = max(biggest, (w, h), key=lambda t: t[0] * t[1])
    total = area * (1 + pack_loss)
    return {"upem": upem, "pixel_height": px, "inked_glyphs": n, "texels": area,
            "with_pack_loss": int(total), "pages_1024": math.ceil(total / (1024 * 1024)),
            "largest_cell": biggest}

if __name__ == "__main__":
    px = float(sys.argv[2]) if len(sys.argv) > 2 else 48.0
    print(sys.argv[1], estimate(sys.argv[1], px))
