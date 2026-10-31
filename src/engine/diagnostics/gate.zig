//! Whether this build includes the development tools: the debug overlay and its geometry, the
//! console, and hot reload. Set with `zig build -Ddev-tools=true|false`, and on by default in Debug
//! builds. Code behind this flag is compiled out of release builds, so it costs nothing there.
//!
//! Only engine modules that are built with the engine's build options may import this file. The
//! pure modules in src/engine/diagnostics/ do not, so `zig build test` can compile them alone.

const build_options = @import("build_options");

pub const enabled: bool = build_options.dev_tools;
