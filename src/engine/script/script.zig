//! Zig interface to the scripting runtime in script.h. The C code parses and runs scripts. This file gives the engine
//! and the game Zig types for values, a typed way to bind Zig functions and values, and loading and calling. The
//! language and the binding rules are in docs/scripting.md.

const std = @import("std");

const c = @cImport({
    @cInclude("script.h");
});

/// A script value: nil, a boolean, a number, or a string that points into the script's source.
pub const Value = c.bs_value;

/// The status codes the C API returns, as the C header declares them.
const status_ok: c.bs_status = @intCast(c.BS_OK);
const status_error: c.bs_status = @intCast(c.BS_ERROR);
const status_not_found: c.bs_status = @intCast(c.BS_NOT_FOUND);
const tag_number: c_uint = @intCast(c.BS_NUMBER);
const tag_string: c_uint = @intCast(c.BS_STRING);

pub fn nilValue() Value {
    return c.bs_nil();
}

pub fn boolean(value: bool) Value {
    return c.bs_bool(@intFromBool(value));
}

pub fn number(value: f64) Value {
    return c.bs_number(value);
}

/// The number in `value`, or null when it is not a number.
pub fn asNumber(value: Value) ?f64 {
    if (value.type != tag_number) return null;
    return value.as.number;
}

/// The text of `value`, or null when it is not a string. The slice is valid until the script that produced it is
/// replaced, so copy it if it must last longer.
pub fn asString(value: Value) ?[]const u8 {
    if (value.type != tag_string) return null;
    return value.as.string.ptr[0..value.as.string.len];
}

pub const Error = error{ LoadFailed, CallFailed, OutOfMemory, InvalidBinding };

/// What a host function returns when it fails. Fail the call with `Call.fail` first, so the script error says why.
pub const HostError = error{HostFailed};

/// What a host function receives: the arguments it was called with, and the means to fail the call.
pub const Call = struct {
    raw: ?*c.bs_vm,
    args: []const Value,

    /// Fails the call with `message`, which the script error shows with the line of the call. Returns the error
    /// to return from the handler.
    pub fn fail(self: Call, message: [:0]const u8) HostError {
        _ = c.bs_fail(self.raw, message.ptr);
        return error.HostFailed;
    }
};

/// A script virtual machine. It belongs to the thread that calls it, and it must be deinitialized before the
/// state its bindings point at is released.
pub const Vm = struct {
    raw: *c.bs_vm,

    /// Creates a VM. `max_steps` bounds the work one load or call may do. Zero uses the default.
    pub fn init(max_steps: usize) error{OutOfMemory}!Vm {
        // C pointers coerce to optional pointers, so the null check goes through a `?*` binding.
        const maybe: ?*c.bs_vm = c.bs_create(max_steps);
        const raw = maybe orelse return error.OutOfMemory;
        return .{ .raw = raw };
    }

    pub fn deinit(self: *Vm) void {
        c.bs_destroy(self.raw);
        self.* = undefined;
    }

    /// Compiles `source` and runs its top level. On failure the previous script stays active, and `errorText` says why.
    pub fn load(self: *Vm, name: [:0]const u8, source: []const u8) Error!void {
        if (c.bs_load(self.raw, name.ptr, source.ptr, source.len) != status_ok) return error.LoadFailed;
    }

    /// Calls a function the script defines. Returns null when the script does not define it, which is how optional
    /// hooks such as `on_update` work.
    pub fn call(self: *Vm, name: [:0]const u8, args: []const Value) Error!?Value {
        var result: Value = c.bs_nil();
        const status = c.bs_call(self.raw, name.ptr, @intCast(args.len), args.ptr, &result);
        if (status == status_not_found) return null;
        if (status != status_ok) return error.CallFailed;
        return result;
    }

    /// The value of a top-level variable, or null when the script does not define it.
    pub fn global(self: *Vm, name: [:0]const u8) ?Value {
        var out: Value = c.bs_nil();
        if (c.bs_get_global(self.raw, name.ptr, &out) != status_ok) return null;
        return out;
    }

    /// The last error message, such as "hud.bs:4: unknown name 'x'". Empty when there was none.
    pub fn errorText(self: *const Vm) []const u8 {
        return std.mem.span(c.bs_error(self.raw));
    }
};

