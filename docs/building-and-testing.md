# Building and testing

All commands assume the repository root as the current directory.

## Makefile

From the repo root, `make` / `make build` runs a Debug build into `build/DerivedData`. `make run` builds (if needed) and opens the Debug app. `make release` matches the unsigned Release layout below. `make test` runs unit tests. `make clean` removes `build/DerivedData` and deletes every **generic password** Keychain item whose **service** is exactly `com.isaaclins.spotiglass.spotify-auth` (the Spotify refresh token; see `KeychainRefreshTokenStore` in the app). That uses the `security` CLI against your default keychain list; you may be prompted for keychain access the same way the app would. For a full reset when testing auth, use `make clean && make build && make run`. Use `UNSIGNED=1` to pass `CODE_SIGNING_ALLOWED=NO` on Debug and test builds (same idea as the raw `xcodebuild` examples).

## App icon (Dock / Finder) and in-app logo

Per [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer): add the **`.icon`** file via the **Project navigator** (drag from Finder or **Add Files…**). In the target **General → App Icons**, the **App Icon** field must match the Icon Composer filename **without** the extension.

This project keeps **`Spotiglass/AppIcon.icon`** next to **`Assets.xcassets`** (not nested inside the catalog). In **`project.pbxproj`**, the file reference must use **`lastKnownFileType = folder.iconcomposer.icon`** (not `folder`). If Xcode treats the bundle as a generic folder, you only get a raw copy in **`Contents/Resources`**—no **`Assets.car`** / **`AppIcon.icns`**, empty **`assetcatalog_generated_info.plist`**, and Dock stays generic. The target sets **`ASSETCATALOG_COMPILER_APPICON_NAME`** = **`AppIcon`**, **`INFOPLIST_KEY_CFBundleIconName`** = **`AppIcon`**, and **`ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS`** = **`YES`**.

**`SpotiglassBrandLogo`** uses **`NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)`**, not `Image("AppIcon")`: app icons are not a normal catalog **`imageset`**, so named lookups log *No image named 'AppIcon' found in asset catalog* even when the Icon Composer pipeline is correct.

After changing the icon, do a **clean build** and remove the old app from the **Dock** (or clear the icon cache) so macOS shows the update.

`scripts/make_square_icon.swift` is only a helper if you need to build a **raster** app icon set from a flat PNG; the shipped app uses **Icon Composer → Xcode**, not a hand-maintained `AppIcon.appiconset`.

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
