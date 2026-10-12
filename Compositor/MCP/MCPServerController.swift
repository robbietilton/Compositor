import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class MCPServerController {
    static let port: UInt16 = 49_678
    private static let enabledKey = "mcp.server.enabled"
    private static let tokenKey = "mcp.server.token"

    private let workspace: ProjectWorkspace
    private var server: MCPHTTPServer?
    private var protocolHandler: MCPProtocolHandler?
    private var serverGeneration = UUID()
    @ObservationIgnored private var window: NSWindow?
    private(set) var isEnabled: Bool
    private(set) var state: MCPHTTPServer.State = .stopped
    private(set) var token: String

    var endpoint: String { "http://127.0.0.1:\(Self.port)/mcp" }
    var statusText: String {
        switch state {
        case .stopped: L10n.string("Stopped")
        case .starting: L10n.string("Starting…")
        case .running: L10n.string("Running on this Mac")
        case .failed(let message): L10n.string("Couldn’t start") + ": \(message)"
        }
    }

    init(workspace: ProjectWorkspace) {
        self.workspace = workspace
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        if let existing = UserDefaults.standard.string(forKey: Self.tokenKey), !existing.isEmpty {
            token = existing
        } else {
            let generated = Self.makeToken()
            token = generated
            UserDefaults.standard.set(generated, forKey: Self.tokenKey)
        }
    }

    func startIfEnabled() {
        if isEnabled { start() }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled { start() } else { stop() }
    }

    func restart() {
        stop()
        guard isEnabled else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, self.isEnabled, self.server == nil else { return }
            self.start()
        }
    }

    private func start() {
        guard server == nil else { return }
        let generation = UUID()
        serverGeneration = generation
        let protocolHandler = MCPProtocolHandler(workspace: workspace, token: token)
        let server = MCPHTTPServer(port: Self.port, handler: { request in
            await protocolHandler.handle(request)
        }, stateChanged: { [weak self] state in
            guard let self, self.serverGeneration == generation else { return }
            self.state = state
        })
        self.protocolHandler = protocolHandler
        self.server = server
        do { try server.start() }
        catch {
            state = .failed(error.localizedDescription)
            self.server = nil
            self.protocolHandler = nil
        }
    }

    private func stop() {
        serverGeneration = UUID()
        server?.stop()
        server = nil
        protocolHandler = nil
        state = .stopped
    }

    func copyEndpoint() { copy(endpoint) }
    func copyToken() { copy(token) }
    func regenerateToken() {
        token = Self.makeToken()
        UserDefaults.standard.set(token, forKey: Self.tokenKey)
        restart()
    }
    func copyConnectionJSON() {
        let object: [String: Any] = [
            "url": endpoint,
            "headers": ["Authorization": "Bearer \(token)"]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        copy(String(decoding: data, as: UTF8.self))
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private static func makeToken() -> String {
        (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
    }

    func showSettings() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 390),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = L10n.string("MCP Server")
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: MCPServerSettingsView(controller: self)
                .environment(\.locale, AppLanguage.current.locale))
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func closeSettings() { window?.close() }
}

private struct MCPServerSettingsView: View {
    @Bindable var controller: MCPServerController

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("MCP Server")).font(.title2.weight(.semibold))
                    Text(L10n.string("Let AI clients work with the canvas open in Compositor."))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(L10n.string("Enabled"), isOn: Binding(get: { controller.isEnabled }, set: controller.setEnabled))
                    .toggleStyle(.switch)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent(L10n.string("Status")) { Text(controller.statusText) }
                    LabeledContent(L10n.string("Endpoint")) {
                        HStack {
                            Text(controller.endpoint).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            Button(L10n.string("Copy")) { controller.copyEndpoint() }
                        }
                    }
                    LabeledContent(L10n.string("Access token")) {
                        HStack {
                            Text(controller.token).lineLimit(1).truncationMode(.middle)
                                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            Button(L10n.string("Copy")) { controller.copyToken() }
                            Button(L10n.string("Regenerate")) { controller.regenerateToken() }
                        }
                    }
                }
                .padding(6)
            }

            Text(L10n.string("Connections are accepted only from this Mac. Clients must send the access token as a Bearer authorization header."))
                .font(.callout).foregroundStyle(.secondary)

            HStack {
                Button(L10n.string("Copy Connection JSON")) { controller.copyConnectionJSON() }
                if controller.isEnabled { Button(L10n.string("Restart")) { controller.restart() } }
                Spacer()
                Button(L10n.string("Done")) { controller.closeSettings() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
