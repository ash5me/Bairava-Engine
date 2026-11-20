const std = @import("std");
const manifest = @import("public_api_manifest.zig");

const Ast = std.zig.Ast;

const RootDeclaration = struct {
    name: []const u8,
    declaration_kind: []const u8,
    target: []const u8,
};

pub const Error = error{
    DuplicateCanonicalName,
    InvalidManifestEntry,
    InvalidZigSource,
    MissingDeclaration,
    TargetMismatch,
    UnlistedPublicDeclaration,
};

pub fn renderInventory(
    allocator: std.mem.Allocator,
    source: []const u8,
    entries: []const manifest.Entry,
) (Error || std.mem.Allocator.Error)![]u8 {
    const source_z = try allocator.dupeZ(u8, source);
    defer allocator.free(source_z);

    var tree = try Ast.parse(allocator, source_z, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) return error.InvalidZigSource;

    var declarations: std.ArrayList(RootDeclaration) = .empty;
    defer declarations.deinit(allocator);
    for (tree.rootDecls()) |node| {
        switch (tree.nodeTag(node)) {
            .global_var_decl, .simple_var_decl, .aligned_var_decl => {
                const declaration = tree.fullVarDecl(node).?;
                if (declaration.visib_token == null) continue;
                const init_node = declaration.ast.init_node.unwrap() orelse continue;
                const span = tree.nodeToSpan(init_node);
                try declarations.append(allocator, .{
                    .name = tree.tokenSlice(tree.nodeMainToken(node) + 1),
                    .declaration_kind = tree.tokenSlice(declaration.ast.mut_token),
                    .target = std.mem.trim(u8, source[span.start..span.end], " \t\r\n"),
                });
            },
            .fn_decl => {
                const first_token = tree.firstToken(node);
                if (!std.mem.eql(u8, tree.tokenSlice(first_token), "pub")) continue;
                try declarations.append(allocator, .{
                    .name = tree.tokenSlice(tree.nodeMainToken(node) + 1),
                    .declaration_kind = "fn",
                    .target = "",
                });
            },
            else => {},
        }
    }

    try validateManifest(declarations.items, entries);

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator,
        \\# Bairava public API
        \\
        \\This reference is generated from an explicit allowlist of canonical names exported by `@import("bairava")`.
        \\Only allowlisted entries are published; implementation target paths are validated but never displayed.
        \\
        \\
    );
    try appendFormatted(allocator, &output, "{d} allowlisted exports. Kind labels are manifest classifications; stability remains unclassified. Compiler-derived signatures and member-level contracts are not included yet.\n\n", .{
        entries.len,
    });

    for (entries) |entry| {
        try output.appendSlice(allocator, "## `bairava.");
        try output.appendSlice(allocator, entry.name);
        try output.appendSlice(allocator, "`\n\n");
        try appendFormatted(allocator, &output, "**Kind:** {s}  \n**Stability:** {s}  \n**Summary:** {s}\n\n", .{
            entry.kind,
            entry.stability,
            entry.summary,
        });
    }
    return output.toOwnedSlice(allocator);
}

fn validateManifest(
    declarations: []const RootDeclaration,
    entries: []const manifest.Entry,
) Error!void {
    for (entries, 0..) |entry, index| {
        if (entry.name.len == 0 or entry.target.len == 0 or entry.kind.len == 0 or entry.summary.len == 0) {
            return error.InvalidManifestEntry;
        }
        if (!isAllowed(entry.kind, &.{ "type", "type factory", "function", "constant", "error set", "namespace" }) or
            !isAllowed(entry.stability, &.{ "unclassified", "stable", "experimental", "deprecated" }))
        {
            return error.InvalidManifestEntry;
        }
        for (entries[0..index]) |previous| {
            if (std.mem.eql(u8, previous.name, entry.name)) return error.DuplicateCanonicalName;
        }

        const declaration = findDeclaration(declarations, entry.name) orelse return error.MissingDeclaration;
        if (!std.mem.eql(u8, declaration.target, entry.target)) return error.TargetMismatch;
        if (!std.mem.eql(u8, declaration.declaration_kind, "const")) {
            return error.InvalidManifestEntry;
        }
    }
    for (declarations) |declaration| {
        if (findManifestEntry(entries, declaration.name) == null) return error.UnlistedPublicDeclaration;
    }
}

