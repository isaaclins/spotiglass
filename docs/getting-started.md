# Getting started

## Prerequisites

- macOS with Xcode suitable for the project deployment target (see `MACOSX_DEPLOYMENT_TARGET` in the Xcode project).
- A [Spotify Developer](https://developer.spotify.com/dashboard) app — you only need the **client ID** (PKCE public client; do not add a client secret).

## Run Spotiglass

1. Create a Spotify app in the dashboard and copy its **client ID**.
2. Open `Spotiglass.xcodeproj` in Xcode and run the **Spotiglass** scheme on macOS.
3. Paste the client ID in Spotiglass (welcome screen or **Settings → Account**, ⌘,), choose **Connect Spotify**, and complete sign-in in your default browser. While Spotiglass is waiting for the callback, use **Cancel** (or the Cancel shortcut) to abandon sign-in and return to the welcome screen.
4. Browse **Home**, **Liked Songs** at the top of the **Playlists** section, your other playlists, and play tracks.

**Settings** (Spotiglass menu or ⌘,) is organized into **Playback** (how Web Playback behaves), **Appearance** (UI language: English, Spanish, or German—defaults to macOS when it is one of those, otherwise English; color scheme: System, Light, or Dark; plus command palette backdrop blur), **Account** (client ID and Spotify connection), and **Keyboard** (shortcuts). On **Keyboard**, each command has a **Click to record** field: focus it, press the shortcut you want, then release (Esc cancels; Delete clears). If a chord is already used elsewhere, use **Replace** to move it. Power users can still edit the raw JSON under **Advanced (JSON)**; the on-disk path is shown there. Open the command palette with the shortcut shown in **Keyboard** (default ⌘K). Use a `>` prefix to list and filter in-app commands (while signed in, type `> lyrics` for **Toggle Lyrics**, or bind **Toggle Lyrics** to a shortcut on **Keyboard**). Otherwise the palette searches Spotify: use the footer to choose **All**, **Tracks**, **Artists**, **Here** (search inside the open playlist, Liked Songs, or the artist page you are viewing, when applicable), or **My Playlists** (your loaded library), or press Tab / Shift+Tab to cycle categories while the search field is focused. A leading `@` still switches to artists-only for one query. **All** merges catalog playlist hits with matching playlists from your sidebar library (same playlist ID appears once, catalog first), shows matches in the current playlist when available, then songs and other hits; **My Playlists** only lists library matches. Readable messages appear when Spotify returns an error.

While signed in, **⌘R** (command **Refresh** in Keyboard settings) reloads the surface under the pointer: **Home** refreshes the playlist sidebar list; a playlist or Liked Songs refreshes tracks for that selection; an artist page reloads that artist; move the pointer over the **queue** column so **⌘R** refreshes the queue instead of the main column. The trailing toolbar uses the same control (spinner while data loads). Legacy **⌘T** bindings for the removed “refresh tracks” command are dropped when `settings.json` is loaded.

**Spotify Premium** is required for in-app playback via the Web Playback SDK. Free accounts can browse playlists but playback from the embedded SDK will fail with an account error surfaced in the UI.

## Spotify app configuration

Configure the Spotify app as follows:

| Setting | Value |
|---------|--------|
| Redirect URI | `http://127.0.0.1:43824/callback` |
| Web Playback SDK | Enabled |

Spotiglass binds a temporary OAuth callback listener to `127.0.0.1` on port **43824** during sign-in. The listener closes after success, error, cancellation, or a **120 second** timeout.

### OAuth scopes

Requested scopes (space-separated):

```text
playlist-read-private playlist-read-collaborative user-library-read user-read-private user-read-email user-read-playback-state user-modify-playback-state user-read-currently-playing streaming
```

## Web Playback verification (manual)

Manual verification needs a Premium account:

- Connect playback from the app and confirm a Spotiglass device becomes ready.
- Start playback from a playlist track row.
- Confirm playback transfers to Spotiglass before audio plays.
- Exercise play/pause, previous, next, and seek.
- Confirm auth, Premium, and playback errors show a clear recovery message.

CI and sandbox environments typically cannot authenticate a real Premium session; treat Web Playback behavior as verified on a developer machine.
