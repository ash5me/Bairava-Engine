#!/usr/bin/env python3
"""Reference shaping snapshot for the Phase 0 test corpus.

Calls the HarfBuzz C API through ctypes, so no Python binding or build is needed. This records what
HarfBuzz returns for each corpus string: glyph IDs, clusters, advances, and offsets in pixels.

It is an oracle for comparing later output, not a pinned result. The library here is the system
libharfbuzz (see the version printed below). The PoC snapshot is HarfBuzz 15.1.0, and Phase 1 pins a
specific revision, so this snapshot must be regenerated with the pinned version before it is used as
an acceptance baseline. Script and language are set explicitly, not guessed, as the plan requires.

Usage: python3 shape_reference.py [--out snapshot.json]
"""
import argparse
import ctypes
import ctypes.util
import json
import os
import sys

PIXEL_HEIGHT = 48.0  # the PoC shapes Tamil at 48 px per em

HB_MEMORY_MODE_READONLY = 1
HB_DIRECTION_LTR = 4


class GlyphInfo(ctypes.Structure):
    _fields_ = [("codepoint", ctypes.c_uint32), ("mask", ctypes.c_uint32),
                ("cluster", ctypes.c_uint32), ("var1", ctypes.c_uint32), ("var2", ctypes.c_uint32)]


class GlyphPosition(ctypes.Structure):
    _fields_ = [("x_advance", ctypes.c_int32), ("y_advance", ctypes.c_int32),
                ("x_offset", ctypes.c_int32), ("y_offset", ctypes.c_int32), ("var", ctypes.c_uint32)]


def load_harfbuzz():
    path = ctypes.util.find_library("harfbuzz") or "libharfbuzz.so.0"
    lib = ctypes.CDLL(path)
    P = ctypes.c_void_p
    sigs = {
        "hb_version_string": (ctypes.c_char_p, []),
        "hb_blob_create": (P, [ctypes.c_char_p, ctypes.c_uint, ctypes.c_int, P, P]),
        "hb_blob_destroy": (None, [P]),
        "hb_face_create": (P, [P, ctypes.c_uint]),
        "hb_face_destroy": (None, [P]),
        "hb_face_get_upem": (ctypes.c_uint, [P]),
        "hb_font_create": (P, [P]),
        "hb_font_destroy": (None, [P]),
        "hb_font_set_scale": (None, [P, ctypes.c_int, ctypes.c_int]),
        "hb_buffer_create": (P, []),
        "hb_buffer_destroy": (None, [P]),
        "hb_buffer_add_utf8": (None, [P, ctypes.c_char_p, ctypes.c_int, ctypes.c_uint, ctypes.c_int]),
        "hb_buffer_set_direction": (None, [P, ctypes.c_int]),
        "hb_buffer_set_script": (None, [P, ctypes.c_int]),
        "hb_buffer_set_language": (None, [P, P]),
        "hb_buffer_guess_segment_properties": (None, [P]),
        "hb_script_from_string": (ctypes.c_int, [ctypes.c_char_p, ctypes.c_int]),
        "hb_language_from_string": (P, [ctypes.c_char_p, ctypes.c_int]),
        "hb_shape": (None, [P, P, P, ctypes.c_uint]),
        "hb_buffer_get_length": (ctypes.c_uint, [P]),
        "hb_buffer_get_glyph_infos": (ctypes.POINTER(GlyphInfo), [P, ctypes.POINTER(ctypes.c_uint)]),
        "hb_buffer_get_glyph_positions": (ctypes.POINTER(GlyphPosition), [P, ctypes.POINTER(ctypes.c_uint)]),
    }
    for name, (restype, argtypes) in sigs.items():
        fn = getattr(lib, name)
        fn.restype = restype
        fn.argtypes = argtypes
    return lib