/// Binds Zig functions and values into a VM. `Ctx` is the state the handlers receive, such as the game's bridge. The
/// binding stores a pointer to `ctx`, so `ctx` must outlive every call the VM can make.
pub fn Bindings(comptime Ctx: type) type {
    return struct {
        /// Binds `name` as a function that takes `min` to `max` arguments. `handler` runs for each call.
        pub fn function(
            vm: *Vm,
            name: [:0]const u8,
            min: u8,
            max: u8,
            ctx: *Ctx,
            comptime handler: fn (*Ctx, Call) HostError!Value,
        ) Error!void {
            const Thunk = struct {
                fn call(
                    raw: ?*c.bs_vm,
                    user: ?*anyopaque,
                    argc: c_int,
                    argv: [*c]const c.bs_value,
                    result: [*c]c.bs_value,
                ) callconv(.c) c.bs_status {
                    const typed: *Ctx = @ptrCast(@alignCast(user.?));
                    const args: []const Value = if (argc == 0) &.{} else argv[0..@intCast(argc)];
                    const value_read = handler(typed, .{ .raw = raw, .args = args }) catch |err| {
                        // A handler that called Call.fail has already set the message. Any other error gets its name.
                        if (err != error.HostFailed) _ = c.bs_fail(raw, @errorName(err).ptr);
                        return status_error;
                    };
                    result[0] = value_read;
                    return status_ok;
                }
            };
            if (c.bs_bind_function(vm.raw, name.ptr, min, max, Thunk.call, ctx) != status_ok) return error.InvalidBinding;
        }

        /// Binds `name` as a value that scripts read as a bare name. `getter` runs each time the name is read.
        pub fn value(vm: *Vm, name: [:0]const u8, ctx: *Ctx, comptime getter: fn (*Ctx) HostError!Value) Error!void {
            const Thunk = struct {
                fn call(
                    raw: ?*c.bs_vm,
                    user: ?*anyopaque,
                    argc: c_int,
                    argv: [*c]const c.bs_value,
                    result: [*c]c.bs_value,
                ) callconv(.c) c.bs_status {
                    _ = argc;
                    _ = argv;
                    const typed: *Ctx = @ptrCast(@alignCast(user.?));
                    const value_read = getter(typed) catch |err| {
                        if (err != error.HostFailed) _ = c.bs_fail(raw, @errorName(err).ptr);
                        return status_error;
                    };
                    result[0] = value_read;
                    return status_ok;
                }
            };
            if (c.bs_bind_getter(vm.raw, name.ptr, Thunk.call, ctx) != status_ok) return error.InvalidBinding;
        }
    };
}

test "values report their type and read back their contents" {
    try std.testing.expectEqual(@as(?f64, 2.5), asNumber(number(2.5)));
    try std.testing.expectEqual(@as(?f64, null), asNumber(boolean(true)));
    const text: []const u8 = "hello";
    try std.testing.expectEqualStrings("hello", asString(c.bs_string(text.ptr, text.len)).?);
    try std.testing.expect(asString(nilValue()) == null);
}

test "a script calls a bound Zig function and reads a bound value" {
    const Game = struct {
        clicks: f64 = 4,
        logged: usize = 0,

        fn add(self: *@This(), call: Call) HostError!Value {
            _ = self;
            const a = asNumber(call.args[0]) orelse return call.fail("add needs a number");
            const b = asNumber(call.args[1]) orelse return call.fail("add needs a number");
            return number(a + b);
        }

        fn clicksValue(self: *@This()) HostError!Value {
            return number(self.clicks);
        }
    };

    var game = Game{};
    var vm = try Vm.init(0);
    defer vm.deinit();
    const bind = Bindings(Game);
    try bind.function(&vm, "add", 2, 2, &game, Game.add);
    try bind.value(&vm, "clicks", &game, Game.clicksValue);
    try vm.load("test.bs", "var total = add(clicks, 3);\nfn bump() { return add(1, 1); }\n");

    try std.testing.expectEqual(@as(?f64, 7), asNumber(vm.global("total").?));
    const result = (try vm.call("bump", &.{})).?;
    try std.testing.expectEqual(@as(?f64, 2), asNumber(result));
    try std.testing.expect((try vm.call("no_such_hook", &.{})) == null);
}

test "a host failure reaches the script error with its line" {
    const Game = struct {
        fn refuse(_: *@This(), call: Call) HostError!Value {
            return call.fail("the door is locked");
        }
    };
    var game = Game{};
    var vm = try Vm.init(0);
    defer vm.deinit();
    try Bindings(Game).function(&vm, "open", 0, 0, &game, Game.refuse);
    try std.testing.expectError(error.LoadFailed, vm.load("test.bs", "var x = 1;\nvar y = open();\n"));
    try std.testing.expect(std.mem.indexOf(u8, vm.errorText(), "test.bs:2: the door is locked") != null);
}
