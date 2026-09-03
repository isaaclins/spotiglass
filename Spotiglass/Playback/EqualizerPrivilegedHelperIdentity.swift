import Foundation

/// Shared identity and requirement builder for the app, helper, and driver.
/// Keeping the signer policy here prevents one side of the trust boundary from
/// silently accepting a broader certificate set than the other.
enum EqualizerPrivilegedHelperIdentity {
    static let machServiceName = "com.isaaclins.spotiglass.eqprivilegedhelper"
    static let plistName = "com.isaaclins.spotiglass.eqprivilegedhelper.plist"
    static let applicationBundleIdentifier = "com.isaaclins.spotiglass"
    static let helperBundleIdentifier = "com.isaaclins.spotiglass.eqprivilegedhelper"
    static let driverBundleIdentifier = "com.isaaclins.spotiglass.eqdriver"
    static let driverBundleName = "SpotiglassEQDriver.driver"
    static let driverRelativePath = "Contents/Library/Audio/Plug-Ins/HAL"
    static let resourceDriverRelativePath = "Contents/Resources"
    static let systemHALDirectory = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL", isDirectory: true)
    static let localCertificateCommonName = "Spotiglass Local Dev"
    static let teamIdentifierInfoKey = "SpotiglassCodeSigningTeamIdentifier"

    static var helperRequirement: String {
        requirement(for: helperBundleIdentifier)
    }

    static var clientRequirement: String {
        requirement(for: applicationBundleIdentifier)
    }

    static var driverRequirement: String {
        requirement(for: driverBundleIdentifier)
    }

    static func helperRequirement(for bundle: Bundle) -> String {
        requirement(for: helperBundleIdentifier, bundle: bundle)
    }

    /// Builds the pure signer requirement used by all three code objects.
    /// Developer ID and Apple Development certificates identify the team via
    /// their leaf OU; the local development certificate has no team OU, so its
    /// stable common name is the explicit development-only alternative.
    static func requirement(
        for identifier: String,
        teamIdentifier: String,
        localCertificateCommonName: String = Self.localCertificateCommonName
    ) -> String {
        "((anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\") or certificate leaf[subject.CN] = \"\(localCertificateCommonName)\") and identifier \"\(identifier)\""
    }

    private static func requirement(for identifier: String, bundle: Bundle = .main) -> String {
        requirement(
            for: identifier,
            teamIdentifier: teamIdentifier(from: bundle)
        )
    }

    private static func teamIdentifier(from bundle: Bundle) -> String {
        let configured = bundle.object(forInfoDictionaryKey: teamIdentifierInfoKey) as? String
        let trimmed = configured?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "UNCONFIGURED" : trimmed
    }

    static var helperVersionURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Spotiglass", isDirectory: true)
            .appendingPathComponent("eq-privileged-helper.version", isDirectory: false)
    }
}
