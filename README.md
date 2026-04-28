# Spotiglass

Spotiglass is a personal macOS 26 SwiftUI Spotify client that pairs the Spotify Web API with Web Playback SDK streaming inside a hidden `WKWebView`. Authentication uses OAuth Authorization Code with PKCE, the loopback redirect runs on `127.0.0.1`, and the macOS Keychain is the only persistent home for refresh tokens.

## Quick start

1. Create a Spotify app (see [Spotify app configuration](#spotify-app-configuration)).
2. Open `Spotiglass.xcodeproj` in Xcode 26 and run the `Spotiglass` scheme on macOS — or build/test from the command line ([Local build & test](#local-build--test)).
3. Paste the client ID from the Spotify dashboard into Spotiglass, click **Connect Spotify**, and complete sign-in in your default browser.
4. Pick a playlist, then press **Play** on a track. Spotify Premium is required for in-app playback ([Web Playback verification](#web-playback-verification)).

## Spotify app configuration

Create a Spotify app in the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard), then paste its client ID into Spotiglass before signing in. Do not add a client secret to the app.

Required dashboard settings:

- Redirect URI: `http://127.0.0.1:43824/callback`
- Web API: enabled by default for Spotify apps
- Web Playback SDK: enabled for the app

The app binds its temporary OAuth callback listener to `127.0.0.1` on port `43824` during sign-in, then closes the listener after success, error, cancellation, or the 120 s timeout.

Requested OAuth scopes:

```text
playlist-read-private playlist-read-collaborative user-read-private user-read-email user-read-playback-state user-modify-playback-state user-read-currently-playing streaming
```

## Web Playback verification

Spotiglass hosts the Spotify Web Playback SDK in a hidden `WKWebView` and exposes only short-lived access tokens to JavaScript. Refresh tokens remain in the macOS Keychain and are never sent to the web context.

Manual Step 5 verification requires a Spotify Premium account because the Web Playback SDK reports `account_error` for unsupported accounts. Verify:

- Connect playback from the native controls and confirm a Spotiglass device becomes ready.
- Start playback from a playlist track row.
- Confirm playback transfers to the Spotiglass device before playing.
- Test play/pause, previous, next, and seek behavior.
- Confirm Premium/account/auth/playback errors show a clear recovery message.

Current live verification blocker: this repository build environment does not have an authenticated Spotify Premium account available, so Web Playback SDK connection and transfer must be verified manually on a developer machine signed in with Premium.

## Local build & test

List available schemes:

```sh
xcodebuild -list -project "Spotiglass.xcodeproj"
```

Build the app target:

```sh
xcodebuild -project "Spotiglass.xcodeproj" -scheme "Spotiglass" -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
```

Run the unit tests (45 cases across `SpotiglassFoundationTests`, `SpotifyAuthStepTests`, `SpotifyWebAPIStepTests`, `PlaylistBrowsingStepTests`, and `PlaybackStepTests`):

```sh
xcodebuild -project "Spotiglass.xcodeproj" -scheme "Spotiglass" -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```

## Release build

Build an unsigned Release `Spotiglass.app` locally with the same command CI uses:

```sh
xcodebuild \
  -project "Spotiglass.xcodeproj" \
  -scheme "Spotiglass" \
  -configuration "Release" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "build/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  clean build
```

The resulting bundle is at `build/DerivedData/Build/Products/Release/Spotiglass.app`. It is a universal `arm64 + x86_64` binary with only the ad-hoc linker signature macOS adds automatically; it is **not** Developer ID signed and **not** notarized.

## Release artifact CI

`.github/workflows/release-artifact.yml` builds the same unsigned Release `Spotiglass.app` on a GitHub-hosted macOS runner, runs the unit tests first, and uploads the `.app` bundle directly as a workflow artifact.

- Trigger: `workflow_dispatch` only — the workflow does not run automatically on push or pull request.
- Runner: `macos-latest` with the latest stable Xcode selected via `maxim-lobanov/setup-xcode`.
- Steps: checkout → select Xcode → run unit tests → build Release `.app` unsigned → stage `Spotiglass.app` at the workspace root → upload as a workflow artifact.
- Artifact name: `Spotiglass-release-app` (retention 14 days). The artifact path is the `Spotiglass.app` bundle directory itself, uploaded with `actions/upload-artifact@v4` — no manual `zip` step is involved.

To produce an artifact:

1. Open the GitHub repository's **Actions** tab.
2. Select the **Release artifact** workflow.
3. Click **Run workflow** and pick the branch.
4. After the run succeeds, open the run's **Summary** page and download the `Spotiglass-release-app` artifact. GitHub serves workflow artifacts as a zip download; unzipping it yields `Spotiglass.app/Contents/...` ready to launch.

### Unsigned distribution expectations

- The artifact is **unsigned** beyond the ad-hoc linker signature. macOS Gatekeeper will refuse to launch it on first open and show an "unidentified developer" or "damaged" dialog.
- To run the downloaded `.app`, either Control-click → **Open** and accept the prompt, or remove the quarantine attribute manually: `xattr -dr com.apple.quarantine ~/Downloads/Spotiglass.app`.
- This step intentionally performs **no** Developer ID signing, **no** notarization, **no** GitHub Release publishing, and **no** deployment. Distribution-grade signing/notarization is out of scope for this workflow.

## Data Spotiglass stores on disk

| Item | Location | Cleared by |
|---|---|---|
| Spotify refresh token | macOS Keychain (service `com.isaaclins.spotiglass.spotify-auth`, accessible only after first unlock, this device only) | **Disconnect** in the app, or any refresh failure that returns HTTP 4xx (revoked / `invalid_grant`) |
| Spotify client ID & granted scope | `UserDefaults` for `com.isaaclins.spotiglass` | The granted scope is cleared by Disconnect; the client ID is preserved so the next sign-in does not require re-pasting it |
| Cached playlists / tracks / settings | `~/Library/Containers/com.isaaclins.spotiglass/Data/Library/Application Support/Spotiglass/SpotifyCache/` | **Disconnect** in the app, or any refresh failure that returns HTTP 4xx |
| Spotify Web Playback SDK web data | Non-persistent `WKWebView` data store, in-memory only | Quitting Spotiglass; the data store is recreated empty on the next launch |

The cache is keyed only by playlist + Spotify-supplied snapshot ID, has a 5-minute TTL, and never contains tokens or other authentication state. Logs published through `PlaybackSessionViewModel.latestLog` only contain SDK status strings — never tokens.

## Known limitations

- **Premium-only playback.** The Web Playback SDK refuses to start without a Spotify Premium account and surfaces an `account_error`; Spotiglass renders this as the "Spotify Premium required" message. Free / Open accounts can browse playlists but cannot stream audio in-app.
- **Unsigned macOS distribution.** As described in [Unsigned distribution expectations](#unsigned-distribution-expectations), the Release build and CI artifact are deliberately unsigned. Production-grade signing/notarization is out of scope for this personal app.
- **No backend.** All Spotify communication happens directly from the macOS client. There is no Spotiglass server, no telemetry, and no shared state between machines.
- **Single Spotify account at a time.** Spotiglass tracks one signed-in session. Switching to a different Spotify account requires Disconnect (which clears the Keychain refresh token and the local cache) followed by Connect Spotify with the new client ID / account.
- **Loopback port is fixed at 43824.** If something else on the machine is listening on `127.0.0.1:43824` during sign-in, the loopback listener fails to bind and the user must close the conflicting service before retrying.
- **Track endpoint cap of 50.** Spotify's `/v1/playlists/{id}/items` endpoint accepts a maximum `limit=50`; Spotiglass paginates internally and stitches the pages together, so this cap is invisible to the user but explains why a single network round-trip will not return more than 50 tracks.

## Roadmap state

The implementation roadmap and per-step rules live under `.cursor/rules/`. `ROADMAP.mdc` is the master index and `roadmap/01-…` through `roadmap/08-…` describe the scope of each completed step.
