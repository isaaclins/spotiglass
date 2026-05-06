import AppKit
import Foundation

/// Abstraction for PKCE loopback authorization so sign-in can be tested and cancelled cooperatively.
protocol SpotifyAuthorizationFlowing {
    func requestAuthorizationCode(clientID: String, timeout: TimeInterval) async throws -> SpotifyAuthorizationCode
}

protocol AuthorizationURLPresenter {
    func open(_ url: URL) async throws
}

struct SystemAuthorizationURLPresenter: AuthorizationURLPresenter {
    func open(_ url: URL) async throws {
        let opened = NSWorkspace.shared.open(url)
        guard opened else {
            throw SpotifyAuthorizationFlowError.browserOpenFailed
        }
    }
}

enum SpotifyAuthorizationFlowError: LocalizedError, Equatable {
    case browserOpenFailed

    var errorDescription: String? {
        switch self {
        case .browserOpenFailed:
            "Could not open Spotify sign-in in the system browser."
        }
    }
}

struct SpotifyAuthorizationFlow: SpotifyAuthorizationFlowing {
    private let listenerFactory: LoopbackOAuthListenerFactory
    private let presenter: AuthorizationURLPresenter

    init(
        listenerFactory: LoopbackOAuthListenerFactory = LoopbackOAuthListenerFactory(),
        presenter: AuthorizationURLPresenter = SystemAuthorizationURLPresenter()
    ) {
        self.listenerFactory = listenerFactory
        self.presenter = presenter
    }

    func requestAuthorizationCode(clientID: String, timeout: TimeInterval = 120) async throws -> SpotifyAuthorizationCode {
        let state = try PKCE.makeCodeVerifier(byteCount: 32)
        let codeVerifier = try PKCE.makeCodeVerifier()
        let codeChallenge = PKCE.makeCodeChallenge(for: codeVerifier)
        let listener = try listenerFactory.start(expectedState: state, timeout: timeout)
        let configuration = try SpotifyAuthConfiguration(clientID: clientID, redirectURI: listener.redirectURI)
        let authorizationURL = try configuration.authorizationURL(state: state, codeChallenge: codeChallenge)

        try await presenter.open(authorizationURL)
        let callback = try await withTaskCancellationHandler {
            try await listener.waitForCallback()
        } onCancel: {
            listener.close()
        }

        return SpotifyAuthorizationCode(
            code: callback.code,
            codeVerifier: codeVerifier,
            redirectURI: listener.redirectURI
        )
    }
}

struct SpotifyAuthorizationCode: Equatable {
    let code: String
    let codeVerifier: String
    let redirectURI: URL
}

extension SpotifyAuthorizationFlowing {
    func requestAuthorizationCode(clientID: String) async throws -> SpotifyAuthorizationCode {
        try await requestAuthorizationCode(clientID: clientID, timeout: 120)
    }
}
