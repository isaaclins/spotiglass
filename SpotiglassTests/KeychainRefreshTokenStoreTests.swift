import Foundation
import Security
import XCTest

@testable import Spotiglass

final class KeychainRefreshTokenStoreTests: XCTestCase {
    func testLoadReturnsNilWhenMissing() throws {
        let client = MockSecItemClient()
        client.copyMatchingResult = { _, result in
            result.pointee = nil
            return errSecItemNotFound
        }
        let store = KeychainRefreshTokenStore(client: client)
        XCTAssertNil(try store.loadRefreshToken())
    }

    func testLoadReturnsDecodedToken() throws {
        let client = MockSecItemClient()
        let data = Data("refresh-token".utf8)
        client.copyMatchingResult = { _, result in
            result.pointee = data as CFTypeRef
            return errSecSuccess
        }
        let store = KeychainRefreshTokenStore(client: client)
        XCTAssertEqual(try store.loadRefreshToken(), "refresh-token")
    }

    func testLoadThrowsOnInvalidData() {
        let client = MockSecItemClient()
        client.copyMatchingResult = { _, result in
            result.pointee = Data([0xFF, 0xFE]) as CFTypeRef
            return errSecSuccess
        }
        let store = KeychainRefreshTokenStore(client: client)
        XCTAssertThrowsError(try store.loadRefreshToken()) { error in
            XCTAssertEqual(error as? KeychainRefreshTokenStoreError, .invalidStoredData)
        }
    }

    func testSaveUpdatesExistingItem() throws {
        let client = MockSecItemClient()
        client.updateResult = { _, _ in errSecSuccess }
        let store = KeychainRefreshTokenStore(client: client)
        try store.saveRefreshToken("token-a")
        XCTAssertEqual(client.updateCallCount, 1)
        XCTAssertEqual(client.addCallCount, 0)
    }

    func testSaveAddsWhenUpdateReportsNotFound() throws {
        let client = MockSecItemClient()
        client.updateResult = { _, _ in errSecItemNotFound }
        client.addResult = { _, result in errSecSuccess }
        let store = KeychainRefreshTokenStore(client: client)
        try store.saveRefreshToken("token-b")
        XCTAssertEqual(client.updateCallCount, 1)
        XCTAssertEqual(client.addCallCount, 1)
    }

    func testDeleteIsIdempotentForMissingItem() throws {
        let client = MockSecItemClient()
        client.deleteResult = { _ in errSecItemNotFound }
        let store = KeychainRefreshTokenStore(client: client)
        XCTAssertNoThrow(try store.deleteRefreshToken())
    }
}

private final class MockSecItemClient: SecItemClient, @unchecked Sendable {
    var copyMatchingResult: ((CFDictionary, UnsafeMutablePointer<CFTypeRef?>) -> OSStatus)?
    var updateResult: ((CFDictionary, CFDictionary) -> OSStatus)?
    var addResult: ((CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus)?
    var deleteResult: ((CFDictionary) -> OSStatus)?
    private(set) var updateCallCount = 0
    private(set) var addCallCount = 0

    func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>) -> OSStatus {
        copyMatchingResult?(query, result) ?? errSecItemNotFound
    }

    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        updateCallCount += 1
        return updateResult?(query, attributes) ?? errSecParam
    }

    func add(_ query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        addCallCount += 1
        return addResult?(query, result) ?? errSecParam
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        deleteResult?(query) ?? errSecParam
    }
}
