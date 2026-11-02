//! Texture staging: the CPU half of loading a texture. A stage reads a texture's file and decodes it into pixels or
//! compressed blocks. It allocates only through the allocator it is given and never touches the GPU or the logger,
//! so it can run on a worker thread. The GPU upload stays on the main thread (see `Context.uploadStaged`).
//!
//! Variant order: ASTC, then BC3, then BC1, then the RGBA8 variant the asset builder wrote, then the source image,
//! decoded here. A compressed variant is used only when the device can sample its format. A variant that is missing
//! or unusable falls through to the next one, so a broken build output never stops a texture from loading.

const std = @import("std");
const image = @import("loaders/image.zig");
const platform = @import("../platform/platform.zig");

/// Reads a whole file for a stage, or reports why it can't. The engine's reader is `packagedReader`. Tests supply
/// their own, so staging can be checked without a file system.
pub const Reader = struct {
    context: *anyopaque,
    read: *const fn (context: *anyopaque, allocator: std.mem.Allocator, relative: []const u8) ReadError![]u8,
};

pub const ReadError = error{ NotFound, ReadFailed, PathTooLong, OutOfMemory };

/// Why a stage failed. A missing source image is `NotFound`; a file that is present but unreadable as an image
/// is `DecodeFailed`.
pub const Error = error{ NotFound, ReadFailed, PathTooLong, DecodeFailed, OutOfMemory, BudgetExceeded, BudgetUnavailable };

/// Thread-safe budget for decoded/staged texture payloads. Reservations remain held until the staged payload
/// is uploaded or explicitly deinitialized.
pub const Budget = struct {
    limit: usize,
    used: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    pub fn init(limit: usize) Budget {
        return .{ .limit = if (limit == 0) std.math.maxInt(usize) else limit };
    }

    pub fn usedBytes(self: *const Budget) usize {
        return self.used.load(.acquire);
    }

    fn reserve(self: *Budget, bytes: usize) error{ BudgetExceeded, BudgetUnavailable }!void {
        if (bytes > self.limit) return error.BudgetExceeded;
        var current = self.used.load(.acquire);
        while (true) {
            if (bytes > self.limit - current) return error.BudgetUnavailable;
            if (self.used.cmpxchgWeak(current, current + bytes, .acq_rel, .acquire)) |observed| {
                current = observed;
            } else {
                return;
            }
        }
    }

    fn release(self: *Budget, bytes: usize) void {
        const previous = self.used.fetchSub(bytes, .acq_rel);
        std.debug.assert(previous >= bytes);
    }
};

/// Which compressed formats the device can sample. The main thread fills this in before a stage starts, because
/// asking the device is not something a worker may do. RGBA8 is always available.
pub const Supported = struct {
    astc_4x4: bool = false,
    bc3: bool = false,
    bc1: bool = false,

    fn allows(self: Supported, format: image.Compression) bool {
        return switch (format) {
            .rgba8 => true,
            .astc_4x4 => self.astc_4x4,
            .bc3 => self.bc3,
            .bc1 => self.bc1,
        };
    }
};

/// A decoded texture, ready for `Context.uploadStaged`. The stage owns its data until `deinit`.
pub const Staged = struct {
    width: u32,
    height: u32,
    /// The format of `payload`. RGBA8 for decoded and RGBA8-variant data, otherwise the compressed format.
    format: image.Compression,
    /// The variant suffix the data came from, such as ".bc3", for debug logs. Empty for the source image.
    variant: []const u8,
    budget: ?*Budget = null,
    budget_bytes: usize = 0,
    data: union(enum) {
        /// An image decoded by stb_image. Its own `deinit` frees it.
        decoded: image.Image,
        /// Bytes read from a variant file. The allocator that read them frees them.
        blocks: image.CompressedImage,
    },

    /// The bytes to upload: RGBA8 pixels, or the compressed blocks of `format`.
    pub fn payload(self: *const Staged) []const u8 {
        return switch (self.data) {
            .decoded => |img| img.pixels,
            .blocks => |blocks| blocks.blocks,
        };
    }

    pub fn deinit(self: *Staged) void {
        switch (self.data) {
            .decoded => |*img| img.deinit(),
            .blocks => |*blocks| blocks.deinit(),
        }
        if (self.budget) |budget| budget.release(self.budget_bytes);
        self.budget = null;
        self.budget_bytes = 0;
    }
};

