import Foundation
@testable import Spotiglass

struct StaticSpotifyAccessTokenProvider: SpotifyAccessTokenProviding {
    let token: String

    func accessToken() async throws -> String {
        token
    }

    func refreshAccessTokenAfterUnauthorized() async throws -> String {
        token
    }
}

struct StaticSpotifyScopeProvider: SpotifyScopeProviding {
    let scopes: Set<String>

    func grantedScopes() async -> Set<String> {
        scopes
    }
}

struct ScopedSpotifyAccessTokenProvider: SpotifyAccessTokenProviding, SpotifyScopeProviding {
    let token: String
    let scopes: Set<String>

    func accessToken() async throws -> String {
        token
    }

    func refreshAccessTokenAfterUnauthorized() async throws -> String {
        token
    }

    func grantedScopes() async -> Set<String> {
        scopes
    }
}
