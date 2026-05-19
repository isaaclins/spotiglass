import SwiftUI

/// Settings → Appearance: window and overlay visuals (command palette, future options).
struct AppearanceSettingsView: View {
    @ObservedObject var settingsStore: SpotiglassSettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SpotiglassDesign.spacingL) {
                header
                colorSchemeSection
                lyricsTextSizeSection
                commandPaletteSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SpotiglassDesign.spacingL)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
            Text("settings.section.appearance", bundle: .main)
                .font(.title3.weight(.semibold))
            Text("settings.section.appearance.subtitle", bundle: .main)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var colorSchemeSection: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
            Text("settings.appearance.colorScheme", bundle: .main)
                .font(.headline)
            Picker(String(localized: "settings.appearance.colorScheme"), selection: colorSchemeBinding) {
                ForEach(AppearanceColorScheme.allCases, id: \.self) { scheme in
                    Text(scheme.displayName).tag(scheme)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("settings.appearance.colorScheme.hint", bundle: .main)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
    }

    private var commandPaletteSection: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
            Text("settings.appearance.commandPalette", bundle: .main)
                .font(.headline)
            Toggle(String(localized: "settings.appearance.backdropBlur"), isOn: backdropBlurBinding)
                .toggleStyle(.switch)
                .accessibilityHint(String(localized: "settings.appearance.backdropBlur.hint"))
            Text("settings.appearance.backdropBlur.hint", bundle: .main)
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

    // MARK: - Lyrics text size

    private var lyricsTextSizeSection: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
            Text("settings.appearance.lyricsTextSize", bundle: .main)
                .font(.headline)
            Picker(String(localized: "settings.appearance.lyricsTextSize"), selection: lyricsTextSizeBinding) {
                ForEach(LyricsTextSize.allCases, id: \.self) { size in
                    Text(size.displayName).tag(size)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            LyricsTextSizePreview(size: settingsStore.settings.appearance.lyricsTextSize)

            Text("settings.appearance.lyricsTextSize.hint", bundle: .main)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var lyricsTextSizeBinding: Binding<LyricsTextSize> {
        Binding(
            get: { settingsStore.settings.appearance.lyricsTextSize },
            set: { newValue in
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    try? settingsStore.mutate { $0.appearance.lyricsTextSize = newValue }
                }
            }
        )
    }
}

/// Live preview tile that mirrors the immersive lyrics styling for the picked size.
private struct LyricsTextSizePreview: View {
    let size: LyricsTextSize

    private let lines: [(text: String, distance: Int)] = [
        (String(localized: "settings.appearance.lyricsPreview.line1"),   -1),
        (String(localized: "settings.appearance.lyricsPreview.line2"),   0),
        (String(localized: "settings.appearance.lyricsPreview.line3"),       1)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: max(8, size.timedLineSpacing * 0.55)) {
            ForEach(lines, id: \.distance) { line in
                Text(line.text)
                    .font(.system(
                        size: line.distance == 0 ? size.activeFontSize : size.inactiveFontSize,
                        weight: line.distance == 0 ? .semibold : .regular
                    ))
                    .foregroundStyle(.primary.opacity(line.distance == 0 ? 1.0 : 0.45))
                    .blur(radius: line.distance == 0 ? 0 : 0.4)
                    .shadow(
                        color: line.distance == 0
                            ? Color.accentColor.opacity(0.22)
                            : .clear,
                        radius: line.distance == 0 ? size.activeGlowRadius * 0.6 : 0
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, SpotiglassDesign.spacingM)
        .padding(.vertical, SpotiglassDesign.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .spotiglassSurface(corner: .m)
        .animation(SpotiglassMotion.surfaceSpring, value: size)
        .accessibilityLabel(
            String(format: String(localized: "settings.appearance.lyricsPreview.label"), size.displayName)
        )
    }
}
