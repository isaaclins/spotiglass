import Combine
import Foundation

/// A music service Spotiglass can browse.
enum MusicService: String, CaseIterable, Equatable, Hashable {
    case spotify
    case appleMusic

    /// Menu and palette order. ⌃1 and ⌃2 follow it.
    static let switcherOrder: [MusicService] = [.appleMusic, .spotify]

    /// The service's own name. Brand names are the same in every language, but they go through
    /// the catalog like every other visible string.
    var displayName: String {
        switch self {
        case .spotify: SpotiglassL10n.string("service.spotify.name")
        case .appleMusic: SpotiglassL10n.string("service.appleMusic.name")
        }
    }

    /// Palette command that switches to this service (default ⌃1 / ⌃2).
    var switchCommandID: String {
        switch self {
        case .spotify: CommandPaletteCommandID.switchToSpotify
        case .appleMusic: CommandPaletteCommandID.switchToAppleMusic
        }
    }

    init?(switchCommandID: String) {
        guard let service = MusicService.allCases.first(where: { $0.switchCommandID == switchCommandID }) else {
            return nil
        }
        self = service
    }
}

/// Where the list of added services and the active one is kept.
protocol MusicServiceSelectionStorage: AnyObject {
    func string(forKey key: String) -> String?
    func stringArray(forKey key: String) -> [String]?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: MusicServiceSelectionStorage {}

/// Which services are added to Spotiglass and which one the app shows.
///
/// Works like Arc's profiles: every added service is its own space with its own sign-in, pins and
/// place, and switching never signs anything out. One choice for the whole app, so every window,
/// the menu bar and Settings agree on it.
///
/// - `services` are the services added to the app. Spotify stays in it while its session merely
///   lapses (that space then shows Spotify's sign-in, exactly as before); only an explicit sign-out
///   removes it.
/// - `active` is the space on screen; `nil` means nothing was chosen yet and the window shows the
///   welcome screen.
/// - `pendingAddition` is a service being signed in to from "Add a service…" or the welcome
///   screen. It is on screen (`active`) but not added until its sign-in succeeds.
@MainActor
final class MusicServiceStore: ObservableObject {
    static let servicesKey = "musicServices.added"
    static let activeKey = "musicServices.active"
    /// The hidden developer switch that came before the switcher (#378).
    static let legacyDeveloperSwitchKey = "SpotiglassMusicService"
    /// `SpotifyAuthSettings`'s key. A saved client ID means Spotify was set up before services existed.
    static let legacySpotifyClientIDKey = "spotify.clientID"

    @Published private(set) var services: [MusicService]
    @Published private(set) var active: MusicService?
    @Published private(set) var pendingAddition: MusicService?
    /// The space that was on screen when an addition started; Cancel goes back to it.
    private var activeBeforeAddition: MusicService?
    /// The account ID each space's pins were last bound to, so a switch can show that space's
    /// pins at once instead of after the next account lookup. In memory only.
    var lastPinnedUserID: [MusicService: String] = [:]

    /// Apple Music needs MusicKit and this app's real bundle identifier, so screenshot mode only
    /// offers it when it runs with real Apple Music (`scripts/screenshots.sh start --with-apple-music`).
    let availableServices: [MusicService]

    private let storage: MusicServiceSelectionStorage?
    private var spotifySignInObservation: AnyCancellable?

    init(storage: MusicServiceSelectionStorage?, availableServices: [MusicService] = MusicService.switcherOrder) {
        self.storage = storage
        self.availableServices = MusicService.switcherOrder.filter(availableServices.contains)
        let restored = Self.restore(from: storage, availableServices: self.availableServices)
        services = restored.services
        active = restored.active
        if storage?.stringArray(forKey: Self.servicesKey) == nil {
            persist()
        }
    }