def shape_run(lib, font_bytes, text, script_tag, lang_tag):
    data = ctypes.create_string_buffer(font_bytes, len(font_bytes))
    blob = lib.hb_blob_create(data, len(font_bytes), HB_MEMORY_MODE_READONLY, None, None)
    face = lib.hb_face_create(blob, 0)
    upem = lib.hb_face_get_upem(face)
    # Keep HarfBuzz at its default scale (font units). Scaling inside HarfBuzz rounds positions to whole
    # pixels, so the conversion to pixels happens here in floating point, as the PoC does.
    font = lib.hb_font_create(face)
    buf = lib.hb_buffer_create()
    raw = text.encode("utf-8")
    lib.hb_buffer_add_utf8(buf, raw, len(raw), 0, len(raw))
    lib.hb_buffer_set_direction(buf, HB_DIRECTION_LTR)
    if script_tag:
        lib.hb_buffer_set_script(buf, lib.hb_script_from_string(script_tag.encode(), -1))
    if lang_tag:
        lib.hb_buffer_set_language(buf, lib.hb_language_from_string(lang_tag.encode(), -1))
    lib.hb_shape(font, buf, None, 0)
    n = lib.hb_buffer_get_length(buf)
    cnt = ctypes.c_uint(0)
    infos = lib.hb_buffer_get_glyph_infos(buf, ctypes.byref(cnt))
    poss = lib.hb_buffer_get_glyph_positions(buf, ctypes.byref(cnt))
    out = []
    px = PIXEL_HEIGHT / upem
    for i in range(n):
        out.append({
            "glyph_id": infos[i].codepoint,
            "cluster": infos[i].cluster,
            "x_advance_units": poss[i].x_advance,
            "x_advance_px": round(poss[i].x_advance * px, 4),
            "x_offset_px": round(poss[i].x_offset * px, 4),
            "y_offset_px": round(poss[i].y_offset * px, 4),
        })
    lib.hb_buffer_destroy(buf)
    lib.hb_font_destroy(font)
    lib.hb_face_destroy(face)
    lib.hb_blob_destroy(blob)
    return out, upem


CORPUS = {
    "tamil": {
        "font": "tamil.ttf",
        "script": "Taml",
        "language": "ta",
        "cases": [
            ("tamil_pulli_word", "தமிழ்"),
            ("tamil_ksha_conjunct", "க்ஷ"),
            ("tamil_vowel_sign_o", "கொ"),
            ("tamil_naan", "நான்"),
            ("tamil_sri", "ஸ்ரீ"),
            ("tamil_jnya", "ஜ்ஞ"),
            ("poc_mixed_line", "தமிழ் Tamil"),
            ("tamil_independent_vowels", "ஆ ஔ"),
        ],
    },
    "latin": {
        "font": "font.ttf",
        "script": "Latn",
        "language": "en",
        "cases": [
            ("latin_kern_av", "AV"),
            ("latin_kern_to", "To"),
            ("latin_fi_ligature", "fi"),
            ("latin_poc_hello", "Hello, Zig!"),
        ],
    },
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--assets", default="../tools/assets", help="folder with the PoC tamil.ttf and font.ttf")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    lib = load_harfbuzz()
    result = {
        "harfbuzz_runtime_version": lib.hb_version_string().decode(),
        "pixel_height": PIXEL_HEIGHT,
        "note": "Reference oracle from the system libharfbuzz. Regenerate with the pinned Phase 1 version before use.",
        "fonts": {},
    }
    for family, spec in CORPUS.items():
        with open(os.path.join(args.assets, spec["font"]), "rb") as fh:
            font_bytes = fh.read()
        entries = []
        for case_id, text in spec["cases"]:
            glyphs, upem = shape_run(lib, font_bytes, text, spec["script"], spec["language"])
            entries.append({"id": case_id, "text": text, "glyphs": glyphs})
        result["fonts"][family] = {"file": spec["font"], "script": spec["script"],
                                   "language": spec["language"], "units_per_em": upem,
                                   "cases": entries}

    text_out = json.dumps(result, ensure_ascii=False, indent=2)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text_out + "\n")
    print(text_out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
