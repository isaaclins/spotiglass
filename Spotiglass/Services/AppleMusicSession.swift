import Foundation
import MusicKit

/// The two system answers Apple Music browsing depends on: the user's permission for this app,
/// and whether the account has a subscription that can play catalog music.
protocol AppleMusicAuthorizing: Sendable {
    func currentStatus() -> MusicAuthorization.Status
    func requestAuthorization() async -> MusicAuthorization.Status
    /// `true` when the account can play catalog content, `nil` when that is unknown.
    func canPlayCatalogContent() async -> Bool?
}

/// Apple Music sign-in state for the browser. There is no account to sign in to: the system
/// permission prompt is the whole flow, and the grant belongs to this app's signature.
@MainActor
final class AppleMusicSession: ObservableObject {
    enum State: Equatable {
        case checking
        /// The user has not been asked yet.
        case needsPermission
        /// The user said no (or a device policy does); only System Settings can change it.
        case denied
        case authorized
    }

    @Published private(set) var state: State = .checking
    /// Known once authorized; browsing works without a subscription, playback will not.
    @Published private(set) var canPlayCatalogContent: Bool?

    private let authorization: any AppleMusicAuthorizing

    init(authorization: any AppleMusicAuthorizing = SystemAppleMusicAuthorization()) {
        self.authorization = authorization
    }

    /// Reads the current permission without prompting.
    func refresh() async {
        await apply(authorization.currentStatus())
    }

    /// Shows the system prompt when the user has not answered it yet.
    func requestAccess() async {
        let current = authorization.currentStatus()
        guard current == .notDetermined else {
            await apply(current)
            return
        }
        await apply(await authorization.requestAuthorization())
    }

    private func apply(_ status: MusicAuthorization.Status) async {
        switch status {
        case .authorized:
            state = .authorized
            canPlayCatalogContent = await authorization.canPlayCatalogContent()
        case .notDetermined:
            state = .needsPermission
        case .denied, .restricted:
            state = .denied
        @unknown default:
            state = .denied
        }
    }

    /// Privacy & Security > Media & Apple Music.
    static let privacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Media"
    )!
}
