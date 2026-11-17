# Wax upgrade validation

## Installed filename

Sparkle intentionally preserves the existing bundle filename, including user-chosen filenames.
The copy of Sparkle already in 0.8.44 cannot be retrofitted by changing a build flag in Wax.
I kept the bundle ID and update signing key, and rename only the exact legacy filename on first
launch. A same-directory `renamex_np(RENAME_EXCL)` keeps file identity and refuses to overwrite
another installation. Custom names and App Translocation are left alone. A failed move leaves
the app usable; a failed relaunch attempts the same no-overwrite rename back. User data is never
moved, copied or deleted by this migration.

I compared these real Mac rename precedents. These sources distinguish a changed download
filename from the policy used by an already-installed updater; they are not claims that every
updater automatically renames every installation.

- **GitHub for Mac → GitHub Desktop.** GitHub's [2015 announcement](https://github.blog/news-insights/product-news/github-desktop-is-now-available/)
  explicitly says existing Mac installations upgrade automatically. The contemporaneous
  [distribution change](https://github.com/Homebrew/homebrew-cask/commit/890ae85c93f9df17fd9fc3e7b5c35c6e538e2e95)
  records `GitHub.app` becoming `GitHub Desktop.app`, with the same `central.github.com/mac/appcast.xml`
  feed. GitHub's closed native installer implementation is not published in those sources;
  they establish the automatic transition and the new distributed bundle, not the exact rename code.
- **Riot → Element.** The [announcement](https://element.io/blog/welcome-to-element/) and
  [rebrand implementation](https://github.com/element-hq/element-desktop/commit/466a871094fdc59f133b73f4e25cd685ab3745e8)
  show the productName transition from Riot to Element. The temporary
  [Element (Riot) name](https://github.com/element-hq/element-desktop/commit/4a488c9ab2f09b3f75a2be6eb5bf1a4692c8ba11)
  was [removed](https://github.com/element-hq/element-desktop/commit/94086f247a8c89630ddf3c134e4af50c18d1af3b)
  separately from the preserved legacy user-data directory. Its
  [Mac updater](https://github.com/element-hq/element-desktop/blob/v1.7.1/src/updater.js)
  uses Electron/Squirrel. Squirrel's [rename implementation](https://github.com/Squirrel/Squirrel.Mac/pull/149)
  selects the new bundle name only when the existing name matches its executable and the
  destination is free. Applying that framework policy to Element is an inference from the code,
  not a captured historical upgrade. A [later Squirrel relaunch report](https://github.com/Squirrel/Squirrel.Mac/issues/325)
  is a reason to test the restart as well as the move.
- **Aurora → Firefox Aurora / Nightly → Firefox Nightly.** Mozilla's
  [verified rename](https://bugzilla.mozilla.org/show_bug.cgi?id=696436) changes new Mac bundles
  to `FirefoxAurora.app` and `FirefoxNightly.app`. The discussion explicitly permits existing
  installations to keep their old filenames. This is the counterexample to assuming a product
  rename must also rename installed bundles. Mozilla's own updater continues to update those
  installations; new distribution names and existing paths are separate decisions.
- **iTerm → iTerm2.** The [release script](https://github.com/gnachman/iTerm2/blob/master/tools/release_beta.sh)
  still packages `iTerm.app` for auto-update. Its
  [updater](https://github.com/gnachman/iTerm2/blob/master/sources/AppLaunch/iTermSoftwareUpdater.swift)
  clears the older alternate-name preference. Keeping the historical filename is viable, but
  does not meet Wax's requested Finder filename.

Sparkle reports [2866](https://github.com/sparkle-project/Sparkle/issues/2866),
[1442](https://github.com/sparkle-project/Sparkle/issues/1442) and
[782](https://github.com/sparkle-project/Sparkle/issues/782) independently confirm its
filename-preservation behavior. A normalization flag in a new app cannot retrofit the updater
already shipped inside 0.8.44.

## Populated 0.8.44 upgrade

I extracted the actual published 0.8.44 archive, without editing its bundle or signature, into
an isolated installation directory. Foundation's home was redirected with `CFFIXED_USER_HOME`.
The app ran in screenshot mode against the loopback Spotify stand-in. It displayed an authenticated
sample session and a pinned Night Drive playlist. Settings included light appearance, a custom
“Upgrade reference” equalizer preset, preamp −2 dB and ten populated bands. The equalizer remained
disabled to avoid starting any audio driver.

Sparkle 2.7.1 downloaded and verified the Developer ID signed, notarized 0.8.45 build 56 ZIP from
a loopback appcast. I deferred installation so the app could be launched explicitly with the same
isolated home and stand-in environment. After quitting 0.8.44, Sparkle installed the candidate into
`Spotiglass.app`. The candidate's first launch renamed it to `Wax.app` and restarted from
`Wax.app/Contents/MacOS/Wax`. The main window still displayed the sample account and pinned playlist.

SHA-256 values before and after the launched upgrade were identical:

| File | SHA-256 |
| --- | --- |
| settings.json | `a76243952d0da9451565ec8112d4cc4cd0978111b61fb9408ba9dd81bfd16b1c` |
| SpotifyCache/pinned/sample.json | `a6164aa2490e075a44f573b1592f805277bb48245fe48bab0014df77cf6aff04` |

Strict/deep signature verification passed after the move. The designated requirement retains
`com.isaaclins.spotiglass`, Apple's Developer ID chain and team `BHAF4L4726`.

## Credentials, Dock and login items

I used no real Spotify account, Apple Music library or saved credential. In a disposable
Keychain, the published 0.8.44 executable stored a dummy generic-password item using the exact
production service `com.isaaclins.spotiglass.spotify-auth`, account `spotify-refresh-token`,
no explicit access-group attribute and `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
The Wax executable read the same bytes with the same query. Both had the same Developer ID
and designated requirement (`com.isaaclins.spotiglass`, team `BHAF4L4726`).

To run the offline probe inside each actual app process before its network/UI startup,
I re-signed isolated copies with test-only DYLD injection entitlements. The injected constructor
used Security.framework with an explicit disposable-Keychain target/search list. This is an
exact credential-identity and access-control check, not a real OAuth refresh or an untouched
production-signature test. The save and read returned `errSecSuccess`. I deleted the dummy,
confirmed `errSecItemNotFound`, and deleted the disposable Keychain. The production token-store
source is unchanged from 0.8.44. Apple Music has no app-managed Keychain token: its sign-in
state comes from MusicKit/system authorization; I did not modify the real system grant.

The current-session integration test backs up the complete Dock preference domain and enumerates
login-item targets/hidden state first. It pins the extracted published 0.8.44 app in the Dock and
adds it as a native user login item, then upgrades through Sparkle to a Developer ID signed Wax
candidate with isolated home and loopback stand-in data. Test-only `LSEnvironment` provides that
isolation when the Dock or login-item target launches it; no real library or audio device is used.

The original implementation exposed a real failure: the Dock eventually resolves the moved
bundle, but a pre-update native login-item alias remains unresolved after the rename. The fix
captures only entries resolving to this exact bundle before the move, then recreates those
entries at Wax's path, preserving their order and hidden setting, only after successful relaunch.
It uses the native shared-file-list API because existing user-created login items are not
SMAppService registrations. It does not enable login launch for anyone who had it disabled.
A failed move or relaunch leaves the original login items unchanged.

The final replay installed successfully through Sparkle, and the renamed signed bundle passed
strict/deep signature verification. Clicking the original pinned Dock tile launched Wax from
`Wax.app`. The preserved login item pointed at `Wax.app` and launching it started Wax too, with
its hidden setting and list position unchanged. After cleanup, the Dock preferences and the
login-item list matched the backups taken before the test.

The rename now runs first thing at launch, before the equalizer, playback or the sound-output log
start, and the old copy waits there until the renamed copy is open. (The updater object exists by
then, but its first check needs the run loop, which the old copy never reaches.) If the open fails
or hasn't answered within 30 seconds, the rename is undone and that copy carries on; a late answer
is refused, and a copy that opens late is closed again. I checked it
with a signed build copied in as `Spotiglass.app` and an isolated home: it renamed itself to
`Wax.app` and quit, its log holds only its launch line, and the renamed copy started 80 ms later
and did the whole startup.

## Automated checks

Six migration tests pass. They cover bookmark/file identity, occupied destination, custom name,
App Translocation, failed moves, relaunch success, relaunch failure and rollback, and a relaunch
that doesn't answer in time. The Python script tests pass. The signed candidate passed notarization, stapling and Gatekeeper.
