#!/usr/bin/env python3
"""Focused integration tests for the asset import and conversion CLIs."""

import math
import struct
import subprocess
import sys
import tempfile
import wave
import zlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def run_tool(executable, *args, cwd):
    result = subprocess.run(
        [str(executable), *map(str, args)],
        cwd=cwd,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode:
        raise AssertionError(
            f"{Path(executable).name} failed ({result.returncode}):\n"
            f"{result.stdout}{result.stderr}"
        )
    return result.stdout


def png_chunk(kind, data):
    return (
        struct.pack(">I", len(data))
        + kind
        + data
        + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    )


def write_rgba_png(path, width, height, pixels):
    rows = b"".join(
        b"\0" + bytes(channel for pixel in pixels[y * width : (y + 1) * width] for channel in pixel)
        for y in range(height)
    )
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + png_chunk(b"IDAT", zlib.compress(rows))
        + png_chunk(b"IEND", b"")
    )


def read_rgba_png(path):
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise AssertionError(f"{path} is not a PNG")
    offset = 8
    compressed = bytearray()
    while offset < len(data):
        size = struct.unpack_from(">I", data, offset)[0]
        kind = data[offset + 4 : offset + 8]
        payload = data[offset + 8 : offset + 8 + size]
        offset += size + 12
        if kind == b"IHDR":
            width, height, bit_depth, color_type, compression, filtering, interlace = struct.unpack(
                ">IIBBBBB", payload
            )
            if (bit_depth, color_type, compression, filtering, interlace) != (8, 6, 0, 0, 0):
                raise AssertionError("keyer output must be non-interlaced RGBA8")
        elif kind == b"IDAT":
            compressed.extend(payload)
        elif kind == b"IEND":
            break
    raw = zlib.decompress(compressed)
    stride = width * 4
    rows = []
    previous = bytearray(stride)
    cursor = 0
    for _ in range(height):
        filter_kind = raw[cursor]
        scanline = bytearray(raw[cursor + 1 : cursor + 1 + stride])
        cursor += stride + 1
        for index in range(stride):
            left = scanline[index - 4] if index >= 4 else 0
            above = previous[index]
            upper_left = previous[index - 4] if index >= 4 else 0
            if filter_kind == 1:
                scanline[index] = (scanline[index] + left) & 0xFF
            elif filter_kind == 2:
                scanline[index] = (scanline[index] + above) & 0xFF
            elif filter_kind == 3:
                scanline[index] = (scanline[index] + ((left + above) // 2)) & 0xFF
            elif filter_kind == 4:
                estimate = left + above - upper_left
                distances = (abs(estimate - left), abs(estimate - above), abs(estimate - upper_left))
                predictor = left if distances[0] <= distances[1] and distances[0] <= distances[2] else (
                    above if distances[1] <= distances[2] else upper_left
                )
                scanline[index] = (scanline[index] + predictor) & 0xFF
            elif filter_kind != 0:
                raise AssertionError(f"unsupported PNG filter {filter_kind}")
        rows.append(scanline)
        previous = scanline
    return width, height, [bytes(row[i : i + 4]) for row in rows for i in range(0, stride, 4)]


def make_checkerboard():
    width = height = 7
    light = (200, 200, 200, 255)
    dark = (160, 160, 160, 255)
    art = (220, 30, 30, 255)
    pixels = [
        light if (x + y) % 2 == 0 else dark
        for y in range(height)
        for x in range(width)
    ]
    for y in range(2, 5):
        for x in range(2, 5):
            if (x, y) != (3, 3):
                pixels[y * width + x] = art
    return width, height, pixels


def test_importer(importer, work):
    project = work / "importer"
    (project / "assets").mkdir(parents=True)
    (project / "assets" / "sprites.txt").write_text("# sprites\n", encoding="utf-8")
    source = project / "source.png"
    write_rgba_png(source, 1, 1, [(12, 34, 56, 255)])
    original = source.read_bytes()

    run_tool(importer, source, "hero_idle", cwd=project)
    imported = project / "assets" / "imported" / "hero_idle.png"
    assert imported.read_bytes() == original
    manifest = (project / "assets" / "sprites.txt").read_text(encoding="utf-8")
    assert manifest.splitlines()[-1] == "hero_idle assets/imported/hero_idle.png"

    duplicate = subprocess.run(
        [str(importer), str(source), "hero_idle"],
        cwd=project,
        capture_output=True,
        text=True,
        check=False,
    )
    assert duplicate.returncode != 0, "importer accepted a duplicate sprite name"
    assert (project / "assets" / "sprites.txt").read_text(encoding="utf-8") == manifest

    invalid_name = subprocess.run(
        [str(importer), str(source), "../escape"],
        cwd=project,
        capture_output=True,
        text=True,
        check=False,
    )
    assert invalid_name.returncode != 0, "importer accepted a path-like sprite name"


def test_keyer(keyer, work):
    project = work / "keyer"
    project.mkdir()
    source = project / "checker.png"
    output = project / "keyed.png"
    width, height, pixels = make_checkerboard()
    write_rgba_png(source, width, height, pixels)

    run_tool(keyer, source, output, cwd=project)
    out_width, out_height, result = read_rgba_png(output)
    assert (out_width, out_height) == (width, height)
    assert result[0][3] == 0, "border-connected checkerboard was not cleared"
    assert result[3 * width + 3][3] == 255, "enclosed checker color was incorrectly cleared"
    assert result[2 * width + 2][3] == 255, "enclosing artwork was incorrectly cleared"


def write_test_wav(path):
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(22050)
        output.writeframes(b"".join(struct.pack("<h", int(12000 * math.sin(i))) for i in range(8)))


def check_variant(path, format_id, width, height, payload_size):
    data = path.read_bytes()
    assert data[:4] == b"BRTX", f"{path} missing BRTX header"
    assert data[4] == format_id, f"{path} has unexpected format id {data[4]}"
    assert struct.unpack_from("<II", data, 8) == (width, height)
    assert len(data) == 16 + payload_size, f"{path} has unexpected payload length"
    return data[16:]


def test_builder(builder, work):
    project = work / "builder"
    assets = project / "assets"
    assets.mkdir(parents=True)
    output = project / "runtime"

    image_path = assets / "tile.png"
    image_pixels = [
        (255, 0, 0, 255),
        (0, 255, 0, 128),
        (0, 0, 255, 0),
        (255, 255, 255, 255),
    ]
    write_rgba_png(image_path, 2, 2, image_pixels)
    write_test_wav(assets / "wind.wav")
    (assets / "font.ttf").write_bytes((ROOT / "assets" / "font.ttf").read_bytes())

    manifest = project / "manifest.txt"
    manifest.write_text(
        "\n".join(
            (
                "tile image assets/tile.png tile.png -",
                "wind1 audio assets/wind.wav wind.wav -",
                "font_10px font assets/font.ttf font_10px.bfnt - 10 32 224",
                "font_8px font assets/font.ttf font_8px.bfnt - 8 32 224",
            )
        )
        + "\n",
        encoding="utf-8",
    )

    run_tool(builder, manifest, output, cwd=project)
    assert (output / "tile.png").exists()
    rgba = check_variant(output / "tile.png.rgba", 0, 2, 2, 2 * 2 * 4)
    assert rgba == bytes(channel for pixel in image_pixels for channel in pixel)
    check_variant(output / "tile.png.bc1", 1, 2, 2, 8)
    check_variant(output / "tile.png.bc3", 2, 2, 2, 16)

    astc_variant = output / "tile.png.astc"
    index = (output / "asset-index.txt").read_text(encoding="utf-8")
    tile_row = next(line for line in index.splitlines() if line.startswith("tile "))
    if astc_variant.exists():
        astc = astc_variant.read_bytes()
        assert astc[:4] == b"BRTX" and astc[4] == 3
        assert struct.unpack_from("<II", astc, 8) == (2, 2)
        assert tile_row.split()[-1] == "tile.png.astc"
    else:
        assert tile_row.split()[-1] == "-"

    ima = (output / "wind.wav.ima").read_bytes()
    assert ima[:4] == b"BRAD"
    assert ima[4] == 1 and ima[5] == 1
    assert struct.unpack_from("<II", ima, 8) == (22050, 8)
    assert struct.unpack_from("<I", ima, 16)[0] == 8
    assert len(ima) == 24 + 8

    # Each font size is its own BFNT v2 file. The source TTF is read at build time and never copied.
    for file_name, pixel_height in (("font_10px.bfnt", 10.0), ("font_8px.bfnt", 8.0)):
        font = (output / file_name).read_bytes()
        assert font[:4] == b"BFNT"
        assert struct.unpack_from("<HH", font, 4) == (2, 52), f"{file_name} is not a BFNT v2 bitmap atlas"
        assert struct.unpack_from("<f", font, 8)[0] == pixel_height
        assert struct.unpack_from("<II", font, 12) == (32, 224)
        atlas_width, atlas_height = struct.unpack_from("<II", font, 28)
        assert atlas_width > 0 and atlas_height > 0
        assert len(font) > 52 + 224 * 20
    assert not (output / "font.ttf").exists(), "a font's source must not be copied into the runtime assets"

    assert "wind1 audio wind.wav" in index
    assert "font_10px font font_10px.bfnt" in index
    assert "font_8px font font_8px.bfnt" in index


def test_rejects_mode_fields(builder, work):
    project = work / "modes"
    (project / "assets").mkdir(parents=True)
    (project / "assets" / "font.ttf").write_bytes((ROOT / "assets" / "font.ttf").read_bytes())
    manifest = project / "manifest.txt"
    manifest.write_text("font font assets/font.ttf font_sdf.bfnt - 10 32 224 sdf\n", encoding="utf-8")
    output = project / "runtime"
    result = subprocess.run(
        [str(builder), str(manifest), str(output)],
        cwd=project,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode != 0, "builder accepted a font row with a leftover SDF mode field"
    assert "eight for fonts" in result.stderr, result.stderr
    assert not (output / "font_sdf.bfnt").exists()


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: test_tools.py <asset-build> <asset-keyer> <asset-import>")
    builder, keyer, importer = map(Path, sys.argv[1:])
    with tempfile.TemporaryDirectory(prefix="bairava-asset-tools-") as directory:
        work = Path(directory)
        test_importer(importer.resolve(), work)
        test_keyer(keyer.resolve(), work)
        test_builder(builder.resolve(), work)
        test_rejects_mode_fields(builder.resolve(), work)
    print("asset importer and converter integration tests passed")


if __name__ == "__main__":
    main()
