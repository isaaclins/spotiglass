import Foundation

/// Shared identity and requirement builder for the app, helper, and driver.
/// Keeping the signer policy here prevents one side of the trust boundary from
/// silently accepting a broader certificate set than the other.
enum EqualizerPrivilegedHelperIdentity {
    static let machServiceName = "com.isaaclins.spotiglass.eqprivilegedhelper"
    static let plistName = "com.isaaclins.spotiglass.eqprivilegedhelper.plist"
    static let helperBundleIdentifier = "com.isaaclins.spotiglass.eqprivilegedhelper"
    static let driverBundleName = "SpotiglassEQDriver.driver"
    static let driverRelativePath = "Contents/Library/Audio/Plug-Ins/HAL"
    static let resourceDriverRelativePath = "Contents/Resources"
    static let systemHALDirectory = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL", isDirectory: true)
    static let signingTeamIdentifier = "BHAF4L4726"
    static let localCertificateCommonName = "Spotiglass Local Dev"

    // Apple-signed builds are pinned to the distribution team's leaf OU and
    // Apple chain. The local self-signed identity is an explicit development
    // alternative because it has no Apple team identifier.
    private static let trustedSignerRequirement =
        "(anchor apple generic and certificate leaf[subject.OU] = \"\(signingTeamIdentifier)\") or certificate leaf[subject.CN] = \"\(localCertificateCommonName)\""

    static let helperRequirement = requirement(for: helperBundleIdentifier)

    // These are consumed by the helper target, which Periphery analyzes separately.
    // periphery:ignore
    static let clientRequirement = requirement(for: "com.isaaclins.spotiglass")
    // periphery:ignore
    static let driverRequirement = requirement(for: "com.isaaclins.spotiglass.eqdriver")

    static func requirement(for identifier: String) -> String {
        "(\(trustedSignerRequirement)) and identifier \"\(identifier)\""
    }

    static var helperVersionURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Spotiglass", isDirectory: true)
            .appendingPathComponent("eq-privileged-helper.version", isDirectory: false)
    }
}
