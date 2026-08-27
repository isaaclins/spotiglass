import Darwin
import XCTest
@testable import Spotiglass

final class LoopbackOAuthCallbackTests: XCTestCase {
  private static let listenerLock = NSLock()
  private static let responseCopy = LoopbackOAuthResponseCopy(
    invalidRequest: "invalid response",
    success: "localized sign-in complete",
    failure: "localized sign-in failure"
  )

  private func withExclusiveListener<T>(_ body: () async throws -> T) async rethrows -> T {
    Self.listenerLock.lock()
    defer { Self.listenerLock.unlock() }
    return try await body()
  }

    // MARK: - LoopbackOAuthCallbackValidator (pure URL parsing)

    func testValidatorReturnsCallbackOnHappyPath() throws {
        let url = URL(string: "http://127.0.0.1:54321/callback?code=ABC&state=STATE123")!
        let result = try LoopbackOAuthCallbackValidator.validate(url: url, expectedState: "STATE123")
        XCTAssertEqual(result, OAuthCallback(code: "ABC"))
    }

    func testValidatorMissingStateThrows() {
        let url = URL(string: "http://127.0.0.1/callback?code=ABC")!
        XCTAssertThrowsError(try LoopbackOAuthCallbackValidator.validate(url: url, expectedState: "S")) { err in
            XCTAssertEqual(err as? LoopbackOAuthCallbackError, .missingState)
        }
    }

    func testValidatorStateMismatchThrows() {
        let url = URL(string: "http://127.0.0.1/callback?code=ABC&state=WRONG")!
        XCTAssertThrowsError(try LoopbackOAuthCallbackValidator.validate(url: url, expectedState: "RIGHT")) { err in
            XCTAssertEqual(err as? LoopbackOAuthCallbackError, .stateMismatch)
        }
    }

    func testValidatorMissingCodeThrows() {
        let url = URL(string: "http://127.0.0.1/callback?state=S")!
        XCTAssertThrowsError(try LoopbackOAuthCallbackValidator.validate(url: url, expectedState: "S")) { err in
            XCTAssertEqual(err as? LoopbackOAuthCallbackError, .missingCode)
        }
    }

    func testValidatorEmptyCodeThrowsMissingCode() {
        let url = URL(string: "http://127.0.0.1/callback?code=&state=S")!
        XCTAssertThrowsError(try LoopbackOAuthCallbackValidator.validate(url: url, expectedState: "S")) { err in
            XCTAssertEqual(err as? LoopbackOAuthCallbackError, .missingCode)
        }
    }

    func testValidatorPropagatesOAuthErrorWithDescription() {
        let url = URL(string: "http://127.0.0.1/callback?error=access_denied&error_description=User%20said%20no")!
        XCTAssertThrowsError(try LoopbackOAuthCallbackValidator.validate(url: url, expectedState: "S")) { err in
            XCTAssertEqual(err as? LoopbackOAuthCallbackError, .oauthError("access_denied", "User said no"))
        }
    }

    func testValidatorPropagatesOAuthErrorWithoutDescription() {
        let url = URL(string: "http://127.0.0.1/callback?error=denied")!
        XCTAssertThrowsError(try LoopbackOAuthCallbackValidator.validate(url: url, expectedState: "S")) { err in
            XCTAssertEqual(err as? LoopbackOAuthCallbackError, .oauthError("denied", nil))
        }
    }

    // MARK: - LoopbackOAuthCallbackError.errorDescription

    func testErrorDescriptionStringsAreNonEmpty() {
        let cases: [LoopbackOAuthCallbackError] = [
            .invalidRequest,
            .oauthError("e", "desc"),
            .oauthError("e", nil),
            .missingState,
            .stateMismatch,
            .missingCode,
            .socketSetupFailed("bind"),
            .timedOut,
        ]
        for c in cases {
            XCTAssertNotNil(c.errorDescription)
            XCTAssertFalse(c.errorDescription!.isEmpty, "empty description for \(c)")
        }
        // The two oauthError variants should produce different output.
        XCTAssertNotEqual(
            LoopbackOAuthCallbackError.oauthError("e", "desc").errorDescription,
            LoopbackOAuthCallbackError.oauthError("e", nil).errorDescription
        )
        // The failing step is a developer fact: it belongs in diagnostics, not
        // in the sentence on the connect screen (#186, #187).
        XCTAssertFalse(LoopbackOAuthCallbackError.socketSetupFailed("bind").errorDescription!.contains("bind"))
        XCTAssertTrue(
            LoopbackOAuthCallbackError.socketSetupFailed("bind").diagnosticDetails!.contains("bind"),
            "the step must still be recoverable for a bug report"
        )
        XCTAssertTrue(
            LoopbackOAuthCallbackError.oauthError("access_denied", nil).diagnosticDetails!
                .contains("access_denied")
        )
    }