fn findDeclaration(declarations: []const RootDeclaration, name: []const u8) ?RootDeclaration {
    for (declarations) |declaration| {
        if (std.mem.eql(u8, declaration.name, name)) return declaration;
    }
    return null;
}

fn findManifestEntry(entries: []const manifest.Entry, name: []const u8) ?manifest.Entry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

fn isAllowed(value: []const u8, allowed: []const []const u8) bool {
    for (allowed) |candidate| {
        if (std.mem.eql(u8, value, candidate)) return true;
    }
    return false;
}

fn appendFormatted(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    comptime format: []const u8,
    args: anytype,
) std.mem.Allocator.Error!void {
    const text = try std.fmt.allocPrint(allocator, format, args);
    defer allocator.free(text);
    try output.appendSlice(allocator, text);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const source = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        "src/engine/bairava.zig",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(source);
    const markdown = try renderInventory(allocator, source, &manifest.entries);
    defer allocator.free(markdown);
    try std.Io.File.stdout().writeStreamingAll(init.io, markdown);
}

test "manifest publishes only selected canonical names and never exposes targets" {
    const source =
        \\//! Package root.
        \\const engine = @import("core/engine.zig");
        \\pub const Config = engine.Config;
        \\pub const Context = engine.Context;
        \\const Unlisted = engine.Unlisted;
    ;
    const entries = [_]manifest.Entry{
        .{ .name = "Config", .target = "engine.Config", .kind = "type", .summary = "Application settings." },
        .{ .name = "Context", .target = "engine.Context", .kind = "type", .summary = "Game services." },
    };
    const markdown = try renderInventory(std.testing.allocator, source, &entries);
    defer std.testing.allocator.free(markdown);
    const repeated = try renderInventory(std.testing.allocator, source, &entries);
    defer std.testing.allocator.free(repeated);

    try std.testing.expectEqualStrings(markdown, repeated);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "## `bairava.Config`") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "## `bairava.Context`") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "## `bairava.Unlisted`") == null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "core/engine.zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "engine.Config") == null);
}

test "inventory rejects malformed Zig source" {
    try std.testing.expectError(
        error.InvalidZigSource,
        renderInventory(std.testing.allocator, "pub const Broken = ;", &.{}),
    );
}

test "manifest target must match the public alias" {
    const source =
        \\const engine = @import("core/engine.zig");
        \\pub const Config = engine.Config;
    ;
    const entries = [_]manifest.Entry{
        .{ .name = "Config", .target = "engine.Other", .kind = "type", .summary = "Application settings." },
    };
    try std.testing.expectError(
        error.TargetMismatch,
        renderInventory(std.testing.allocator, source, &entries),
    );
}

test "manifest rejects missing and duplicate canonical entries" {
    const source =
        \\const engine = @import("core/engine.zig");
        \\pub const Config = engine.Config;
    ;
    const missing = [_]manifest.Entry{
        .{ .name = "Missing", .target = "engine.Missing", .kind = "type", .summary = "No declaration." },
    };
    try std.testing.expectError(
        error.MissingDeclaration,
        renderInventory(std.testing.allocator, source, &missing),
    );

    const duplicate = [_]manifest.Entry{
        .{ .name = "Config", .target = "engine.Config", .kind = "type", .summary = "Application settings." },
        .{ .name = "Config", .target = "engine.Config", .kind = "type", .summary = "Duplicate." },
    };
    try std.testing.expectError(
        error.DuplicateCanonicalName,
        renderInventory(std.testing.allocator, source, &duplicate),
    );
}

test "unlisted root exports fail instead of being published automatically" {
    const source =
        \\const engine = @import("core/engine.zig");
        \\pub const Config = engine.Config;
        \\pub const Unreviewed = engine.Unreviewed;
    ;
    const entries = [_]manifest.Entry{
        .{ .name = "Config", .target = "engine.Config", .kind = "type", .summary = "Application settings." },
    };
    try std.testing.expectError(
        error.UnlistedPublicDeclaration,
        renderInventory(std.testing.allocator, source, &entries),
    );
}
