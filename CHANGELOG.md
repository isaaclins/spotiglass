# Changelog

## [0.8.24] - 2026-11-11

### Fixed

- Album and playlist covers on Home and Search now open the right-click menu, and their artist names are clickable.

## [0.8.23] - 2026-11-10

### Fixed

- Apple Music playlists without their own picture now show the cover from the Music app instead of a grey tile.

## [0.8.22] - 2026-11-10

### Fixed

- Lyrics now follow the song in the player bar, even when you're browsing the other service.

## [0.8.21] - 2026-11-10

### Fixed

- The sidebar now collapses when there isn't room for it at narrow window widths, so the main content is no longer cut off.

## [0.8.20] - 2026-11-10

### Fixed

- Network errors in the Spotify queue now show in the app's language, so German users see them in German.

## [0.8.19] - 2026-11-10

### Fixed

- Command palette filters stay visible when the window is short.
- The selected filter in the command palette keeps its label in narrow windows.
- The search palette is now one clean panel near the top of the window.

## [0.8.18] - 2026-11-10

### Fixed

- Appearance option labels now switch to your new language right away when you change the app's language.

## [0.8.17] - 2026-11-10

### Fixed

- Shelves on Home and artist pages now scroll smoothly with a mouse wheel, including Shift-scrolling, instead of jumping.

## [0.8.16] - 2026-11-10

### Fixed

- Home has its own greeting after midnight, so it no longer says "Good evening" overnight.

## [0.8.15] - 2026-11-10

### Fixed

- The player bar now stays on the song you paused, even when the other service is on screen.

## [0.8.14] - 2026-11-09

### Fixed

- Lyrics can now pop out into a small window that stays on top of your other apps.

## [0.8.13] - 2026-11-09

### Fixed

- Opening an Apple Music artist page no longer closes Spotiglass.

## [0.8.12] - 2026-11-09

### Fixed

- Big Apple Music playlists and Liked Songs now open without a long wait.

## [0.8.11] - 2026-11-09

### Fixed

- The back button now uses a normal label that says where it goes, instead of tiny "Spotiglass" text.

## [0.8.10] - 2026-11-09

### Fixed

- Play and pause now show up the moment you press them, instead of taking about 5 seconds.

## [0.8.9] - 2026-11-09

### Fixed

- ⌘S now shows and hides the sidebar.

## [0.8.8] - 2026-11-09

### Fixed

- The player bar stays visible while lyrics are open, and the top bar shows only lyrics controls.

## [0.8.7] - 2026-11-09

### Fixed

- The lyrics backdrop now shows album art for songs from your Apple Music library, instead of staying black.

## [0.8.6] - 2026-11-09

### Fixed

- The sidebar now looks consistent, with matching rows, headers and tiles.

## [0.8.5] - 2026-11-09

### Fixed

- Play, pause and track changes are smoother, because only the rows and the player bar that change get redrawn.

## [0.8.4] - 2026-11-09

### Fixed

- Spacing and alignment now follow one grid, so elements in the app line up.
- The Reconnect button no longer shows up in the player bar when you use Apple Music.
- Updates now install by themselves, and the app checks for them every few hours.
- Playlists with explicit songs play on a Mac set to allow only clean music, including Your top tracks.

## [0.8.3] - 2026-11-09

### Fixed

- The lyrics button in the player bar is centred again.
- Apple Music covers in Recently played are sharp instead of blurry.

## [0.8.2] - 2026-11-09

### Fixed

- Small fixes behind the scenes.

## [0.8.1] - 2026-11-08

### Fixed