/// Stages the texture at `relative`, which is relative to the executable's folder: the first usable variant the
/// device supports, or else the source image. Every allocation goes through `allocator`, which must be safe to use
/// from the calling thread. A failed stage allocates nothing that it keeps.
pub fn stage(allocator: std.mem.Allocator, reader: Reader, relative: []const u8, supported: Supported) Error!Staged {
    return stageInternal(allocator, reader, relative, supported, null);
}

/// Stages a texture while reserving its retained payload against a shared streaming budget.
pub fn stageBudgeted(
    allocator: std.mem.Allocator,
    reader: Reader,
    relative: []const u8,
    supported: Supported,
    budget: *Budget,
) Error!Staged {
    return stageInternal(allocator, reader, relative, supported, budget);
}

fn stageInternal(
    allocator: std.mem.Allocator,
    reader: Reader,
    relative: []const u8,
    supported: Supported,
    budget: ?*Budget,
) Error!Staged {
    const variants = [_]struct { suffix: []const u8, format: image.Compression }{
        .{ .suffix = ".astc", .format = .astc_4x4 },
        .{ .suffix = ".bc3", .format = .bc3 },
        .{ .suffix = ".bc1", .format = .bc1 },
        .{ .suffix = ".rgba", .format = .rgba8 },
    };
    for (variants) |variant| {
        if (!supported.allows(variant.format)) continue;
        if (try stageVariant(allocator, reader, relative, variant.suffix, variant.format, budget)) |staged| return staged;
    }
    return stageSource(allocator, reader, relative, budget);
}

/// Tries one variant file. A missing or unusable file gives null, so the next variant is tried.
fn stageVariant(
    allocator: std.mem.Allocator,
    reader: Reader,
    relative: []const u8,
    suffix: []const u8,
    format: image.Compression,
    budget: ?*Budget,
) Error!?Staged {
    var name_buf: [platform.max_full_path]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{s}{s}", .{ relative, suffix }) catch return null;
    const bytes = reader.read(reader.context, allocator, name) catch |err| switch (err) {
        error.NotFound => return null,
        error.OutOfMemory => return error.OutOfMemory,
        error.PathTooLong => return error.PathTooLong,
        error.ReadFailed => return error.ReadFailed,
    };
    defer allocator.free(bytes);
    const payload_size = compressedPayloadSize(bytes, format) orelse return null;
    var reserved = false;
    if (budget) |limit| {
        limit.reserve(payload_size) catch |err| return err;
        reserved = true;
    }
    errdefer if (reserved) budget.?.release(payload_size);
    // A corrupt variant is skipped, but running out of memory is a real failure and is reported.
    const blocks = image.parseCompressed(allocator, bytes, format) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (reserved) budget.?.release(payload_size);
            reserved = false;
            return null;
        },
    };
    reserved = false;
    return .{
        .width = blocks.width,
        .height = blocks.height,
        .format = format,
        .variant = suffix,
        .budget = budget,
        .budget_bytes = if (budget != null) payload_size else 0,
        .data = .{ .blocks = blocks },
    };
}

