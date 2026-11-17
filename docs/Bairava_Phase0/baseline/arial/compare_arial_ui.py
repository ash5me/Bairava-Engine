#!/usr/bin/env python3
"""Phase 0 baseline for the shipped Arial UI font: the current prebaked widths (text.c, measured with
measure.c) against HarfBuzz 15.1.0 shaping of the same font. Sections:
  1. Kerning sources over printable ASCII pairs (GPOS kern path versus the classic kern table).
  2. Baked path versus HarfBuzz at the shipped sizes, 9 px mono and 10 px gray.
  3. The gray bake's pixel-height convention: HarfBuzz at px * upem / (ascent - descent).

Usage (from this folder; HarfBuzz 15.1.0 built as libharfbuzz.so.0 on the loader path):
  LD_LIBRARY_PATH=<dir> python3 compare_arial_ui.py ../../../../assets/font.ttf m9.txt m10.txt
"""
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "shaping"))
import shape_reference as sr
from fontTools.ttLib import TTFont

font_path, m9_path, m10_path = sys.argv[1:4]
lib = sr.load_harfbuzz()
data = open(font_path, "rb").read()
tt = TTFont(font_path)
upem = tt["head"].unitsPerEm
hhea = tt["hhea"]
hmtx = tt["hmtx"].metrics
cmap = tt.getBestCmap()
order = tt.getGlyphOrder()
ascii_cps = [c for c in range(32, 127) if c in cmap]

def glyph_units(cp):
    return hmtx[cmap[cp]][0]

def shape(text, px):
    sr.PIXEL_HEIGHT = float(px)
    shaped, _ = sr.shape_run(lib, data, text, "Latn", "en")
    return shaped

def hb_width(text, px):
    return sum(g["x_advance_px"] for g in shape(text, px))

def parse_measure(path):
    widths, adv, kern = {}, {}, {}
    for line in open(path, encoding="utf-8"):
        p = line.rstrip("\n").split("\t")
        if p[0] == "WIDTH":
            widths[p[1]] = float(p[2])
        elif p[0] == "ADV":
            adv[int(p[1])] = float(p[2])
        elif p[0] == "KERN":
            kern[(int(p[1]), int(p[2]))] = float(p[3])
    return widths, adv, kern

# 1. Kerning sources.
hb_kern = {}
subs = []
for a in ascii_cps:
    for b in ascii_cps:
        sr.PIXEL_HEIGHT = float(upem)
        shaped, _ = sr.shape_run(lib, data, chr(a) + chr(b), "Latn", "en")
        if len(shaped) != 2:
            subs.append(chr(a) + chr(b))
            continue
        k = shaped[0]["x_advance_units"] - glyph_units(a)
        if k != 0:
            hb_kern[(a, b)] = k
name_to_cp = {}
for cp in ascii_cps:
    name_to_cp.setdefault(cmap[cp], cp)
classic = {}
for (ln, rn), v in tt["kern"].kernTables[0].kernTable.items():
    if ln in name_to_cp and rn in name_to_cp and v != 0:
        classic[(name_to_cp[ln], name_to_cp[rn])] = v
both = set(hb_kern) & set(classic)
print("== 1. kerning sources over printable ASCII pairs (font units)")
print(f"   HarfBuzz (GPOS kern path): {len(hb_kern)} pairs")
print(f"   classic kern table:        {len(classic)} pairs")
print(f"   in both: {len(both)}; only HarfBuzz: {len(set(hb_kern) - set(classic))}; only classic: {len(set(classic) - set(hb_kern))}")
print(f"   in both with different values: {sum(1 for k in both if hb_kern[k] != classic[k])}")
print(f"   substituted pairs (ligatures; not measured as kerning): {len(subs)} {subs[:8]}")

# 2. Baked path versus HarfBuzz at the shipped sizes.
def report(px, path):
    widths, adv, baked_kern = parse_measure(path)
    diffs = [abs(adv[cp] - glyph_units(cp) * px / upem) for cp in range(32, 127) if cp in adv and cp in cmap]
    print(f"\n== 2. {px} px: baked path (text.c) versus HarfBuzz")
    print(f"   baked glyph advances differing from unhinted by more than 0.5 px: "
          f"{sum(1 for d in diffs if d > 0.5)} of {len(diffs)}; max {max(diffs):.3f} px")
    print(f"   baked kerning pairs (printable ASCII): {len(baked_kern)}")
    print(f"   {'UI string':<18}{'baked':>9}{'HB kerned':>11}{'HB no-kern':>12}{'baked-HB':>10}")
    changed = 0
    for text in widths:
        hbw = hb_width(text, px)
        nokern = sum(glyph_units(ord(c)) * px / upem for c in text)
        d = widths[text] - hbw
        changed += abs(d) > 0.5
        print(f"   {text:<18}{widths[text]:>9.2f}{hbw:>11.2f}{nokern:>12.2f}{d:>10.2f}")
    print(f"   strings differing from HarfBuzz by more than 0.5 px: {changed} of {len(widths)}")

report(9, m9_path)
report(10, m10_path)

# 3. The gray bake's pixel-height convention (stb ScaleForPixelHeight: px / (ascent - descent)).
eff = 10 * upem / (hhea.ascent - hhea.descent)
widths10, _, _ = parse_measure(m10_path)
worst = max(abs(widths10[t] - hb_width(t, eff)) for t in widths10)
print(f"\n== 3. gray bake convention: effective em for a 10 px font = {eff:.4f} px "
      f"(upem {upem}, ascent-descent {hhea.ascent - hhea.descent})")
print(f"   max |baked - HarfBuzz at that em| over the UI strings: {worst:.4f} px")
