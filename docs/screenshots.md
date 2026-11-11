# Screenshots

The screenshots in the README and on the landing page are captures of the real app. They are
taken in **screenshot mode**: the app runs against a local stand-in for Spotify that serves a
sample library, so no Spotify account, Premium subscription, Keychain item or audio driver is
involved.

## What screenshot mode is

Launching the app with `SPOTIGLASS_MOCK_BASE=http://127.0.0.1:<port>` switches it on
([`ScreenshotMode`](../Spotiglass/Infrastructure/ScreenshotMode.swift)). Then:

- Accounts and Web API requests go to that address instead of `accounts.spotify.com` and
  `api.spotify.com`. Only `127.0.0.1` and `localhost` are accepted.
- The app signs in at launch with a fixed refresh token kept in memory; the Keychain is never read
  or written.
- The playback host page gets a stand-in Web Playback SDK from the mock. It plays a silent clock
  instead of audio, so the player bar, scrubber and synced lyrics move as they would.
- Sparkle does not check for updates, and the equalizer never starts the audio driver, so a seeded
  EQ curve stays editable on screen.

Without the variable none of this is active; normal builds and launches are unchanged.

Lyrics are real: they come from [LRCLIB](https://lrclib.net) exactly as in a normal run.

## The mock and the sample library

[`scripts/screenshot-mode/mock_spotify.py`](../scripts/screenshot-mode/mock_spotify.py) (Python 3,
standard library only) serves the endpoints the app uses. The library is
[`sample-library.json`](../scripts/screenshot-mode/sample-library.json): a list of songs, five
playlists and the track that is playing. Track metadata and album artwork come from the public
iTunes Search API on first run and are cached in `build/screenshot-mode/library-cache.json`;
artwork URLs point at Apple's CDN, so no covers are committed. Delete the cache to look tracks up
again.

## Taking screenshots

```sh
scripts/screenshots.sh start                     # dark appearance, "Midnight City" playing
scripts/screenshots.sh shot home                 # largest window -> build/screenshot-mode/shots/home.png
scripts/screenshots.sh key 40 cmd                # ⌘K opens the command palette
cliclick t:night                                 # type a query (brew install cliclick)
scripts/screenshots.sh shot palette
scripts/screenshots.sh key 53                    # esc
scripts/screenshots.sh key 43 cmd                # ⌘, opens Settings (Equalizer pane)
scripts/screenshots.sh shot equalizer Settings   # capture the window whose title contains "Settings"
scripts/screenshots.sh stop                      # quit, stop the mock, remove all state
```

Options for `start`: `--light` for the light appearance, `--now-playing "<title>"` to play
another track from the library (useful for the lyrics view: View → Show Lyrics, ⌥⌘L), and
`--with-apple-music` to let the service switcher add the real Apple Music next to the Spotify
stand-in. That run uses your own Apple Music library through MusicKit and the system permission
prompt, so it keeps the real bundle id (MusicKit issues its token for that id only); the real
app's preferences are saved at `start` and put back at `stop`. It also needs the Developer ID
signing identity: macOS keeps one Apple Music permission per bundle id, so an ad-hoc copy under the
real id would take it over from the signed app (and from `make test`'s test host, #520). Without
the identity, `start --with-apple-music` stops before staging. Without the option screenshot mode
never reaches MusicKit.
`--release` builds and runs the Release configuration instead of Debug.
`SHOTS_DIR` changes the output folder, `WINDOW_FRAME="x, y, width, height"` the window size.

## Timing a window resize

`resize [rounds] [steps] [max-ms-per-step]` resizes the window from code the way Hammerspoon's
`setFrame`, Rectangle or Magnet do (size, position, size again through the Accessibility API) and
prints how long one resize and an animated one of `steps` steps took
([`resize_timing.swift`](../scripts/screenshot-mode/resize_timing.swift)). With `max-ms-per-step` it
exits with an error when the median step is slower. It times the app's main window and reads the size back after
every resize, inside the timing: the read waits for the app the way a window manager's next call
does, so work the app puts off until after a resize still counts. A resize call that fails, or a
window that doesn't take a size it was given (full screen, clamped), stops the run with an error.
Measure a Release build:

```sh
scripts/screenshots.sh start --release
scripts/screenshots.sh resize 8 12 40   # fails above 40 ms per step
build/screenshot-mode/resize_timing $(pgrep -x Finder) 8 12   # Finder, timed the same way
scripts/screenshots.sh stop             # also removes resize_timing
```

Time Finder in the same minute, as above, since other work on the Mac slows both. On a Mac mini
M4 (#473) Finder takes 13 to 15 ms a step, the playlist pages and Apple Music's Home 2 to 4 ms, and
Spotify mode's Home about 22. The terminal needs the Accessibility permission.

`appearance light` or `appearance dark` switches the macOS appearance while the app runs, the way
System Settings does, to check how the window takes a live theme change (set Settings → Appearance
→ Color scheme to System first; Light and Dark there switch only the app). The first switch
remembers your appearance and `stop` puts it back.

Both backups (the real app's preferences and your appearance) are kept in
`~/Library/Application Support/Spotiglass Screenshot Mode`, outside `build/`, so cleaning the build
folder can't lose them. The checkout that saved them owns them until its `stop` puts them back:
meanwhile `start --with-apple-music` and `appearance` in another checkout refuse to run, and `stop`
there leaves the backups alone. If the owner's folder was deleted, any checkout takes them over. If one can't be put back, `stop` says so, keeps that backup and exits with
an error; run it again.

`key` posts a real key event with its virtual key code (the app's keymap matches on key codes, so
text typed by other tools does not trigger shortcuts). Modifiers are `cmd`, `shift`, `alt` and
`ctrl`. Common codes: K 40, F 3, comma 43, L 37, W 13, 1 18, 2 19, escape 53, return 36, delete 51.

Screen capture and synthetic input need the Screen Recording and Accessibility permissions for the
terminal you run the script from.

## Where the run's data goes

The script builds the Debug app, copies it to `build/screenshot-mode/Spotiglass.app` with the
bundle id `com.isaaclins.spotiglass.screenshots` and an ad-hoc signature, and launches it with
`CFFIXED_USER_HOME=build/screenshot-mode/home`. Settings, caches and logs therefore land in that
folder and preferences in their own domain, never in your real Spotiglass data. `stop` deletes
both. The client ID is passed as a launch argument (`-spotify.clientID screenshot-mode`) and is
not saved.
