const std = @import("std");
const manifest = @import("public_api_manifest.zig");
const bairava = @import("bairava");

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
    InvalidMemberChecklist,
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
    try validateMemberChecklist(entries);

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator,
        \\# Bairava public API
        \\
        \\This reference is generated from an explicit allowlist of canonical names exported by `@import("bairava")`.
        \\Only allowlisted entries are published; implementation target paths are validated but never displayed.
        \\The current public API is experimental and not production-ready.
        \\
        \\
    );
    try appendFormatted(allocator, &output, "{d} allowlisted exports. All entries inherit the project's experimental API status. Callable export types are emitted from compiler reflection; contract notes are authored and reviewed in the manifest.\n\n", .{
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
        if (entry.contract.len != 0) {
            try output.appendSlice(allocator, "**Contract:** ");
            try output.appendSlice(allocator, entry.contract);
            try output.appendSlice(allocator, "\n\n");
        }
        for (entry.member_contracts) |member| {
            try output.appendSlice(allocator, "- **");
            try output.appendSlice(allocator, entry.name);
            try output.appendSlice(allocator, ".");
            try output.appendSlice(allocator, member.member);
            try output.appendSlice(allocator, " (");
            try output.appendSlice(allocator, @tagName(member.area));
            try output.appendSlice(allocator, "):** ");
            try output.appendSlice(allocator, member.description);
            try output.appendSlice(allocator, "\n");
        }
        if (entry.member_contracts.len != 0) try output.appendSlice(allocator, "\n");
    }
    try appendMemberChecklist(allocator, &output, entries);
    return output.toOwnedSlice(allocator);
}

pub fn validateMemberChecklist(entries: []const manifest.Entry) Error!void {
    for (entries) |entry| {
        for (entry.member_contracts, 0..) |member, index| {
            if (member.member.len == 0 or member.description.len == 0) return error.InvalidMemberChecklist;
            for (entry.member_contracts[0..index]) |previous| {
                if (previous.area == member.area and std.mem.eql(u8, previous.member, member.member)) {
                    return error.InvalidMemberChecklist;
                }
            }
        }
        inline for (member_areas) |area| {
            const status = checklistStatus(entry.member_checklist, area);
            const has_contract = hasMemberContract(entry.member_contracts, area);
            if ((status == .documented and !has_contract) or (status == .not_applicable and has_contract)) {
                return error.InvalidMemberChecklist;
            }
        }
    }
}

const member_areas = [_]manifest.MemberArea{
    .fields,
    .methods,
    .parameters,
    .returns,
    .errors,
    .allocators,
    .handles,
    .callbacks,
    .capacities,
};

fn checklistStatus(checklist: manifest.MemberChecklist, area: manifest.MemberArea) manifest.CoverageStatus {
    return switch (area) {
        .fields => checklist.fields,
        .methods => checklist.methods,
        .parameters => checklist.parameters,
        .returns => checklist.returns,
        .errors => checklist.errors,
        .allocators => checklist.allocators,
        .handles => checklist.handles,
        .callbacks => checklist.callbacks,
        .capacities => checklist.capacities,
    };
}

fn hasMemberContract(contracts: []const manifest.MemberContract, area: manifest.MemberArea) bool {
    for (contracts) |contract| {
        if (contract.area == area) return true;
    }
    return false;
}

fn appendMemberChecklist(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    entries: []const manifest.Entry,
) std.mem.Allocator.Error!void {
    var review_areas: usize = 0;
    var total_areas: usize = 0;
    for (entries) |entry| {
        if (!std.mem.eql(u8, entry.kind, "type") and !std.mem.eql(u8, entry.kind, "type factory")) continue;
        inline for (member_areas) |area| {
            total_areas += 1;
            if (checklistStatus(entry.member_checklist, area) == .needs_review) review_areas += 1;
        }
    }
    try appendFormatted(allocator, output, "{d} of {d} type/member contract areas are marked needs_review. This is a visible coverage report, not a claim that the API is fully documented.\n\n", .{
        review_areas,
        total_areas,
    });
    try output.appendSlice(allocator,
        \\## Member-level contract checklist
        \\
        \\`needs_review` means the member-level audit or documentation is incomplete; `documented` means the applicable contracts are recorded above; `not_applicable` means the category does not apply to the type.
        \\
        \\
        \\| Public type | Fields | Methods | Parameters | Returns | Errors | Allocators | Handles | Callbacks | Capacities |
        \\|---|---|---|---|---|---|---|---|---|---|
        \\
    );
    for (entries) |entry| {
        if (!std.mem.eql(u8, entry.kind, "type") and !std.mem.eql(u8, entry.kind, "type factory")) continue;
        try output.appendSlice(allocator, "| `bairava.");
        try output.appendSlice(allocator, entry.name);
        try output.appendSlice(allocator, "`");
        inline for (member_areas) |area| {
            try output.appendSlice(allocator, " | ");
            try output.appendSlice(allocator, @tagName(checklistStatus(entry.member_checklist, area)));
        }
        try output.appendSlice(allocator, " |\n");
    }
    try output.appendSlice(allocator, "\n");
}

