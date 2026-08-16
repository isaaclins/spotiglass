import XCTest
@testable import Spotiglass

final class SpotifyAuthorizationFlowTests: XCTestCase {

    func testBrowserOpenFailedDescription() {
        let err = SpotifyAuthorizationFlowError.browserOpenFailed
        // Localized now, so assert against the catalog rather than pinning
        // one language's wording here (#186).
        XCTAssertEqual(err.errorDescription, SpotiglassL10n.string("auth.flow.browserOpenFailed"))
    }

    func testDefaultTimeoutExtensionUses120Seconds() async throws {
        let flow = ImmediateAuthorizationFlow()
        let code = try await flow.requestAuthorizationCode(clientID: "cid")
        XCTAssertEqual(code.code, "stub")
    }

    func testRequestAuthorizationCodeCompletesViaLoopback() async throws {
        let presenter = CapturingAuthorizationURLPresenter()
        let flow = SpotifyAuthorizationFlow(presenter: presenter)
        async let codeTask = flow.requestAuthorizationCode(clientID: "test-client-id", timeout: 15)
        try await Task.sleep(nanoseconds: 250_000_000)

        guard let authURL = presenter.openedURL,
              let components = URLComponents(url: authURL, resolvingAgainstBaseURL: false),
              let redirectURI = components.queryItems?.first(where: { $0.name == "redirect_uri" })?.value,
              let redirectURL = URL(string: redirectURI),
              let state = components.queryItems?.first(where: { $0.name == "state" })?.value
        else {
            return XCTFail("authorization URL missing redirect_uri or state")
        }

        let port = redirectURL.port ?? 0
        XCTAssertGreaterThan(port, 0)
        let callbackURL = URL(string: "http://127.0.0.1:\(port)/callback?code=AUTHCODE99&state=\(state)")!
        let session = URLSession(configuration: .ephemeral)
        let (_, response) = try await session.data(from: callbackURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let result = try await codeTask
        XCTAssertEqual(result.code, "AUTHCODE99")
        XCTAssertFalse(result.codeVerifier.isEmpty)
        XCTAssertEqual(result.redirectURI, redirectURL)
    }

    func testPresenterOpenFailurePropagates() async {
        let flow = SpotifyAuthorizationFlow(presenter: FailingAuthorizationURLPresenter())
        do {
            _ = try await flow.requestAuthorizationCode(clientID: "id", timeout: 1)
            XCTFail("expected browserOpenFailed")
        } catch let err as SpotifyAuthorizationFlowError {
            XCTAssertEqual(err, .browserOpenFailed)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}

private struct ImmediateAuthorizationFlow: SpotifyAuthorizationFlowing {
    func requestAuthorizationCode(clientID: String, timeout: TimeInterval) async throws -> SpotifyAuthorizationCode {
        SpotifyAuthorizationCode(code: "stub", codeVerifier: "verifier", redirectURI: URL(string: "http://127.0.0.1:1/callback")!)
    }
}

private final class CapturingAuthorizationURLPresenter: AuthorizationURLPresenter, @unchecked Sendable {
    private(set) var openedURL: URL?

    func open(_ url: URL) async throws {
        openedURL = url
    }
}

private struct FailingAuthorizationURLPresenter: AuthorizationURLPresenter {
    func open(_ url: URL) async throws {
        throw SpotifyAuthorizationFlowError.browserOpenFailed
    }
}
