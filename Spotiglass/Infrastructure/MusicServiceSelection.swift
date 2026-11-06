import Foundation

/// The music service the app browses.
enum MusicService: String, Equatable {
    case spotify
    case appleMusic
}

/// Picks the music service at launch.
///
/// Spotify is the default and the only service a normal launch ever sees. Apple Music is
/// reachable through a hidden developer switch until the service switcher (#373) exists:
///
/// - launch argument: `-SpotiglassMusicService appleMusic`
/// - or the defaults key: `defaults write com.isaaclins.spotiglass SpotiglassMusicService appleMusic`
///
/// Both land in `UserDefaults` (launch arguments in its argument domain), so one lookup covers
/// them. See `docs/apple-music.md`. Screenshot mode and the unit-test host always stay on
/// Spotify, so neither the screenshot stand-in nor the tests can ever reach MusicKit.
enum MusicServiceSelection {
    static let defaultsKey = "SpotiglassMusicService"

    static let current: MusicService = resolve(
        storedValue: UserDefaults.standard.string(forKey: defaultsKey),
        isScreenshotMode: ScreenshotMode.isActive,
        isRunningUnitTests: AppMetadata.isRunningUnitTests
    )

    static func resolve(storedValue: String?, isScreenshotMode: Bool, isRunningUnitTests: Bool) -> MusicService {
        guard !isScreenshotMode, !isRunningUnitTests else { return .spotify }
        return MusicService(rawValue: storedValue ?? "") ?? .spotify
    }
}
