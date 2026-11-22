//! TB-11 validates immediate-mode UI, live locale changes, fallback, text wrapping, and script rendering.

const std = @import("std");
const engine = @import("bairava");

const log = engine.log.scoped("tb11");
const Color = engine.ui.Color;
const white = Color{ .r = 0.94, .g = 0.95, .b = 0.98, .a = 1 };
const muted = Color{ .r = 0.62, .g = 0.69, .b = 0.77, .a = 1 };
const panel_color = Color{ .r = 0.055, .g = 0.075, .b = 0.11, .a = 0.96 };
const accent = Color{ .r = 0.24, .g = 0.38, .b = 0.54, .a = 0.9 };

const Page = enum(u8) { inventory, settings, dialogue };
const Locale = enum(u8) { english, french, tamil };

const config = engine.Config{
    .title = "Bairava TB-11 UI and Localization",
    .window_w = 960,
    .window_h = 540,
    .native_w = 320,
    .native_h = 180,
    .clear_rgb = .{ 0.025, 0.035, 0.055 },
    .settings_file = "tb11_settings.txt",
};

var bounded_frames: ?u64 = null;

const translations = [_]struct { locale: Locale, key: []const u8, value: []const u8 }{
    .{ .locale = .english, .key = "title", .value = "Field Journal" },
    .{ .locale = .english, .key = "nav.inventory", .value = "Inventory" },
    .{ .locale = .english, .key = "nav.settings", .value = "Settings" },
    .{ .locale = .english, .key = "nav.dialogue", .value = "Dialogue" },
    .{ .locale = .english, .key = "nav.language", .value = "Language" },
    .{ .locale = .english, .key = "nav.next", .value = "Next page" },
    .{ .locale = .english, .key = "inventory.title", .value = "Traveler's Pack" },
    .{ .locale = .english, .key = "inventory.items", .value = "Items carried:" },
    .{ .locale = .english, .key = "inventory.contents", .value = "Tonic x1   Map x1" },
    .{ .locale = .english, .key = "inventory.potion", .value = "Use tonic" },
    .{ .locale = .english, .key = "inventory.empty", .value = "Your pack is empty." },
    .{ .locale = .english, .key = "settings.title", .value = "Settings" },
    .{ .locale = .english, .key = "settings.volume", .value = "Volume" },
    .{ .locale = .english, .key = "settings.scale", .value = "Scale mode" },
    .{ .locale = .english, .key = "settings.scale.fit", .value = "Fit" },
    .{ .locale = .english, .key = "settings.scale.integer", .value = "Integer" },
    .{ .locale = .english, .key = "settings.scale.toggle", .value = "Toggle scaling" },
    .{ .locale = .english, .key = "dialogue.title", .value = "A note from the keeper" },
    .{ .locale = .english, .key = "dialogue.body", .value = "The northern road is open again. Take care near the old stone bridge, and return before the evening bell." },
    .{ .locale = .english, .key = "dialogue.body.alt", .value = "A fresh map is waiting at the gate. Follow the river until the watchtower comes into view." },
    .{ .locale = .english, .key = "dialogue.next", .value = "Continue" },
    .{ .locale = .english, .key = "locale.name", .value = "English" },
    .{ .locale = .english, .key = "fallback.notice", .value = "This text uses the fallback locale." },
    .{ .locale = .french, .key = "title", .value = "Carnet de voyage" },
    .{ .locale = .french, .key = "nav.inventory", .value = "Inventaire" },
    .{ .locale = .french, .key = "nav.settings", .value = "Paramètres" },
    .{ .locale = .french, .key = "nav.dialogue", .value = "Dialogue" },
    .{ .locale = .french, .key = "nav.language", .value = "Langue" },
    .{ .locale = .french, .key = "nav.next", .value = "Page suivante" },
    .{ .locale = .french, .key = "inventory.title", .value = "Sac du voyageur" },
    .{ .locale = .french, .key = "inventory.items", .value = "Objets transportés :" },
    .{ .locale = .french, .key = "inventory.contents", .value = "Tonique x1   Carte x1" },
    .{ .locale = .french, .key = "inventory.potion", .value = "Prendre tonique" },
    .{ .locale = .french, .key = "inventory.empty", .value = "Votre sac est vide." },
    .{ .locale = .french, .key = "settings.title", .value = "Paramètres" },
    .{ .locale = .french, .key = "settings.volume", .value = "Volume" },
    .{ .locale = .french, .key = "settings.scale", .value = "Mode de mise à l'échelle" },
    .{ .locale = .french, .key = "settings.scale.fit", .value = "Ajusté" },
    .{ .locale = .french, .key = "settings.scale.integer", .value = "Entier" },
    .{ .locale = .french, .key = "settings.scale.toggle", .value = "Changer l'échelle" },
    .{ .locale = .french, .key = "dialogue.title", .value = "Un mot du gardien" },
    .{ .locale = .french, .key = "dialogue.body", .value = "La route du nord est de nouveau ouverte. Prenez garde près du vieux pont de pierre et revenez avant la cloche du soir." },
    .{ .locale = .french, .key = "dialogue.body.alt", .value = "Une nouvelle carte vous attend à la porte. Suivez la rivière jusqu'à voir la tour de garde." },
    .{ .locale = .french, .key = "dialogue.next", .value = "Continuer" },
    .{ .locale = .french, .key = "locale.name", .value = "Français" },
    .{ .locale = .tamil, .key = "title", .value = "பயணக் குறிப்பு" },
    .{ .locale = .tamil, .key = "nav.inventory", .value = "பொருட்கள்" },
    .{ .locale = .tamil, .key = "nav.settings", .value = "அமைப்புகள்" },
    .{ .locale = .tamil, .key = "nav.dialogue", .value = "உரையாடல்" },
    .{ .locale = .tamil, .key = "nav.language", .value = "மொழி" },
    .{ .locale = .tamil, .key = "nav.next", .value = "அடுத்த பக்கம்" },
    .{ .locale = .tamil, .key = "inventory.title", .value = "பயணியின் பை" },
    .{ .locale = .tamil, .key = "inventory.items", .value = "பொருட்கள்:" },
    .{ .locale = .tamil, .key = "inventory.contents", .value = "மருந்து x1   வரைபடம் x1" },
    .{ .locale = .tamil, .key = "inventory.potion", .value = "மருந்து" },
    .{ .locale = .tamil, .key = "inventory.empty", .value = "பை காலியாக உள்ளது." },
    .{ .locale = .tamil, .key = "settings.title", .value = "அமைப்புகள்" },
    .{ .locale = .tamil, .key = "settings.volume", .value = "ஒலி" },
    .{ .locale = .tamil, .key = "settings.scale", .value = "திரை அளவு" },
    .{ .locale = .tamil, .key = "settings.scale.fit", .value = "பொருத்து" },
    .{ .locale = .tamil, .key = "settings.scale.integer", .value = "முழு எண்" },
    .{ .locale = .tamil, .key = "settings.scale.toggle", .value = "அளவை மாற்று" },
    .{ .locale = .tamil, .key = "dialogue.title", .value = "காவலரின் செய்தி" },
    .{ .locale = .tamil, .key = "dialogue.body", .value = "வடக்குப் பாதை மீண்டும் திறக்கப்பட்டுள்ளது. பழைய கல் பாலத்தின் அருகே கவனமாக இருங்கள்; மாலை மணி அடிக்கும் முன் திரும்புங்கள்." },
    .{ .locale = .tamil, .key = "dialogue.body.alt", .value = "வாயிலில் புதிய வரைபடம் காத்திருக்கிறது. காவல் கோபுரம் தெரியும் வரை ஆற்றைப் பின்தொடருங்கள்." },
    .{ .locale = .tamil, .key = "dialogue.next", .value = "தொடரவும்" },
    .{ .locale = .tamil, .key = "locale.name", .value = "தமிழ்" },
    .{ .locale = .english, .key = "locale.hint", .value = "Q/E changes language" },
    .{ .locale = .french, .key = "locale.hint", .value = "Q/E change la langue" },
    .{ .locale = .tamil, .key = "locale.hint", .value = "Q/E மொழியை மாற்றும்" },
};

