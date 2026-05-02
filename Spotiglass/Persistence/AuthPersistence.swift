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

struct KeychainRefreshTokenStore: RefreshTokenStore {
    private let service = "com.isaaclins.spotiglass.spotify-auth"
    private let account = "spotify-refresh-token"

    func loadRefreshToken() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainRefreshTokenStoreError.unexpectedStatus(status)
        }
        guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            throw KeychainRefreshTokenStoreError.invalidStoredData
        }
        return token
    }

    func saveRefreshToken(_ refreshToken: String) throws {
        let data = Data(refreshToken.utf8)
        var query = baseQuery()

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            return
        }
        guard status == errSecItemNotFound else {
            throw KeychainRefreshTokenStoreError.unexpectedStatus(status)
        }

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainRefreshTokenStoreError.unexpectedStatus(addStatus)
        }
    }

    func deleteRefreshToken() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainRefreshTokenStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
