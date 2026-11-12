import Foundation

/// A browsing or library request the current provider doesn't offer. It belongs to no service,
/// so its text names none. The browser hides what a provider can't do
/// (``MusicLibraryEdits``), so this only shows when a request gets through anyway.
struct MusicBrowsingError: Error, Equatable, LocalizedError {
    /// The request, for logs and the details disclosure ("Playlist rename").
    let unsupportedOperation: String

    var errorDescription: String? {
        SpotiglassL10n.string("error.browsing.unsupported")
    }
}

/// The sentence a listener reads for an error, whichever service it came from.
///
/// An error that belongs to a service (``SpotifyAPIError``, ``MusicPlaybackError``, an Apple
/// Music failure) names that service. An error that belongs to none (a `URLError`, a response
/// that didn't decode) is told in the words of `service`, the service the request went to, so a
/// timeout while Apple Music is on screen never reads "The connection to Spotify timed out" (#388).
enum MusicServiceErrorText {
    static func userMessage(for error: Error, service: MusicService) -> String {
        if let apiError = error as? SpotifyAPIError { return apiError.userMessage }
        // Its detail is the SDK's or the error's own English text, kept for the log.
        if let playbackError = error as? MusicPlaybackError {
            return failedMessage(for: playbackError.service)
        }
        if service == .appleMusic, let appleMusic = BrowsingDisplayError.appleMusic(for: error, recognisedOnly: true) {
            return appleMusic.message
        }
        if let urlError = error as? URLError { return networkMessage(for: urlError, service: service) }
        // A response that didn't decode (SpotifyPlaybackAPI decodes outside the client).
        if error is DecodingError {
            return service == .spotify ? SpotiglassL10n.string("error.spotify.unexpectedShape") : failedMessage(for: service)
        }
        // Spotiglass's own errors already say it in the app's language. Anything else (a WebKit
        // or Foundation NSError) would read in the Mac's language, so it gets the app's sentence.
        // It may not come from a service at all, so it names none.
        if let localized = error as? LocalizedError, let text = localized.errorDescription?.nilWhenEmpty {
            return text
        }
        return SpotiglassL10n.string("error.generic.tryAgain")
    }

    /// "<Service> couldn't do that. Try again in a moment."
    static func failedMessage(for service: MusicService) -> String {
        SpotiglassL10n.string(service == .appleMusic ? "error.playback.appleMusic.failed" : "error.playback.spotify.failed")
    }

    /// A transport failure in the app's language, saying what to check. `fallback` is the
    /// sentence for a code that isn't a connection problem (sign-in's "something went wrong");
    /// without one, it says the service couldn't do it: a garbled or empty answer isn't the network.
    static func networkMessage(for error: URLError, service: MusicService, fallback: String? = nil) -> String {
        switch error.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return SpotiglassL10n.string("auth.error.offline")
        case .cancelled:
            return SpotiglassL10n.string("auth.error.cancelled")
        case .timedOut, .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
             .clientCertificateRejected, .clientCertificateRequired, .cannotConnectToHost, .networkConnectionLost:
            switch service {
            case .spotify: return spotifyConnectionMessage(for: error.code)
            case .appleMusic: return SpotiglassL10n.string("appleMusic.error.network.message")
            }
        default:
            return fallback ?? failedMessage(for: service)
        }
    }

    private static func spotifyConnectionMessage(for code: URLError.Code) -> String {
        switch code {
        case .timedOut:
            return SpotiglassL10n.string("auth.error.timeout")
        case .cannotFindHost, .dnsLookupFailed:
            return SpotiglassL10n.string("auth.error.dns")
        case .cannotConnectToHost, .networkConnectionLost:
            return SpotiglassL10n.string("auth.error.network")
        default:
            return SpotiglassL10n.string("auth.error.tls")
        }
    }
}

extension BrowsingDisplayError {
    /// Apple Music failures as calm sentences in the app's language, the way playback errors and
    /// library edits already read. MusicKit's own text is English only and names no fix, so it
    /// goes to the details disclosure (#397). While Apple Music is on screen, a failure that isn't
    /// recognised still reads as Apple Music's (unless `recognisedOnly`); Spotify's errors and
    /// Spotiglass's own neutral ones never get here.
    static func appleMusic(
        for error: Error,
        service: MusicService = MusicServiceSelection.current,
        recognisedOnly: Bool = false
    ) -> BrowsingDisplayError? {
        if error is CancellationError || error is SpotifyAPIError || error is MusicBrowsingError { return nil }
        if let editError = error as? AppleMusicLibraryEditError {
            return BrowsingDisplayError(
                title: SpotiglassL10n.string("appleMusic.error.failed.title"),
                message: editError.localizedDescription,
                canRetry: true
            )
        }
        let failure: AppleMusicFailure
        if let recognised = AppleMusicFailure.from(error) {
            failure = recognised
        } else if service == .appleMusic, !recognisedOnly {
            failure = error is URLError ? .network : .failed
        } else {
            return nil
        }
        let details = String(describing: error)
        switch failure {
        case .notSignedIn:
            return BrowsingDisplayError(
                title: SpotiglassL10n.string("appleMusic.error.signIn.title"),
                message: SpotiglassL10n.string("appleMusic.error.signIn.message"),
                canRetry: true,
                diagnosticDetails: details
            )
        case .privacyNoticeNotAccepted:
            return BrowsingDisplayError(
                title: SpotiglassL10n.string("appleMusic.error.privacyNotice.title"),
                message: SpotiglassL10n.string("appleMusic.error.privacyNotice.message"),
                canRetry: true,
                diagnosticDetails: details
            )
        case .accessOff:
            return BrowsingDisplayError(
                title: SpotiglassL10n.string("error.playback.appleMusic.permission.title"),
                message: SpotiglassL10n.string("error.playback.appleMusic.permission.message"),
                canRetry: true,
                diagnosticDetails: details
            )
        case .unavailable:
            return BrowsingDisplayError(
                title: SpotiglassL10n.string("appleMusic.error.unavailable.title"),
                message: SpotiglassL10n.string("appleMusic.error.unavailable.message"),
                canRetry: false,
                diagnosticDetails: details
            )
        case .notFound:
            return BrowsingDisplayError(
                title: SpotiglassL10n.string("error.browsing.notFound.title"),
                message: SpotiglassL10n.string("appleMusic.error.notFound"),
                canRetry: false
            )
        case .network:
            return BrowsingDisplayError(
                title: SpotiglassL10n.string("error.browsing.network.title"),
                message: SpotiglassL10n.string("appleMusic.error.network.message"),
                canRetry: true,
                diagnosticDetails: details
            )
        case .failed:
            return BrowsingDisplayError(
                title: SpotiglassL10n.string("appleMusic.error.failed.title"),
                message: SpotiglassL10n.string("error.playback.appleMusic.failed"),
                canRetry: true,
                diagnosticDetails: details
            )
        }
    }
}
