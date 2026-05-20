import SwiftUI

/// Settings → Appearance: window and overlay visuals (command palette, future options).
struct AppearanceSettingsView: View {
    @ObservedObject var settingsStore: SpotiglassSettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SpotiglassDesign.spacingL) {
                header
                languageSection
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
            Text(SpotiglassL10n.string("settings.section.appearance"))
                .font(.title3.weight(.semibold))
            Text(SpotiglassL10n.string("settings.section.appearance.subtitle"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
            Text(SpotiglassL10n.string("settings.appearance.language"))
                .font(.headline)
            Picker(SpotiglassL10n.string("settings.appearance.language"), selection: languageBinding) {
                ForEach(AppLanguage.allCases, id: \.self) { language in
                    Text(language.nativeDisplayName).tag(language)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(SpotiglassL10n.string("settings.appearance.language.hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { settingsStore.settings.appearance.language },
            set: { newValue in
                try? settingsStore.mutate { $0.appearance.language = newValue }
            }
        )
    }

    private var colorSchemeSection: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
            Text(SpotiglassL10n.string("settings.appearance.colorScheme"))
                .font(.headline)
            Picker(SpotiglassL10n.string("settings.appearance.colorScheme"), selection: colorSchemeBinding) {
                ForEach(AppearanceColorScheme.allCases, id: \.self) { scheme in
                    Text(scheme.displayName).tag(scheme)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(SpotiglassL10n.string("settings.appearance.colorScheme.hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
    }

    private var commandPaletteSection: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
            Text(SpotiglassL10n.string("settings.appearance.commandPalette"))
                .font(.headline)
            Toggle(SpotiglassL10n.string("settings.appearance.backdropBlur"), isOn: backdropBlurBinding)
                .toggleStyle(.switch)
                .accessibilityHint(SpotiglassL10n.string("settings.appearance.backdropBlur.hint"))
            Text(SpotiglassL10n.string("settings.appearance.backdropBlur.hint"))
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
            Text(SpotiglassL10n.string("settings.appearance.lyricsTextSize"))
                .font(.headline)
            Picker(SpotiglassL10n.string("settings.appearance.lyricsTextSize"), selection: lyricsTextSizeBinding) {
                ForEach(LyricsTextSize.allCases, id: \.self) { size in
                    Text(size.displayName).tag(size)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            LyricsTextSizePreview(size: settingsStore.settings.appearance.lyricsTextSize)

            Text(SpotiglassL10n.string("settings.appearance.lyricsTextSize.hint"))
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
        (SpotiglassL10n.string("settings.appearance.lyricsPreview.line1"),   -1),
        (SpotiglassL10n.string("settings.appearance.lyricsPreview.line2"),   0),
        (SpotiglassL10n.string("settings.appearance.lyricsPreview.line3"),       1)
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
            String(format: SpotiglassL10n.string("settings.appearance.lyricsPreview.label"), size.displayName)
        )
    }
}
