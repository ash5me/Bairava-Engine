#!/usr/bin/env python3
"""Generate the D-09 bitmap font asset: font8x8_basic, printable ASCII U+0020-U+007E.

Source: dhepper/font8x8, commit 4876b70490600222f30bb9acd2c02868e390bb56, file font8x8_basic.h.
Public domain (README and header). The generator refuses any source file whose SHA-256 differs
from the value below, so the asset can only come from the pinned commit.

Output (grayscale coverage, D-09 spec):
  font8x8_basic.png   8-bit single-channel grayscale, 128x48. 0 = no ink, 255 = full ink.
                      Glyph pixels are binary. Alpha is not used.
  font8x8_basic.fnt   AngelCode BMFont text descriptor. Glyph data is in the red channel (chnl=4).
  font8x8_basic.NOTICE.txt   Source, commit, hash, and license notice.

Usage: python3 gen_font8x8_asset.py <path/to/font8x8_basic.h> <output-dir>
"""
import hashlib
import os
import re
import sys

from PIL import Image

COMMIT = "4876b70490600222f30bb9acd2c02868e390bb56"
SOURCE_SHA256 = "49d8df366296b203ca3211bc0672cf2a762135bf12710735b6292756b19dffd5"
FIRST, LAST = 0x20, 0x7E          # printable ASCII
COLS, ROWS, CELL = 16, 6, 8       # 16 x 6 grid of 8 x 8 cells
W, H = COLS * CELL, ROWS * CELL   # 128 x 48
FACE = "font8x8_basic"
PAGE_FILE = "font8x8_basic.png"
FALLBACK = ord("?")
LINE_HEIGHT, BASE = 8, 7
ADVANCE = 8
CHNL_RED = 4                      # BMFont channel bit for red


def read_table(path):
    with open(path, "rb") as fh:
        raw = fh.read()
    digest = hashlib.sha256(raw).hexdigest()
    if digest != SOURCE_SHA256:
        sys.exit(f"source hash mismatch: {digest} != {SOURCE_SHA256}; refusing to generate")
    text = raw.decode("ascii")
    start = text.index("font8x8_basic[128][8]")
    body = text[text.index("{", start) + 1: text.index("};", start)]
    rows = re.findall(r"\{\s*((?:0x[0-9A-Fa-f]{2}\s*,?\s*){8})\}", body)
    if len(rows) != 128:
        sys.exit(f"expected 128 glyph rows, parsed {len(rows)}")
    return [[int(v, 16) for v in re.findall(r"0x[0-9A-Fa-f]{2}", r)] for r in rows], digest


def cell_origin(cp):
    index = cp - FIRST
    return (index % COLS) * CELL, (index // COLS) * CELL


def build_atlas(glyphs):
    pixels = bytearray(W * H)  # all 0 = no ink, including the unused 96th cell
    for cp in range(FIRST, LAST + 1):
        x0, y0 = cell_origin(cp)
        for row, byte in enumerate(glyphs[cp]):
            for col in range(8):
                if byte >> col & 1:          # LSB is the leftmost pixel (font8x8 encoding)
                    pixels[(y0 + row) * W + x0 + col] = 255
    return Image.frombytes("L", (W, H), bytes(pixels))


def verify_png(path, glyphs):
    img = Image.open(path)
    assert img.mode == "L", f"mode {img.mode}, expected L (8-bit grayscale)"
    assert img.size == (W, H), f"size {img.size}"
    data = img.tobytes()
    assert set(data) <= {0, 255}, "non-binary value in a binary glyph atlas"
    for cp in range(FIRST, LAST + 1):
        x0, y0 = cell_origin(cp)
        for row in range(8):
            for col in range(8):
                want = 255 if glyphs[cp][row] >> col & 1 else 0
                got = data[(y0 + row) * W + x0 + col]
                assert got == want, f"U+{cp:04X} row {row} col {col}: {got} != {want}"
    # Cells past the last printable glyph (index 95 onward) must be empty.
    for index in range(LAST - FIRST + 1, COLS * ROWS):
        x0, y0 = (index % COLS) * CELL, (index // COLS) * CELL
        for row in range(8):
            assert not any(data[(y0 + row) * W + x0: (y0 + row) * W + x0 + 8]), f"unused cell {index} has ink"
    return len(data)


def descriptor():
    lines = [
        f'info face="{FACE}" size=8 bold=0 italic=0 charset="" unicode=1 stretchH=100 smooth=0 aa=1 '
        "padding=0,0,0,0 spacing=0,0 outline=0",
        # Glyph data in red only: redChnl=0 (glyph), others 4 (one), alpha not used.
        f"common lineHeight={LINE_HEIGHT} base={BASE} scaleW={W} scaleH={H} pages=1 packed=0 "
        "alphaChnl=4 redChnl=0 greenChnl=4 blueChnl=4",
        f'page id=0 file="{PAGE_FILE}"',
        f"chars count={LAST - FIRST + 1}",
    ]
    for cp in range(FIRST, LAST + 1):
        if cp == 0x20:
            # A space has no ink. It keeps its advance, with a zero-size rectangle.
            lines.append(f"char id=32 x=0 y=0 width=0 height=0 xoffset=0 yoffset=0 "
                         f"xadvance={ADVANCE} page=0 chnl={CHNL_RED}")
        else:
            x0, y0 = cell_origin(cp)
            lines.append(f"char id={cp} x={x0} y={y0} width=8 height=8 xoffset=0 yoffset=0 "
                         f"xadvance={ADVANCE} page=0 chnl={CHNL_RED}")
    return "\n".join(lines) + "\n"


def notice(digest):
    return f"""font8x8_basic bitmap font (Bairava D-09)

Source repository:  https://github.com/dhepper/font8x8
Pinned commit:      {COMMIT}
Source file:        font8x8_basic.h (glyph table, U+0000-U+007F; U+0020-U+007E used)
Source SHA-256:     {digest}

License: Public Domain. The upstream README states "License: Public Domain", and each header
states "License: Public Domain". The upstream commit has no separate LICENSE file.

Original credit: the glyph data is derived from IBM VGA fonts by Marcel Sondaar (public domain),
as cited in the upstream header. Author of the header files: Daniel Hepper.

Generated by gen_font8x8_asset.py from the source file above. Do not edit the PNG or FNT by hand.
"""


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    source, out_dir = sys.argv[1], sys.argv[2]
    glyphs, digest = read_table(source)
    os.makedirs(out_dir, exist_ok=True)
    png_path = os.path.join(out_dir, PAGE_FILE)
    build_atlas(glyphs).save(png_path, format="PNG")
    checked = verify_png(png_path, glyphs)
    with open(os.path.join(out_dir, "font8x8_basic.fnt"), "w", encoding="ascii", newline="\n") as fh:
        fh.write(descriptor())
    with open(os.path.join(out_dir, "font8x8_basic.NOTICE.txt"), "w", encoding="ascii", newline="\n") as fh:
        fh.write(notice(digest))
    print(f"wrote {PAGE_FILE} ({W}x{H}, L, {checked} pixels verified against the source table)")
    print("wrote font8x8_basic.fnt and font8x8_basic.NOTICE.txt")


if __name__ == "__main__":
    main()
