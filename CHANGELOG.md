# Changelog

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
- HAL driver registers as output-only — no spurious microphone-permission prompt.
- Driver bundle installs with `cp -pR` so the kernel `cs_mtime != mtime` code-signing check passes.
- Driver factory symbol is exported so `coreaudiod` can `dlsym` it.

## [0.1.1] - 2026-05-28

### Added

- `.dmg` installer attached to GitHub Releases for one-click human downloads (drag-to-Applications).
- `CHANGELOG.md` and `scripts/changelog.sh` generator.
- `SUPPORT.md` with a Buy Me a Coffee link.

## [0.1.0] - 2026-05-26

Initial public release.
