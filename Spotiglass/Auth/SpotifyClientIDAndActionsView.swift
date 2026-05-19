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

    @FocusState private var isClientIDFocused: Bool
    @State private var lastSignInTriggerAt: Date?

    var body: some View {
        VStack(spacing: SpotiglassDesign.spacingM) {
            clientIDField

            HStack(spacing: SpotiglassDesign.spacingS) {
                Button {
                    triggerSignInIfAllowed()
                } label: {
                    Label(String(localized: "auth.connect.button"), systemImage: "arrow.right.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSignIn)
                .accessibilityHint(String(localized: "auth.connect.hint"))

                if viewModel.state == .signingIn {
                    Button {
                        viewModel.cancelSignIn()
                    } label: {
                        Label(String(localized: "auth.cancel.button"), systemImage: "xmark.circle")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint(String(localized: "auth.cancel.hint"))
                } else {
                    Button {
                        viewModel.signOut()
                    } label: {
                        Label(String(localized: "auth.disconnect.button"), systemImage: "rectangle.portrait.and.arrow.right")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.state.isConnectedOrRefreshing)
                    .accessibilityHint(String(localized: "auth.disconnect.hint"))
                }
            }
        }
    }

    /// Plain `TextField` while empty or while editing; `SecureField` (dots) when there is a saved value and the field is not focused.
    private var clientIDField: some View {
        Group {
            if showsPlaintextClientID {
                TextField(String(localized: "auth.clientID.label"), text: $viewModel.clientID)
            } else {
                SecureField(String(localized: "auth.clientID.label"), text: $viewModel.clientID)
            }
        }
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: layout == .welcome ? 420 : .infinity)
        .disabled(viewModel.state == .signingIn)
        .focused($isClientIDFocused)
        .accessibilityLabel(String(localized: "auth.clientID.label"))
        .accessibilityHint(String(localized: "auth.clientID.hint"))
        .onSubmit {
            triggerSignInIfAllowed()
        }
    }

    private var showsPlaintextClientID: Bool {
        isClientIDFocused || clientIDTrimmed.isEmpty
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
