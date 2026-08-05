import Foundation

/// Sparkle feed and signing configuration (serverless: GitHub Pages appcast + GitHub Releases).
enum SparkleConfiguration {
    /// Canonical Pages host, reached over HTTPS with no redirect.
    ///
    /// The `isaaclins.github.io` alias 301s to `http://isaaclins.com/...`, and App Transport
    /// Security cancels that plaintext hop, so every update check failed. Point at the final
    /// HTTPS URL directly instead of relying on a redirect.
    static let feedURL = "https://isaaclins.com/spotiglass/appcast.xml"

    /// EdDSA public key from `generate_keys` (pair with `SPARKLE_EDDSA_PRIVATE_KEY` in CI).
    static let publicEDKey = "HknEj0Snyq5WsrWwAxj89njv+qkdMASLlzKMFrlog8Y="
}
