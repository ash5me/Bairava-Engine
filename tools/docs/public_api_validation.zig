const bairava = @import("bairava");
const manifest = @import("public_api_manifest.zig");

test "every allowlisted API name resolves through the public package root" {
    inline for (manifest.entries) |entry| {
        if (!@hasDecl(bairava, entry.name)) {
            @compileError("public API manifest entry is not exported by bairava");
        }
        _ = @field(bairava, entry.name);
    }
}
