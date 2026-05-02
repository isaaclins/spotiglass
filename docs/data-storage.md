# Data storage

Spotiglass keeps minimal state on disk. Refresh tokens never leave the Keychain for web playback context — only short-lived access tokens are exposed to the hidden `WKWebView`.

## Local storage summary


| Item                              | Location                                                                                                                                | Cleared by                                                                                          |
| --------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Spotify refresh token             | macOS Keychain (service `com.isaaclins.spotiglass.spotify-auth`, accessible after first unlock, this device only)                       | **Disconnect** in the app; refresh failures that return HTTP 4xx (e.g. revoked / `invalid_grant`)   |
| Client ID and granted OAuth scope | `UserDefaults` for `com.isaaclins.spotiglass`                                                                                           | Granted scope cleared on Disconnect; client ID kept so the next sign-in does not require re-pasting |
| Cached playlists / tracks         | Under the app container, e.g. `~/Library/Containers/com.isaaclins.spotiglass/Data/Library/Application Support/Spotiglass/SpotifyCache/` | Disconnect; same auth failures as above                                                             |
| Web Playback SDK web data         | Non-persistent `WKWebView` data store (in-memory for that session)                                                                      | Quitting Spotiglass                                                                                 |


## Cache behavior

- Keyed by playlist and Spotify snapshot ID.
- Short TTL (on the order of minutes).
- Does not contain tokens or credentials.

Logs surfaced via playback diagnostics contain SDK status strings only — never tokens.

## Troubleshooting Keychain errors

If sign-in fails with a message about **Keychain**, **macOS blocked access**, or a **security error code**, try: unlock your Mac and retry; use **Disconnect** then **Connect** again; reinstall Spotiglass from the same distribution you used before (Keychain items are tied to the app’s code signature). When reporting an issue, include the numeric **security error** code shown in the message if present.