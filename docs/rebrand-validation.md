# Wax upgrade validation

## Installed filename

Sparkle intentionally preserves the existing bundle filename, including user-chosen filenames.
The copy of Sparkle already in 0.8.44 cannot be retrofitted by changing a build flag in Wax.
I kept the bundle ID and update signing key, and rename only the exact legacy filename on first
launch. A same-directory `renamex_np(RENAME_EXCL)` keeps file identity and refuses to overwrite
another installation. Custom names and App Translocation are left alone. A failed move leaves
the app usable; a failed relaunch attempts the same no-overwrite rename back. User data is never
moved, copied or deleted by this migration.

I compared these reported approaches and failure cases. Only the first is a well-known named
app; I could not substantiate three to five well-known apps with published implementation details,
so I have not attributed an undocumented solution to them.

- [iTerm2's release script](https://github.com/gnachman/iTerm2/blob/master/tools/release_beta.sh)
  deliberately packages `iTerm.app` for auto-update even though the product is iTerm2. Its
  [updater](https://github.com/gnachman/iTerm2/blob/master/sources/AppLaunch/iTermSoftwareUpdater.swift)
  also removes the older alternate-name preference. Keeping the old filename is compatible,
  but does not meet this rename's Finder requirement.
- [QuickIP to Quicker IP](https://github.com/sparkle-project/Sparkle/issues/2866)
  reports the same installed-filename problem and the custom-framework normalization option.
- [The 2018 rename report](https://github.com/sparkle-project/Sparkle/issues/1442)
  keeps its bundle ID to preserve signature verification, but normalization still retains the
  old filename. The follow-up [Sparkle change](https://github.com/sparkle-project/Sparkle/pull/1444)
  cannot change the updater already installed on users' machines.
- [The trademark-driven rename](https://github.com/sparkle-project/Sparkle/issues/782)
  confirms that preserving filenames is intentional, while failure to relaunch is a separate
  bug. This is why the app-side migration explicitly relaunches and handles failure.

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

No real Spotify account, Apple Music library or real saved credential was used. Screenshot mode
uses an in-memory stand-in refresh token, so this test does **not** establish end-to-end preservation
of a real OAuth login. Separately, I saved a synthetic token in a disposable macOS Keychain using
a signed legacy-named executable, then read it with a renamed, newly signed executable carrying
the same bundle identifier and Developer ID requirement. That read succeeded. The disposable
Keychain was deleted. `KeychainRefreshTokenStore.swift` is byte-for-byte identical to 0.8.44
(SHA-256 `b49db7bcb464ac97f5222649588d59e58a69aae90c25f85fce25e64324a1b3c5`).

The automated filesystem test creates a bookmark before migration and resolves it to Wax after
the move, with the same file resource identifier and intact payload. This exercises the identity
mechanism used by Finder aliases/bookmarks. I did not modify the real Dock or login-item preferences;
an actual pinned Dock entry/login-item launch has not been tested in a separate macOS user session.

## Automated checks

Five migration tests pass. They cover bookmark/file identity, occupied destination, custom name,
App Translocation, failed moves, relaunch success, relaunch failure and rollback. The migration
file has 98.44% line coverage (63/64 executable lines). The broader CI run passed its tests before
failing the initial migration coverage gate; the refactor and additional tests address that failure.
All 37 Python script tests pass, with one skipped. The signed candidate passed notarization,
stapling and Gatekeeper. No release was published and the repository has not been renamed.
