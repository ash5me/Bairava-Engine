// The single SDL C import for the project. Every file uses this one
// instead of its own @cImport, so SDL types match across files.
pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
});
