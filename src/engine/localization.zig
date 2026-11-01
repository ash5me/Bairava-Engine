//! String translations indexed by locale and stable message key.
//!
//! Locale identifiers are case-insensitive ASCII tags normalized to lowercase (for example,
//! `fr-CA` becomes `fr-ca`). Translation keys use the engine's validated-name rules.

const std = @import("std");
const strings = @import("memory/string.zig");
const StringMap = @import("memory/hash_map.zig").StringMap;

/// A normalized locale tag, such as `en`, `fr-ca`, or `zh-hant`.
pub const LocaleId = struct {
    name: strings.Name,

    pub const Error = strings.Error || error{InvalidLocale};

    /// Validates and normalizes an ASCII locale tag to lowercase.
    pub fn init(tag: []const u8) Error!LocaleId {
        if (tag.len == 0) return error.Empty;
        if (tag.len > strings.max_name_len) return error.TooLong;

        var normalized: [strings.max_name_len]u8 = undefined;
        var previous_was_separator = true;
        for (tag, 0..) |character, index| {
            if (character == '-') {
                if (previous_was_separator) return error.InvalidLocale;
                previous_was_separator = true;
                normalized[index] = character;
                continue;
            }

            if (!std.ascii.isAlphanumeric(character)) return error.InvalidLocale;
            previous_was_separator = false;
            normalized[index] = std.ascii.toLower(character);
        }
        if (previous_was_separator) return error.InvalidLocale;

        return .{ .name = try strings.Name.init(normalized[0..tag.len]) };
    }

    /// The normalized tag. The slice is valid while this value is.
    pub fn slice(self: *const LocaleId) []const u8 {
        return self.name.slice();
    }
};

const Locale = struct {
    translations: StringMap([]const u8),

    fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!Locale {
        return .{ .translations = try StringMap([]const u8).init(allocator, 0) };
    }
};

/// Owns localized strings and resolves lookups through the active then fallback locale.
///
/// The catalog and its contents are owned by the allocator passed to `init`. Translation keys
/// follow `strings.Name` rules, and stored values are copied into catalog-owned memory.
pub const Catalog = struct {
    const LocaleMap = StringMap(Locale);

    pub const Error = std.mem.Allocator.Error || strings.Error || error{
        /// A locale or translation key is already registered.
        Duplicate,
        /// The requested locale has not been added to the catalog.
        UnknownLocale,
    };

    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    locales: LocaleMap,
    current_locale: LocaleId,
    fallback_locale: LocaleId,

    /// Creates a catalog with `fallback_tag` registered as its initial active locale.
    pub fn init(allocator: std.mem.Allocator, fallback_tag: []const u8) (Error || LocaleId.Error)!Catalog {
        const fallback = try LocaleId.init(fallback_tag);
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }

        const storage = arena.allocator();
        var locales = try LocaleMap.init(storage, 1);
        try locales.insert(fallback.slice(), .{ .translations = try StringMap([]const u8).init(storage, 0) });

        return .{
            .allocator = allocator,
            .arena = arena,
            .locales = locales,
            .current_locale = fallback,
            .fallback_locale = fallback,
        };
    }

    /// Releases the catalog and all locale, key, and translation storage.
    pub fn deinit(self: *Catalog) void {
        const allocator = self.allocator;
        const arena = self.arena;
        self.arena.deinit();
        allocator.destroy(arena);
        self.* = undefined;
    }

    /// Registers an empty locale. Locale tags are normalized by `LocaleId.init`.
    pub fn addLocale(self: *Catalog, locale_id: LocaleId) Error!void {
        if (self.locales.contains(locale_id.slice())) return error.Duplicate;

        const storage = self.arena.allocator();
        try self.locales.insert(locale_id.slice(), .{ .translations = try StringMap([]const u8).init(storage, 0) });
    }

    /// Adds one translation. Duplicate keys are errors rather than silent replacements.
    pub fn add(self: *Catalog, locale_id: LocaleId, key: []const u8, value: []const u8) Error!void {
        const locale = self.locales.getPtr(locale_id.slice()) orelse return error.UnknownLocale;
        if (locale.translations.contains(key)) return error.Duplicate;
        try strings.validateName(key);

        const owned_value = try self.arena.allocator().dupe(u8, value);
        try locale.translations.insert(key, owned_value);
    }

    /// Selects the locale used first by `lookup`.
    pub fn setLocale(self: *Catalog, locale_id: LocaleId) Error!void {
        if (!self.locales.contains(locale_id.slice())) return error.UnknownLocale;
        self.current_locale = locale_id;
    }

    /// Changes the locale consulted when the active locale has no translation.
    pub fn setFallbackLocale(self: *Catalog, locale_id: LocaleId) Error!void {
        if (!self.locales.contains(locale_id.slice())) return error.UnknownLocale;
        self.fallback_locale = locale_id;
    }

    /// Looks up a key in the active locale, then the fallback locale. Missing keys return null.
    pub fn lookup(self: *const Catalog, key: []const u8) ?[]const u8 {
        const current = self.locales.get(self.current_locale.slice()) orelse return null;
        if (current.translations.get(key)) |value| return value;
        if (std.mem.eql(u8, self.current_locale.slice(), self.fallback_locale.slice())) return null;

        const fallback = self.locales.get(self.fallback_locale.slice()) orelse return null;
        return fallback.translations.get(key);
    }
};

test "locale IDs normalize case and reject malformed tags" {
    const id = try LocaleId.init("fr-CA");
    try std.testing.expectEqualStrings("fr-ca", id.slice());
    try std.testing.expectError(error.InvalidLocale, LocaleId.init("-en"));
    try std.testing.expectError(error.InvalidLocale, LocaleId.init("en--us"));
    try std.testing.expectError(error.InvalidLocale, LocaleId.init("en_US"));
}

test "catalog looks up active strings and falls back without hiding missing keys" {
    var catalog = try Catalog.init(std.testing.allocator, "en");
    defer catalog.deinit();

    const english = try LocaleId.init("EN");
    const french = try LocaleId.init("fr-CA");
    try catalog.addLocale(french);
    try catalog.add(english, "menu/start", "Start");
    try catalog.add(french, "menu/start", "Commencer");
    try catalog.add(english, "menu/options", "Options");
    try catalog.setLocale(french);

    try std.testing.expectEqualStrings("Commencer", catalog.lookup("menu/start").?);
    try std.testing.expectEqualStrings("Options", catalog.lookup("menu/options").?);
    try std.testing.expect(catalog.lookup("menu/missing") == null);
}

test "catalog rejects duplicate translations and unknown locales" {
    var catalog = try Catalog.init(std.testing.allocator, "en");
    defer catalog.deinit();

    const english = try LocaleId.init("en");
    const missing = try LocaleId.init("de");
    try std.testing.expectError(error.UnknownLocale, catalog.setLocale(missing));
    try std.testing.expectError(error.UnknownLocale, catalog.add(missing, "menu/start", "Start"));
    try catalog.add(english, "menu/start", "Start");
    try std.testing.expectError(error.Duplicate, catalog.add(english, "menu/start", "Begin"));
}
