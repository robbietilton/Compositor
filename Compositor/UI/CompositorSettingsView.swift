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
                        .background(page == tab ? CompositorAppearance.ink.opacity(0.09) : .clear,
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
        .panelTitle("Settings")
        .toolbar(removing: .title)
        // The toolbar's glass blurred the header drawn under it.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
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
                    HStack {
                        Text("Appearance").font(.headline)
                        Spacer()
                        CompositorSegmentedPicker("Appearance", selection: Binding(get: { appearance }, set: { option in
                            appearance = option
                            option.apply()
                        }), options: CompositorAppearance.allCases) { Text($0.rawValue) }
                        .fixedSize()
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
                    Divider()
                    Text("Add Compositor to your AI app").font(.subheadline.weight(.semibold))
                    ForEach(MCPClient.allCases, id: \.self) { MCPClientRow(client: $0) }
                }
            }
            .padding(24)
        }
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
                    .toggleStyle(.checkbox)
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

/// The AI apps an MCP connection is set up in, and the setup each takes: the companion inside this app, which the
/// app, sandboxed, can't write into their settings itself.
private enum MCPClient: String, CaseIterable {
    case chatGPT = "ChatGPT", claude = "Claude", claudeCode = "Claude Code"

    static var helper: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/compositor-mcp").path }

    var whereItGoes: String {
        switch self {
        case .claudeCode: "Paste into Terminal."
        case .claude: "Add under \"mcpServers\" in Claude's Settings › Developer › Edit Config, then restart Claude."
        case .chatGPT: "Add to ~/.codex/config.toml, then restart ChatGPT."
        }
    }

    var setup: String {
        let path = Self.helper
        switch self {
        case .claudeCode:
            return "claude mcp add --scope user compositor -- '\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
        case .claude:
            let json = (try? JSONSerialization.data(withJSONObject: path, options: .fragmentsAllowed))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(path)\""
            return "\"compositor\": { \"command\": \(json.replacingOccurrences(of: "\\/", with: "/")) }"
        case .chatGPT:
            let toml = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "[mcp_servers.compositor]\ncommand = \"\(toml)\""
        }
    }
}

private struct MCPClientRow: View {
    let client: MCPClient
    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(client.rawValue)
                Text(client.whereItGoes).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(copied ? "Copied" : "Copy Setup") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(client.setup, forType: .string)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            }
            .help(client.setup)
        }
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CompositorAppearance.ink.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 12))
    }
}
