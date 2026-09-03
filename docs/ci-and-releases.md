# CI and releases

> **As of v0.2.0, real releases are cut locally** via `./scripts/sparkle-release.sh`,
> not from CI. The script embeds `SpotiglassEQDriver.driver`, signs the nested
> privileged helper and every shipped bundle with the maintainer's Developer ID
> Application identity, submits the app
> and disk image for notarization, and staples Apple's tickets. CI has neither the
> signing identity nor the notary profile, and `coreaudiod` on macOS 26 rejects
> ad-hoc-signed HAL plugins. A CI-published Sparkle update would therefore ship a
> broken EQ and fail Gatekeeper. The workflow only produces a preview artifact.

## Continuous integration

The workflow **CI** lives at [.github/workflows/ci.yml](../.github/workflows/ci.yml) and is what actually guards `main`. The Spotiglass scheme builds the `SpotiglassEQPrivilegedHelper` target as part of the app build, while signed release packaging signs that nested helper before sealing the app.

| Aspect | Detail |
|--------|--------|
| Trigger | Every pull request, and every push to `main` |
| `static-checks` job | `ubuntu-latest`: microphone / process-tap audit, then the four-part localization audit |
| `test` job | `macos-26`: resolve packages, full unit test suite with coverage, per-file coverage gate |
| On failure | The `.xcresult` bundle is uploaded as an artifact for 14 days |
| Concurrency | Superseded runs are cancelled per branch, except on `main` |

The static audits run on Linux so an obvious violation fails in about a minute instead of waiting on a macOS runner. The `test` job is pinned to `macos-26` for the same deployment-target reason as the release workflow below.

CI does **not** publish a release. It has no access to the Developer ID identity,
the Sparkle private key, or the notary profile, so releases stay local.

> Before this workflow existed, nothing ran the suite automatically and two tests rotted unnoticed on `main` ([#73](https://github.com/isaaclins/spotiglass/issues/73), [#74](https://github.com/isaaclins/spotiglass/issues/74)). Both were found by hand.

## Workflow

The workflow **Release artifact** lives at [.github/workflows/release-artifact.yml](../.github/workflows/release-artifact.yml).

| Aspect | Detail |
|--------|--------|
| Trigger | `workflow_dispatch` only, not on push or pull request |
| Inputs | `marketing_version` (required), `build_number` (optional; defaults to run number) |
| Steps | Resolve packages → unit tests → coverage gate → unsigned Release build → Actions artifact (preview only) |
| Artifact name | `Spotiglass-release-app` (14-day retention) |
| Permanent updates | None; cut releases locally via `scripts/sparkle-release.sh` |

Download the short-lived Actions artifact from the workflow run **Summary** page to preview a branch. For end users and Sparkle, use **GitHub Releases** (published by the local script) and the Pages-hosted appcast.

## Sparkle auto-update (serverless)

No Spotiglass server is required. Updates use:

| Piece | Host |
|-------|------|
| Appcast RSS | [GitHub Pages](https://isaaclins.com/spotiglass/appcast.xml), from `docs/appcast.xml` on branch `main` |
| Update `.zip` | [GitHub Releases](https://github.com/isaaclins/spotiglass/releases), used by Sparkle |
| Installer `.dmg` | [GitHub Releases](https://github.com/isaaclins/spotiglass/releases), human download, drag-to-Applications |
| Archive signatures | Sparkle EdDSA (`SUPublicEDKey` in the app; private key stored locally and never committed) |
| Gatekeeper trust | Developer ID Application, hardened runtime, Apple notarization ticket stapled to the app and disk image |

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

1. Confirm `main` is clean, pushed, and green in CI.
2. Confirm the Developer ID identity and notary profile are available:
   ```sh
   security find-identity -v -p codesigning | grep 'Developer ID Application'
   xcrun notarytool history --keychain-profile spotiglass
   ```
3. Validate the version without building or writing files:
   ```sh
   SPARKLE_RELEASE_VALIDATE_ONLY=1 ./scripts/sparkle-release.sh 0.5.0 7
   ```
4. Run the local release:
   ```sh
   ./scripts/sparkle-release.sh 0.5.0 7 docs/release-notes/v0.5.0.md
   ```
5. The script builds and embeds the EQ driver, signs the privileged helper and
   other nested code from the inside out, notarizes and staples the app, creates
   and notarizes the disk image,
   signs the Sparkle archive with EdDSA, regenerates `docs/appcast.xml`, and bumps
   the project version last. Publish the generated zip and dmg in GitHub Release
   `v0.5.0`, then commit and push the appcast, release notes, and version bump.

The **Release artifact** workflow remains useful for an unsigned preview build.
It does not publish an end-user release.

### Version and build-number rules

The script is the source of truth for versioning and enforces these before it builds anything:

| Rule | Why |
|------|-----|
| Marketing version must be `MAJOR.MINOR.PATCH` | The appcast URL rewrite assumes three numeric components, and the value is interpolated into a `sed` replacement |
| Build number must be a positive integer with no leading zeros | `007` would be written verbatim into `CFBundleVersion` and into delta filenames |
| Build number must be strictly greater than the one recorded in `project.pbxproj` | `CFBundleVersion` must increase or Sparkle will not offer the update |
| All build configurations must agree on `CURRENT_PROJECT_VERSION` | Disagreement means a manual edit, a bad merge, or an aborted run |
| Omitting the build number uses the recorded build plus one | Keeps the sequence contiguous |

On success the script rewrites `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `Spotiglass.xcodeproj/project.pbxproj`, so **the release commit carries the bump** and a later `make build` reports the shipped version. That write happens **last**, after the zip, dmg and appcast exist, so a failure part-way through leaves the project file untouched and the same command can simply be retried.

To check the version arguments without building or writing anything:

```bash
SPARKLE_RELEASE_VALIDATE_ONLY=1 ./scripts/sparkle-release.sh 0.5.0 7
```

### Testing updates

- Install an older build, then cut a newer local release (or lower `CURRENT_PROJECT_VERSION` temporarily in Xcode for a development build).
- Clear Sparkle’s last-check time: `defaults delete com.isaaclins.spotiglass SULastCheckTime`
- Inspect **Console.app** filtered by `Sparkle` if something fails.

## Runner and deployment target

The app and test targets declare **macOS 26** as the deployment minimum. `xcodebuild test` requires the host OS to satisfy the test bundle’s deployment target. Use a GitHub runner image that matches (for example a `macos-26`-class runner), not an older `macos-latest` image whose host OS is below the project minimum.

The workflow pins Xcode explicitly where needed (see the workflow file for the current action steps).

## Signing and notarization

Published GitHub Releases are signed with Developer ID Application, use the
hardened runtime, and carry a stapled Apple notarization ticket. Gatekeeper must
accept both the app and the disk image without asking users to bypass security.
The release script verifies the code signature, validates the stapled app ticket,
and runs `spctl` before packaging. It notarizes and staples the disk image as a
separate distributed artifact.

The short-lived CI preview artifact remains unsigned because GitHub-hosted
runners do not have the local signing identity or notary profile. Do not publish
that artifact as an end-user release.

Sparkle EdDSA independently verifies that the downloaded zip came from the feed's
signing key. It complements Developer ID and notarization; it does not replace
either one.
