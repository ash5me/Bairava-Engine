const bairava = @import("bairava");
const manifest = @import("public_api_manifest.zig");
const inventory = @import("public_api_inventory.zig");
const std = @import("std");

test "every allowlisted API name resolves through the public package root" {
    inline for (manifest.entries) |entry| {
        if (!@hasDecl(bairava, entry.name)) {
            @compileError("public API manifest entry is not exported by bairava");
        }
        _ = @field(bairava, entry.name);
    }
}

test "compiler-derived callable type metadata uses canonical public types" {
    const signatures = try inventory.renderCompilerSignatures(std.testing.allocator);
    defer std.testing.allocator.free(signatures);
    try std.testing.expect(std.mem.indexOf(u8, signatures, "bairava.Config") != null);
    try std.testing.expect(std.mem.indexOf(u8, signatures, "bairava.ActionMap`") != null);
    try std.testing.expect(std.mem.indexOf(u8, signatures, "`fn (type) type`") != null);
    try std.testing.expect(std.mem.indexOf(u8, signatures, "engine.core.") == null);
}

test "manifest member checklist claims have supporting contracts" {
    try inventory.validateMemberChecklist(&manifest.entries);
}
