import Combine
import Sparkle
import SwiftUI

/// Publishes when the user can manually check for updates (Sparkle sample pattern).
@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

/// App menu item wired to Sparkle's manual update check.
struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button(SpotiglassL10n.string("app.menu.checkForUpdates")) {
            updater.checkForUpdates()
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}

/// Mirrors Sparkle's "download and install by itself" switch so Settings can show and change it.
/// Sparkle keeps the choice in its own defaults; until someone changes it, the default comes from
/// `SUAutomaticallyUpdate` in `SparkleInfo.plist` (on).
@MainActor
final class AutomaticUpdatesViewModel: ObservableObject {
    @Published private(set) var installsAutomatically: Bool
    @Published private(set) var canCheckForUpdates = false

    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        installsAutomatically = updater.automaticallyDownloadsUpdates
        updater.publisher(for: \.automaticallyDownloadsUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$installsAutomatically)
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    func setInstallsAutomatically(_ isOn: Bool) {
        // Sparkle only downloads by itself while it also checks by itself.
        if isOn { updater.automaticallyChecksForUpdates = true }
        updater.automaticallyDownloadsUpdates = isOn
        installsAutomatically = updater.automaticallyDownloadsUpdates
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}

/// Settings › Account › Updates: the automatic-install switch next to a manual check.
struct UpdatesSettingsSection: View {
    @StateObject private var viewModel: AutomaticUpdatesViewModel

    init(updater: SPUUpdater) {
        _viewModel = StateObject(wrappedValue: AutomaticUpdatesViewModel(updater: updater))
    }

    var body: some View {
        Section {
            Toggle(
                SpotiglassL10n.string("settings.updates.installAutomatically"),
                isOn: Binding(
                    get: { viewModel.installsAutomatically },
                    set: { viewModel.setInstallsAutomatically($0) }
                )
            )
            HStack {
                Spacer(minLength: 0)
                Button(SpotiglassL10n.string("app.menu.checkForUpdates")) {
                    viewModel.checkForUpdates()
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.canCheckForUpdates)
            }
        } header: {
            Text(SpotiglassL10n.string("settings.updates.header"))
        } footer: {
            Text(SpotiglassL10n.string(
                viewModel.installsAutomatically
                    ? "settings.updates.footer.automatic"
                    : "settings.updates.footer.prompt"
            ))
            .foregroundStyle(.secondary)
        }
    }
}
