import AppKit
import SwiftUI

extension MusicService {
    /// The service's official icon (Spotify icon, Apple Music icon) in its monochrome version.
    ///
    /// Both brands allow only these marks here: Spotify's green icon may sit only on black or
    /// white, so on the translucent sidebar it has to be the black or white one, and Apple asks for
    /// the black or white Apple Music icon whenever the icons beside it aren't in color. The assets
    /// are template images, so they draw in the label color: black in light mode, white in dark.
    var logoAssetName: String {
        switch self {
        case .spotify: "SpotifyIcon"
        case .appleMusic: "AppleMusicIcon"
        }
    }

    /// The logo for a menu item. Menus draw images at their own size, so the vector asset gets one.
    func menuIcon(pointSize: CGFloat = 16) -> NSImage? {
        guard let source = NSImage(named: logoAssetName) else { return nil }
        let aspect = source.size.height > 0 ? source.size.width / source.size.height : 1
        let size = NSSize(width: (pointSize * aspect).rounded(), height: pointSize)
        // Drawn on demand at the menu's own scale, so the vector logo stays sharp on every display.
        let image = NSImage(size: size, flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = displayName
        return image
    }
}

/// A service's logo at a given height.
struct MusicServiceLogo: View {
    let service: MusicService
    var size: CGFloat = 22

    var body: some View {
        Image(service.logoAssetName)
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: size)
            .accessibilityHidden(true)
    }
}

/// The active service's logo and name at the top left of the sidebar. Clicking it lists every
/// added service, with a checkmark on the one on screen, and "Add a service…".
///
/// The list is a native `NSMenu`: a SwiftUI menu drops an item's image as soon as it carries a
/// checkmark, and the logos are the point of the list.
struct MusicServiceSwitcher: View {
    @ObservedObject var store: MusicServiceStore
    @ObservedObject var keymapStore: CommandPaletteKeymapStore
    let switchTo: (MusicService) -> Void
    let add: (MusicService) -> Void

    /// Spotify's minimum for its icon in digital use is 21 px; this keeps it above that at 1x.
    static let logoSize: CGFloat = 22

    @State private var anchor = MusicServiceMenuAnchor()
    @State private var isHovering = false

    var body: some View {
        if let active = store.active {
            Button {
                anchor.popUp(items: menuItems())
            } label: {
                label(for: active)
            }
            .buttonStyle(.plain)
            .background(MusicServiceMenuAnchorView(anchor: anchor))
            .onHover { isHovering = $0 }
            .fixedSize()
            .help(SpotiglassL10n.string("switcher.help"))
            .accessibilityLabel(SpotiglassL10n.format("switcher.accessibility.label", active.displayName))
            .accessibilityHint(SpotiglassL10n.string("switcher.accessibility.hint"))
        }
    }

    private func label(for service: MusicService) -> some View {
        HStack(spacing: SpotiglassDesign.spacingXS) {
            MusicServiceLogo(service: service, size: Self.logoSize)
            Text(service.displayName)
                .font(.headline)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, SpotiglassDesign.spacingXS)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                .fill(.primary.opacity(isHovering ? 0.08 : 0))
        )
        .contentShape(Rectangle())
    }

    /// What the menu shows, newest state every time it opens.
    func menuItems() -> [MusicServiceMenuItem] {
        var items: [MusicServiceMenuItem] = store.orderedServices.map { service in
            let shortcut = keymapStore.menuShortcut(for: service.switchCommandID)
            return .service(
                service,
                isActive: store.active == service,
                keyEquivalent: shortcut.map { String($0.key.character) } ?? "",
                modifiers: shortcut.map { NSEvent.ModifierFlags($0.modifiers) } ?? [],
                action: { switchTo(service) }
            )
        }
        items.append(.separator)
        let next = store.addableServices.first
        items.append(.add(isEnabled: next != nil, action: {
            if let next { add(next) }
        }))
        return items
    }
}

/// One row of the service menu.
enum MusicServiceMenuItem {
    case service(
        MusicService,
        isActive: Bool,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags,
        action: () -> Void
    )
    case separator
    case add(isEnabled: Bool, action: () -> Void)

    var title: String? {
        switch self {
        case let .service(service, _, _, _, _): service.displayName
        case .separator: nil
        case .add: SpotiglassL10n.string("switcher.addService")
        }
    }
}

extension NSEvent.ModifierFlags {
    init(_ modifiers: EventModifiers) {
        self = []
        if modifiers.contains(.command) { insert(.command) }
        if modifiers.contains(.control) { insert(.control) }
        if modifiers.contains(.option) { insert(.option) }
        if modifiers.contains(.shift) { insert(.shift) }
    }
}

/// Builds and shows the service menu under the label.
@MainActor
final class MusicServiceMenuAnchor: NSObject {
    weak var view: NSView?
    private var actions: [() -> Void] = []

