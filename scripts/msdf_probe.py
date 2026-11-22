#!/usr/bin/env python3
"""Export an MFNT glyph crop, RGB channels, and render metadata from a TB-03 probe report."""

import argparse
import json
import math
import struct
import zlib
from pathlib import Path


def png_chunk(kind, payload):
    return (
        struct.pack(">I", len(payload))
        + kind
        + payload
        + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
    )


def write_png(path, width, height, pixels, channels):
    color_type = {1: 0, 3: 2}[channels]
    stride = width * channels
    raw = b"".join(b"\0" + pixels[row * stride : (row + 1) * stride] for row in range(height))
    data = b"\x89PNG\r\n\x1a\n"
    data += png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0))
    data += png_chunk(b"IDAT", zlib.compress(raw))
    data += png_chunk(b"IEND", b"")
    path.write_bytes(data)


def table_bounds(data, offset, size):
    if offset < 0 or size < 0 or offset + size > len(data):
        raise ValueError("font table points outside the embedded font data")


def glyph_for_codepoint(font, codepoint):
    table_bounds(font, 0, 12)
    table_count = struct.unpack_from(">H", font, 4)[0]
    tables = {}
    for index in range(table_count):
        record = 12 + index * 16
        table_bounds(font, record, 16)
        tag = font[record : record + 4]
        offset, length = struct.unpack_from(">II", font, record + 8)
        table_bounds(font, offset, length)
        tables[tag] = (offset, length)
    if b"cmap" not in tables:
        raise ValueError("embedded font has no cmap table")

    cmap_offset, cmap_length = tables[b"cmap"]
    table_bounds(font, cmap_offset, 4)
    subtable_count = struct.unpack_from(">H", font, cmap_offset + 2)[0]
    candidates = []
    for index in range(subtable_count):
        record = cmap_offset + 4 + index * 8
        table_bounds(font, record, 8)
        platform, encoding = struct.unpack_from(">HH", font, record)
        subtable = cmap_offset + struct.unpack_from(">I", font, record + 4)[0]
        table_bounds(font, subtable, 2)
        fmt = struct.unpack_from(">H", font, subtable)[0]
        score = (100 if platform == 3 else 0) + (10 if encoding == 10 else 0)
        if fmt == 12:
            candidates.append((score + 2, subtable, 12))
        elif fmt == 4 and codepoint <= 0xFFFF:
            candidates.append((score + 1, subtable, 4))

    for _, offset, fmt in sorted(candidates, reverse=True):
        if fmt == 12:
            table_bounds(font, offset, 16)
            length = struct.unpack_from(">I", font, offset + 4)[0]
            table_bounds(font, offset, length)
            groups = struct.unpack_from(">I", font, offset + 12)[0]
            lo, hi = 0, groups
            while lo < hi:
                mid = (lo + hi) // 2
                start, end, first = struct.unpack_from(">III", font, offset + 16 + mid * 12)
                if codepoint < start:
                    hi = mid
                elif codepoint > end:
                    lo = mid + 1
                else:
                    return first + codepoint - start
        else:
            length = struct.unpack_from(">H", font, offset + 2)[0]
            table_bounds(font, offset, length)
            segments = struct.unpack_from(">H", font, offset + 6)[0] // 2
            end_codes = offset + 14
            start_codes = end_codes + segments * 2 + 2
            deltas = start_codes + segments * 2
            range_offsets = deltas + segments * 2
            for index in range(segments):
                end = struct.unpack_from(">H", font, end_codes + index * 2)[0]
                start = struct.unpack_from(">H", font, start_codes + index * 2)[0]
                if start <= codepoint <= end:
                    delta = struct.unpack_from(">h", font, deltas + index * 2)[0]
                    range_offset = struct.unpack_from(">H", font, range_offsets + index * 2)[0]
                    if range_offset == 0:
                        return (codepoint + delta) & 0xFFFF
                    glyph_offset = range_offsets + index * 2 + range_offset + 2 * (codepoint - start)
                    table_bounds(font, glyph_offset, 2)
                    glyph = struct.unpack_from(">H", font, glyph_offset)[0]
                    return 0 if glyph == 0 else (glyph + delta) & 0xFFFF
    raise ValueError(f"embedded font has no cmap entry for U+{codepoint:04X}")