fn stageSource(allocator: std.mem.Allocator, reader: Reader, relative: []const u8, budget: ?*Budget) Error!Staged {
    const bytes = reader.read(reader.context, allocator, relative) catch |err| return switch (err) {
        error.NotFound => error.NotFound,
        error.OutOfMemory => error.OutOfMemory,
        error.PathTooLong => error.PathTooLong,
        error.ReadFailed => error.ReadFailed,
    };
    defer allocator.free(bytes);
    const payload_size = image.decodedRgba8Size(bytes) catch |err| return switch (err) {
        error.ImageTooLarge => error.BudgetExceeded,
        else => error.DecodeFailed,
    };
    var reserved = false;
    if (budget) |limit| {
        limit.reserve(payload_size) catch |err| return err;
        reserved = true;
    }
    errdefer if (reserved) budget.?.release(payload_size);
    const decoded = image.decodeRgba8(bytes) catch return error.DecodeFailed;
    reserved = false;
    return .{
        .width = decoded.width,
        .height = decoded.height,
        .format = .rgba8,
        .variant = "",
        .budget = budget,
        .budget_bytes = if (budget != null) payload_size else 0,
        .data = .{ .decoded = decoded },
    };
}

fn compressedPayloadSize(bytes: []const u8, format: image.Compression) ?usize {
    if (bytes.len < 16 or !std.mem.eql(u8, bytes[0..4], "BRTX") or bytes[4] != @intFromEnum(format)) return null;
    const width = readU32(bytes[8..12]);
    const height = readU32(bytes[12..16]);
    if (width == 0 or height == 0) return null;
    const payload_size = if (format == .rgba8) blk: {
        const pixels = std.math.mul(usize, width, height) catch return null;
        break :blk std.math.mul(usize, pixels, 4) catch return null;
    } else blk: {
        const blocks_x = (@as(usize, width) + 3) / 4;
        const blocks_y = (@as(usize, height) + 3) / 4;
        const blocks = std.math.mul(usize, blocks_x, blocks_y) catch return null;
        const bytes_per_block: usize = if (format == .bc1) 8 else 16;
        break :blk std.math.mul(usize, blocks, bytes_per_block) catch return null;
    };
    if (bytes.len - 16 != payload_size) return null;
    return payload_size;
}

fn readU32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

fn readPackaged(context: *anyopaque, allocator: std.mem.Allocator, relative: []const u8) ReadError![]u8 {
    _ = context;
    return platform.files.readQuiet(allocator, .packaged, relative) catch |err| switch (err) {
        error.NotFound => error.NotFound,
        error.PathTooLong => error.PathTooLong,
        error.OutOfMemory => error.OutOfMemory,
        else => error.ReadFailed,
    };
}

/// Marker whose address stands in for the reader's context. The packaged reader needs no state.
var packaged_context: u8 = 0;

/// Reads shipped assets. Thread-safe: it only reads files, and it never logs.
pub fn packagedReader() Reader {
    return .{ .context = &packaged_context, .read = readPackaged };
}

// ---- Tests --------------------------------------------------------------------------------------

const fixtures = @import("../test_fixtures.zig");

/// A reader that serves a fixed set of files by name, and reports the rest as missing.
const FakeFiles = struct {
    entries: []const Entry,

    const Entry = struct { name: []const u8, bytes: []const u8 };

    fn read(context: *anyopaque, allocator: std.mem.Allocator, relative: []const u8) ReadError![]u8 {
        const self: *FakeFiles = @ptrCast(@alignCast(context));
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.name, relative)) return allocator.dupe(u8, entry.bytes) catch error.OutOfMemory;
        }
        return error.NotFound;
    }

    fn reader(self: *FakeFiles) Reader {
        return .{ .context = self, .read = read };
    }
};

test "the first variant the device supports is used" {
    const bc1 = try fixtures.compressedImageVariant(std.testing.allocator, @intFromEnum(image.Compression.bc1), 4, 4, 8);
    defer std.testing.allocator.free(bc1);
    const bc3 = try fixtures.compressedImageVariant(std.testing.allocator, @intFromEnum(image.Compression.bc3), 4, 4, 16);
    defer std.testing.allocator.free(bc3);
    var files = FakeFiles{ .entries = &.{
        .{ .name = "tile.png.bc1", .bytes = bc1 },
        .{ .name = "tile.png.bc3", .bytes = bc3 },
    } };

    var staged = try stage(std.testing.allocator, files.reader(), "tile.png", .{ .bc3 = true, .bc1 = true });
    defer staged.deinit();
    try std.testing.expectEqual(image.Compression.bc3, staged.format);
    try std.testing.expectEqualStrings(".bc3", staged.variant);
    try std.testing.expectEqual(@as(u32, 4), staged.width);
    try std.testing.expectEqual(@as(usize, 16), staged.payload().len);
}

