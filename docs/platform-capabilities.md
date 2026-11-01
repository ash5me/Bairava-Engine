# Runtime platform capabilities

Games can query the active runtime through `Context.capabilities()`. It returns
the SDL-independent `engine.Capabilities` value and is valid only while the
engine is running. GPU results reflect both formats embedded in this build and
formats accepted by the active GPU device. `audio_playback` reports whether the
default playback device opened, and `presentation.immediate` reports whether
the active window supports immediate presentation without vsync.

```zig
const caps = ctx.capabilities();
if (caps.audio_playback) {
    const sound = try ctx.loadSound("wind1.wav");
    defer sound.deinit();
    _ = try ctx.audio.play(&sound, .{});
}
```

`shader_formats` reports SPIR-V, DXIL, and MSL support only when both the
vertex and fragment shaders are embedded and the GPU accepts that format.
`texture_formats` reports RGBA8 and the optional BC1, BC3, and ASTC 4x4
sampling formats. RGBA8 is the engine's required uncompressed fallback.

## Unsupported-feature behavior

- **Compressed textures:** the asset loader tries supported ASTC, BC3, BC1, and
  RGBA8 variants in that order. Missing, malformed, or unsupported variants
  fall through to the next variant, then decode the original image as RGBA8.
  If the original is also missing or invalid, texture loading returns an
  `AssetError`; it does not report a successful fallback.
- **Required GPU formats:** startup fails with `UnsupportedGpuCapabilities`
  before creating renderer resources if there is no usable embedded shader
  format or the active device cannot sample RGBA8. Games that reach `init` can
  rely on both requirements; `shader_formats` and `texture_formats.rgba8`
  describe the available alternatives and required baseline.
- **Audio playback:** failure to open the default device is non-fatal and the
  game runs silently. `audio_playback` is false; sound loading and playback
  return `error.NoDevice`. Audio decode and conversion helpers that operate on
  caller-provided data do not require a playback device.
- **Shader formats:** only compiled formats are requested from SDL and reported
  as usable. The engine needs at least one format to create its renderer;
  otherwise startup returns `UnsupportedGpuCapabilities` instead of silently
  drawing nothing.
- **Immediate presentation:** check `caps.presentation.immediate` before
  offering a no-vsync setting. If a configuration requests immediate
  presentation on a display that does not support it, the engine keeps vsync
  on and logs a warning. A true value means the mode is supported, not that it
  is currently selected.
- **Development-only tools:** diagnostics, the overlay, console, and hot reload
  are controlled by the build profile and `-Ddev-tools`; they are not runtime
  capabilities and are absent when compiled out.

The capability query reports the session's current device and window. It does
not promise that a later device, display, or target will have the same
capabilities.
