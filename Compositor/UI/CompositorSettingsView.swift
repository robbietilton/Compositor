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
    private let mcpDescription = "Lets AI apps view and edit your open projects."

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("General").font(.title2.weight(.semibold))
                SettingsCard {
                    HStack {
                        Text("Appearance").font(SettingsText.title)
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
                            Text("Allow MCP control").font(SettingsText.title)
                            Text(mcpDescription).font(SettingsText.note).foregroundStyle(.secondary)
                        }
                        .accessibilityHidden(true)
                        Spacer()
                        Toggle("Allow MCP control", isOn: Binding(get: { access == .allowed }, set: {
                            access = $0 ? .allowed : .denied
                        }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .accessibilityHint(mcpDescription)
                    }
                    Divider()
                    Text("Add Compositor to your AI app").font(SettingsText.note).foregroundStyle(.secondary)
                    // With MCP control off, no AI app can use Compositor: the rows are dimmed and show no connection,
                    // though what's connected is kept for when it's turned on again.
                    ForEach(MCPClient.allCases, id: \.self) { MCPClientRow(client: $0, allowed: access == .allowed) }
                        .disabled(access != .allowed)
                    if access != .allowed {
                        Text("Turn on Allow MCP control to connect AI apps.").font(SettingsText.note).foregroundStyle(.secondary)
                    }
                    if let problem = MCPConnect.shared.problem {
                        Text(problem).font(SettingsText.note).foregroundStyle(.red)
                    }
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

/// The AI apps an MCP connection is set up in. ChatGPT and Claude connect from here (see MCPConnect); Claude Code takes
/// a line pasted into Terminal, which the sandboxed app can't run itself.
private enum MCPClient: String, CaseIterable {
    case chatGPT = "ChatGPT", claude = "Claude", claudeCode = "Claude Code"
}

private struct MCPClientRow: View {
    let client: MCPClient
    /// MCP control is on: off, a connected app shows no dot.
    var allowed = true
    @State private var connect = MCPConnect.shared
    @State private var copied = false

    private var claudeCodeSetup: String {
        "claude mcp add --scope user compositor -- '\(MCPConnect.helper.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private var note: String {
        if !allowed {
            switch client {
            case .chatGPT: return "Adds Compositor to ChatGPT."
            case .claude: return "Adds Compositor to Claude as an extension."
            case .claudeCode: return "Paste into Terminal."
            }
        }
        switch client {
        case .chatGPT:
            if MCPConnect.installed(MCPConnect.chatGPTBundleIDs) == nil { return "ChatGPT isn't on this Mac." }
            if !connect.chatGPTConnected { return "Adds Compositor to ChatGPT." }
            return connect.chatGPTNeedsRestart ? "Connected. Restart ChatGPT to start using it." : "Connected. Ask ChatGPT in a new chat."
        case .claude:
            if MCPConnect.installed([MCPConnect.claudeBundleID]) == nil { return "Claude isn't on this Mac." }
            if connect.claudeConnected { return "Connected. Ask Claude in a new chat." }
            if connect.claudeInstalled { return "Disconnected. To remove it from Claude too, use Claude's Settings › Plugins." }
            return connect.claudeWaiting ? "Click Install in Claude to finish." : "Adds Compositor to Claude as an extension."
        case .claudeCode:
            return "Paste into Terminal."
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(client.rawValue).font(SettingsText.name)
                    if allowed, client == .chatGPT ? connect.chatGPTConnected : client == .claude && connect.claudeConnected {
                        Circle().fill(.green).frame(width: 6, height: 6).accessibilityLabel("Connected")
                    }
                }
                Text(note).font(SettingsText.note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Group {
            switch client {
            case .chatGPT:
                if connect.chatGPTConnected {
                    Button("Disconnect") { connect.disconnectChatGPT() }
                } else {
                    Button("Connect") { connect.connectChatGPT() }
                        .disabled(MCPConnect.installed(MCPConnect.chatGPTBundleIDs) == nil)
                }
            case .claude:
                if connect.claudeConnected {
                    Button("Disconnect") { connect.disconnectClaude() }
                } else {
                    Button(connect.claudeWaiting ? "Open Again" : "Connect") { connect.connectClaude() }
                        .disabled(MCPConnect.installed([MCPConnect.claudeBundleID]) == nil)
                }
            case .claudeCode:
                Button(copied ? "Copied" : "Copy Setup") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(claudeCodeSetup, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                }
                .help(claudeCodeSetup)
            }
            }
            .controlSize(.small)
        }
        .onAppear { connect.refresh() }
        // Back from Claude or ChatGPT: see what changed there.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in connect.refresh() }
    }
}

/// The General page's three kinds of text: a card's title, an app's name under it, and every note in gray.
private enum SettingsText {
    static let title = Font.system(size: 13, weight: .semibold)
    static let name = Font.system(size: 13)
    static let note = Font.system(size: 11)
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
