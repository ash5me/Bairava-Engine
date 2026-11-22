# TB-15 Audio Laboratory

TB-15 exercises the existing WAV/optional IMA-sidecar loading path, streamed looping music,
simultaneous positional effects, live music/SFX bus gain, listener/emitter movement, voice-pool
capacity, and scene cleanup.

## Run a bounded test

```powershell
zig build run-tb15 -- --frames 360
```

The test writes `TB-15-audio-results.json` beside the executable. At startup it loads the packaged
`assets/wind1.wav`, opens it for streaming, checks missing and invalid input errors, fills the
32-voice pool and verifies the next play fails with `NoFreeVoice`, then stops all voices and checks
the pool is empty before starting the interactive mix. The original WAV is packaged a second time
as `assets/testbeds/tb15/wind1_wav_only.wav` without an IMA sidecar, so the lab tests both IMA
preferred decode/stream and forced WAV decode/stream paths. The report records whether the IMA
sidecar was available and selected.

## Controls

- Space: trigger a burst of positional sound effects.
- Left/Right: move the emitter.
- Up/Down: change the SFX bus gain.
- Q: toggle the music bus gain.
- E: stop/start the looping positional emitter.
- Escape: exit.

When available, a playback device is opened by the engine before the sample starts. If no device
is present the UI and report identify the unavailable case instead of pretending playback passed.
Listen for the simultaneous effects, streamed loop, gain changes, and emitter pan/attenuation.

## Coverage limits

The engine currently exposes no public audio-device-loss injection/reopen control and no underrun
counter. The result explicitly labels those checks as not tested/not exposed. Audio resource cleanup
is verified by stopping every tracked voice and freeing the loaded sound during testbed teardown;
device-loss recovery requires a platform-level test hook.
