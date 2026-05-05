<p align="center">
  <img src="assets/readme/logo.png" alt="Spotiglass logo" width="128" />
</p>

<h1 align="center">Spotiglass</h1>

<p align="center">
  Native macOS Spotify client built with SwiftUI, OAuth PKCE, Spotify Web API, and Web Playback SDK.
</p>

<p align="center">
  <a href="docs/getting-started.md">Get started</a>
  ·
  <a href="docs/building-and-testing.md">Build and test</a>
  ·
  <a href="docs/README.md">Documentation</a>
</p>

<!--## Demo

Drop your app GIF at `assets/readme/demo.gif` and keep this block:

```md
<p align="center">
  <img src="assets/readme/demo.gif" alt="Spotiglass demo" />
</p>
```-->

## Features

- Native SwiftUI macOS app with a polished, glass-inspired interface.
- Spotify OAuth Authorization Code with PKCE flow for secure sign-in.
- Playlist and track browsing through a typed Spotify Web API layer.
- In-app playback via Spotify Web Playback SDK hosted in a hidden `WKWebView`.
- Keychain-backed refresh token storage for persistent sessions.
- Developer-friendly build, test, and release workflow (`make` + `xcodebuild`).

## Quick start

1. Create a Spotify app in the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard).
2. Enable Web Playback SDK and set redirect URI to `http://127.0.0.1:43824/callback`.
3. Open `Spotiglass.xcodeproj` and run the `Spotiglass` scheme.
4. Enter your Spotify client ID, connect, then browse playlists and play.

See [Getting started](docs/getting-started.md) for scopes and setup details.

## Prerequisites and limitations

- macOS with Xcode and command-line tools available.
- Spotify Premium is required for Web Playback SDK streaming.
- Local builds are unsigned unless you explicitly sign/notarize them.

For details, read [Limitations](docs/limitations.md).

## Build and test

From repo root:

```sh
make build
make test
make run
```

For release artifact and raw `xcodebuild` commands, see [Building and testing](docs/building-and-testing.md) and [CI and releases](docs/ci-and-releases.md).

## Regenerate README logo

The README logo is exported from the app icon pipeline, not manually drawn.

```sh
scripts/generate_readme_logo.sh
```

Use `scripts/generate_readme_logo.sh --rebuild` to force a fresh Release build first.

## Documentation

Detailed guides live in [docs/README.md](docs/README.md):

- [Getting started](docs/getting-started.md)
- [Building and testing](docs/building-and-testing.md)
- [CI and releases](docs/ci-and-releases.md)
- [Data storage](docs/data-storage.md)
- [Pinning](docs/pinning.md)
- [Equalizer](docs/equalizer.md)
- [Limitations](docs/limitations.md)

## Contributing

Contributions are welcome. For now, open an issue describing the change you want to make before opening a PR so scope and direction are aligned.

## License

This repository currently does not include a published license file.
