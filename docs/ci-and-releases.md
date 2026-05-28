# CI and releases

## Workflow

The workflow **Release artifact** lives at [.github/workflows/release-artifact.yml](../.github/workflows/release-artifact.yml).

| Aspect | Detail |
|--------|--------|
| Trigger | `workflow_dispatch` only — not on push or pull request |
| Inputs | `marketing_version` (required), `build_number` (optional; defaults to run number), `release_notes` (optional markdown), `publish_sparkle_update` (default true) |
| Steps | Resolve packages → unit tests → coverage gate → unsigned Release build → Actions artifact → optional Sparkle release |
| Artifact name | `Spotiglass-release-app` (14-day retention) |
| Permanent updates | GitHub Release zip + [appcast](appcast.xml) on GitHub Pages (when Sparkle publish is enabled) |

Download the short-lived Actions artifact from the workflow run **Summary** page. For end users and Sparkle, use **GitHub Releases** and the Pages-hosted appcast.

## Sparkle auto-update (serverless)

No Spotiglass server is required. Updates use:

| Piece | Host |
|-------|------|
| Appcast RSS | [GitHub Pages](https://isaaclins.github.io/spotiglass/appcast.xml) — `docs/appcast.xml` on branch `main` |
| Update `.zip` | [GitHub Releases](https://github.com/isaaclins/spotiglass/releases) — used by Sparkle |
| Installer `.dmg` | [GitHub Releases](https://github.com/isaaclins/spotiglass/releases) — human download, drag-to-Applications |
| Archive signatures | Sparkle EdDSA (`SUPublicEDKey` in the app; private key in CI only) |

The app checks the feed automatically about once per day, or via **Spotiglass → Check for Updates…** in the menu bar. Automatic **install** is off by default (`SUAllowsAutomaticUpdates` = false); the user confirms the update.

### One-time setup (maintainer)

1. **EdDSA keys** (once per Mac / org):
   - Download [Sparkle 2.7.1](https://github.com/sparkle-project/Sparkle/releases/download/2.7.1/Sparkle-2.7.1.tar.xz) or use SPM artifacts under `build/DerivedData/SourcePackages/artifacts/sparkle/`.
   - Run `bin/generate_keys` and confirm `SUPublicEDKey` in [Spotiglass/App/SparkleInfo.plist](../Spotiglass/App/SparkleInfo.plist) matches the printed public key.
   - Export the private key: `bin/generate_keys -x scripts/sparkle_eddsa_private.key` (do **not** commit this file).
2. **GitHub Actions secret**: add repository secret `SPARKLE_EDDSA_PRIVATE_KEY` with the **full contents** of `sparkle_eddsa_private.key`.
3. **GitHub Pages**: repo **Settings → Pages → Build from branch `main` / folder `/docs`**. The feed URL must be `https://isaaclins.github.io/spotiglass/appcast.xml` (matches `SUFeedURL`).

### Cutting a release

1. Dispatch **Release artifact** with a new `marketing_version` and a **higher** `build_number` than any prior release (`CFBundleVersion` must increase).
2. Leave `publish_sparkle_update` enabled when the secret is configured.
3. The workflow will:
   - Build and test an unsigned Release `Spotiglass.app`
   - Upload the 14-day Actions artifact
   - Zip the app for Sparkle, sign the archive with EdDSA, regenerate `docs/appcast.xml`
   - Package the app into a `Spotiglass-{version}.dmg` (drag-to-Applications) for human downloads
   - Create a GitHub Release `v{version}` with both the `.dmg` and Sparkle `.zip` attached
   - Commit `docs/appcast.xml` (and optional `docs/release-notes/`) to `main` for Pages

**Local parity:** `./scripts/sparkle-release.sh 0.2.0 42 docs/release-notes/v0.2.0.md` then create the Release and push the appcast commit manually if needed.

### Testing updates

- Install an older build, then run a newer release workflow (or lower `CURRENT_PROJECT_VERSION` temporarily in Xcode for a dev build).
- Clear Sparkle’s last-check time: `defaults delete com.isaaclins.spotiglass SULastCheckTime`
- Inspect **Console.app** filtered by `Sparkle` if something fails.

## Runner and deployment target

The app and test targets declare **macOS 26** as the deployment minimum. `xcodebuild test` requires the host OS to satisfy the test bundle’s deployment target. Use a GitHub runner image that matches (for example a `macos-26`-class runner), not an older `macos-latest` image whose host OS is below the project minimum.

The workflow pins Xcode explicitly where needed (see the workflow file for the current action steps).

## Unsigned distribution

The CI artifact and GitHub Release builds are **unsigned** beyond ad-hoc signing. Gatekeeper may block first launch and each Sparkle update.

- Control-click the app → **Open**, then confirm; or  
- Remove quarantine: `xattr -dr com.apple.quarantine /path/to/Spotiglass.app`

Sparkle EdDSA verifies that the downloaded zip came from your signing key and feed; it does **not** replace Apple Developer ID notarization. This pipeline intentionally does **not** perform Developer ID signing or notarization.
