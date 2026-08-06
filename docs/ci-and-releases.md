# CI and releases

> **As of v0.2.0, real releases are cut locally** via `./scripts/sparkle-release.sh`,
> not from CI. The script embeds `SpotiglassEQDriver.driver` and re-signs it with
> the maintainer's Apple Development identity — CI doesn't have access to that
> identity, and `coreaudiod` on macOS 26 rejects ad-hoc-signed HAL plugins, so a
> CI-published Sparkle update would ship a broken EQ to every user. The
> Sparkle/Release/Pages steps have been removed from the workflow; what's left is
> a preview-only build for reviewing a branch.

## Continuous integration

The workflow **CI** lives at [.github/workflows/ci.yml](../.github/workflows/ci.yml) and is what actually guards `main`.

| Aspect | Detail |
|--------|--------|
| Trigger | Every pull request, and every push to `main` |
| `static-checks` job | `ubuntu-latest`: microphone / process-tap audit, then the four-part localization audit |
| `test` job | `macos-26`: resolve packages, full unit test suite with coverage, per-file coverage gate |
| On failure | The `.xcresult` bundle is uploaded as an artifact for 14 days |
| Concurrency | Superseded runs are cancelled per branch, except on `main` |

The static audits run on Linux so an obvious violation fails in about a minute instead of waiting on a macOS runner. The `test` job is pinned to `macos-26` for the same deployment-target reason as the release workflow below.

CI does **not** build or publish a release. It has no access to the signing identity, so releases stay local.

> Before this workflow existed, nothing ran the suite automatically and two tests rotted unnoticed on `main` ([#73](https://github.com/isaaclins/spotiglass/issues/73), [#74](https://github.com/isaaclins/spotiglass/issues/74)). Both were found by hand.

## Workflow

The workflow **Release artifact** lives at [.github/workflows/release-artifact.yml](../.github/workflows/release-artifact.yml).

| Aspect | Detail |
|--------|--------|
| Trigger | `workflow_dispatch` only — not on push or pull request |
| Inputs | `marketing_version` (required), `build_number` (optional; defaults to run number) |
| Steps | Resolve packages → unit tests → coverage gate → unsigned Release build → Actions artifact (preview only) |
| Artifact name | `Spotiglass-release-app` (14-day retention) |
| Permanent updates | None — cut releases locally via `scripts/sparkle-release.sh` |

Download the short-lived Actions artifact from the workflow run **Summary** page to preview a branch. For end users and Sparkle, use **GitHub Releases** (published by the local script) and the Pages-hosted appcast.

## Sparkle auto-update (serverless)

No Spotiglass server is required. Updates use:

| Piece | Host |
|-------|------|
| Appcast RSS | [GitHub Pages](https://isaaclins.com/spotiglass/appcast.xml) — `docs/appcast.xml` on branch `main` |
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
3. **GitHub Pages**: repo **Settings → Pages → Build from branch `main` / folder `/docs`**. The feed URL must be `https://isaaclins.com/spotiglass/appcast.xml` (matches `SUFeedURL`).

> **`SUFeedURL` must be the final HTTPS URL, never a redirecting alias.** `isaaclins.github.io`
> is a Pages alias for the `isaaclins.com` custom domain, and it 301s to **`http://`** because
> GitHub cannot enforce HTTPS while the domain is proxied through Cloudflare rather than pointed
> at the Pages IPs. App Transport Security cancels that plaintext hop, so Sparkle fails every
> check with "An error occurred in retrieving update information." (issue #80). Verify with:
>
> ```sh
> curl -sS -o /dev/null -w '%{num_redirects} %{http_code}\n' "$(
>   /usr/libexec/PlistBuddy -c 'Print :SUFeedURL' Spotiglass/App/SparkleInfo.plist)"
> # expect: 0 200
> ```

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
