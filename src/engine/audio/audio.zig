//! Sound output: the API the engine and the game use. The playback backend is SDL3, in
//! platform/sdl/audio.zig. The SDL-free parts sit beside this file: the voice rules in voices.zig,
//! and the BRAD IMA ADPCM decoder in ima.zig.

const backend = @import("../platform/sdl/audio.zig");

pub const Audio = backend.Audio;
pub const Sound = backend.Sound;
pub const Error = backend.Error;
pub const PlayOptions = backend.PlayOptions;
pub const Handle = backend.Handle;
pub const max_voices = backend.max_voices;