const Tb11 = struct {
    allocator: std.mem.Allocator,
    catalog: engine.localization.Catalog,
    english_id: engine.localization.LocaleId,
    french_id: engine.localization.LocaleId,
    tamil_id: engine.localization.LocaleId,
    latin_ui: engine.ui.Ui,
    tamil_ui: engine.ui.Ui,
    content: engine.ui.Canvas,
    tamil_content: engine.ui.Canvas,
    page: Page = .inventory,
    page_focus: u8 = 0,
    locale: Locale = .english,
    scale_integer: bool = false,
    items: u32 = 3,
    volume: f32 = 0.7,
    dialogue_page: u32 = 0,
    dialogue_layout: engine.ui.TextLayout,
    dialogue_layout_ready: bool = false,
    long_layout_checks: u64 = 0,
    long_layout_failures: u64 = 0,
    fallback_checks: u64 = 0,
    fallback_failures: u64 = 0,
    locale_switches: u64 = 0,
    keyboard_page_switches: u64 = 0,
    pointer_page_switches: u64 = 0,
    inventory_actions: u64 = 0,
    settings_actions: u64 = 0,
    dialogue_actions: u64 = 0,
    ui_quad_drops: u64 = 0,
    report_written: bool = false,

    pub fn init(ctx: *engine.Context) !Tb11 {
        const allocator = ctx.allocators.game;
        var catalog = try engine.localization.Catalog.init(allocator, "en");
        var catalog_owned = true;
        errdefer if (catalog_owned) catalog.deinit();
        const english_id = try engine.localization.LocaleId.init("en");
        const french_id = try engine.localization.LocaleId.init("fr");
        const tamil_id = try engine.localization.LocaleId.init("ta");
        try catalog.addLocale(french_id);
        try catalog.addLocale(tamil_id);
        for (translations) |entry| {
            const id = switch (entry.locale) {
                .english => english_id,
                .french => french_id,
                .tamil => tamil_id,
            };
            try catalog.add(id, entry.key, entry.value);
        }

        const latin_font = try ctx.loadFont("assets/ui_font_9px.bfnt", 9);
        const tamil_font = try ctx.loadOutlineFont("assets/fonts/ChemmozhiParanar.ttf", 16);
        const latin_ui = engine.ui.Ui.init(allocator, ctx.fonts, latin_font);
        const tamil_ui = engine.ui.Ui.init(allocator, ctx.fonts, tamil_font);
        const content = engine.ui.Canvas.create(allocator, ctx.fonts, latin_font);
        const tamil_content = engine.ui.Canvas.create(allocator, ctx.fonts, tamil_font);

        var self = Tb11{
            .allocator = allocator,
            .catalog = catalog,
            .english_id = english_id,
            .french_id = french_id,
            .tamil_id = tamil_id,
            .latin_ui = latin_ui,
            .tamil_ui = tamil_ui,
            .content = content,
            .tamil_content = tamil_content,
            .dialogue_layout = undefined,
        };
        catalog_owned = false;
        errdefer self.deinit();
        self.verifyCatalog();
        try self.verifyLayouts();
        try self.refreshDialogue();
        return self;
    }

    pub fn update(self: *Tb11, ctx: *engine.Context, _: *engine.SceneNavigator) void {
        if (ctx.input.wasPressed(.escape)) ctx.running = false;
        if (ctx.input.wasPressed(.up)) self.page_focus = (self.page_focus + 2) % 3;
        if (ctx.input.wasPressed(.down)) self.page_focus = (self.page_focus + 1) % 3;
        if (ctx.input.wasPressed(.enter) or ctx.input.wasPressed(.space)) {
            self.page = @enumFromInt(self.page_focus);
            self.keyboard_page_switches += 1;
        }
        if (ctx.input.wasPressed(.tab)) {
            self.page_focus = (self.page_focus + 1) % 3;
            self.page = @enumFromInt(self.page_focus);
            self.keyboard_page_switches += 1;
        }
        if (ctx.input.wasPressed(.q)) self.cycleLocale(-1, ctx);
        if (ctx.input.wasPressed(.e)) self.cycleLocale(1, ctx);
        if (self.page == .settings) {
            if (ctx.input.wasPressed(.left)) self.volume = @max(0, self.volume - 0.05);
            if (ctx.input.wasPressed(.right)) self.volume = @min(1, self.volume + 0.05);
        }

        self.buildWidgets(ctx);
        if (self.page == .settings) ctx.scale_mode = if (self.scale_integer) .integer else .fit;
        if (ctx.diagnostics.snapshot.frames >= 360 and !self.report_written) self.report(ctx);
        if (bounded_frames) |limit| {
            if (ctx.diagnostics.snapshot.frames >= limit) ctx.running = false;
        }
    }

    fn buildWidgets(self: *Tb11, ctx: *engine.Context) void {
        var ui = self.activeUi();
        ui.begin(ctx.input, ctx.layout, 8, 24, 126);
        if (ui.button(self.lookup("nav.language"))) self.cycleLocale(1, ctx);
        if (ui.button(self.lookup("nav.next"))) {
            self.page = @enumFromInt((@intFromEnum(self.page) + 1) % 3);
            self.page_focus = @intFromEnum(self.page);
            self.pointer_page_switches += 1;
        }
        if (self.page == .settings) {
            _ = ui.slider(self.lookup("settings.volume"), &self.volume, 0, 1);
            if (ui.button(self.lookup("settings.scale.toggle"))) {
                self.scale_integer = !self.scale_integer;
                self.settings_actions += 1;
            }
        } else if (self.page == .inventory) {
            var label_buf: [96]u8 = undefined;
            const dynamic_label = std.fmt.bufPrint(&label_buf, "{s} ({d})##use-item", .{
                self.lookup("inventory.potion"),
                self.items,
            }) catch self.lookup("inventory.potion");
            if (ui.button(dynamic_label) and self.items > 0) {
                self.items -= 1;
                self.inventory_actions += 1;
            }
        } else {
            if (ui.button(self.lookup("dialogue.next"))) {
                self.dialogue_page = (self.dialogue_page + 1) % 2;
                self.dialogue_actions += 1;
                self.refreshDialogue() catch |err| {
                    log.err("could not update dialogue page: {s}", .{@errorName(err)});
                };
            }
        }
        ui.end();
        self.ui_quad_drops += @intCast(@max(ui.ctx.list.dropped, 0));
    }

    pub fn draw(self: *Tb11, dc: *const engine.DrawContext) void {
        var content_canvas = self.activeContent();
        content_canvas.clear();
        content_canvas.rect(142, 20, 170, 152, panel_color);
        content_canvas.rect(142, 20, 170, 2, accent);
        content_canvas.text(150, 28, self.lookup("title"), white);
        content_canvas.text(150, 40, self.lookup(self.pageTitleKey()), muted);
        switch (self.page) {
            .inventory => self.drawInventory(content_canvas),
            .settings => self.drawSettings(content_canvas),
            .dialogue => self.drawDialogue(content_canvas),
        }
        content_canvas.queue(dc.batch, 900);
        self.activeUi().queue(dc.batch, 1000);
    }

    fn drawInventory(self: *Tb11, canvas: *engine.ui.Canvas) void {
        var count_text: [80]u8 = undefined;
        const status = if (self.items == 0)
            self.lookup("inventory.empty")
        else
            std.fmt.bufPrint(&count_text, "{s} {d}", .{ self.lookup("inventory.items"), self.items }) catch self.lookup("inventory.items");
        canvas.text(150, 62, status, white);
        if (self.items > 0) canvas.text(150, 80, self.lookup("inventory.contents"), muted);
        self.drawLocaleIndicator(canvas, 150, 148);
    }

    fn drawSettings(self: *Tb11, canvas: *engine.ui.Canvas) void {
        canvas.text(150, 62, self.lookup("settings.volume"), white);
        var volume_text: [48]u8 = undefined;
        const text = std.fmt.bufPrint(&volume_text, "{d:.0}%", .{self.volume * 100}) catch "0%";
        canvas.text(150, 76, text, muted);
        const scale_text = if (self.scale_integer) self.lookup("settings.scale.integer") else self.lookup("settings.scale.fit");
        canvas.text(150, 94, self.lookup("settings.scale"), white);
        canvas.text(150, 108, scale_text, muted);
        canvas.text(150, 126, self.lookup("settings.scale.toggle"), muted);
    }

    fn drawDialogue(self: *Tb11, canvas: *engine.ui.Canvas) void {
        canvas.text(150, 60, self.lookup("dialogue.title"), white);
        if (self.locale == .tamil) {
            self.tamil_content.drawTextLayout(150, 76, &self.dialogue_layout, white);
        } else {
            canvas.drawTextLayout(150, 76, &self.dialogue_layout, white);
        }
        canvas.text(150, 148, self.lookup("dialogue.next"), muted);
        self.drawLocaleIndicator(canvas, 150, 160);
    }

    fn drawLocaleIndicator(self: *Tb11, canvas: *engine.ui.Canvas, x: f32, y: f32) void {
        var text_buf: [96]u8 = undefined;
        const text = std.fmt.bufPrint(&text_buf, "{s}  |  {s}", .{ self.lookup("locale.name"), self.lookup("locale.hint") }) catch self.lookup("locale.name");
        canvas.text(x, y, text, muted);
    }

    pub fn debugText(self: *const Tb11, out: *engine.diagnostics.Text) void {
        out.print("TB-11 {s} / {s} | Up/Down + Enter pages, Q/E locale, mouse widgets, Escape quits", .{
            @tagName(self.page),
            @tagName(self.locale),
        });
        out.print("fallback {d}/{d} errors {d}; wrap {d}/{d} errors {d}; keyboard/pointer switches {d}/{d}; UI drops {d}", .{
            self.fallback_checks - self.fallback_failures,
            self.fallback_checks,
            self.fallback_failures,
            self.long_layout_checks - self.long_layout_failures,
            self.long_layout_checks,
            self.long_layout_failures,
            self.keyboard_page_switches,
            self.pointer_page_switches,
            self.ui_quad_drops,
        });
    }

    pub fn deinit(self: *Tb11) void {
        if (self.dialogue_layout_ready) self.dialogue_layout.deinit();
        self.tamil_content.deinit();
        self.content.deinit();
        self.tamil_ui.deinit();
        self.latin_ui.deinit();
        self.catalog.deinit();
    }

    fn activeUi(self: *Tb11) *engine.ui.Ui {
        return if (self.locale == .tamil) &self.tamil_ui else &self.latin_ui;
    }

    fn activeContent(self: *Tb11) *engine.ui.Canvas {
        return if (self.locale == .tamil) &self.tamil_content else &self.content;
    }

    fn setLocale(self: *Tb11, locale: Locale, ctx: *engine.Context) void {
        if (self.locale == locale) return;
        const previous = self.locale;
        const id = self.localeId(locale);
        self.catalog.setLocale(id) catch |err| {
            log.err("could not select locale {s}: {s}", .{ id.slice(), @errorName(err) });
            return;
        };
        self.locale = locale;
        self.refreshDialogue() catch |err| {
            self.locale = previous;
            self.catalog.setLocale(self.localeId(previous)) catch |restore_err| {
                log.err("could not restore locale after layout failure: {s}", .{@errorName(restore_err)});
            };
            log.err("could not lay out localized dialogue: {s}", .{@errorName(err)});
            return;
        };
        self.locale_switches += 1;
        _ = ctx;
    }

    fn cycleLocale(self: *Tb11, direction: i32, ctx: *engine.Context) void {
        const current: i32 = @intFromEnum(self.locale);
        const next = @mod(current + direction + 3, 3);
        self.setLocale(@enumFromInt(next), ctx);
    }

    fn localeId(self: *const Tb11, locale: Locale) engine.localization.LocaleId {
        return switch (locale) {
            .english => self.english_id,
            .french => self.french_id,
            .tamil => self.tamil_id,
        };
    }

    fn lookup(self: *const Tb11, key: []const u8) []const u8 {
        return self.catalog.lookup(key) orelse key;
    }

    fn pageTitleKey(self: *const Tb11) []const u8 {
        return switch (self.page) {
            .inventory => "inventory.title",
            .settings => "settings.title",
            .dialogue => "dialogue.title",
        };
    }

    fn refreshDialogue(self: *Tb11) !void {
        const canvas = if (self.locale == .tamil) &self.tamil_content else &self.content;
        const key = if (self.dialogue_page == 0) "dialogue.body" else "dialogue.body.alt";
        const next = try canvas.layoutText(self.allocator, self.lookup(key), 148, .left);
        if (self.dialogue_layout_ready) self.dialogue_layout.deinit();
        self.dialogue_layout = next;
        self.dialogue_layout_ready = true;
        self.long_layout_checks += 1;
        if (self.dialogue_layout.lines.len < 2) self.long_layout_failures += 1;
    }

    fn verifyCatalog(self: *Tb11) void {
        const locales = [_]Locale{ .english, .french, .tamil };
        for (locales) |locale| {
            self.catalog.setLocale(self.localeId(locale)) catch |err| {
                log.err("locale validation could not select locale: {s}", .{@errorName(err)});
                self.fallback_failures += 1;
                continue;
            };
            self.fallback_checks += 1;
            if (!std.mem.eql(u8, self.catalog.lookup("fallback.notice") orelse "", "This text uses the fallback locale.")) self.fallback_failures += 1;
            self.fallback_checks += 1;
            if (self.catalog.lookup("intentionally.missing") != null) self.fallback_failures += 1;
        }
        self.catalog.setLocale(self.english_id) catch |err| {
            log.err("could not restore fallback locale: {s}", .{@errorName(err)});
            self.fallback_failures += 1;
        };
    }

    fn verifyLayouts(self: *Tb11) !void {
        const locales = [_]Locale{ .english, .french, .tamil };
        for (locales) |locale| {
            self.catalog.setLocale(self.localeId(locale)) catch |err| {
                log.err("text-layout validation could not select locale: {s}", .{@errorName(err)});
                self.long_layout_checks += 1;
                self.long_layout_failures += 1;
                continue;
            };
            const canvas = if (locale == .tamil) &self.tamil_content else &self.content;
            var layout = try canvas.layoutText(self.allocator, self.lookup("dialogue.body"), 148, .left);
            const line_count = layout.lines.len;
            layout.deinit();
            self.long_layout_checks += 1;
            if (line_count < 2) self.long_layout_failures += 1;
        }
        try self.catalog.setLocale(self.english_id);
    }

    fn report(self: *Tb11, ctx: *engine.Context) void {
        const pass = self.fallback_failures == 0 and self.fallback_checks == 6 and
            self.long_layout_failures == 0 and self.long_layout_checks >= 4 and self.ui_quad_drops == 0;
        const result: []const u8 = if (pass) "pass" else "incomplete";
        log.info("TB-11 {s}: fallback {d}/{d}, wrapped locales {d}/{d}, locale switches {d}, keyboard/pointer page switches {d}/{d}, UI drops {d}; localized images and sounds unsupported", .{
            result,
            self.fallback_checks - self.fallback_failures,
            self.fallback_checks,
            self.long_layout_checks - self.long_layout_failures,
            self.long_layout_checks,
            self.locale_switches,
            self.keyboard_page_switches,
            self.pointer_page_switches,
            self.ui_quad_drops,
        });
        var json: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(
            &json,
            "{{\"testbed\":\"TB-11\",\"scenario\":\"ui-localization\",\"result\":\"{s}\",\"fallback_checks\":{d},\"fallback_failures\":{d},\"wrapped_locale_checks\":{d},\"wrap_failures\":{d},\"locale_switches\":{d},\"keyboard_page_switches\":{d},\"pointer_page_switches\":{d},\"inventory_actions\":{d},\"settings_actions\":{d},\"dialogue_actions\":{d},\"ui_quad_drops\":{d},\"localized_images_supported\":false,\"localized_sounds_supported\":false}}\n",
            .{
                result,
                self.fallback_checks,
                self.fallback_failures,
                self.long_layout_checks,
                self.long_layout_failures,
                self.locale_switches,
                self.keyboard_page_switches,
                self.pointer_page_switches,
                self.inventory_actions,
                self.settings_actions,
                self.dialogue_actions,
                self.ui_quad_drops,
            },
        ) catch |err| {
            log.err("TB-11 metrics formatting failed: {s}", .{@errorName(err)});
            return;
        };
        ctx.writeFile("TB-11-ui-localization-results.json", text) catch |err| {
            log.err("TB-11 metrics write failed: {s}", .{@errorName(err)});
            return;
        };
        self.report_written = true;
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const args = init.args.toSlice(arena_state.allocator()) catch return error.InvalidArgument;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--help")) {
            std.debug.print("TB-11 options: --frames 360. Up/Down + Enter changes pages; Tab cycles; Q/E or Language switches locale; click Next page to cycle screens. Escape quits.\n", .{});
            return;
        } else if (std.mem.eql(u8, args[index], "--frames") and index + 1 < args.len) {
            index += 1;
            bounded_frames = try std.fmt.parseUnsigned(u64, args[index], 10);
        } else {
            return error.InvalidArgument;
        }
    }
    try engine.run(engine.SceneHost(Tb11), config);
}
