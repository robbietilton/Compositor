import Sparkle
import SwiftUI

struct CompositorSettingsView: View {
    private enum Page: String, CaseIterable {
        case general = "General", shortcuts = "Shortcuts", updates = "Updates"

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .shortcuts: "keyboard"
            case .updates: "arrow.down.circle"
            }
        }
    }

    let updater: SPUUpdater
    @Environment(\.compositorAmber) private var amber
    @State private var page = Page.general

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(Page.allCases, id: \.self) { tab in
                    Button {
                        page = tab
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: tab.symbol).font(.system(size: 20)).frame(height: 24)
                            Text(tab.rawValue)
                        }
                        .frame(width: 78, height: 52)
                        .foregroundStyle(page == tab ? .primary : .secondary)
                        .background(page == tab ? (amber ? CompositorAppearance.amberButton : CompositorAppearance.ink.opacity(0.09)) : .clear,
                                    in: .rect(cornerRadius: 8))
                        .contentShape(.rect(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.rawValue)
                    .accessibilityAddTraits(page == tab ? .isSelected : [])
                }
            }
            .padding(.vertical, 6)
            Divider()
            ZStack {
                GeneralSettings().opacity(page == .general ? 1 : 0).allowsHitTesting(page == .general)
                    .accessibilityHidden(page != .general)
                KeyboardShortcutsSettings(settings: .shared).opacity(page == .shortcuts ? 1 : 0)
                    .disabled(page != .shortcuts).allowsHitTesting(page == .shortcuts).accessibilityHidden(page != .shortcuts)
                UpdateSettings(updater: updater).opacity(page == .updates ? 1 : 0).allowsHitTesting(page == .updates)
                    .accessibilityHidden(page != .updates)
            }
        }
        .frame(width: 560, height: 580)
        .panelSurface()
        .toolbar(removing: .title)
        .background(SettingsWindowMarker())
    }
}

struct SettingsWindowMarker: NSViewRepresentable {
    static let identifier = NSUserInterfaceItemIdentifier("compositorSettings")

    func makeNSView(context: Context) -> MarkerView { MarkerView() }
    func updateNSView(_ view: MarkerView, context: Context) {}

    final class MarkerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.identifier = SettingsWindowMarker.identifier
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.window else { return }
                PanelTitleBar.install(in: window, title: "Settings", showsCloseButton: true)
            }
        }
    }
}

