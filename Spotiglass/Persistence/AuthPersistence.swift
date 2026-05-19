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
        case let .unexpectedStatus(status):
            Self.message(forUnexpectedStatus: status)
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case let .unexpectedStatus(status):
            SecCopyErrorMessageString(status, nil).map { $0 as String }
        case .invalidStoredData:
            nil
        }
    }

    private static func message(forUnexpectedStatus status: OSStatus) -> String {
        switch status {
        case errSecMissingEntitlement:
            return "macOS blocked Keychain access for Spotiglass—often after reinstalling or changing how the app is signed. Try Connect again, or reinstall Spotiglass from a trusted build."
        case errSecInteractionNotAllowed:
            return "Keychain access isn’t allowed right now. Unlock your Mac, wait a moment, then try again."
        case errSecAuthFailed:
            return "Keychain verification failed. Try again, or disconnect and connect Spotify again."
        case errSecDuplicateItem:
            return "Saved sign-in data conflicted with an existing Keychain entry. Disconnect, then connect again."
        case errSecReadOnly:
            return "Keychain is read-only. Check disk space and permissions, then try again."
        case errSecNotAvailable:
            return "Keychain is not available. Restart your Mac and try again."
        case errSecIO:
            return "Could not read or write sign-in data (Keychain I/O error). Try again."
        case errSecParam:
            return "Keychain rejected the request. Disconnect and connect Spotify again."
        case errSecAllocate:
            return "Not enough memory to use Keychain. Close other apps and try again."
        case errSecDecode:
            return "Could not decode Keychain data. Disconnect and connect Spotify again."
        default:
            let suffix = SecCopyErrorMessageString(status, nil).map { " — \($0 as String)" } ?? ""
            return "Could not access saved Spotify sign-in data (security error \(status))\(suffix). If this keeps happening, note this code when reporting the issue. Try Disconnect, then Connect again."
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
