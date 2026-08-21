import Foundation
@testable import Spotiglass

// Convenience wrappers that only tests need. They used to live in the app
// target, where the dead-code scan correctly flagged them once production
// stopped calling them. Keeping them here preserves the terse call sites
// without leaving unreferenced declarations in shipped code.

extension PlaybackSessionViewModel {
    /// Unwraps the display error carried by ``connectionState``.
    var connectionStateError: PlaybackDisplayError? {
        guard case let .error(error) = connectionState else { return nil }
        return error
    }

    /// Delivers a bridge event stamped with the current host generation.
    func handle(_ event: PlaybackBridgeEvent) {
        handle(PlaybackBridgeEventEnvelope(event: event, hostGeneration: playbackHostGeneration))
    }
}

extension SpotifyGETResponseCache {
    /// Unfenced store. Production always writes through a write-ownership
    /// token so a slow response cannot overwrite a newer one; tests that only
    /// seed the cache do not care about that ordering.
    func store(body: Data, cacheKey key: String, ttl: TimeInterval) {
        store(body: body, cacheKey: key, ttl: ttl, ownership: beginWrite(forCacheKey: key))
    }
}
