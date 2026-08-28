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
        "user-follow-read",
        "user-read-private",
        "user-read-email",
        "user-read-playback-state",
        "user-modify-playback-state",
        "user-read-currently-playing",
        "user-top-read",
        "user-read-recently-played",
        "streaming"
    ]

    /// Scopes needed to populate the signed-in playlist library. These are
    /// intentionally kept separate from the optional feature scopes below:
    /// an older token can still browse while an individual feature is
    /// unavailable until the user reconnects.
    static let requiredPlaylistReadScopes = [
        "playlist-read-private",
        "playlist-read-collaborative"
    ]
    static let requiredBrowsingScopes = requiredPlaylistReadScopes

    static let requiredSavedTracksReadScopes = ["user-library-read"]
    static let requiredSavedTracksModifyScopes = ["user-library-modify"]
    static let requiredPlaylistModifyScopes = [
        "playlist-modify-private",
        "playlist-modify-public"
    ]
    static let requiredPlaybackReadScopes = ["user-read-playback-state"]
    static let requiredPlaybackModifyScopes = ["user-modify-playback-state"]
    static let requiredTopReadScopes = ["user-top-read"]
    static let requiredFollowReadScopes = ["user-follow-read"]
    static let requiredRecentlyPlayedScopes = ["user-read-recently-played"]

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
            SpotiglassL10n.string("auth.settings.missingClientID")
        case .invalidRedirectURI:
            SpotiglassL10n.string("auth.settings.invalidRedirectURI")
        case .invalidAuthorizationURL:
            SpotiglassL10n.string("auth.settings.invalidAuthorizationURL")
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

/// A feature may require every scope in `allOf`, or one scope from `anyOf`
/// when Spotify has separate permissions for public and private resources.
struct SpotifyScopeRequirement: Equatable {
    let allOf: [String]
    let anyOf: [String]

    init(allOf: [String] = [], anyOf: [String] = []) {
        self.allOf = allOf
        self.anyOf = anyOf
    }

    var isEmpty: Bool { allOf.isEmpty && anyOf.isEmpty }

    /// Scope names that are useful in diagnostics. For an `anyOf` requirement
    /// all alternatives are retained so a reconnect can grant the right one.
    var listedScopes: [String] {
        var result = allOf
        for scope in anyOf where !result.contains(scope) {
            result.append(scope)
        }
        return result
    }

    func missingScopes(from grantedScopes: Set<String>) -> [String] {
        var missing = allOf.filter { !grantedScopes.contains($0) }
        if !anyOf.isEmpty, !anyOf.contains(where: grantedScopes.contains) {
            missing.append(contentsOf: anyOf.filter { !missing.contains($0) })
        }
        return missing
    }
}

/// Supplies the scopes associated with the current access token. Returning an
/// empty set is deliberate: a signed-in session with no recorded OAuth scope
/// must not optimistically issue feature requests. Types that only provide a
/// token (for example lightweight test doubles) do not conform and therefore
/// remain scope-agnostic.
protocol SpotifyScopeProviding {
    func grantedScopes() async -> Set<String>
}

struct AuthenticatedSession: Equatable {
    let accessToken: String
    let tokenType: String
    let scope: String?
    let expiresAt: Date

    var grantedScopes: Set<String> {
        Set((scope ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
    }

    func missingScopes(_ requiredScopes: [String]) -> [String] {
        requiredScopes.filter { !grantedScopes.contains($0) }
    }

    func includesScopes(_ requiredScopes: [String]) -> Bool {
        missingScopes(requiredScopes).isEmpty
    }

    func includesRequiredBrowsingScopes(_ requiredScopes: [String] = SpotifyAuthConfiguration.requiredBrowsingScopes) -> Bool {
        includesScopes(requiredScopes)
    }

    func expires(within interval: TimeInterval, now: Date = Date()) -> Bool {
        expiresAt <= now.addingTimeInterval(interval)
    }

    func refreshed(with grant: SpotifyTokenGrant) -> AuthenticatedSession {
        let returnedScope = grant.scope?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AuthenticatedSession(
            accessToken: grant.accessToken,
            tokenType: grant.tokenType,
            scope: returnedScope?.isEmpty == false ? returnedScope : scope,
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