    func makeMenu(items: [MusicServiceMenuItem]) -> NSMenu {
        actions = []
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            switch item {
            case let .service(service, isActive, keyEquivalent, modifiers, action):
                let menuItem = NSMenuItem(
                    title: service.displayName,
                    action: #selector(run(_:)),
                    keyEquivalent: keyEquivalent
                )
                menuItem.keyEquivalentModifierMask = modifiers
                menuItem.image = service.menuIcon()
                menuItem.state = isActive ? .on : .off
                menuItem.target = self
                menuItem.tag = actions.count
                actions.append(action)
                menu.addItem(menuItem)
            case .separator:
                menu.addItem(.separator())
            case let .add(isEnabled, action):
                let menuItem = NSMenuItem(
                    title: item.title ?? "",
                    action: #selector(run(_:)),
                    keyEquivalent: ""
                )
                menuItem.isEnabled = isEnabled
                menuItem.target = self
                menuItem.tag = actions.count
                actions.append(action)
                menu.addItem(menuItem)
            }
        }
        return menu
    }

    func popUp(items: [MusicServiceMenuItem]) {
        guard let view else { return }
        let menu = makeMenu(items: items)
        // Just under the label, aligned with its leading edge.
        let origin = NSPoint(x: 0, y: view.isFlipped ? view.bounds.height + 4 : -4)
        menu.popUp(positioning: nil, at: origin, in: view)
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        // Let the menu close before the window's content changes underneath it.
        let action = actions[sender.tag]
        DispatchQueue.main.async { action() }
    }
}

/// Gives the anchor the label's view to pop the menu from.
private struct MusicServiceMenuAnchorView: NSViewRepresentable {
    let anchor: MusicServiceMenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

/// First launch, or every service signed out: pick the service you listen on.
struct MusicServiceWelcomeView: View {
    let services: [MusicService]
    let choose: (MusicService) -> Void

    var body: some View {
        ZStack {
            ShellBackground()
            GlassPanel {
                VStack(spacing: SpotiglassDesign.spacingL) {
                    VStack(spacing: SpotiglassDesign.spacingXS) {
                        Label {
                            Text(AppMetadata.displayName)
                        } icon: {
                            Image(systemName: "music.note")
                                .symbolRenderingMode(.hierarchical)
                        }
                        .font(.title2.weight(.semibold))
                        .labelStyle(.titleAndIcon)

                        Text(SpotiglassL10n.string("welcome.service.message"))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }

                    HStack(spacing: SpotiglassDesign.spacingM) {
                        ForEach(services, id: \.self) { service in
                            MusicServiceChoiceButton(service: service) {
                                choose(service)
                            }
                        }
                    }
                }
                .padding(SpotiglassDesign.spacingL)
            }
            .frame(maxWidth: 560)
            .padding(SpotiglassDesign.spacingL)
        }
    }
}

/// One of the welcome screen's two choices.
private struct MusicServiceChoiceButton: View {
    let service: MusicService
    let action: () -> Void
    @State private var isHovering = false

    private var detail: String {
        switch service {
        case .spotify: SpotiglassL10n.string("welcome.service.spotify.detail")
        case .appleMusic: SpotiglassL10n.string("welcome.service.appleMusic.detail")
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: SpotiglassDesign.spacingS) {
                MusicServiceLogo(service: service, size: 44)
                Text(service.displayName)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 190)
            .padding(.vertical, SpotiglassDesign.spacingL)
            .padding(.horizontal, SpotiglassDesign.spacingM)
            .background(
                RoundedRectangle(cornerRadius: SpotiglassDesign.cornerM, style: .continuous)
                    .fill(.primary.opacity(isHovering ? 0.10 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SpotiglassDesign.cornerM, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08))
            )
            .contentShape(RoundedRectangle(cornerRadius: SpotiglassDesign.cornerM, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(detail)
    }
}

/// Below a service's sign-in: leave an unfinished "Add a service…", go to another service that is
/// already added, or try the other service instead. Spotify's sign-in itself is unchanged.
struct MusicServiceSignInFooter: View {
    @ObservedObject var store: MusicServiceStore
    let switchTo: (MusicService) -> Void
    let add: (MusicService) -> Void

    var body: some View {
        if store.canCancelAddition {
            Button(SpotiglassL10n.string("switcher.cancelAddition")) {
                store.cancelAddition()
            }
            .buttonStyle(.link)
        } else if let other = store.switchTargets.first {
            Button(SpotiglassL10n.format("switcher.switchTo", other.displayName)) {
                switchTo(other)
            }
            .buttonStyle(.link)
        } else if let other = store.addableServices.first(where: { $0 != store.active }) {
            Button(SpotiglassL10n.format("switcher.useInstead", other.displayName)) {
                add(other)
            }
            .buttonStyle(.link)
        }
    }
}
