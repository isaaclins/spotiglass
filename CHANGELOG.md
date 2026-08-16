# Changelog

## [0.7.0] - 2026-08-16

### Added

- **Add to Queue** and **Pin** are menu bar items acting on the track table's selection (⌥⌘E, ⌥⌘P). They previously existed only in a right-click menu.
- The **Help** menu opens the documentation and the issue tracker. Its single item used to do nothing at all: the bundle declares no help book, so choosing it was a silent no-op.
- Plural rules in the string catalog, so counts are pluralized per language instead of by appending an English "s".
- A **diagnostics** section on errors, carrying the status codes, scope names and paths that used to sit inside the sentence.
- CI runs the dead-code detector the Makefile already had and never invoked, gating on new findings against a recorded baseline, plus a check for Swift files present in the repo but in no Xcode target.

### Fixed

- Tracks on Home, Artist and Search could not be activated from the keyboard, and a track selected with the arrow keys in the playlist table could not be played at all, because Return was not handled. Album cards and queue rows had the same gap.
- ⌘F opened nothing on any existing install. A command ID was renamed without migrating saved keymaps, so every upgraded install had a dead binding. Tests could not see it because they start from fresh settings.
- Rebinding "Open command palette" left ⌘K alive as a second, undisclosed trigger.
- VoiceOver could not change playback position, was never told the volume level, and heard the identical label "Band gain" from all ten equalizer faders. Explicit and Unavailable badges were not spoken. Breadcrumbs claimed to be buttons but exposed no action.
- The Spotify error vocabulary, browser empty states, the loading spinner, the artist header's "followers" and the equalizer's errors were hardcoded English and ignored the in-app language picker.
- The localization audit reported a clean bill of health while at least six leaks existed. It could not see prose returned from a message property, nor plural entries, which it reported as untranslated in every locale.
- Error copy exposed HTTP status codes, OAuth scopes and SDK names. An alert containing a raw HTTP request and response dump could open unprompted. The sidebar printed the reason phrase "Forbidden" verbatim.
- The Settings window was translucent, its sidebar painted a selection highlight that stayed bright when the window lost focus, and its search field had no clear button, no focus ring, no ⌘F, and announced itself as "Account".
- The pinned badge was drawn five different ways and Liked Songs artwork four. The queue row and the track row had drifted into two different copies of one design. The Recently played shelf cut its last card in half.
- The equalizer's Output device picker rendered blank when the saved device was not connected, and its gain readout would clip at larger text sizes.
- A failed profile fetch at launch silently emptied the pinned sidebar for the whole session, with no error and no retry.

### Changed

- The equalizer is described as a **graphic** equalizer. It exposes gain on ten fixed frequencies and no control over Q or centre frequency, so the previous "parametric" was wrong about the software.
- One concept is named one way per language across every surface.
- Track durations go through a formatter rather than being assembled by hand.
- Disconnecting asks for confirmation instead of acting on a single unlabelled click.

## [0.6.0] - 2026-08-12

### Added

- A dedicated **Search** surface for the Spotify catalog. A Search row sits above the library in the sidebar and opens a full-window view covering tracks, albums, artists, and playlists, with category filters and paged results.
- **Cmd+F** opens Search. It is registered as an ordinary editable command, so it appears in Settings → Keyboard, can be rebound, and takes part in conflict detection.
- Command palette catalog results end with a **Show all results** row that opens the Search view carrying the current query and category. Cmd+K is unchanged.
- `/v1/search` gained an offset-paged variant, since the endpoint caps `limit` at 10 per item type.

### Fixed

- Labels on accent-filled controls now derive their color from the fill they sit on. A selected filter pill previously drew a white label on a white capsule in a background window, hiding the active category.
- The swift-format configuration was invalid, so `make format` and `make lint` had never run successfully. Both work now, and the violations they surfaced are fixed.
- `SpotiglassComponentsViewTests` was never added to the test target, so its four tests had never compiled or run. They now execute with the rest of the suite.

## [0.5.0] - 2026-08-11

### Added

- A native **Playback** menu exposes transport, shuffle, repeat, and connection actions. View and File menus add queue, lyrics, refresh, and library-loading commands, with shortcuts sourced from the editable keymap.
- Icon-only controls across playback, queue, browsing, breadcrumbs, pinning, lyrics, and shortcut settings now have hover tooltips and VoiceOver labels.
- Developer ID signing and Apple notarization cover the app, nested Sparkle components, equalizer driver, and disk image.

### Changed

- Equalizer, Playback, Appearance, Keyboard, and Account settings use native grouped forms with consistent sections, label columns, insets, and scrolling.
- Playlist tracks use the native macOS table, providing system selection, Shift and Command multi-select, arrow-key navigation, double-click playback, and context-menu focus rings while retaining row virtualization.
- Custom accent controls become neutral when a window is inactive, matching macOS focus conventions.
- Command palette and queue section headers use locale-appropriate capitalization instead of all caps.
- Release tooling validates increasing build numbers and keeps historical Sparkle downloads pinned to their original release tags.

