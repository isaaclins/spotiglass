import Security
import XCTest
@testable import Spotiglass

final class KeychainSecItemClientTests: XCTestCase {
    func testLiveClientCopyMatchingReturnsNotFoundForMissingItem() {
        let client = LiveSecItemClient()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "spotiglass-unit-test-missing-\(UUID().uuidString)",
            kSecAttrService as String: "com.spotiglass.tests",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = client.copyMatching(query as CFDictionary, result: &result)
        XCTAssertEqual(status, errSecItemNotFound)
        XCTAssertNil(result)
    }

    func testLiveClientAddUpdateAndDeleteForEphemeralAccount() {
        let client = LiveSecItemClient()
        let account = "spotiglass-unit-test-\(UUID().uuidString)"
        let service = "com.spotiglass.tests"
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
        ]
        var addResult: CFTypeRef?
        let addStatus = client.add(
            (base.merging([kSecValueData as String: Data("secret".utf8)]) { $1 }) as CFDictionary,
            result: &addResult
        )
        XCTAssertTrue(addStatus == errSecSuccess || addStatus == errSecDuplicateItem)

        let updateStatus = client.update(
            base as CFDictionary,
            [kSecValueData as String: Data("rotated".utf8)] as CFDictionary
        )
        XCTAssertTrue(updateStatus == errSecSuccess || updateStatus == errSecItemNotFound)

        XCTAssertEqual(client.delete(base as CFDictionary), errSecSuccess)
    }
}
