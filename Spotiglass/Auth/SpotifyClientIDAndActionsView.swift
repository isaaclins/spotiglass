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

    var body: some View {
        VStack(spacing: SpotiglassDesign.spacingM) {
            clientIDField

            HStack(spacing: SpotiglassDesign.spacingS) {
                Button {
                    Task { await viewModel.signIn() }
                } label: {
                    Label("Connect Spotify", systemImage: "arrow.right.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSignIn)
                .accessibilityHint("Starts Spotify sign-in using the configured client ID.")

                if viewModel.state == .signingIn {
                    Button {
                        viewModel.cancelSignIn()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Stops waiting for the browser sign-in and returns to the welcome screen.")
                } else {
                    Button {
                        viewModel.signOut()
                    } label: {
                        Label("Disconnect", systemImage: "rectangle.portrait.and.arrow.right")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.state.isConnectedOrRefreshing)
                    .accessibilityHint("Clears the current Spotify sign-in state.")
                }
            }
        }
    }

    /// Plain `TextField` while empty or while editing; `SecureField` (dots) when there is a saved value and the field is not focused.
    private var clientIDField: some View {
        Group {
            if showsPlaintextClientID {
                TextField("Spotify client ID", text: $viewModel.clientID)
            } else {
                SecureField("Spotify client ID", text: $viewModel.clientID)
            }
        }
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: layout == .welcome ? 420 : .infinity)
        .disabled(viewModel.state == .signingIn)
        .focused($isClientIDFocused)
        .accessibilityLabel("Spotify client ID")
        .accessibilityHint("Paste the client ID from your Spotify Developer Dashboard app. Value is hidden until you click or tab into this field.")
        .onSubmit {
            guard canSignIn else { return }
            Task { await viewModel.signIn() }
        }
    }

    private var showsPlaintextClientID: Bool {
        isClientIDFocused || clientIDTrimmed.isEmpty
    }

    private var clientIDTrimmed: String {
        viewModel.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSignIn: Bool {
        !clientIDTrimmed.isEmpty && viewModel.state != .signingIn
    }
}
