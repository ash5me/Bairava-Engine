//! Semantic version of the public Bairava engine API.

/// A semantic version, represented by its numeric components.
pub const Version = struct {
    major: u16,
    minor: u16,
    patch: u16,
};

/// Current engine API version. Keep this in sync with `build.zig.zon`'s package version.
pub const version: Version = .{ .major = 0, .minor = 1, .patch = 0 };
