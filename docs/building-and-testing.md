# Building and testing

All commands assume the repository root as the current directory.

## Makefile

From the repo root, `make` / `make build` runs a Debug build into `build/DerivedData`. `make run` builds (if needed) and opens the Debug app. `make release` matches the unsigned Release layout below. `make test` runs unit tests. `make clean` removes `build/DerivedData`. Use `UNSIGNED=1` to pass `CODE_SIGNING_ALLOWED=NO` on Debug and test builds (same idea as the raw `xcodebuild` examples).

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
