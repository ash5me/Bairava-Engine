#!/usr/bin/env python3
"""Does routing the shipped UI font through HarfBuzz change any glyph?

For VT323 (Bairava's shipped UI font), shape every printable ASCII character alone and the real UI
strings used by the game and the debug overlay. A shaped result differs from the current prebaked
path when a glyph is substituted (GSUB) or a position is nonzero (GPOS). Any difference is a visible
change the migration must either accept on purpose or prevent.
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shape_reference import load_harfbuzz, shape_run
from fontTools.ttLib import TTFont

# Usage: python3 shipped_ui_shaping_check.py [path/to/bairava/assets/font.ttf]
ASSET = sys.argv[1] if len(sys.argv) > 1 else "../bairava/assets/font.ttf"  # VT323 Regular
lib = load_harfbuzz()
data = open(ASSET, "rb").read()
tt = TTFont(ASSET)
cmap = tt.getBestCmap()
hmtx = tt["hmtx"].metrics
order = tt.getGlyphOrder()

def cmap_gid(ch):
    return order.index(cmap[ord(ch)]) if ord(ch) in cmap else None

# Strings the game and debug overlay actually draw (from src/game/game.zig and the overlay code).
UI_STRINGS = [
    "Semkootru", "Click me", "Saves", "Controls", "Back", "Next", "Clear slot", "Volume",
    "Clicks: 12", "Level: 0.50", "Slot 1: F5/F9", "Controls 1/2", "fps 60", "F8 menu  I scale",
]

def check(text):
    shaped, upem = shape_run(lib, data, text, "Latn", "en")
    diffs = []
    for i, ch in enumerate(text):
        g = shaped[i] if i < len(shaped) else None
        if g is None:
            diffs.append(f"glyph count changed ({len(shaped)} vs {len(text)} chars)")
            break
        expect = cmap_gid(ch)
        if expect is not None and g["glyph_id"] != expect:
            diffs.append(f"{ch!r}: gid {g['glyph_id']} != cmap {expect}")
        if g["x_offset_px"] != 0 or g["y_offset_px"] != 0:
            diffs.append(f"{ch!r}: nonzero offset ({g['x_offset_px']}, {g['y_offset_px']})")
        if expect is not None:
            hadv = hmtx[order[expect]][0] * 48.0 / upem
            if abs(g["x_advance_px"] - hadv) > 1e-3:
                diffs.append(f"{ch!r}: advance {g['x_advance_px']} != hmtx {round(hadv,4)}")
    return diffs

ascii_bad = {}
for code in range(32, 127):
    ch = chr(code)
    d = check(ch)
    if d:
        ascii_bad[repr(ch)] = d
print("== single printable ASCII characters:", 95 - len(ascii_bad), "identical,", len(ascii_bad), "differ")
for k, v in ascii_bad.items():
    print("   ", k, v)

print("\n== shipped UI strings:")
ui_bad = 0
for s in UI_STRINGS:
    d = check(s)
    status = "identical" if not d else "DIFFERS"
    if d: ui_bad += 1
    print(f"   {s!r:<22} {status}" + (f"  {d[:2]}" if d else ""))
print(f"\n{ui_bad} of {len(UI_STRINGS)} UI strings change under shaping")