### Fixed

- Unit tests can no longer overwrite the real Spotify client ID, playback volume, or app-storage preferences.
- Release packaging refuses unsigned or unnotarized artifacts instead of producing downloads that Gatekeeper rejects.

## [0.4.0] - 2026-08-05

### Added

- Playlist owners can rename playlists from the detail header by double-clicking the title or choosing **Edit playlist name** from the context menu.
- Followed playlists that do not allow track access now show a clear locked state.

### Changed

- Settings panes now share one scroll container with consistent top padding and window width. The traffic lights align with the main window, raw settings JSON has one discoverable entry point, and the sidebar can be hidden and shown again.
- Library pin reordering now uses the native list interaction.
- Localization cleanup removes obsolete strings and checks catalogs for stale entries.

### Fixed

- The equalizer master enable and bypass state is restored correctly when the app launches.
- VoiceOver announces when a track is pinned.

### Removed

- The duplicate **Spotiglass** menu was removed.

## [0.3.0] - 2026-06-23

### Added

- A Home surface, reachable from the existing **Home** sidebar row, with a localized time-of-day greeting (English, Español, Deutsch), a quick-access grid (Liked Songs plus your playlists), a **Recently Played** carousel that opens albums, and a **Your Top Tracks** list with full playback, queue, and artist navigation.
- New Spotify scopes `user-top-read` and `user-read-recently-played`. Existing sessions must reconnect to grant them, and until then the Top Tracks and Recently Played sections show a reconnect hint. The greeting and quick access work without reconnecting.

### Changed

- The app now opens to Home by default after the library loads, instead of jumping to the first playlist.

### Fixed

- A failed detail load with no cached data now shows a clear error instead of leaving the previous screen visible behind a stale-content banner.
- ViewInspector view-host tests no longer crash the test run on the current toolchain.

## [0.2.1] - 2026-06-17

### Changed

- Command-palette song search is now local-first: matches from data already in memory (the open playlist's tracks and your library playlists) render instantly on every keystroke, and Spotify catalog results merge in when they arrive instead of blocking behind the network. Typing no longer shows a blank spinner while results load.
- Footer category pills (and Tab) re-filter the already-fetched result set client-side instead of issuing a new network search, so switching between All / Tracks / Artists / This playlist / My Playlists is instant.
- **All** now leads the footer as the default search mode, and its sections are ordered by how closely each one's best hit matches the query (e.g. typing an artist name floats Artists above Tracks).

## [0.2.0] - 2026-05-29

### Added

- 10-band graphic equalizer with audible end-to-end output via a custom CoreAudio HAL plugin (`SpotiglassEQDriver`). vDSP biquads process audio in-buffer; the `EQRouter` forwarder hands processed frames to the device of your choice.
- Forwarding-target picker in **Settings → Equalizer** to choose where EQ'd audio is sent (defaults to the previous system default output).
- System volume controls now follow the EQ output: `kAudioVolumeControl` on the virtual device mirrors the EQRouter target, so the volume keys and menu-bar slider work as expected.
- EQ presets: built-in and user-saved, persisted in `~/.config/spotiglass/settings.json`.
- Playlist track operations menu with shift-click multi-select for batch actions on selected tracks.
- Tap any synced lyric line to seek playback, with press/hover polish.
- Two-pane Raycast-style Settings layout.
- Full in-app language switcher (English, Español, Deutsch) covering Settings, browsing, command palette, breadcrumbs, playback state, lyrics artwork, hotkey recorder, EQ settings, and playlist menus. Routes through `SpotiglassL10n` + `.lproj` bundles so the picker actually swaps copy at runtime.
- `SPOTIGLASS_EQ_DEBUG` build opt-in for driver diagnostic logging.

### Changed

- macOS menu bar app name now goes through the localization layer.
- Settings window rebuilds itself on a language change so every visible string updates immediately.
- `forwardingTargetUID` is now persisted across enable/disable cycles of the equalizer.

### Fixed

- Playback no longer cuts off when the in-app language is changed.
- Lyric rows no longer show a press-glow on tappable lines or a horizontal seam between rows.
- EQ target-device volume IO runs on a worker thread instead of blocking the main thread.
- HAL driver registers as output-only, with no spurious microphone-permission prompt.
- Driver bundle installs with `cp -pR` so the kernel `cs_mtime != mtime` code-signing check passes.
- Driver factory symbol is exported so `coreaudiod` can `dlsym` it.

## [0.1.1] - 2026-05-28

### Added

- `.dmg` installer attached to GitHub Releases for one-click human downloads (drag-to-Applications).
- `CHANGELOG.md` and `scripts/changelog.sh` generator.
- `SUPPORT.md` with a Buy Me a Coffee link.

## [0.1.0] - 2026-05-26

Initial public release.
