# TB-03 Text and Font Rendering

Purpose: validate Latin, Tamil, combining-mark, bitmap, BFNT, runtime outline, and MSDF text
rendering plus glyph-cache and atlas metrics through public engine APIs.

## Run

```sh
zig build run-tb03 -- --count 100 --frames 180
zig build run-tb03 -- --count 500 --frames 180
zig build run-tb03 -- --count 1000 --frames 180
zig build run-tb03 -- --count 1000 --gpu-timing --frames 180
```

Supported workload counts are `100`, `500`, and `1000`. `--frames` sets the frame count at which
the metrics summary is written; the window remains open until Escape. GPU timing is opt-in
because it waits for the GPU and must not be interpreted as an unrestricted frame-rate measurement.

The sample displays bitmap, BFNT, runtime Latin, runtime Tamil, and MSDF fonts. It logs shaping,
measurement, glyph-cache, rasterization, atlas, and frame metrics, and writes
`TB-03-text-font-rendering-results.json` beside the executable.

## Known limitations

- Right-to-left text is not currently installed as a dedicated font sample.
- Atlas exhaustion is covered separately by the unit and glyph-atlas tests; this visual run reports
  page and upload state but does not deliberately exhaust the fixed atlas capacity.
- Reference screenshots are not generated automatically.
