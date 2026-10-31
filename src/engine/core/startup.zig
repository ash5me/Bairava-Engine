//! The steps of engine startup, in the order they open. `Session.start` records the step it is on, so a
//! failure is reported with the subsystem and the operation that failed, not only with an error name. The
//! stages are plain text, so `zig build test` covers them with no window.

const std = @import("std");

pub const Stage = enum {
    /// Before the first step, or after a clean start.
    not_started,
    platform,
    window,
    gpu,
    targets,
    audio,
    textures,
    /// Every step opened.
    ready,

    /// The subsystem a stage belongs to, for logs.
    pub fn subsystem(self: Stage) []const u8 {
        return switch (self) {
            .not_started => "none",
            .platform => "platform",
            .window => "window",
            .gpu => "gpu",
            .targets => "renderer",
            .audio => "audio",
            .textures => "assets",
            .ready => "engine",
        };
    }

    /// What the stage does, as a short phrase, for logs.
    pub fn operation(self: Stage) []const u8 {
        return switch (self) {
            .not_started => "not started",
            .platform => "starting SDL",
            .window => "creating the window",
            .gpu => "creating the GPU device",
            .targets => "creating the native target and sprite batches",
            .audio => "opening the audio device",
            .textures => "setting up the texture store",
            .ready => "running",
        };
    }
};

/// The one-line summary logged when startup fails. It names the subsystem, the operation, and the error,
/// and it says that everything opened before the failure was released. `buf` holds the text.
pub fn failureSummary(buf: []u8, stage: Stage, error_name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "startup failed in the {s} subsystem while {s}: {s}; anything opened before it was released", .{
        stage.subsystem(),
        stage.operation(),
        error_name,
    }) catch "startup failed";
}

test "every stage names a subsystem and an operation" {
    for (std.enums.values(Stage)) |stage| {
        try std.testing.expect(stage.subsystem().len > 0);
        try std.testing.expect(stage.operation().len > 0);
    }
}

test "the failure summary names the subsystem, the operation, and the error" {
    var buf: [256]u8 = undefined;
    const text = failureSummary(&buf, .window, "WindowCreateFailed");
    try std.testing.expectEqualStrings(
        "startup failed in the window subsystem while creating the window: WindowCreateFailed; anything opened before it was released",
        text,
    );
}