test "a variant the device cannot sample is skipped, even when its file exists" {
    const bc3 = try fixtures.compressedImageVariant(std.testing.allocator, @intFromEnum(image.Compression.bc3), 4, 4, 16);
    defer std.testing.allocator.free(bc3);
    const bc1 = try fixtures.compressedImageVariant(std.testing.allocator, @intFromEnum(image.Compression.bc1), 4, 4, 8);
    defer std.testing.allocator.free(bc1);
    var files = FakeFiles{ .entries = &.{
        .{ .name = "tile.png.bc3", .bytes = bc3 },
        .{ .name = "tile.png.bc1", .bytes = bc1 },
    } };

    var staged = try stage(std.testing.allocator, files.reader(), "tile.png", .{ .bc1 = true });
    defer staged.deinit();
    try std.testing.expectEqual(image.Compression.bc1, staged.format);
}

test "an unusable variant falls through to the next one" {
    const bc1 = try fixtures.compressedImageVariant(std.testing.allocator, @intFromEnum(image.Compression.bc1), 4, 4, 8);
    defer std.testing.allocator.free(bc1);
    var files = FakeFiles{ .entries = &.{
        .{ .name = "tile.png.bc3", .bytes = "BRTX" },
        .{ .name = "tile.png.bc1", .bytes = bc1 },
    } };

    var staged = try stage(std.testing.allocator, files.reader(), "tile.png", .{ .bc3 = true, .bc1 = true });
    defer staged.deinit();
    try std.testing.expectEqual(image.Compression.bc1, staged.format);
}

test "budgeted staging reserves payload bytes until upload ownership is released" {
    const bc3 = try fixtures.compressedImageVariant(std.testing.allocator, @intFromEnum(image.Compression.bc3), 4, 4, 16);
    defer std.testing.allocator.free(bc3);
    var files = FakeFiles{ .entries = &.{.{ .name = "tile.png.bc3", .bytes = bc3 }} };
    var budget = Budget.init(16);

    var staged = try stageBudgeted(std.testing.allocator, files.reader(), "tile.png", .{ .bc3 = true }, &budget);
    try std.testing.expectEqual(@as(usize, 16), budget.usedBytes());
    try std.testing.expectError(error.BudgetUnavailable, stageBudgeted(std.testing.allocator, files.reader(), "tile.png", .{ .bc3 = true }, &budget));
    staged.deinit();
    try std.testing.expectEqual(@as(usize, 0), budget.usedBytes());

    var too_small = Budget.init(8);
    try std.testing.expectError(error.BudgetExceeded, stageBudgeted(std.testing.allocator, files.reader(), "tile.png", .{ .bc3 = true }, &too_small));
    try std.testing.expectEqual(@as(usize, 0), too_small.usedBytes());

    var unlimited = Budget.init(0);
    var unrestricted = try stageBudgeted(std.testing.allocator, files.reader(), "tile.png", .{ .bc3 = true }, &unlimited);
    try std.testing.expectEqual(@as(usize, 16), unlimited.usedBytes());
    unrestricted.deinit();
    try std.testing.expectEqual(@as(usize, 0), unlimited.usedBytes());
}

test "a source image that is missing reports NotFound, and one that is not an image reports DecodeFailed" {
    var none = FakeFiles{ .entries = &.{} };
    try std.testing.expectError(error.NotFound, stage(std.testing.allocator, none.reader(), "tile.png", .{}));

    var junk = FakeFiles{ .entries = &.{.{ .name = "tile.png", .bytes = "not an image" }} };
    try std.testing.expectError(error.DecodeFailed, stage(std.testing.allocator, junk.reader(), "tile.png", .{}));
}
