# Spotiglass

Native macOS Spotify client built with SwiftUI: OAuth PKCE against Spotify, Web API for browsing, and Web Playback SDK audio inside a hidden `WKWebView`. Long-lived tokens stay in the Keychain.

## Documentation

Detailed guides live under **[docs/](docs/README.md)**:

- [Getting started](docs/getting-started.md) — Xcode run, Spotify Developer app, OAuth  
- [Building and testing](docs/building-and-testing.md) — `xcodebuild`  
- [CI and releases](docs/ci-and-releases.md) — GitHub Actions artifact  
- [Data storage](docs/data-storage.md) — Keychain, cache, privacy-related paths  
- [Limitations](docs/limitations.md) — Premium, signing, operational constraints  
- [Roadmap pointer](docs/development/roadmap.md) — Where step specs live in-repo

## Quick start

1. Create a Spotify app ([Developer Dashboard](https://developer.spotify.com/dashboard)), enable Web Playback SDK, redirect URI `http://127.0.0.1:43824/callback`.
2. Open `Spotiglass.xcodeproj`, run the **Spotiglass** scheme.
3. Paste the client ID → **Connect Spotify** → pick playlists and play.

**Premium** is required for in-app streaming. See [Getting started](docs/getting-started.md) for scopes and verification notes.