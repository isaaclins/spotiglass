# CI and releases

## Workflow

The workflow **Release artifact** lives at `.github/workflows/release-artifact.yml`.

| Aspect | Detail |
|--------|--------|
| Trigger | `workflow_dispatch` only — not on push or pull request |
| Steps | Checkout → Xcode selection → unit tests → unsigned Release `Spotiglass.app` → upload artifact |
| Artifact name | `Spotiglass-release-app` |
| Retention | 14 days |

Download the artifact from the workflow run **Summary** page. GitHub delivers it as a zip; after unzip you get `Spotiglass.app`.

## Runner and deployment target

The app and test targets declare **macOS 26** as the deployment minimum. `xcodebuild test` requires the host OS to satisfy the test bundle’s deployment target. Use a GitHub runner image that matches (for example a `macos-26`-class runner), not an older `macos-latest` image whose host OS is below the project minimum.

The workflow pins Xcode explicitly where needed (see the workflow file for the current action steps).

## Unsigned distribution

The CI artifact is **unsigned** beyond ad-hoc signing. Gatekeeper may block first launch.

- Control-click the app → **Open**, then confirm; or  
- Remove quarantine: `xattr -dr com.apple.quarantine /path/to/Spotiglass.app`

This pipeline intentionally does **not** perform Developer ID signing, notarization, or publishing to GitHub Releases.
