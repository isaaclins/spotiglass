# Known limitations

- **Premium-only playback** — The Web Playback SDK reports `account_error` for non-Premium accounts. Spotiglass shows a clear “Spotify Premium required” style message. Playlist browsing may still work without Premium.
- **Unsigned macOS distribution** — Release and CI artifacts are deliberately unsigned. Notarization and Developer ID signing are out of scope for this repository’s workflows.
- **No backend** — All Spotify traffic goes directly from the Mac client. No Spotiglass server, telemetry product, or cross-machine sync.
- **Single Spotify session** — One signed-in account at a time. To switch accounts: Disconnect (clears Keychain refresh token and local cache), then Connect again.
- **Fixed OAuth loopback port** — Sign-in listens on `127.0.0.1:43824`. Another process binding that port during sign-in prevents the listener from starting; resolve the conflict and retry.
- **Playlist items API limit** — Spotify’s playlist tracks endpoint returns at most 50 items per request. Spotiglass paginates and merges pages; users still see full playlists, but network traffic is chunked accordingly.