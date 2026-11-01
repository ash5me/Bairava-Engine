# Runtime platform capabilities

Games can query the active runtime through `Context.capabilities()`. It returns
the SDL-independent `engine.Capabilities` value and is valid only while the
engine is running. GPU results reflect both formats embedded in this build and
formats accepted by the active GPU device. `audio_playback` reports whether the
default playback device opened.

```zig
const caps = ctx.capabilities();
if (caps.audio_playback) {
    const sound = try ctx.loadSound("wind1.wav");
    defer sound.deinit();
    _ = try ctx.audio.play(&sound, .{});
}
```

`shader_formats` reports SPIR-V, DXIL, and MSL support. The engine requires at
least one shader format to start rendering; a device with no usable embedded
shader format cannot run the renderer. `texture_formats` reports RGBA8 and the
optional BC1, BC3, and ASTC 4x4 sampling formats. RGBA8 is the engine's
uncompressed fallback.

## Unsupported-feature behavior

- **Compressed textures:** the asset loader tries supported ASTC, BC3, BC1, and
  RGBA8 variants in that order. Missing, malformed, or unsupported variants
  fall through to the next variant, then decode the original image as RGBA8.
  If the original is also missing or invalid, texture loading returns an
  `AssetError`; it does not report a successful fallback.
- **Audio playback:** failure to open the default device is non-fatal and the
  game runs silently. `audio_playback` is false; sound loading and playback
  return `error.NoDevice`. Audio decode and conversion helpers that operate on
  caller-provided data do not require a playback device.
- **Shader formats:** only compiled formats are requested from SDL and reported
  as usable. The engine needs one supported format to create its renderer;
  otherwise renderer initialization panics with the unsupported-format flags
  rather than silently drawing nothing.
- **Immediate presentation:** when the display cannot present without vsync,
  the engine keeps vsync on and logs a warning.
- **Development-only tools:** diagnostics, the overlay, console, and hot reload
  are controlled by the build profile and `-Ddev-tools`; they are not runtime
  capabilities and are absent when compiled out.

The capability query reports the session's current device. It does not promise
that a later device, display mode, or target will have the same capabilities.
