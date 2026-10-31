// The single SDL C import for the project. Every file uses this one
// instead of its own @cImport, so SDL types match across files.
const builtin = @import("builtin");

pub const c = @cImport({
    // Apple's SDK uses this compiler marker to select its macOS target definitions. Zig's C
    // translator targets the Apple ABI but does not identify itself as Apple's Clang build.
    if (builtin.os.tag == .macos) @cDefine("__APPLE_CC__", "6000");
    @cInclude("SDL3/SDL.h");
});