    /// The app's store: real defaults for a normal launch, a throwaway domain in screenshot mode
    /// and nothing at all under the unit-test host.
    static func live() -> MusicServiceStore {
        if AppMetadata.isRunningUnitTests {
            // The test host keeps showing Spotify's sign-in, as before services existed.
            return MusicServiceStore(
                storage: InMemoryMusicServiceSelectionStorage(services: [.spotify], active: .spotify),
                availableServices: [.spotify]
            )
        }
        if ScreenshotMode.isActive {
            let defaults = UserDefaults(suiteName: ScreenshotMode.musicServicesDefaultsSuite)
            defaults?.removePersistentDomain(forName: ScreenshotMode.musicServicesDefaultsSuite)
            // The stand-in signs Spotify in at launch; set it up as an existing Spotify user.
            defaults?.set([MusicService.spotify.rawValue], forKey: servicesKey)
            defaults?.set(MusicService.spotify.rawValue, forKey: activeKey)
            return MusicServiceStore(
                storage: defaults,
                availableServices: ScreenshotMode.allowsAppleMusic ? MusicService.switcherOrder : [.spotify]
            )
        }
        return MusicServiceStore(storage: UserDefaults.standard)
    }

    /// Restores the saved choice. A first launch of this version derives it instead, so an
    /// existing Spotify user lands in Spotify with their pins and caches untouched (both are keyed
    /// by the Spotify account, not by the service list), and the old developer switch carries over.
    static func restore(
        from storage: MusicServiceSelectionStorage?,
        availableServices: [MusicService]
    ) -> (services: [MusicService], active: MusicService?) {
        var services: [MusicService]
        var active: MusicService?
        if let saved = storage?.stringArray(forKey: servicesKey) {
            services = saved.compactMap(MusicService.init(rawValue:))
            active = storage?.string(forKey: activeKey).flatMap(MusicService.init(rawValue:))
        } else {
            services = []
            let hasSpotifySetup = !(storage?.string(forKey: legacySpotifyClientIDKey) ?? "").isEmpty
            if hasSpotifySetup {
                services.append(.spotify)
            }
            if storage?.string(forKey: legacyDeveloperSwitchKey) == MusicService.appleMusic.rawValue {
                services.append(.appleMusic)
                active = .appleMusic
            } else {
                active = services.first
            }
        }
        var seen = Set<MusicService>()
        services = services.filter { availableServices.contains($0) && seen.insert($0).inserted }
        if let current = active, !services.contains(current) {
            active = services.first
        }
        if active == nil {
            active = services.first
        }
        return (services, active)
    }

    /// A Spotify sign-in adds Spotify wherever it happens: the welcome screen, "Add a service…", or
    /// Settings with every main window closed (no window is there to notice it then). Adding is
    /// idempotent, so the windows' own handling of the sign-in stays as it is.
    func followSpotifySignIn<States: Publisher>(_ states: States)
    where States.Output == AppConnectionState, States.Failure == Never {
        // Only a move from signed out to signed in counts. A token refresh (signed in → refreshing
        // → signed in) never adds Spotify, so one finishing just as Spotify is signed out can't put
        // it back in the menu.
        var wasSignedIn = false
        spotifySignInObservation = states.sink { [weak self] state in
            let isSignedIn: Bool
            switch state {
            case .signedIn, .refreshing(.some): isSignedIn = true
            case .signedOut, .signingIn, .failed, .refreshing(.none): isSignedIn = false
            }
            defer { wasSignedIn = isSignedIn }
            guard isSignedIn, !wasSignedIn else { return }
            self?.completeAddition(of: .spotify)
        }
    }

    /// Added services in menu order (⌃1, ⌃2).
    var orderedServices: [MusicService] {
        MusicService.switcherOrder.filter(services.contains)
    }

    /// Services "Add a service…" can still add.
    var addableServices: [MusicService] {
        availableServices.filter { !services.contains($0) }
    }

    /// Added services other than the one on screen: what ⌃1 / ⌃2 and the palette can switch to.
    var switchTargets: [MusicService] {
        orderedServices.filter { $0 != active }
    }

    func isAdded(_ service: MusicService) -> Bool {
        services.contains(service)
    }

