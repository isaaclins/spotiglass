# Localization

Spotiglass ships in English, Spanish, and German. The active language is chosen
in **Settings → Appearance → Language** and persisted under
`appearance.language` in `~/.config/spotiglass/settings.json`. The picker shows
each language in its own script (English, Español, Deutsch) so users can find
their own language regardless of what's currently active.

## Architecture

```
SpotiglassSettingsStore.settings.appearance.language   ← user choice
                       │
                       ▼
       SpotiglassSettingsStore.appLocale (Locale)
                       │
                       ▼  (referenced from main-thread reads)
              SpotiglassL10n.locale
                       │
                       ▼  (loads <lang>.lproj from Bundle.main)
   Bundle.localizedString(forKey:value:table:)
                       │
                       ▼
              Localizable.xcstrings  (en / es / de)
```

`SpotiglassL10n.string(_:)` is the only API call sites should use. It always
routes through the `.lproj` bundle that matches `appLocale`, **not** through
`String(localized:)`. (`String(localized:locale:)`'s `locale:` parameter only
controls how numbers and dates are formatted *inside* the resolved string — it
does not pick which translation `Bundle` returns; that's chosen by
`Bundle.preferredLocalizations`, which comes from the *system* locale. So a
naïve `String(localized: "...", locale: appLocale)` would always render in the
system language regardless of what the user picked.)

## Adding a new string

1. Add a key + values to `Spotiglass/Localizable.xcstrings`. Either:
   - Open the catalog in Xcode and add the row through the GUI, **or**
   - Add a top-level entry under `"strings"` with `localizations.{en,es,de}.stringUnit.{state:"translated", value:"…"}`. The audit script accepts either format.
2. Resolve it from Swift via `SpotiglassL10n.string("your.key")`.
   - For `printf`-style argument substitution, use `SpotiglassL10n.format("your.key", arg1, arg2, …)`.
   - For keys constructed at runtime (e.g. `"prefix.\(value).suffix"`), use the same `SpotiglassL10n.string(_:)` — the API takes a `String`, so interpolation works naturally without falling into Xcode's `String.LocalizationValue` template trap.
3. Run `scripts/audit-localization.sh` — it scans for hardcoded English literals
   in user-visible modifiers and verifies every referenced key exists with
   non-empty en/es/de values.

## Live switching

Top-level scenes attach `.id(settingsStore.settings.appearance.language)` so
the entire view hierarchy tears down and rebuilds when the user picks a new
language (`Spotiglass/App/SpotiglassApp.swift`). That guarantees every Text /
Label / accessibility-label re-runs its body in the new locale without a
restart. Reactive surfaces:

| Surface | How it reacts |
|---------|---------------|
| Main window (browsing, lyrics, palette, playback) | `.id(language)` on `WindowGroup` root |
| Settings window (Playback / Appearance / Account / Keyboard) | `.id(language)` on the `Settings` scene root |
| Command palette commands (titles + subtitles) | `CommandPaletteCommandSpec.title` / `.subtitle` are computed properties that resolve through `SpotiglassL10n` on every read, so a SwiftUI rebuild reads the new locale |
| macOS app menu palette command | Driven by `SpotiglassL10n.string("app.menu.openPalette")` through the standard application menu command group |

## What is *not* translated

Per the i18n policy:

- Raw Spotify data — track names, artist names, album names, playlist names.
- The literal word `"Spotify"`.
- The brand name `"Spotiglass"` itself (surrounding chrome like "Spotiglass
  Settings" *is* translated — "Configuración de Spotiglass" /
  "Spotiglass-Einstellungen").
- Keymap config tokens (`"cmd"`, `"shift"`, `"return"`, …) in `keymap.json`.
- Debug logs (`SpotiglassLog.info`, etc.) and `#Preview` / `#if DEBUG` code paths.

The audit script encodes all of the above as exemptions, so adding a new
exempt class means editing `scripts/audit-localization.sh`.

## Style guide

- **Spanish**: neutral Latin-American, e.g. "Canciones" / "Aceptar" / "Mostrar".
- **German**: formal Sie register in multi-clause subtitles ("Verwenden Sie …",
  "Wählen Sie …"). Short labels stay in the impersonal infinitive ("Spotify
  verbinden", "Trennen"), matching Apple's HIG German tone.
- **German never uses the sharp-s.** Write `ss`: "schliessen", not "schließen";
  "Gross", not "Groß". Umlauts are unaffected, so "Zurück" and "Wählen" keep
  their diacritics. `scripts/audit-localization.sh` fails if a sharp-s appears
  in a German value.
- Sentence case for sentences; title case (or German noun capitalization) for
  short labels.
- Track / artist / album names are user-content and never touched.
