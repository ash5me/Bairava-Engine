const bairava = @import("bairava");
const std = @import("std");
const controls = @import("game/controls.zig");

test "the named Bairava module exports its public engine API" {
    _ = bairava.Config;
    _ = bairava.Context;
    _ = bairava.Capabilities;
    _ = bairava.ShaderFormats;
    _ = bairava.TextureFormats;
    _ = bairava.PresentationCapabilities;
    _ = bairava.Event;
    _ = bairava.Scancode;
    _ = bairava.GamepadId;
    _ = bairava.TextInput;
    _ = bairava.run;
    _ = bairava.version;
    _ = bairava.transform.Transform;
    _ = bairava.ui.TextLayout;
    _ = bairava.ui.TextAlignment;
    _ = bairava.localization.LocaleId;
    _ = bairava.localization.Catalog;
    _ = bairava.particles.System;
    _ = bairava.particles.Config;
    _ = bairava.ShadowSegment;
}

test "the public engine version is the initial semantic API version" {
    try std.testing.expectEqual(@as(u16, 0), bairava.version.major);
    try std.testing.expectEqual(@as(u16, 1), bairava.version.minor);
    try std.testing.expectEqual(@as(u16, 0), bairava.version.patch);
}

test "transforms compose through an entity hierarchy" {
    var hierarchy = bairava.transform.Hierarchy.init(std.testing.allocator);
    defer hierarchy.deinit();

    const parent = try hierarchy.spawn(.{ .position = .{ 10.0, 20.0, 0.0 } });
    const child = try hierarchy.spawn(.{ .position = .{ 3.0, 4.0, 0.0 } });
    try hierarchy.setParent(child, parent);
    const matrix = try hierarchy.worldMatrix(child);
    const point = bairava.math.transformPoint(&matrix, 0.0, 0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 13.0), point[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 24.0), point[1], 1e-5);
}

test "Context does not expose a device field or SDL types" {
    const fields = @typeInfo(bairava.Context).@"struct".fields;
    inline for (fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "device")) @compileError("Context must not expose its GPU device");
    }
    expectNoSdlApi(bairava.Context);
    expectNoSdlApi(bairava.Capabilities);
    expectNoSdlApi(bairava.PresentationCapabilities);
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
    expectNoSdlApi(bairava.Input);
}

test "the action map and its bindings expose no SDL types" {
    const Action = enum { jump };
    expectNoSdlApi(bairava.ActionMap(Action));
    inline for (@typeInfo(bairava.Binding).@"union".fields) |field| {
        if (comptime std.mem.indexOf(u8, @typeName(field.type), "SDL_") != null)
            @compileError("bindings must not carry SDL types");
    }
    try std.testing.expect(@hasDecl(bairava.ActionMap(Action), "pressed"));
    try std.testing.expect(@hasDecl(bairava.ActionMap(Action), "value"));
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

test "texture handles and the context's texture functions expose no SDL types" {
    expectNoSdlApi(bairava.TextureHandle);
    try std.testing.expect(@hasDecl(bairava.Context, "registerTexture"));
    try std.testing.expect(@hasDecl(bairava.Context, "acquireTexture"));
    try std.testing.expect(@hasDecl(bairava.Context, "textureOf"));
    try std.testing.expect(@hasDecl(bairava.Context, "retainTexture"));
    try std.testing.expect(@hasDecl(bairava.Context, "releaseTexture"));
    try std.testing.expect(@hasDecl(bairava.Context, "requestTexture"));
}

test "Context exposes an SDL-free runtime capabilities query" {
    try std.testing.expect(@hasDecl(bairava.Context, "capabilities"));
    try std.testing.expect(@hasField(bairava.Capabilities, "audio_playback"));
    try std.testing.expect(@hasField(bairava.Capabilities, "shader_formats"));
    try std.testing.expect(@hasField(bairava.Capabilities, "texture_formats"));
    try std.testing.expect(@hasField(bairava.Capabilities, "presentation"));
    try std.testing.expect(@hasField(bairava.ShaderFormats, "spirv"));
    try std.testing.expect(@hasField(bairava.TextureFormats, "astc_4x4"));
    try std.testing.expect(@hasField(bairava.TextureFormats, "rgba8"));
    try std.testing.expect(@hasField(bairava.PresentationCapabilities, "immediate"));
}

test "Context exposes SDL-independent typed game events" {
    try std.testing.expect(@hasDecl(bairava.Context, "pollEvent"));
    try std.testing.expect(@typeInfo(bairava.Event) == .@"union");
    try std.testing.expect(@hasField(bairava.Event, "key_down"));
    try std.testing.expect(@hasField(bairava.Event, "gamepad_axis"));
    try std.testing.expect(@hasField(bairava.Event, "text_input"));
    try std.testing.expect(std.mem.indexOf(u8, @typeName(bairava.Event), "SDL_") == null);
    expectNoSdlApi(bairava.GamepadId);
    expectNoSdlApi(bairava.TextInput);
}

test "game rebinding rolls back when saving settings fails" {
    var context: bairava.Context = undefined;
    context.allocators.frame = std.testing.allocator;
    context.settings_file = "../unsafe.txt";
    context.settings_text = "resolution = 960x540\n";

    var bindings = controls.load(context.settings_text);
    const previous = bindings.bindingsOf(.move_left)[0];
    try std.testing.expectError(
        error.WriteFailed,
        controls.rebind(&context, &bindings, .move_left, &.{.{ .key = .q }}),
    );
    try std.testing.expectEqual(previous, bindings.bindingsOf(.move_left)[0]);
}

test "Canvas text layout validates dimensions through the public UI API" {
    var font = bairava.ui.Font{
        .baked = .{ .line_height = 10 },
        .texture = undefined,
        .uploaded_generation = 0,
    };
    const canvas = bairava.ui.Canvas{
        .allocator = std.testing.allocator,
        .font = &font,
        .list = undefined,
    };
    try std.testing.expectError(error.InvalidWidth, canvas.layoutText(std.testing.allocator, "text", 0, .left));
}
