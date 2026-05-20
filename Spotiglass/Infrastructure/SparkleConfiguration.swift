import Foundation

/// Sparkle feed and signing configuration (serverless: GitHub Pages appcast + GitHub Releases).
enum SparkleConfiguration {
    static let feedURL = "https://isaaclins.github.io/spotiglass/appcast.xml"

    /// EdDSA public key from `generate_keys` (pair with `SPARKLE_EDDSA_PRIVATE_KEY` in CI).
    static let publicEDKey = "HknEj0Snyq5WsrWwAxj89njv+qkdMASLlzKMFrlog8Y="
}
