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
