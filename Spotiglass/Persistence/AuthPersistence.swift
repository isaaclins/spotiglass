import Foundation
import Security

protocol RefreshTokenStore {
    func loadRefreshToken() throws -> String?
    func saveRefreshToken(_ refreshToken: String) throws
    func deleteRefreshToken() throws
}

enum KeychainRefreshTokenStoreError: Error, Equatable, LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidStoredData

    var errorDescription: String? {
        switch self {
        case .invalidStoredData:
            "The saved Spotify sign-in data could not be read. Disconnect, then connect again to sign in."
        case .unexpectedStatus(let status):
            Self.message(forUnexpectedStatus: status)
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .unexpectedStatus(let status):
            SecCopyErrorMessageString(status, nil).map { $0 as String }
        case .invalidStoredData:
            nil
        }
    }

    private static func message(forUnexpectedStatus status: OSStatus) -> String {
        switch status {
        case errSecMissingEntitlement:
            return SpotiglassL10n.string("auth.keychain.missingEntitlement")
        case errSecInteractionNotAllowed:
            return SpotiglassL10n.string("auth.keychain.interactionNotAllowed")
        case errSecAuthFailed:
            return SpotiglassL10n.string("auth.keychain.authFailed")
        case errSecDuplicateItem:
            return SpotiglassL10n.string("auth.keychain.duplicate")
        case errSecReadOnly:
            return SpotiglassL10n.string("auth.keychain.readOnly")
        case errSecNotAvailable:
            return SpotiglassL10n.string("auth.keychain.notAvailable")
        case errSecIO:
            return SpotiglassL10n.string("auth.keychain.io")
        case errSecParam:
            return SpotiglassL10n.string("auth.keychain.param")
        case errSecAllocate:
            return SpotiglassL10n.string("auth.keychain.allocate")
        case errSecDecode:
            return SpotiglassL10n.string("auth.keychain.decode")
        default:
            let suffix = SecCopyErrorMessageString(status, nil).map { " — \($0 as String)" } ?? ""
            return String(
                format: SpotiglassL10n.string("auth.keychain.generic"),
                status,
                suffix
            )
        }
    }
}

/// In-process refresh token storage for the **unit-test host** only (`AppMetadata.isRunningUnitTests`).
/// Keeps `SecItem*` out of the login keychain while `SpotiglassTests` runs inside `Spotiglass.app`.
final class MemoryOnlyRefreshTokenStore: RefreshTokenStore {
    private var token: String?

    func loadRefreshToken() throws -> String? {
        token
    }

    func saveRefreshToken(_ refreshToken: String) throws {
        token = refreshToken
    }

    func deleteRefreshToken() throws {
        token = nil
    }
}
