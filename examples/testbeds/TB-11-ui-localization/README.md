# TB-11 UI and Localization

This testbed combines inventory, settings, and dialogue screens with the engine's immediate-mode
widgets, translation catalog, fallback lookup, wrapped text, and runtime font providers.

## Run

```powershell
zig build run-tb11
```

Run a bounded smoke test that writes `TB-11-ui-localization-results.json` beside the executable:

```powershell
zig build run-tb11 -- --frames 360
```

The report separates automated catalog/layout checks from interaction counters, which remain zero
until exercised manually.

## Controls

- Up/Down selects a page; Enter or Space opens it. Tab cycles pages directly.
- Q/E changes locale between English, French, and Tamil; click Language to cycle locale.
- Click Next page to cycle through Inventory, Settings, and Dialogue.
- In Inventory, click Use tonic to consume an item. In Settings, use the slider or Left/Right to
  adjust volume and click the scale button to toggle Fit/Integer scaling.
- Click Continue in Dialogue to switch between the two localized messages.
- Escape exits.

English and French use the packaged bitmap font. Tamil uses the packaged Tamil outline font. Dialogue
text is laid out again when the locale changes. The testbed verifies that all three translations wrap
to multiple lines and that missing locale entries resolve to English; unknown keys remain missing.

Localized image and sound selection are explicitly unsupported here: the engine does not exercise a
tested localized-content selection mechanism in this testbed. Gamepad navigation is not exercised.
