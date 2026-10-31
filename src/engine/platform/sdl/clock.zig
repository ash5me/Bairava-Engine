//! Monotonic time and thread delays through SDL3. Only the platform layer calls these SDL functions;
//! the engine reaches them through `platform.clock`.

const c = @import("sdl.zig").c;

/// Nanoseconds from an arbitrary fixed point. Only differences mean anything, and the value never
/// goes backward.
pub fn nowNs() u64 {
    return c.SDL_GetTicksNS();
}

/// Blocks the calling thread for at least `ms` milliseconds.
pub fn sleepMs(ms: u32) void {
    c.SDL_Delay(ms);
}
