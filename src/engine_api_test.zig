const bairava = @import("bairava");
const std = @import("std");

test "the named Bairava module exports its public engine API" {
    _ = bairava.Config;
    _ = bairava.Context;
    _ = bairava.run;
}

test "Context does not expose a device field or SDL types" {
    const fields = @typeInfo(bairava.Context).@"struct".fields;
    inline for (fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "device")) @compileError("Context must not expose its GPU device");
    }
    expectNoSdlApi(bairava.Context);
}

test "engine resource fields do not expose SDL types" {
    expectNoSdlApi(bairava.DrawContext);
    expectNoSdlApi(bairava.Texture);
    expectNoSdlApi(bairava.SpriteBatch);
    expectNoSdlApi(bairava.LoadedAtlas);
    expectNoSdlApi(bairava.ui.Font);
    expectNoSdlApi(bairava.ui.Ui);
    expectNoSdlApi(bairava.audio.Audio);
    expectNoSdlApi(bairava.audio.Sound);
}

test "engine resource types do not publish backend operations" {
    try std.testing.expect(!@hasDecl(bairava.Texture, "createRgba8"));
    try std.testing.expect(!@hasDecl(bairava.Texture, "initTarget"));
    try std.testing.expect(!@hasDecl(bairava.SpriteBatch, "init"));
    try std.testing.expect(!@hasDecl(bairava.SpriteBatch, "upload"));
    try std.testing.expect(!@hasDecl(bairava.SpriteBatch, "draw"));
    try std.testing.expect(!@hasDecl(bairava.ui.Font, "load"));
    try std.testing.expect(!@hasDecl(bairava.ui.Font, "bake"));
}

fn expectNoSdlApi(comptime T: type) void {
    @setEvalBranchQuota(10000);
    const fields = @typeInfo(T).@"struct".fields;
    inline for (fields) |field| {
        if (comptime std.mem.indexOf(u8, @typeName(field.type), "SDL_") != null)
            @compileError("public engine fields must not expose SDL types");
    }

    const declarations = @typeInfo(T).@"struct".decls;
    inline for (declarations) |declaration| {
        const declaration_type = @typeInfo(@TypeOf(@field(T, declaration.name)));
        if (declaration_type == .@"fn") {
            const function = declaration_type.@"fn";
            inline for (function.params) |parameter| {
                if (parameter.type) |ParameterType| {
                    if (comptime std.mem.indexOf(u8, @typeName(ParameterType), "SDL_") != null)
                        @compileError("public engine method parameters must not expose SDL types");
                }
            }
            if (function.return_type) |ReturnType| {
                if (comptime std.mem.indexOf(u8, @typeName(ReturnType), "SDL_") != null)
                    @compileError("public engine method returns must not expose SDL types");
            }
        }
    }
}