    /// Shows an added service. Does nothing for a service that isn't added or is already on screen.
    @discardableResult
    func activate(_ service: MusicService) -> Bool {
        guard services.contains(service), active != service || pendingAddition != nil else { return false }
        pendingAddition = nil
        activeBeforeAddition = nil
        active = service
        persist()
        return true
    }

    /// Starts signing in to a service from the welcome screen or "Add a service…". Its sign-in is
    /// shown until it succeeds (``completeAddition(of:)``) or is cancelled (``cancelAddition()``).
    func beginAddition(of service: MusicService) {
        guard availableServices.contains(service) else { return }
        guard !services.contains(service) else {
            activate(service)
            return
        }
        if pendingAddition == nil {
            activeBeforeAddition = active
        }
        pendingAddition = service
        active = service
        SpotiglassLog.info(.settings, "Music services: adding \(service.rawValue)")
    }

    /// A sign-in succeeded. Adds the service; when it was being added it also becomes the space on
    /// screen. A Spotify sign-in from Settings adds Spotify without moving the window.
    func completeAddition(of service: MusicService) {
        guard availableServices.contains(service) else { return }
        let wasPending = pendingAddition == service
        if !services.contains(service) {
            services.append(service)
        }
        if wasPending {
            pendingAddition = nil
            activeBeforeAddition = nil
            active = service
        } else if active == nil {
            active = service
        }
        persist()
    }

    /// Leaves a sign-in that was started to add a service and goes back to where the user was
    /// (the welcome screen when nothing was added yet).
    func cancelAddition() {
        guard pendingAddition != nil else { return }
        SpotiglassLog.info(.settings, "Music services: cancelled adding \(pendingAddition?.rawValue ?? "")")
        pendingAddition = nil
        let previous = activeBeforeAddition
        activeBeforeAddition = nil
        active = previous.flatMap { services.contains($0) ? $0 : nil } ?? services.first
    }

    /// Whether the welcome screen or Cancel would take this sign-in back somewhere.
    var canCancelAddition: Bool {
        pendingAddition != nil
    }

    /// Explicit sign-out from one service. The next added service takes over the window; with
    /// none left, the welcome screen does.
    func remove(_ service: MusicService) {
        guard services.contains(service) || pendingAddition == service else { return }
        services.removeAll { $0 == service }
        if pendingAddition == service {
            pendingAddition = nil
            activeBeforeAddition = nil
        }
        if active == service {
            active = orderedServices.first
        }
        persist()
    }

    /// An explicit sign-out from the UI. Spotify is removed only while another service is left:
    /// signing out of Spotify as the only service shows Spotify's own sign-in again, exactly as
    /// before services existed. Apple Music has no sign-in screen of its own, so signing out of it
    /// always removes it (the welcome screen takes over when it was the last one).
    func signOutRemoving(_ service: MusicService) {
        lastPinnedUserID[service] = nil
        if service == .spotify, services == [.spotify], pendingAddition == nil {
            return
        }
        remove(service)
    }

    private func persist() {
        SpotiglassLog.info(
            .settings,
            "Music services: added=\(services.map(\.rawValue)) active=\(active?.rawValue ?? "none")"
        )
        storage?.set(services.map(\.rawValue), forKey: Self.servicesKey)
        storage?.set(active?.rawValue, forKey: Self.activeKey)
    }
}

/// Keeps the service list in memory: previews, view tests and the unit-test host.
final class InMemoryMusicServiceSelectionStorage: MusicServiceSelectionStorage {
    private var values: [String: Any] = [:]

    init(services: [MusicService]? = nil, active: MusicService? = nil) {
        if let services {
            values[MusicServiceStore.servicesKey] = services.map(\.rawValue)
        }
        if let active {
            values[MusicServiceStore.activeKey] = active.rawValue
        }
    }

    func string(forKey key: String) -> String? {
        values[key] as? String
    }

    func stringArray(forKey key: String) -> [String]? {
        values[key] as? [String]
    }

    func set(_ value: Any?, forKey key: String) {
        values[key] = value
    }
}