def read_mfnt(path, expected_height):
    data = path.read_bytes()
    if len(data) < 64 or data[:4] != b"MFNT":
        raise ValueError(f"{path} is not an MFNT file")
    version, header_size = struct.unpack_from("<HH", data, 4)
    height, px_range = struct.unpack_from("<ff", data, 8)
    glyph_count = struct.unpack_from("<I", data, 16)[0]
    atlas_width, atlas_height = struct.unpack_from("<II", data, 36)
    source_length, coverage_length, rgba_length, records_length = struct.unpack_from("<IIII", data, 44)
    if version != 1 or header_size != 64:
        raise ValueError(f"{path} has an unsupported MFNT version/header")
    if not math.isclose(height, expected_height, abs_tol=0.01):
        raise ValueError(f"{path} is baked at {height}px, expected {expected_height}px")
    if not atlas_width or not atlas_height or records_length != glyph_count * 28:
        raise ValueError(f"{path} has invalid atlas or glyph-record dimensions")
    if coverage_length != atlas_width * atlas_height or rgba_length != coverage_length * 4:
        raise ValueError(f"{path} has invalid atlas byte counts")
    atlas_offset = header_size + records_length + coverage_length
    source_offset = atlas_offset + rgba_length
    if source_offset + source_length != len(data):
        raise ValueError(f"{path} has inconsistent file length")
    return data, {
        "pixel_height": height,
        "px_range": px_range,
        "glyph_count": glyph_count,
        "atlas_width": atlas_width,
        "atlas_height": atlas_height,
        "records_offset": header_size,
        "atlas_offset": atlas_offset,
        "rgba_length": rgba_length,
        "source_offset": source_offset,
        "source_length": source_length,
    }


def export_sample(report, sample, assets, output):
    height = sample["baked_px"]
    mfnt_path = assets / f"default_font_msdf_{height}px.mfnt"
    data, info = read_mfnt(mfnt_path, height)
    font = data[info["source_offset"] : info["source_offset"] + info["source_length"]]
    glyph_id = glyph_for_codepoint(font, ord(report["glyph"]))
    if glyph_id >= info["glyph_count"]:
        raise ValueError(f"{mfnt_path}: glyph ID {glyph_id} is outside the MFNT records")

    record_offset = info["records_offset"] + glyph_id * 28
    x0, y0, x1, y1 = struct.unpack_from("<HHHH", data, record_offset)
    expected_source = sample["src_px"]
    source_from_font = [x0, y0, x1 - x0, y1 - y0]
    if any(not math.isclose(a, b, abs_tol=0.01) for a, b in zip(source_from_font, expected_source)):
        raise ValueError(f"{mfnt_path}: rendered source rectangle does not match glyph {report['glyph']}")
    if x1 <= x0 or y1 <= y0:
        raise ValueError(f"{mfnt_path}: glyph {report['glyph']} has an empty atlas rectangle")

    width, height_px = x1 - x0, y1 - y0
    atlas_width, atlas_height = info["atlas_width"], info["atlas_height"]
    atlas = data[info["atlas_offset"] : info["atlas_offset"] + info["rgba_length"]]
    crop = bytearray(width * height_px * 3)
    for row in range(height_px):
        for col in range(width):
            source = ((y0 + row) * atlas_width + x0 + col) * 4
            target = (row * width + col) * 3
            crop[target : target + 3] = atlas[source : source + 3]

    output.mkdir(parents=True, exist_ok=True)
    stem = f"{height}px_A"
    write_png(output / f"{stem}_msdf_rgb.png", width, height_px, crop, 3)
    for channel, name in enumerate(("r", "g", "b")):
        plane = bytes(crop[index] for index in range(channel, len(crop), 3))
        write_png(output / f"{stem}_msdf_{name}.png", width, height_px, plane, 1)

    src = sample["src_px"]
    dst = sample["dst_px"]
    scale_x = report["window_px"][0] / report["logical_px"][0]
    scale_y = report["window_px"][1] / report["logical_px"][1]
    return {
        "baked_px": height,
        "glyph": report["glyph"],
        "glyph_id": glyph_id,
        "px_range": info["px_range"],
        "atlas_px": [atlas_width, atlas_height],
        "atlas_crop_px": [x0, y0, x1, y1],
        "uv": [src[0] / atlas_width, src[1] / atlas_height,
               (src[0] + src[2]) / atlas_width, (src[1] + src[3]) / atlas_height],
        "render_logical_px": dst,
        "render_window_px": [
            dst[0] * scale_x, dst[1] * scale_y, dst[2] * scale_x, dst[3] * scale_y
        ],
        "captures": [f"{stem}_msdf_{channel}.png" for channel in ("rgb", "r", "g", "b")],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, required=True, help="TB-03-msdf-scale-probe.json")
    parser.add_argument("--assets", type=Path, required=True, help="folder containing staged MFNT assets")
    parser.add_argument("--output", type=Path, required=True, help="folder for atlas crops and metadata")
    args = parser.parse_args()

    report = json.loads(args.report.read_text(encoding="utf-8"))
    if report.get("testbed") != "TB-03" or report.get("glyph") != "A":
        raise ValueError("report is not a TB-03 MSDF glyph-A probe")
    samples = report.get("samples", [])
    if [sample.get("baked_px") for sample in samples] != [16, 24, 32, 48]:
        raise ValueError("report must include exactly the 16, 24, 32, and 48px samples")
    results = [export_sample(report, sample, args.assets, args.output) for sample in samples]
    metadata = {
        "testbed": "TB-03",
        "glyph": report["glyph"],
        "window_px": report["window_px"],
        "logical_px": report["logical_px"],
        "samples": results,
    }
    (args.output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    print(f"Exported {len(results)} MSDF atlas crops and channel images to {args.output}")


if __name__ == "__main__":
    main()
