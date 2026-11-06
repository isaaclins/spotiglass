import AppKit
import SwiftUI

/// What the browser's transport bar does.
enum BrowserPlaybackMode: Equatable {
    /// The Spotify player: real transport controls.
    case live
    /// No playback for this service yet; the bar shows this message instead.
    case comingSoon(String)
}

/// Main-window content while Apple Music is the service on screen (see `MusicServiceStore`).
///
/// It asks for the Apple Music permission, then shows the normal browser on top of
/// `AppleMusicBrowsingProvider`. Spotify's session, Keychain item and caches are never touched,
/// and pins are kept under the library's own user ID.
struct AppleMusicBrowserRoot: View {
    @ObservedObject var session: AppleMusicSession
    let playbackHost: SpotiglassPlaybackHost
    let commandPaletteManager: CommandPaletteManager
    /// Kept by the scene while Spotify is on screen, so switching back returns to the same place.
    let viewModel: PlaylistBrowserViewModel
    /// Apple Music is being added ("Add a service…" or the welcome screen): ask for access at once.
    var isAdding = false
    /// Clears every window's browser state. Access is app-wide, so losing it affects all windows.
    let prepareForReset: () -> Void
    /// Re-arms this window's own palette callbacks (Settings, Sign Out) after a detach.
    let rewireScene: () -> Void
    /// Access was granted (or already was): Apple Music counts as added.
    var onAuthorized: () -> Void = {}
    /// The service switcher at the top of the sidebar.
    var sidebarHeader: AnyView? = nil
    /// Below the permission screen: Cancel, or a way to another service.
    var signInFooter: AnyView? = nil


    enum AccessTransition: Equatable {
        case granted
        case lost
        case unchanged
    }

    /// Only a real change of access touches the windows: gaining it re-arms this window's
    /// callbacks, losing it resets every window. Moving from "checking" to "needs permission"
    /// at launch is neither.
    static func accessTransition(from old: AppleMusicSession.State, to new: AppleMusicSession.State) -> AccessTransition {
        if new == .authorized {
            return old == .authorized ? .unchanged : .granted
        }
        return old == .authorized ? .lost : .unchanged
    }

    var body: some View {
        Group {
            switch session.state {
            case .checking:
                ZStack {
                    ShellBackground()
                    ProgressView()
                        .controlSize(.large)
                        .accessibilityLabel(SpotiglassL10n.string("home.section.loading"))
                }
            case .needsPermission, .denied:
                permissionContent
            case .authorized:
                browser
            }
        }
        .task {
            await session.refresh()
            // The user just chose Apple Music: the system prompt is the whole sign-in.
            if isAdding, session.state == .needsPermission {
                await session.requestAccess()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Access is changed in System Settings; pick it up when the user comes back.
            Task { await session.refresh() }
        }
        .onChange(of: session.state, initial: true) { old, state in
            commandPaletteManager.isSignedIn = state == .authorized
            if state == .authorized {
                onAuthorized()
            }
            switch Self.accessTransition(from: old, to: state) {
            case .granted: rewireScene()
            case .lost: prepareForReset()
            case .unchanged: break
            }
        }
    }

    private var browser: some View {
        PlaylistBrowserView(
            viewModel: viewModel,
            playbackHost: playbackHost,
            catalogProvider: AppleMusicBrowsingProvider(),
            commandPaletteManager: commandPaletteManager,
            // No Disconnect: access is a system permission, turned off in System Settings,
            // and signing out of Apple Music lives in Settings › Account (#373).
            signOut: {},
            playbackMode: .comingSoon(playbackMessage),
            canDisconnect: false,
            sidebarHeader: sidebarHeader
        )
        .id(MusicService.appleMusic)
    }

    private var playbackMessage: String {
        session.canPlayCatalogContent == false
            ? SpotiglassL10n.string("appleMusic.playback.comingSoon.noSubscription")
            : SpotiglassL10n.string("appleMusic.playback.comingSoon")
    }

    private var permissionContent: some View {
        ZStack {
            ShellBackground()
            GlassPanel {
                VStack(spacing: SpotiglassDesign.spacingM) {
                    Label {
                        Text(AppMetadata.displayName)
                    } icon: {
                        Image(systemName: "music.note")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .font(.title2.weight(.semibold))
                    .labelStyle(.titleAndIcon)

                    Text(
                        session.state == .denied
                            ? SpotiglassL10n.string("appleMusic.permission.denied")
                            : SpotiglassL10n.string("appleMusic.permission.message")
                    )
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)

                    if session.state == .denied {
                        Button(SpotiglassL10n.string("appleMusic.permission.openSettings")) {
                            NSWorkspace.shared.open(AppleMusicSession.privacySettingsURL)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    } else {
                        Button(SpotiglassL10n.string("appleMusic.permission.allow")) {
                            Task { await session.requestAccess() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }

                    if let signInFooter {
                        signInFooter
                    }
                }
                .padding(SpotiglassDesign.spacingL)
            }
            .frame(maxWidth: 560)
            .padding(SpotiglassDesign.spacingL)
        }
    }

    /// No disk cache for Apple Music: library reads are local and fast, and library artwork
    /// URLs are only valid while MusicKit's session lives, so a stored copy would go blank.
    /// Spotify's own cache is never shared with this browser.
    static func makeViewModel() -> PlaylistBrowserViewModel {
        PlaylistBrowserViewModel(api: AppleMusicBrowsingProvider(), cache: DisabledSpotifyBrowsingCache())
    }
}

/// Stands in for the transport bar while a service has no playback yet.
struct PlaybackComingSoonBar: View {
    let message: String

    var body: some View {
        GlassPanel {
            Label(message, systemImage: "play.slash")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, SpotiglassDesign.spacingM)
                .padding(.vertical, SpotiglassDesign.spacingS)
        }
        .padding(.horizontal, SpotiglassDesign.spacingM)
        .padding(.bottom, SpotiglassDesign.spacingM)
        .accessibilityElement(children: .combine)
    }
}
