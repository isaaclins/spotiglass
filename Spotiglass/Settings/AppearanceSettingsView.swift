import SwiftUI

/// Settings → Appearance: window and overlay visuals (command palette, future options).
struct AppearanceSettingsView: View {
    @ObservedObject var settingsStore: SpotiglassSettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SpotiglassDesign.spacingL) {
                header
                colorSchemeSection
                commandPaletteSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SpotiglassDesign.spacingL)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
            Text("Appearance")
                .font(.title3.weight(.semibold))
            Text("Visual options for Spotiglass windows and overlays.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var colorSchemeSection: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
            Text("Color scheme")
                .font(.headline)
            Picker("Color scheme", selection: colorSchemeBinding) {
                ForEach(AppearanceColorScheme.allCases, id: \.self) { scheme in
                    Text(scheme.displayName).tag(scheme)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("System follows macOS. Light and Dark apply only to Spotiglass.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var commandPaletteSection: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
            Text("Command palette")
                .font(.headline)
            Toggle("Blur window behind palette", isOn: backdropBlurBinding)
                .toggleStyle(.switch)
            Text("When on, the rest of the window is slightly blurred while the palette is open.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var colorSchemeBinding: Binding<AppearanceColorScheme> {
        Binding(
            get: { settingsStore.settings.appearance.colorScheme },
            set: { newValue in
                try? settingsStore.mutate { $0.appearance.colorScheme = newValue }
            }
        )
    }

    private var backdropBlurBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.commandPalette.backdropBlur },
            set: { newValue in
                try? settingsStore.mutate { $0.commandPalette.backdropBlur = newValue }
            }
        )
    }
}
