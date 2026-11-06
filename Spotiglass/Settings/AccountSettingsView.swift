import SwiftUI
import AppKit

struct AccountSettingsView: View {
    @ObservedObject var viewModel: AuthViewModel
    var onSignOut: () -> Void = {}
    /// The added services (#373). Each one signs in and out here on its own; `nil` (previews and
    /// older tests) shows Spotify only, as before services existed.
    var serviceStore: MusicServiceStore? = nil
    var appleMusicSession: AppleMusicSession? = nil

    /// Clears every window's palette and lyrics state before a sign-out, but only when the service
    /// being signed out is the one on screen. Signing out of the other one changes nothing on
    /// screen, so nothing would wire the palette up again and the library left on screen would
    /// lose its commands.
    private func prepareForSignOut(of service: MusicService) {
        if let serviceStore, serviceStore.active != service { return }
        onSignOut()
    }

    var body: some View {
        Form {
            spotifySections
            if let serviceStore, let appleMusicSession, serviceStore.availableServices.contains(.appleMusic) {
                AppleMusicAccountSection(
                    store: serviceStore,
                    session: appleMusicSession,
                    onSignOut: { prepareForSignOut(of: .appleMusic) },
                    onAdd: onSignOut
                )
            }
            diagnosticsSection
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var spotifySections: some View {
            Section {
                LabeledContent(SpotiglassL10n.string("settings.account.status")) {
                    Text(viewModel.state.title)
                }
                // When signed in, Status already says so. The token expiry that
                // used to sit here told the user nothing they could act on and
                // made a silent refresh look like an expiry; it lives in
                // Diagnostics now (#163).
                if activeSession == nil {
                    LabeledContent(SpotiglassL10n.string("settings.account.details")) {
                        Text(viewModel.state.message)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text(MusicService.spotify.displayName)
            }

            Section {
                SpotifyClientIDAndActionsView(
                    viewModel: viewModel,
                    layout: .settings,
                    onSignOut: {
                        prepareForSignOut(of: .spotify)
                        serviceStore?.signOutRemoving(.spotify)
                    }
                )
            } header: {
                Text(SpotiglassL10n.string("settings.account.developerApp"))
            } footer: {
                Text(SpotiglassL10n.string("settings.account.developerApp.hint"))
                    .foregroundStyle(.secondary)
            }
    }

    private var diagnosticsSection: some View {
            Section {
                if let session = activeSession {
                    LabeledContent(SpotiglassL10n.string("settings.account.accessToken")) {
                        Text(
                            String(
                                format: SpotiglassL10n.string("settings.account.validUntil"),
                                session.expiresAt.formatted(
                                    .dateTime.year().month().day().hour().minute().timeZone()
                                )
                            )
                        )
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                LabeledContent(SpotiglassL10n.string("settings.account.diagnostics.logFileLabel")) {
                    if let url = SpotiglassLog.logFileURL {
                        HStack(spacing: SpotiglassDesign.spacingS) {
                            // Truncate the front, not the middle, so the file name stays
                            // readable; the full path is available via tooltip and Copy.
                            Text(url.path)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                                .textSelection(.enabled)
                                .help(url.path)
                            Button(SpotiglassL10n.string("settings.account.diagnostics.copyPath")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url.path, forType: .string)
                            }
                            Button(SpotiglassL10n.string("settings.account.diagnostics.revealInFinder")) {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                        }
                    } else {
                        Text(SpotiglassL10n.string("settings.account.diagnostics.logFileUnavailable"))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(SpotiglassL10n.string("settings.account.diagnostics.header"))
            } footer: {
                Text(SpotiglassL10n.string("settings.account.diagnostics.footer"))
                    .foregroundStyle(.secondary)
            }
    }

    private var activeSession: AuthenticatedSession? {
        switch viewModel.state {
        case let .signedIn(session):
            session
        case let .refreshing(.some(session)):
            session
        case .signedOut, .signingIn, .failed, .refreshing(.none):
            nil
        }
    }
}

/// Settings › Account for Apple Music: its status, and signing in or out of it in Spotiglass.
/// Access itself is a system permission, so signing out only removes Apple Music from the service
/// menu; the footer says where the permission lives.
private struct AppleMusicAccountSection: View {
    @ObservedObject var store: MusicServiceStore
    @ObservedObject var session: AppleMusicSession
    let onSignOut: () -> Void
    /// Adding puts Apple Music on screen, so the windows' state is cleared first.
    let onAdd: () -> Void

    private var statusText: String {
        guard store.isAdded(.appleMusic) else {
            return SpotiglassL10n.string("settings.account.appleMusic.status.notAdded")
        }
        switch session.state {
        case .authorized: return SpotiglassL10n.string("settings.account.appleMusic.status.allowed")
        case .denied: return SpotiglassL10n.string("settings.account.appleMusic.status.denied")
        case .needsPermission, .checking: return SpotiglassL10n.string("settings.account.appleMusic.status.checking")
        }
    }

    var body: some View {
        Section {
            LabeledContent(SpotiglassL10n.string("settings.account.status")) {
                Text(statusText)
            }
            HStack {
                Spacer(minLength: 0)
                if store.isAdded(.appleMusic) {
                    Button {
                        onSignOut()
                        store.signOutRemoving(.appleMusic)
                    } label: {
                        Label(
                            SpotiglassL10n.string("settings.account.appleMusic.signOut"),
                            systemImage: "rectangle.portrait.and.arrow.right"
                        )
                        .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        onAdd()
                        store.beginAddition(of: .appleMusic)
                    } label: {
                        Label(SpotiglassL10n.string("settings.account.appleMusic.add"), systemImage: "plus.circle")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.bordered)
                }
            }
        } header: {
            Text(MusicService.appleMusic.displayName)
        } footer: {
            Text(SpotiglassL10n.string("settings.account.appleMusic.footer"))
                .foregroundStyle(.secondary)
        }
        .task {
            await session.refresh()
        }
    }
}
