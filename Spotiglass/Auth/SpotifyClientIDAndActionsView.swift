import SwiftUI

/// Shared Spotify client ID field and Connect / Disconnect actions for the welcome screen and Settings.
struct SpotifyClientIDAndActionsView: View {
    enum Layout {
        /// Centered card width on the sign-in screen.
        case welcome
        /// Full-width fields inside a settings form.
        case settings
    }

    @ObservedObject var viewModel: AuthViewModel
    var layout: Layout = .welcome
    /// Lets the hosting scene clear transient browser state before auth loss
    /// replaces its content. Settings uses the same hook as the welcome screen.
    var onSignOut: (() -> Void)? = nil

    @FocusState private var isClientIDFocused: Bool
    @State private var lastSignInTriggerAt: Date?

    var body: some View {
        VStack(spacing: SpotiglassDesign.spacingM) {
            clientIDField

            HStack(spacing: SpotiglassDesign.spacingS) {
                Button {
                    triggerSignInIfAllowed()
                } label: {
                    Label(connectButtonTitle, systemImage: connectButtonIcon)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSignIn)
                .accessibilityHint(SpotiglassL10n.string("auth.connect.hint"))

                if viewModel.state == .signingIn {
                    Button {
                        viewModel.cancelSignIn()
                    } label: {
                        Label(SpotiglassL10n.string("auth.cancel.button"), systemImage: "xmark.circle")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint(SpotiglassL10n.string("auth.cancel.hint"))
                } else {
                    Button {
                        onSignOut?()
                        Task { await viewModel.signOut() }
                    } label: {
                        Label(SpotiglassL10n.string("auth.disconnect.button"), systemImage: "rectangle.portrait.and.arrow.right")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.state.isConnectedOrRefreshing)
                    .accessibilityHint(SpotiglassL10n.string("auth.disconnect.hint"))
                }
            }
        }
    }

    /// The Spotify Client ID is a public PKCE identifier, not a secret, so it is
    /// always shown in plain text — masking it only blocked verification.
    private var clientIDField: some View {
        TextField(SpotiglassL10n.string("auth.clientID.label"), text: $viewModel.clientID)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: layout == .welcome ? 420 : .infinity)
            .disabled(viewModel.state == .signingIn)
            .focused($isClientIDFocused)
            .accessibilityLabel(SpotiglassL10n.string("auth.clientID.label"))
            .accessibilityHint(SpotiglassL10n.string("auth.clientID.hint"))
            .onSubmit {
                triggerSignInIfAllowed()
            }
    }

    /// When already connected, the prominent action is a reconnect rather than a
    /// fresh "Connect Spotify", which contradicted the "connected" status.
    private var connectButtonTitle: String {
        viewModel.state.isConnectedOrRefreshing
            ? SpotiglassL10n.string("auth.reconnect.button")
            : SpotiglassL10n.string("auth.connect.button")
    }

    private var connectButtonIcon: String {
        viewModel.state.isConnectedOrRefreshing ? "arrow.triangle.2.circlepath" : "arrow.right.circle.fill"
    }

    private var clientIDTrimmed: String {
        viewModel.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSignIn: Bool {
        !clientIDTrimmed.isEmpty && viewModel.state != .signingIn && !viewModel.isSignInRetryCoolingDown
    }

    private func triggerSignInIfAllowed() {
        guard canSignIn else { return }
        let now = Date()
        if let lastSignInTriggerAt, now.timeIntervalSince(lastSignInTriggerAt) < 0.25 {
            return
        }
        lastSignInTriggerAt = now
        Task { await viewModel.signIn() }
    }
}
