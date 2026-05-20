import Foundation
import Security

struct KeychainRefreshTokenStore: RefreshTokenStore {
    private let service: String
    private let account: String
    private let client: SecItemClient

    init(
        service: String = "com.isaaclins.spotiglass.spotify-auth",
        account: String = "spotify-refresh-token",
        client: SecItemClient = LiveSecItemClient()
    ) {
        self.service = service
        self.account = account
        self.client = client
    }

    func loadRefreshToken() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = client.copyMatching(query as CFDictionary, result: &item)
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

        let status = client.update(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            return
        }
        guard status == errSecItemNotFound else {
            throw KeychainRefreshTokenStoreError.unexpectedStatus(status)
        }

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = client.add(query as CFDictionary, result: nil)
        guard addStatus == errSecSuccess else {
            throw KeychainRefreshTokenStoreError.unexpectedStatus(addStatus)
        }
    }

    func deleteRefreshToken() throws {
        let status = client.delete(baseQuery() as CFDictionary)
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
