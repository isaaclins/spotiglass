# Data storage

Spotiglass keeps minimal state on disk. Refresh tokens never leave the Keychain for web playback context — only short-lived access tokens are exposed to the hidden `WKWebView`.

## Local storage summary


| Item                              | Location                                                                                                                                | Cleared by                                                                                          |
| --------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Spotify refresh token             | macOS Keychain (service `com.isaaclins.spotiglass.spotify-auth`, accessible after first unlock, this device only)                       | **Disconnect** in the app; refresh failures that return HTTP 4xx (e.g. revoked / `invalid_grant`)   |
| Client ID and granted OAuth scope | `UserDefaults` for `com.isaaclins.spotiglass`                                                                                           | Granted scope cleared on Disconnect; client ID kept so the next sign-in does not require re-pasting |
| User settings (keybinds + EQ)     | `~/.config/spotiglass/settings.json` — single dotfile holding keybinds, equalizer state, and saved EQ presets                           | Delete the file (Spotiglass rewrites defaults on next launch)                                       |
| Cached playlists / tracks         | `~/Library/Application Support/Spotiglass/SpotifyCache/` (sandbox is disabled, so this is the user-visible Application Support folder)  | Disconnect; same auth failures as above                                                             |
| Sidebar pins (per Spotify user)   | `~/Library/Application Support/Spotiglass/SpotifyCache/pinned/<userID>.json` — one JSON array per account (`userID` is the Spotify user id) | **Disconnect** removes the whole `SpotifyCache` tree (pins included). In-memory pins are cleared on disconnect before the next session. |
| Cached Web API GET bodies        | `~/Library/Application Support/Spotiglass/SpotifyCache/get_responses/` (SHA256-named JSON; search, artist, profile, album-track pages — short TTL) | Same as playlist cache; cleared with **Disconnect** |
| Artwork image blobs               | `~/Library/Caches/Spotiglass/Artwork/` (SHA256-named files); HTTP layer also uses `~/Library/Caches/Spotiglass/ArtworkURLCache/`       | Disconnect (cleared with Spotify cache); eviction trims disk blobs when the artwork folder exceeds ~50 MB                           |
| Web Playback SDK web data         | Non-persistent `WKWebView` data store (in-memory for that session)                                                                      | Quitting Spotiglass                                                                                 |

### `settings.json` shape

```json
{
  "version": 1,
  "keybinds": [
    { "keystrokes": ["cmd-k"], "command": "palette.open", "when": "always" },
    { "keystrokes": ["cmd-,"], "command": "app.openSettings", "when": "always" }
  ],
  "equalizer": {
    "enabled": false,
    "preamp": 0,
    "bands": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    "activePresetName": "Flat",
    "userPresets": []
  }
}
```

`bands` is exactly 10 entries, each in dB, mapped to fixed center frequencies 32 Hz, 64 Hz, 125 Hz, 250 Hz, 500 Hz, 1 kHz, 2 kHz, 4 kHz, 8 kHz, 16 kHz. Hand-edits to the file are picked up live by Spotiglass via a file-system watcher.


## Cache behavior

### Playlist and track metadata (`SpotifyCache`)

- Keyed by playlist and Spotify snapshot ID for saved tracks.
- Short TTL (five minutes by default) for treating cached tracks as still valid for instant display.
- **Stale-while-revalidate**: opening a playlist shows cached tracks immediately when the snapshot and TTL match; the app still refreshes from the Spotify Web API in the background and updates the UI when new data arrives. **Refresh Tracks** or changing the playlist snapshot invalidates or bypasses the soft cache as before.
- **Playlist list**: on launch, if the on-disk playlist list is newer than about **30 minutes**, Spotiglass skips an automatic `GET /v1/me/playlists` round-trip and only loads tracks for the current selection (still subject to track-cache rules above). Older lists still trigger a refresh. Use the in-app refresh control when you need the latest sidebar immediately.
- Does not contain tokens or credentials.

### Web API GET response cache (`get_responses/`)

- In-memory plus optional on-disk JSON for **read-only** Spotify Web API GETs that are safe to reuse briefly (e.g. search, artist metadata, `GET /v1/me`, album track pages). **Not** used for playlist list or playlist items (those use the snapshot-aware caches above).
- TTLs are short (on the order of **90s–15m** depending on endpoint) to reduce rate limiting while keeping results reasonably fresh.

### Artwork (CDN images)

- Loaded URLs are deduplicated in memory and stored on disk as image bytes (not JSON). Same artwork URL reuses cache across scrolling and restarts until cleared.
- Does not contain tokens or credentials.

Logs surfaced via playback diagnostics contain SDK status strings only — never tokens.

## Troubleshooting Keychain errors

If sign-in fails with a message about **Keychain**, **macOS blocked access**, or a **security error code**, try: unlock your Mac and retry; use **Disconnect** then **Connect** again; reinstall Spotiglass from the same distribution you used before (Keychain items are tied to the app’s code signature). When reporting an issue, include the numeric **security error** code shown in the message if present.