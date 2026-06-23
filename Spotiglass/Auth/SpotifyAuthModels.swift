import Foundation

struct SpotifyAuthConfiguration: Equatable {
    static let defaultLoopbackPort: UInt16 = 43824

    static let defaultScopes = [
        "playlist-read-private",
        "playlist-read-collaborative",
        "playlist-modify-private",
        "playlist-modify-public",
        "user-library-read",
        "user-library-modify",
        "user-read-private",
        "user-read-email",
        "user-read-playback-state",
        "user-modify-playback-state",
        "user-read-currently-playing",
        "user-top-read",
        "user-read-recently-played",
        "streaming"
    ]

    static let requiredBrowsingScopes = [
        "playlist-read-private",
        "playlist-read-collaborative"
    ]

    let clientID: String
    let redirectURI: URL
    let scopes: [String]

    static func loopbackRedirectURI(port: UInt16 = Self.defaultLoopbackPort) -> URL {
        URL(string: "http://127.0.0.1:\(port)/callback")!
    }

    init(clientID: String, redirectURI: URL, scopes: [String] = Self.defaultScopes) throws {
        let trimmedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClientID.isEmpty else {
            throw SpotifyAuthConfigurationError.missingClientID
        }
        guard redirectURI.scheme == "http",
              redirectURI.host == "127.0.0.1",
              redirectURI.path == "/callback" else {
            throw SpotifyAuthConfigurationError.invalidRedirectURI
        }

        self.clientID = trimmedClientID
        self.redirectURI = redirectURI
        self.scopes = scopes
    }

    func authorizationURL(state: String, codeChallenge: String) throws -> URL {
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: codeChallenge)
        ]

        guard let url = components?.url else {
            throw SpotifyAuthConfigurationError.invalidAuthorizationURL
        }
        return url
    }
}

enum SpotifyAuthConfigurationError: LocalizedError, Equatable {
    case missingClientID
    case invalidRedirectURI
    case invalidAuthorizationURL

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            "Enter a Spotify client ID before signing in."
        case .invalidRedirectURI:
            "The Spotify redirect URI must use http://127.0.0.1:<port>/callback."
        case .invalidAuthorizationURL:
            "Could not build the Spotify authorization URL."
        }
    }
}

struct SpotifyAuthSettings {
    private let defaults: UserDefaults
    private let clientIDKey = "spotify.clientID"
    private let grantedScopeKey = "spotify.grantedScope"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var clientID: String {
        get { defaults.string(forKey: clientIDKey) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: clientIDKey) }
    }

    var grantedScope: String? {
        get { defaults.string(forKey: grantedScopeKey) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: grantedScopeKey)
            } else {
                defaults.removeObject(forKey: grantedScopeKey)
            }
        }
    }
}

struct AuthenticatedSession: Equatable {
    let accessToken: String
    let tokenType: String
    let scope: String?
    let expiresAt: Date

    var grantedScopes: Set<String> {
        Set((scope ?? "").split(separator: " ").map(String.init))
    }

    func includesRequiredBrowsingScopes(_ requiredScopes: [String] = SpotifyAuthConfiguration.requiredBrowsingScopes) -> Bool {
        let grantedScopes = grantedScopes
        return requiredScopes.allSatisfy { grantedScopes.contains($0) }
    }

    func expires(within interval: TimeInterval, now: Date = Date()) -> Bool {
        expiresAt <= now.addingTimeInterval(interval)
    }

    func refreshed(with grant: SpotifyTokenGrant) -> AuthenticatedSession {
        AuthenticatedSession(
            accessToken: grant.accessToken,
            tokenType: grant.tokenType,
            scope: grant.scope ?? scope,
            expiresAt: grant.expiresAt
        )
    }
}

struct AuthDisplayError: Error, Equatable, Identifiable {
    let id = UUID()
    let message: String

    static func == (lhs: AuthDisplayError, rhs: AuthDisplayError) -> Bool {
        lhs.message == rhs.message
    }
}
