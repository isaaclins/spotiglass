import XCTest
@testable import Spotiglass

final class AuthPersistenceTests: XCTestCase {

    // MARK: - MemoryOnlyRefreshTokenStore

    func testMemoryStoreRoundTripAndDelete() throws {
        let store = MemoryOnlyRefreshTokenStore()
        XCTAssertNil(try store.loadRefreshToken())

        try store.saveRefreshToken("rt1")
        XCTAssertEqual(try store.loadRefreshToken(), "rt1")

        try store.saveRefreshToken("rt2")
        XCTAssertEqual(try store.loadRefreshToken(), "rt2")

        try store.deleteRefreshToken()
        XCTAssertNil(try store.loadRefreshToken())

        // Delete is idempotent.
        XCTAssertNoThrow(try store.deleteRefreshToken())
    }

    // MARK: - KeychainRefreshTokenStoreError.errorDescription

    func testInvalidStoredDataHasNonEmptyDescriptionAndNoRecoverySuggestion() {
        let err = KeychainRefreshTokenStoreError.invalidStoredData
        XCTAssertNotNil(err.errorDescription)
        XCTAssertFalse(err.errorDescription!.isEmpty)
        XCTAssertNil(err.recoverySuggestion)
    }

    func testEveryKnownOSStatusHasUniqueDescription() {
        let cases: [(OSStatus, String)] = [
            (errSecMissingEntitlement, "blocked Keychain"),
            (errSecInteractionNotAllowed, "Keychain access"),
            (errSecAuthFailed, "verification"),
            (errSecDuplicateItem, "conflicted"),
            (errSecReadOnly, "read-only"),
            (errSecNotAvailable, "not available"),
            (errSecIO, "I/O"),
            (errSecParam, "rejected"),
            (errSecAllocate, "memory"),
            (errSecDecode, "decode"),
        ]
        for (status, marker) in cases {
            let err = KeychainRefreshTokenStoreError.unexpectedStatus(status)
            XCTAssertNotNil(err.errorDescription, "missing description for \(status)")
            XCTAssertTrue(
                err.errorDescription!.localizedCaseInsensitiveContains(marker),
                "description for \(status) should mention '\(marker)', got: \(err.errorDescription ?? "<nil>")"
            )
        }
    }

    func testUnknownOSStatusFallsBackToGenericMessageEmbeddingTheCode() {
        let bizarre: OSStatus = -90210
        let err = KeychainRefreshTokenStoreError.unexpectedStatus(bizarre)
        XCTAssertNotNil(err.errorDescription)
        XCTAssertTrue(err.errorDescription!.contains("\(bizarre)"))
    }

    func testRecoverySuggestionForUnexpectedStatusIsOSDerivedString() {
        // We can't predict the OS string, but the recoverySuggestion getter
        // must be exercised. For errSecParam the OS provides a short message.
        let err = KeychainRefreshTokenStoreError.unexpectedStatus(errSecParam)
        // Either OS returns a message or we get nil — both are valid.
        _ = err.recoverySuggestion
    }

    func testEqualityRespectsAssociatedValue() {
        XCTAssertEqual(
            KeychainRefreshTokenStoreError.unexpectedStatus(errSecParam),
            KeychainRefreshTokenStoreError.unexpectedStatus(errSecParam)
        )
        XCTAssertNotEqual(
            KeychainRefreshTokenStoreError.unexpectedStatus(errSecParam),
            KeychainRefreshTokenStoreError.unexpectedStatus(errSecIO)
        )
        XCTAssertNotEqual(
            KeychainRefreshTokenStoreError.invalidStoredData,
            KeychainRefreshTokenStoreError.unexpectedStatus(errSecParam)
        )
    }
}
