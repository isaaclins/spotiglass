# Building and testing

All commands assume the repository root as the current directory.

## Makefile

From the repo root, `make` / `make build` runs a Debug build into `build/DerivedData`. The Spotiglass scheme also builds and embeds the `SpotiglassEQPrivilegedHelper` LaunchDaemon and its plist. `make run` builds (if needed) and opens the Debug app. `make release` matches the unsigned Release layout below. `make test` runs unit tests with `-parallel-testing-enabled NO` so results stay deterministic (parallel runs can occasionally surface ordering races in unrelated suites). `make format` and `make lint` use [swift-format](https://github.com/swiftlang/swift-format) with the repo [`.swift-format`](../.swift-format) configuration (`brew install swift-format`). `make scan` runs `periphery scan` for dead-code detection and `tokei .` for line counts. Both run in one shell step so a failing Periphery build still prints Tokei output; the final exit status reflects Periphery first, then Tokei if Periphery succeeded. `make clean` removes `build/DerivedData` and deletes every **generic password** Keychain item whose **service** is exactly `com.isaaclins.spotiglass.spotify-auth` (the Spotify refresh token; see `KeychainRefreshTokenStore` in the app). That uses the `security` CLI against your default keychain list; you may be prompted for keychain access the same way the app would. For a full reset when testing auth, use `make clean && make build && make run`. Use `UNSIGNED=1` to pass `CODE_SIGNING_ALLOWED=NO` on Debug and test builds (same idea as the raw `xcodebuild` examples).

## App icon (Dock / Finder) and in-app logo

Per [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer): add the **`.icon`** file via the **Project navigator** (drag from Finder or **Add Files…**). In the target **General → App Icons**, the **App Icon** field must match the Icon Composer filename **without** the extension.

This project keeps **`Spotiglass/AppIcon.icon`** next to **`Assets.xcassets`** (not nested inside the catalog). In **`project.pbxproj`**, the file reference must use **`lastKnownFileType = folder.iconcomposer.icon`** (not `folder`). If Xcode treats the bundle as a generic folder, you only get a raw copy in **`Contents/Resources`**, no **`Assets.car`** / **`AppIcon.icns`**, empty **`assetcatalog_generated_info.plist`**, and Dock stays generic. The target sets **`ASSETCATALOG_COMPILER_APPICON_NAME`** = **`AppIcon`**, **`INFOPLIST_KEY_CFBundleIconName`** = **`AppIcon`**, and **`ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS`** = **`YES`**.

**`SpotiglassBrandLogo`** uses **`NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)`**, not `Image("AppIcon")`: app icons are not a normal catalog **`imageset`**, so named lookups log *No image named 'AppIcon' found in asset catalog* even when the Icon Composer pipeline is correct.

After changing the icon, do a **clean build** and remove the old app from the **Dock** (or clear the icon cache) so macOS shows the update. The shipped app uses **Icon Composer → Xcode**, not a hand-maintained `AppIcon.appiconset`.

To regenerate the logo used by the root `README.md` from the current app icon pipeline:

```sh
scripts/generate_readme_logo.sh
```

Add `--rebuild` to force a fresh unsigned Release build before exporting the PNG.

## List schemes

```sh
xcodebuild -list -project Spotiglass.xcodeproj
```

## Debug build

```sh
xcodebuild -project Spotiglass.xcodeproj -scheme Spotiglass -destination 'platform=macOS' build
```

Add `CODE_SIGNING_ALLOWED=NO` if you need to build without signing locally.

## Unit tests

```sh
xcodebuild -project Spotiglass.xcodeproj -scheme Spotiglass -destination 'platform=macOS' test
```

Because `SpotiglassTests` uses **`TEST_HOST`** (tests run inside `Spotiglass.app`), the app’s normal launch path would call `restoreSessionIfAvailable()` and touch the Spotify refresh token in the **login keychain**, which can trigger a password prompt. When Xcode sets **`XCTestConfigurationFilePath`** (always true for this scheme’s test action), the app uses an in-memory refresh-token store instead so **unit tests do not read or write that Keychain item**.

If you add UI tests or another host that does not set that variable, expect Keychain behavior to match a normal app launch.

## Code coverage

Run the full test suite with coverage and print a per-target summary:

```sh
./scripts/coverage.sh
```

Enforce per-file thresholds (default **80%** region coverage on every `Spotiglass/**/*.swift` file). During ramp-up, files listed in [`scripts/coverage-allowlist.json`](../scripts/coverage-allowlist.json) are excluded from the gate; remove paths from that list as each file reaches 80%.

```sh
make coverage-check
# or, after a coverage run:
./scripts/check-coverage-per-file.sh
```

The check prints `FILES_AT_THRESHOLD` (count of gated files at or above the threshold). View-heavy code uses [ViewInspector](https://github.com/nalexn/ViewInspector) on the test target; logic is tested directly or via extracted helpers (`BrowserWidthCommitPolicy`, `PlaylistBrowserPlaybackHelpers`, etc.).

Auth launch guardrails are covered by `SpotifyAuthStepTests`:
- concurrent `signIn()` calls stay one-flight (extra triggers are ignored while one browser auth is active),
- immediate retries after a sign-in failure are suppressed briefly before retries are allowed again.

## Unsigned Release bundle (matches CI packaging)

```sh
xcodebuild \
  -project Spotiglass.xcodeproj \
  -scheme Spotiglass \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  clean build
```

The built app is at:

`build/DerivedData/Build/Products/Release/Spotiglass.app`

This product uses only the ad-hoc linker signature macOS applies automatically. It is **not** Developer ID signed and **not** notarized. That is fine for local work, but such a build cannot be published: Gatekeeper refuses it on any other Mac.

## Signed and notarized release

`scripts/sparkle-release.sh` signs and notarizes automatically. Two facts are worth knowing before running it.

**Developer ID is the only certificate that works for distribution.** An `Apple Development` certificate produces a real `TeamIdentifier`, so a build signed with it looks signed, but Apple will not notarize it and Gatekeeper rejects it everywhere except a Mac that already trusts that development certificate. The script requires `Developer ID Application` and fails with an explanation if it is missing. Contributors who only need a local build can set `ALLOW_UNSIGNED_RELEASE=1`, which warns loudly and produces an ad-hoc build that must never be published.

**Nested code is signed explicitly, deepest first.** Signing a bundle seals its contents, so Sparkle's `Downloader.xpc`, `Installer.xpc`, `Autoupdate` and `Updater.app` are signed before `Sparkle.framework`, the privileged helper and audio driver are signed after they are embedded, and the app is signed last. `--deep` is deliberately not used: it is deprecated and applies one identity and entitlement set to nested code that may need different ones, which is a common cause of notarization rejections.

### One time notarization setup

Notarization uploads the signed app to Apple, which scans it and returns a ticket that gets stapled into the bundle. Store the credentials once, under the profile name `spotiglass`:

```sh
xcrun notarytool store-credentials "spotiglass" \
  --apple-id <your-apple-id-email> \
  --team-id <your-team-id> \
  --password <app-specific-password>
```

`--password` takes an **app-specific password** generated at [account.apple.com](https://account.apple.com) under Sign-In and Security, not your Apple ID password. Apple rejects the account password here. The credentials are stored in your Keychain, so the secret never needs to appear in a script, a file, or an environment variable.

If the profile is absent, the release script stops rather than producing an
artifact that Gatekeeper will reject. For local signing tests only,
`ALLOW_UNNOTARIZED_RELEASE=1` permits a signed but unnotarized artifact and warns
that it must never be published.

### Verifying a build yourself

```sh
codesign --verify --strict --verbose=2 path/to/Spotiglass.app
codesign -dvv path/to/Spotiglass.app 2>&1 | grep -E 'Authority|TeamIdentifier|Runtime'
xcrun stapler validate path/to/Spotiglass.app
spctl --assess --verbose=4 --type execute path/to/Spotiglass.app

xcrun stapler validate path/to/Spotiglass.dmg
spctl --assess --verbose=4 --type open --context context:primary-signature path/to/Spotiglass.dmg
```

`spctl` is the check that matters, because it reflects what a user actually experiences:

- `accepted` with `source=Notarized Developer ID` is a publishable build.
- `rejected` with `source=Unnotarized Developer ID` means signing is correct but notarization has not run.
- Anything mentioning ad-hoc or an unidentified developer means the signing step did not happen at all.

### Known risk: hardened runtime and the audio driver

Notarization requires the hardened runtime (`--options runtime`), and the EQ driver is loaded by `coreaudiod` rather than by the app. Verify that audio still plays through the equalizer on a signed build before publishing a release. A signature that verifies cleanly does not prove the driver still loads.
