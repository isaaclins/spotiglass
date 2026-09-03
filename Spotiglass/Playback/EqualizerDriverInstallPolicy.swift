import Foundation

/// Version identity for the driver bundle. The release and build components
/// are compared independently so a driver rebuild cannot be mistaken for the
/// same payload merely because its marketing version stayed unchanged.
struct EqualizerDriverVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    let releaseComponents: [Int]
    let buildComponents: [Int]

    init?(shortVersion: String, build: String) {
        guard let releaseComponents = Self.parseComponents(shortVersion),
            let buildComponents = Self.parseComponents(build)
        else { return nil }
        self.releaseComponents = Self.normalized(releaseComponents)
        self.buildComponents = Self.normalized(buildComponents)
    }

    var description: String {
        let release = releaseComponents.map(String.init).joined(separator: ".")
        let build = buildComponents.map(String.init).joined(separator: ".")
        return "\(release) (\(build))"
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        guard lhs.releaseComponents == rhs.releaseComponents else {
            return compare(lhs.releaseComponents, rhs.releaseComponents)
        }
        return compare(lhs.buildComponents, rhs.buildComponents)
    }

    private static func compare(_ lhs: [Int], _ rhs: [Int]) -> Bool {
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    private static func parseComponents(_ rawValue: String) -> [Int]? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty,
            parts.allSatisfy({ part in
                !part.isEmpty
                    && part.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
            })
        else { return nil }
        let components = parts.compactMap { Int($0) }
        guard components.count == parts.count else { return nil }
        return components
    }

    private static func normalized(_ components: [Int]) -> [Int] {
        var result = components
        while result.count > 1, result.last == 0 {
            result.removeLast()
        }
        return result
    }
}

enum EqualizerDriverState: Equatable {
    case missing
    case unreadable
    case version(EqualizerDriverVersion)
}

enum EqualizerDriverInstallReason: Equatable {
    case missing
    case stale
    case repair
}

enum EqualizerDriverInstallDecision: Equatable {
    case install(reason: EqualizerDriverInstallReason)
    case alreadyCurrent

    var shouldInstall: Bool {
        if case .install = self { return true }
        return false
    }
}

/// Decides whether the privileged helper needs to touch the system HAL path.
/// A malformed installed bundle is treated as repair work, while an older
/// version is stale. A newer installed driver is safe to keep during a
/// temporary app downgrade.
enum EqualizerDriverInstallPolicy {
    static func decision(
        bundled: EqualizerDriverVersion,
        installed: EqualizerDriverState
    ) -> EqualizerDriverInstallDecision {
        switch installed {
        case .missing:
            return .install(reason: .missing)
        case .unreadable:
            return .install(reason: .repair)
        case .version(let installedVersion):
            return installedVersion < bundled
                ? .install(reason: .stale)
                : .alreadyCurrent
        }
    }
}

enum EqualizerDriverInstallError: Error, Equatable {
    case registrationFailed(status: Int)
    case unregistrationFailed(status: Int)
    case helperUnavailable(message: String)
    case helperRejected(status: Int, message: String)
    case helperOperationFailed(status: Int, message: String)
    case invalidReply
    case invalidRequest

    var diagnosticDetails: String {
        switch self {
        case .registrationFailed(let status):
            return "SMAppService registration failed (status \(status))"
        case .unregistrationFailed(let status):
            return "SMAppService re-registration could not remove the previous service (status \(status))"
        case .helperUnavailable(let message):
            return "Spotiglass EQ privileged helper was unavailable: \(message)"
        case .helperRejected(let status, let message):
            return "Spotiglass EQ privileged helper rejected the request (status \(status)): \(message)"
        case .helperOperationFailed(let status, let message):
            return "Spotiglass EQ privileged helper failed (status \(status)): \(message)"
        case .invalidReply:
            return "Spotiglass EQ privileged helper returned an invalid reply"
        case .invalidRequest:
            return "Spotiglass EQ privileged helper request did not match the installed app bundle"
        }
    }
}

enum EqualizerDriverInstallErrorMapper {
    static func map(_ error: EqualizerDriverInstallError) -> EqualizerHALPluginError {
        .driverInstallationFailed(diagnostic: error.diagnosticDetails)
    }
}
