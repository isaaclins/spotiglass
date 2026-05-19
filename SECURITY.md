# Security policy

## Reporting a vulnerability

If you believe you have found a security issue in Spotiglass, please report it
privately. Do not open a public GitHub issue for exploitable vulnerabilities.

**Preferred:** [GitHub private vulnerability reporting](https://github.com/isaaclins/spotiglass/security/advisories/new) for this repository (if enabled).

**Alternative:** Contact the repository owner through a private channel you already
use for this project (for example a direct message). Include enough detail to
reproduce the issue.

We aim to acknowledge reports within a reasonable time and will work with you on
a fix and coordinated disclosure when appropriate.

## What not to include in reports or public issues

- Spotify **refresh tokens**, **access tokens**, or authorization codes
- Spotify **client secrets** (this app uses PKCE; there should be no client secret)
- Contents of your **Keychain** or `settings.json` from Application Support
- OAuth callback URLs containing live `code=` or `state=` parameters from a real session

Redact or rotate credentials if they were accidentally exposed.

## Scope

In scope:

- Spotiglass macOS app code in this repository
- OAuth loopback listener and token storage behavior documented in [data-storage.md](docs/data-storage.md)
- Local cache and settings handling

Out of scope:

- Vulnerabilities in Spotify's services or SDKs (report those to Spotify)
- Social engineering or physical access to an unlocked Mac with an active session
- Issues that require a user to install a malicious modified build from an untrusted source

## Supported versions

Security fixes are applied on the default development branch. There is no separate
LTS release channel for this personal project.
