# Localization

The public `bairava.localization` module provides locale identifiers and an in-memory translation
catalog. Create a catalog with a required fallback locale, register other locales, add translations,
and select the active locale:

```zig
var translations = try engine.localization.Catalog.init(allocator, "en");
defer translations.deinit();

const french = try engine.localization.LocaleId.init("fr-CA");
try translations.addLocale(french);
const english = try engine.localization.LocaleId.init("en");
try translations.add(english, "menu/start", "Start");
try translations.add(french, "menu/start", "Commencer");
try translations.setLocale(french);

const label = translations.lookup("menu/start") orelse "menu/start";
```

Locale tags are case-insensitive ASCII alphanumeric subtags separated by single hyphens and are
normalized to lowercase (`fr-CA` becomes `fr-ca`). The fallback locale is registered by `Catalog.init`;
other locales must be registered before translations can be added or selected. Lookup checks the
active locale first, then the fallback locale. If neither has a translation, `lookup` returns `null`.

Translation keys follow the engine's validated-name rules: lowercase names containing letters,
digits, `_`, `-`, and `.`, with optional `/`-separated segments. Translation values are copied into
the catalog's owned storage. Repeated locale IDs and translation keys return `error.Duplicate`;
lookups do not allocate.