private struct GeneralSettings: View {
    @AppStorage(CompositorAppearance.defaultsKey) private var appearance = CompositorAppearance.dark
    @AppStorage(MCPAccess.defaultsKey) private var access = MCPAccess.undecided
    private let mcpDescription = "Lets local MCP clients view and edit open projects."

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("General").font(.title2.weight(.semibold))
                SettingsCard {
                    Text("Appearance").font(.headline)
                    HStack(spacing: 12) {
                        ForEach(CompositorAppearance.allCases, id: \.self) { option in
                            appearanceButton(option)
                        }
                    }
                }
                SettingsCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Allow MCP control").font(.headline)
                            Text(mcpDescription).foregroundStyle(.secondary)
                        }
                        .accessibilityHidden(true)
                        Spacer()
                        Toggle("Allow MCP control", isOn: Binding(get: { access == .allowed }, set: {
                            access = $0 ? .allowed : .denied
                        }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .accessibilityHint(mcpDescription)
                    }
                }
            }
            .padding(24)
        }
    }

    private func appearanceButton(_ option: CompositorAppearance) -> some View {
        let selected = appearance == option
        return Button {
            appearance = option
            option.apply()
        } label: {
            VStack(spacing: 7) {
                AppearancePreview(option: option)
                    .frame(height: 76)
                    .clipShape(.rect(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7).strokeBorder(
                            selected ? Color.accentColor : CompositorAppearance.ink.opacity(0.14),
                            lineWidth: selected ? 2 : 1
                        )
                    }
                    .accessibilityHidden(true)
                Text(option.rawValue)
                    .fontWeight(selected ? .semibold : .regular)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct AppearancePreview: View {
    let option: CompositorAppearance

    var body: some View {
        if option == .auto {
            editor(light: true).overlay {
                editor(light: false).mask {
                    HStack(spacing: 0) { Color.clear; Color.black }
                }
            }
        } else {
            editor(light: option == .light, amber: option == .amber)
        }
    }

    private func editor(light: Bool, amber: Bool = false) -> some View {
        let ink = amber ? Color(nsColor: CompositorAppearance.amberText) : light ? .black : .white
        return VStack(spacing: 0) {
            HStack(spacing: 3) {
                Capsule().fill(ink.opacity(0.25)).frame(width: 18, height: 3)
                Capsule().fill(ink.opacity(0.15)).frame(width: 12, height: 3)
                Spacer()
                Capsule().fill(ink.opacity(0.20)).frame(width: 12, height: 3)
            }
            .padding(6)
            .background(ink.opacity(0.06))
            HStack(spacing: 0) {
                VStack(spacing: 4) {
                    ForEach(0..<4) { tool in
                        RoundedRectangle(cornerRadius: 1).fill(ink.opacity(tool == 0 ? 0.46 : 0.22))
                            .frame(width: 5, height: 5)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 14)
                .padding(.top, 6)
                Rectangle().fill(amber ? Color(nsColor: CompositorAppearance.amberSurround)
                                       : Color(white: light ? CompositorAppearance.lightSurroundWhite : 0.105)).overlay {
                    RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.57))
                        .aspectRatio(1.5, contentMode: .fit).padding(9)
                }
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(0..<3) { layer in
                        Capsule().fill(ink.opacity(layer == 0 ? 0.34 : 0.18)).frame(width: 13, height: 3)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 24)
                .padding(.top, 7)
            }
        }
        .background(amber ? CompositorAppearance.amberEditor : Color(white: light ? CompositorAppearance.lightEditorWhite : 0.14))
    }
}

private struct UpdateSettings: View {
    let updater: SPUUpdater
    @Environment(\.openURL) private var openURL
    @State private var canCheck = false
    @State private var checksAutomatically = false
    @State private var lastChecked: Date?

    private var installedVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return version }
        return "\(version) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Updates").font(.title2.weight(.semibold))

                SettingsCard {
                    Text("Software Update").font(.headline)
                    detail("Installed version", value: installedVersion)
                    detail("Last checked", value: lastChecked?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                    Divider()
                    Toggle("Check for updates automatically", isOn: Binding(get: { checksAutomatically }, set: {
                        checksAutomatically = $0
                        updater.automaticallyChecksForUpdates = $0
                    }))
                    .toggleStyle(CompositorCheckboxStyle())
                    Button {
                        updater.checkForUpdates()
                    } label: {
                        Text("Check for Updates…").padding(.horizontal, 14)
                    }
                    .buttonStyle(EditorToolbarPillStyle())
                    .disabled(!canCheck)
                }

                SettingsCard {
                    Text("Release Notes").font(.headline)
                    Text("Read what changed in each version on GitHub.")
                        .foregroundStyle(.secondary)
                    Button {
                        openURL(URL(string: "https://github.com/robbietilton/Compositor/releases")!)
                    } label: {
                        Text("View GitHub Releases").padding(.horizontal, 14)
                    }
                    .buttonStyle(EditorToolbarPillStyle())
                }
            }
            .padding(24)
        }
        .onReceive(updater.publisher(for: \.canCheckForUpdates)) { canCheck = $0 }
        .onReceive(updater.publisher(for: \.automaticallyChecksForUpdates)) { checksAutomatically = $0 }
        .onReceive(updater.publisher(for: \.lastUpdateCheckDate)) { lastChecked = $0 }
    }

    private func detail(_ label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.compositorAmber) private var amber

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(amber ? CompositorAppearance.amberInactiveTab : CompositorAppearance.ink.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 12))
    }
}