    // MARK: - LoopbackOAuthListenerFactory (real loopback socket)

    private func startListener(state: String, timeout: TimeInterval = 5) throws -> ActiveLoopbackOAuthListener {
        // Use port=0 to let the kernel pick a free port for parallelism safety.
        try LoopbackOAuthListenerFactory().start(
            expectedState: state,
            timeout: timeout,
            port: 0,
            responseCopy: Self.responseCopy
        )
    }

    func testFactoryStartReturnsListenerWithBoundPort() throws {
        let listener = try startListener(state: "S")
        defer { listener.close() }
        let port = listener.redirectURI.port ?? 0
        XCTAssertGreaterThan(port, 0, "kernel should have assigned a non-zero port")
        XCTAssertEqual(listener.redirectURI.host, "127.0.0.1")
    }

    func testListenerAcceptsValidCallbackAndReturnsCode() async throws {
        try await withExclusiveListener {
            var lastError: Error?
            for _ in 0 ..< 5 {
                do {
                    try await exerciseValidOAuthCallback()
                    return
                } catch {
                    lastError = error
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            throw lastError ?? NSError(domain: "LoopbackOAuthCallbackTests", code: 1)
        }
    }

    private func exerciseValidOAuthCallback() async throws {
        let listener = try startListener(state: "MYSTATE", timeout: 10)
        defer { listener.close() }

        let port = listener.redirectURI.port!

        async let waited = listener.waitForCallback()
        try await Task.sleep(nanoseconds: 150_000_000)
        let response = try Self.sendHTTPGet(path: "/callback?code=CODE42&state=MYSTATE", port: port)
        let callback = try await waited
        XCTAssertEqual(callback.code, "CODE42")
        XCTAssertTrue(response.contains(Self.responseCopy.success))
    }

    @discardableResult
    private static func sendHTTPGet(path: String, port: Int) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "LoopbackOAuthCallbackTests", code: 3)
        }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            throw NSError(domain: "LoopbackOAuthCallbackTests", code: 4)
        }

        let request = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
        _ = request.withCString { write(fd, $0, strlen($0)) }
        shutdown(fd, SHUT_WR)

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { pointer in
                read(fd, pointer.baseAddress, buffer.count)
            }
            guard count >= 0 else {
                throw NSError(domain: "LoopbackOAuthCallbackTests", code: 5)
            }
            guard count > 0 else { break }
            response.append(contentsOf: buffer.prefix(count))
        }
        return String(data: response, encoding: .utf8) ?? ""
    }

    private func waitUntilPortAcceptsConnections(_ port: Int, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Self.canConnect(toPort: port) { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw NSError(
            domain: "LoopbackOAuthCallbackTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for loopback listener on port \(port)"]
        )
    }

    private static func canConnect(toPort port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return connected == 0
    }

    func testListenerRejectsStateMismatch() async throws {
        try await withExclusiveListener {
            let listener = try startListener(state: "EXPECTED", timeout: 10)
            defer { listener.close() }
            let port = listener.redirectURI.port!

            async let waited = listener.waitForCallback()
            try await Task.sleep(nanoseconds: 150_000_000)
            let response = try Self.sendHTTPGet(path: "/callback?code=C&state=NOPE", port: port)
            XCTAssertTrue(response.contains(Self.responseCopy.failure))

            do {
                _ = try await waited
                XCTFail("expected stateMismatch")
            } catch let err as LoopbackOAuthCallbackError {
                XCTAssertEqual(err, .stateMismatch)
            }
        }
    }

    func testListenerTimesOutWhenNoCallbackArrives() async throws {
        let listener = try startListener(state: "S", timeout: 0.2)
        defer { listener.close() }
        do {
            _ = try await listener.waitForCallback()
            XCTFail("expected timeout")
        } catch let err as LoopbackOAuthCallbackError {
            // Either the timeout task wins (.timedOut) or the close-triggered
            // accept() failure wins (.invalidRequest). Both are valid terminal states.
            XCTAssertTrue(err == .timedOut || err == .invalidRequest, "unexpected error \(err)")
        }
    }

    func testListenerCloseIsIdempotent() throws {
        let listener = try startListener(state: "S")
        listener.close()
        listener.close() // second close must be a no-op (guarded by didClose flag)
    }

}
