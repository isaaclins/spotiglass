# Getting started

## Prerequisites

- macOS with Xcode suitable for the project deployment target (see `MACOSX_DEPLOYMENT_TARGET` in the Xcode project).
- A [Spotify Developer](https://developer.spotify.com/dashboard) app — you only need the **client ID** (PKCE public client; do not add a client secret).

## Run Spotiglass

1. Create a Spotify app in the dashboard and copy its **client ID**.
2. Open `Spotiglass.xcodeproj` in Xcode and run the **Spotiglass** scheme on macOS.
3. Paste the client ID in Spotiglass (welcome screen or **Settings → Account**, ⌘,), choose **Connect Spotify**, and complete sign-in in your default browser.
4. Browse **Home** (placeholder), **Liked Songs** under Favorites, your **Playlists**, and play tracks.

**Settings** (Spotiglass menu or ⌘,) is organized into **Playback** (how Web Playback behaves), **Account** (client ID and Spotify connection), and **Keyboard** (shortcuts). On **Keyboard**, each command has a **Click to record** field: focus it, press the shortcut you want, then release (Esc cancels; Delete clears). If a chord is already used elsewhere, use **Replace** to move it. Power users can still edit the raw JSON under **Advanced (JSON)**; the on-disk path is shown there. Open the command palette with the shortcut shown in **Keyboard** (default ⌘K). Use a `>` prefix to list and filter in-app commands. Otherwise the palette searches Spotify: use the footer to choose **All**, **Tracks**, **Artists**, **Here** (search inside the playlist or Liked Songs you have open, when applicable), or **My Playlists** (your loaded library), or press Tab / Shift+Tab to cycle categories while the search field is focused. A leading `@` still switches to artists-only for one query. **All** merges catalog playlist hits with matching playlists from your sidebar library (same playlist ID appears once, catalog first), shows matches in the current playlist when available, then songs and other hits; **My Playlists** only lists library matches. Readable messages appear when Spotify returns an error.

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
