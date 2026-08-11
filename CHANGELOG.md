# Changelog

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

- 10-band parametric equalizer with audible end-to-end output via a custom CoreAudio HAL plugin (`SpotiglassEQDriver`). vDSP biquads process audio in-buffer; the `EQRouter` forwarder hands processed frames to the device of your choice.
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
