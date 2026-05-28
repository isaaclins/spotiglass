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
                LabeledContent(SpotiglassL10n.string("settings.account.diagnostics.logFileLabel")) {
                    if let url = SpotiglassLog.logFileURL {
                        HStack(spacing: SpotiglassDesign.spacingS) {
                            Text(url.path)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
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