pub fn renderCompilerSignatures(allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "## Compiler-derived callable types\n\n");
    try output.appendSlice(allocator, "Types below are derived from the configured `bairava` module. Parameter names are omitted by Zig type reflection; generic type parameters appear as `type`, and inferred generic parameters as `anytype`.\n\n");

    inline for (manifest.entries) |entry| {
        const ExportType = @TypeOf(@field(bairava, entry.name));
        if (comptime @typeInfo(ExportType) != .@"fn") continue;
        try output.appendSlice(allocator, "### `bairava.");
        try output.appendSlice(allocator, entry.name);
        try output.appendSlice(allocator, "`\n\n`");
        try appendFunctionType(allocator, &output, ExportType);
        try output.appendSlice(allocator, "`\n\n");
    }
    return output.toOwnedSlice(allocator);
}

fn appendFunctionType(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    comptime FunctionType: type,
) std.mem.Allocator.Error!void {
    const function = @typeInfo(FunctionType).@"fn";
    try output.appendSlice(allocator, "fn (");
    inline for (function.params, 0..) |parameter, index| {
        if (index != 0) try output.appendSlice(allocator, ", ");
        if (parameter.type) |ParameterType| {
            try appendPublicType(allocator, output, ParameterType);
        } else {
            try output.appendSlice(allocator, "anytype");
        }
    }
    try output.appendSlice(allocator, ") ");
    if (function.return_type) |ReturnType| {
        try appendPublicType(allocator, output, ReturnType);
    } else {
        try output.appendSlice(allocator, "anytype");
    }
}

fn appendPublicType(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    comptime T: type,
) std.mem.Allocator.Error!void {
    const type_info = @typeInfo(T);
    switch (type_info) {
        .pointer => |pointer| {
            switch (pointer.size) {
                .slice => try output.appendSlice(allocator, "[]"),
                .one => try output.appendSlice(allocator, "*"),
                .many => try output.appendSlice(allocator, "[*]"),
                .c => try output.appendSlice(allocator, "[*c]"),
            }
            if (pointer.is_const) try output.appendSlice(allocator, "const ");
            return appendPublicType(allocator, output, pointer.child);
        },
        .optional => |optional| {
            try output.appendSlice(allocator, "?");
            return appendPublicType(allocator, output, optional.child);
        },
        .error_union => |error_union| {
            try output.appendSlice(allocator, "anyerror!");
            return appendPublicType(allocator, output, error_union.payload);
        },
        else => {},
    }

    const compiler_name = @typeName(T);
    inline for (manifest.entries) |entry| {
        if (comptime !std.mem.eql(u8, entry.kind, "type")) continue;
        if (comptime std.mem.endsWith(u8, compiler_name, "." ++ entry.name)) {
            try output.appendSlice(allocator, "bairava.");
            return output.appendSlice(allocator, entry.name);
        }
    }
    if (std.mem.startsWith(u8, compiler_name, "std.")) {
        return output.appendSlice(allocator, compiler_name);
    }
    if (std.mem.indexOf(u8, compiler_name, ".engine.") != null or
        std.mem.startsWith(u8, compiler_name, "engine."))
    {
        return output.appendSlice(allocator, "opaque");
    }
    return output.appendSlice(allocator, compiler_name);
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
    const signatures = try renderCompilerSignatures(allocator);
    defer allocator.free(signatures);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try output.appendSlice(allocator, markdown);
    try output.appendSlice(allocator, signatures);
    try std.Io.File.stdout().writeStreamingAll(init.io, output.items);
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

test "member checklist exposes unreviewed areas and rejects unsupported completion claims" {
    const source =
        \\const engine = @import("core/engine.zig");
        \\pub const Config = engine.Config;
    ;
    const entry = manifest.Entry{
        .name = "Config",
        .target = "engine.Config",
        .kind = "type",
        .summary = "Application settings.",
    };
    const markdown = try renderInventory(std.testing.allocator, source, &.{entry});
    defer std.testing.allocator.free(markdown);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "Member-level contract checklist") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "| `bairava.Config` | needs_review") != null);

    var invalid = entry;
    invalid.member_checklist.methods = .documented;
    try std.testing.expectError(error.InvalidMemberChecklist, validateMemberChecklist(&.{invalid}));
}