- Small fixes behind the scenes that make sign-in more reliable (#392).

## [0.8.0] - 2026-11-08

### Added

- **Apple Music.** Add it on the welcome screen or with **Add a service…** in the service switcher and allow access when macOS asks. Spotiglass then shows your library, playlists, Home and search, plays songs, and lets you like songs, add them to playlists, create, rename and delete playlists, remove songs from a playlist, and add or remove albums. Playing needs an Apple Music subscription. Some library edits go through the Music app, so the first of those asks once whether Spotiglass may control Music. In Apple Music, Liked Songs is your library, so unliking a song takes it out of your playlists on all your devices too; Spotiglass asks before it does that.
- A **service switcher** at the top left of the sidebar, like profiles in Arc. Spotify and Apple Music sit side by side, each with its own sign-in, pins and place, and switching never signs anything out. ⌃1 switches to Apple Music and ⌃2 to Spotify; both can be rebound in Settings › Keyboard, and the command palette has **Switch to Spotify** and **Switch to Apple Music**.
- Apple Music playlists show their track counts in the sidebar.
- The equalizer installs its audio driver itself, through a privileged helper registered with the Service Management framework. macOS asks for your approval in its own words; the previous build asked you to run `sudo` commands in Terminal.
- **More from your library** in the track menu queues more music from your own Spotify library after the current song.
- A universal track options menu, so the same actions are available wherever a track appears rather than a different subset per surface.
- Artist pages have selectable rows and play and shuffle actions in the header.
- The ten equalizer band faders are reachable and adjustable from the keyboard.

### Fixed

- The progress bar seeks on the first click while a song plays. The first click used to be lost.
- Playback no longer keeps a CPU core busy. With a playlist open and a song playing, Spotiglass now redraws only the progress bar instead of the whole window.
- The play bar and Space control the music you actually hear, even when it comes from the other service, and signing out of Apple Music stops its music.
- The queue panel fits at every window width, shows the queue while Spotiglass is in the background, and says "Next 20 tracks" instead of a wrong exact count when more are queued.
- German and Spanish no longer show English or misspelled text in several places, and Apple Music mode names Apple Music on screen and shows calm errors instead of raw MusicKit messages.
- ⌃1 and ⌃2 work while lyrics are open, and while another service is added, a Spotify session that lapsed can be removed without signing in again first.
- Apple Music songs can be pinned from track lists, covers no longer disappear in large libraries, and a library album on an artist page counts the songs it really has in your library.
- After a language switch your own playlists keep **Edit playlist name**, and the sidebar collapses in a narrow window instead of getting cut off.
- In Apple Music, adding songs from your playlists and library albums to a playlist works, **New playlist…** never leaves an empty playlist behind, and a failed add takes back what it added.
- An Apple Music edit that takes Music longer than 60 seconds no longer goes through after Spotiglass said it failed. Spotiglass waits for Music and reports what really happened.
- In Apple Music, songs that are only in a playlist, not in your library, no longer show as liked.
- The Spotify response and lyrics caches on disk now have size limits and drop what they no longer need.
- Clicking a track with shuffle on played a different one, the transport could stay stuck on "Transferring playback...", and picking an album in the command palette did nothing.
- The device menu showed no checkmark, the scrubber could shrink to nothing in a narrow window, the transport buttons had no VoiceOver labels, Toggle Lyrics did nothing without saying why, Shuffle and Repeat showed no state in the Playback menu, and File › Load All Your Songs showed no progress.
- The equalizer could never install its driver on a real Mac. A daemon that has never been registered reports "not found", which the app treated as fatal; it connected to the helper before launchd had the job running; its retry path discarded an approval you had already granted and asked again, forever; and the helper carried a debug-only entitlement that launchd refuses to run a daemon with, so registration reported success while the job silently never loaded.
- Enabling the equalizer without permission to run in the background flipped the switch back with nothing on screen. Install failures are deliberately kept out of the settings pane, which is right for every case except the one only you can resolve. It now says what happened and offers the trip to Login Items.
- The equalizer reported itself live as soon as it selected the virtual output device, long before the driver had opened a route to real speakers, so a missing or disconnected target left the pane green with audio going nowhere.
- Disabling the equalizer discarded the saved output device even when restoring it failed, and the pre-equalizer device was held only in memory, so it did not survive a relaunch.
- External edits to the settings file did not reach the running equalizer engine, and a default-output change made outside Spotiglass was ignored rather than reconciled.
- Preamp values were clamped where they were drawn instead of where they were saved, and the equalizer editor accepted edits while the equalizer was off.
- A second window could not play anything, because the playback host belonged to the first one.
- Playback started elsewhere on Spotify Connect did not appear in the transport, volume changed on another device did not come back, and the scrubber could seek the wrong track across a track change.
- Rapid play and skip presses interleaved into an inconsistent state, and disconnecting left work in flight that could resurrect a signed-out session.
- The now-playing summary had disappeared, the lyrics button in the transport did nothing when clicked, and Repeat had two competing shortcuts and no single cycling one.
- The lyrics overlay swallowed transport and global shortcuts, and did not trap focus.
- Two track context menus disagreed about whether a track was liked, Search and Home did not refresh, and browsing used non-canonical entity identity.
- Removing several tracks from a playlist removed the wrong ones, because batched removals were applied from the front. Liked Songs stopped paginating partway.
- Missing Spotify permission scopes were discovered only by failing, and a raw 403 was printed into the sidebar. Token retry-after windows were ignored, and account lifecycle state leaked across sign-ins.
- Shortcut conflicts were swallowed silently, one bad field in the keymap discarded the rest of the file, upgraded installs lost keybindings a migration should have carried across, and numeric shortcut keys were mishandled.
- The command palette and other transient state leaked between window scenes.
- Global shortcuts fired ahead of a focused control that owned the key.
- The in-app language picker is now a dependency the interface observes, so every surface changes language at once instead of some waiting for a relaunch.
- Home, the browser and Settings had drifted from the design system, and Settings had an empty playback pane.

### Changed

- 0.7.0 offers this update by itself. The update key stays the same, so there is nothing to download by hand.
- Local builds are signed with a stable identity, so the keychain stops asking for the login password after every rebuild.
- The equalizer requires a signed and notarized build. Its helper is a LaunchDaemon, and macOS enforces a launch constraint that only a notarized Developer ID build satisfies, so there is no local-development path for it.
- The test suite no longer sleeps for a fixed duration anywhere; it waits for the condition it cares about. Local runs use CI's per-test timeout, view tests are hosted off screen so no remote view service attaches, the artwork tests no longer touch the real cache, and the audio driver's router is unit-tested in CI.
- Release packaging checks the Sparkle tools against a pinned checksum before running them, and stops when a given release notes file is missing.
- The unit test host stays in the background and opens no windows.


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
