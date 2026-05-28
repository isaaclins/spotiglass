import SwiftUI
import AppKit

struct AccountSettingsView: View {
    @ObservedObject var viewModel: AuthViewModel

    var body: some View {
        Form {
            Section {
                LabeledContent(SpotiglassL10n.string("settings.account.status")) {
                    Text(viewModel.state.title)
                }
                if let session = activeSession {
                    LabeledContent(SpotiglassL10n.string("settings.account.accessToken")) {
                        Text(
                            String(
                                format: SpotiglassL10n.string("settings.account.validUntil"),
                                session.expiresAt.formatted(date: .omitted, time: .shortened)
                            )
                        )
                            .foregroundStyle(.secondary)
                    }
                } else {
                    LabeledContent(SpotiglassL10n.string("settings.account.details")) {
                        Text(viewModel.state.message)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text(SpotiglassL10n.string("settings.account.connection"))
            }

            Section {
                SpotifyClientIDAndActionsView(viewModel: viewModel, layout: .settings)
            } header: {
                Text(SpotiglassL10n.string("settings.account.developerApp"))
            } footer: {
                Text(SpotiglassL10n.string("settings.account.developerApp.hint"))
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Log file") {
                    if let url = SpotiglassLog.logFileURL {
                        HStack(spacing: SpotiglassDesign.spacingS) {
                            Text(url.path)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                        }
                    } else {
                        Text("Log file not available.")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Truncated at every launch. Attach this file when filing bug reports.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(SpotiglassDesign.spacingL)
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
