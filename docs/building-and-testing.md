# Building and testing

All commands assume the repository root as the current directory.

## Makefile

From the repo root, `make` / `make build` runs a Debug build into `build/DerivedData`. `make run` builds (if needed) and opens the Debug app. `make release` matches the unsigned Release layout below. `make test` runs unit tests with `-parallel-testing-enabled NO` so results stay deterministic (parallel runs can occasionally surface ordering races in unrelated suites). `make format` and `make lint` use [swift-format](https://github.com/swiftlang/swift-format) with the repo [`.swift-format`](../.swift-format) configuration (`brew install swift-format`). `make scan` runs `periphery scan` for dead-code detection and `tokei .` for line counts. Both run in one shell step so a failing Periphery build still prints Tokei output; the final exit status reflects Periphery first, then Tokei if Periphery succeeded. `make clean` removes `build/DerivedData` and deletes every **generic password** Keychain item whose **service** is exactly `com.isaaclins.spotiglass.spotify-auth` (the Spotify refresh token; see `KeychainRefreshTokenStore` in the app). That uses the `security` CLI against your default keychain list; you may be prompted for keychain access the same way the app would. For a full reset when testing auth, use `make clean && make build && make run`. Use `UNSIGNED=1` to pass `CODE_SIGNING_ALLOWED=NO` on Debug and test builds (same idea as the raw `xcodebuild` examples).

## App icon (Dock / Finder) and in-app logo

Per [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer): add the **`.icon`** file via the **Project navigator** (drag from Finder or **Add Files…**). In the target **General → App Icons**, the **App Icon** field must match the Icon Composer filename **without** the extension.

This project keeps **`Spotiglass/AppIcon.icon`** next to **`Assets.xcassets`** (not nested inside the catalog). In **`project.pbxproj`**, the file reference must use **`lastKnownFileType = folder.iconcomposer.icon`** (not `folder`). If Xcode treats the bundle as a generic folder, you only get a raw copy in **`Contents/Resources`**—no **`Assets.car`** / **`AppIcon.icns`**, empty **`assetcatalog_generated_info.plist`**, and Dock stays generic. The target sets **`ASSETCATALOG_COMPILER_APPICON_NAME`** = **`AppIcon`**, **`INFOPLIST_KEY_CFBundleIconName`** = **`AppIcon`**, and **`ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS`** = **`YES`**.

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

Because `SpotiglassTests` uses **`TEST_HOST`** (tests run inside `Spotiglass.app`), the app’s normal launch path would call `restoreSessionIfAvailable()` and touch the Spotify refresh token in the **login keychain**—which can trigger a password prompt. When Xcode sets **`XCTestConfigurationFilePath`** (always true for this scheme’s test action), the app uses an in-memory refresh-token store instead so **unit tests do not read or write that Keychain item**.

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

This product uses only the ad-hoc linker signature macOS applies automatically. It is **not** Developer ID signed and **not** notarized.
