# Streamed audio

Long sounds, such as music and ambience, can play from disk without being read into memory. Short effects still load
whole with `Context.loadSound`, because they start at once and can be positioned without any file access during play.

## Using it

```zig
var music = try ctx.openStreamed("music/theme.wav");   // reads only the header
const voice = try ctx.audio.playStreamed(&music, .{ .loop = true, .gain = 0.6 });
```

`openStreamed` takes the same relative path as `loadSound`, and it prefers the build-encoded IMA sidecar
(`music/theme.wav.ima`) when one exists, as `loadSound` does. `playStreamed` takes the same `PlayOptions` as `play`:
gain, loop, pan, and an optional position for a positional sound. Stop a voice with `stop`, and check it with
`isPlaying`, as for any other voice.

A `StreamedSound` holds only the path and the format. It owns no file and needs no `deinit`. Each playing voice opens
its own reader, which closes when the voice ends or is stopped. The same `StreamedSound` can play several times at once.

## What is held in memory

A loaded sound queues its whole length. A streamed voice that is not positional keeps one second of converted sound
queued instead, so a hitch in the game loop of up to a second does not reach the output. A positional streamed voice
keeps the same short lookahead as a positional loaded sound, a tenth of a second, so moving it is heard promptly. Each
read fills at most 4096 bytes, and an IMA read decodes at most 1024 frames, into one buffer that all voices share.

## Formats

- **WAV:** PCM at 8, 16, or 32 bits, and IEEE float at 32 bits. Extensible WAV is accepted when its sub-format is one of
  these. 24-bit and other formats are refused with `UnsupportedFormat`, and `loadSound` still plays them. A data chunk
  longer than the file is clipped to the bytes present.
- **BRAD IMA ADPCM** (the build's `.ima` sidecar): mono or stereo. The sidecar stores each channel as a whole block, so a
  chunk reads a run of nibbles from each block at its own offset. The decoder is checked sample for sample against the
  whole-file decoder in `audio/ima.zig`.

Sound converts from its own rate and channel count to the device's format through an SDL stream that keeps its
resampling state between chunks, so a sound cut into chunks sounds the same as one converted whole.

## Looping

A looping streamed voice starts its sound again at the end. Its converter keeps running across the join, so the loop has
no gap at the seam. A voice that cannot read its sound any further stops looping and finishes once its queued sound has
played out, so a read error never leaves a silent voice running forever.

## Files and the platform

`platform/sdl/files.zig` provides `open`, `close`, `size`, and `readAt` for reads at chosen offsets. `platform/sdl/audio.zig`
provides `createConverter` and `getStreamData`. Both sit behind `platform.zig`, so `audio/streaming.zig` and
`audio/audio.zig` keep their SDL-free boundary. `audio/streaming.zig` reads only through a `Source` (a context, a read
function, and a size), so its tests run with no device and no file system.

## Not covered yet

- Streaming from a file that changes while a voice plays. The reader trusts the size it read when the voice started.
- Volume categories, such as separate music and effects levels, and reacting to a device change.
- Music that is decoded ahead on a worker thread. Each chunk is decoded on the main thread, which is cheap for these
  formats.
