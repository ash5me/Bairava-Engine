//! An atlas on the GPU: the texture that holds every sprite, and the index that says where each
//! sprite sits in it. `Context.loadAtlas` builds one from the build's two files.

const std = @import("std");

const atlas = @import("../assets/loaders/atlas.zig");
const Texture = @import("texture.zig").Texture;

pub const LoadedAtlas = struct {
    texture: Texture,
    index: atlas.Atlas,

    /// The region of the sprite called `name`. Panics when it is missing, because a name the game
    /// asks for must have been packed into the atlas.
    pub fn region(self: *const LoadedAtlas, name: []const u8) atlas.Region {
        return self.index.find(name) orelse std.debug.panic("sprite '{s}' is not in the atlas", .{name});
    }

    pub fn deinit(self: *LoadedAtlas) void {
        self.texture.deinit();
        self.index.deinit();
    }
};
