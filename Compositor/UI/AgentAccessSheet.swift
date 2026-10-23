import SwiftUI

/// Compositor › Agent Access…: turns the MCP server on or off (see AgentServer), shows how to connect an agent to it,
/// and which folders agents may open and save in.
struct AgentAccessSheet: View {
    @Bindable var server = AgentServer.shared
    let close: () -> Void
    @State private var folders = AgentFolders.urls
    @State private var portText = String(AgentServer.shared.port)
    @State private var copied: String?
    /// What adding Compositor to Claude Desktop came to, to show under its buttons.
    @State private var desktopResult: (ok: Bool, message: String)?

    var body: some View { sheet.roundedControls() }

    @ViewBuilder private var sheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Agent Access").font(.title2.bold())
            Text("AI agents such as Claude Code can open, edit and make images in Compositor through MCP, while you watch. Only apps on this Mac that have the token below can connect.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Let AI agents use Compositor", isOn: $server.isEnabled)
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(status).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Port")
                    TextField("", text: $portText)
                        .frame(width: 70)
                        .onSubmit(applyPort)
                    Button("Apply", action: applyPort).disabled(UInt16(portText) == server.port)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Connect").font(.headline)
                Text("In a terminal, this adds Compositor to Claude Code:").foregroundStyle(.secondary)
                Text(server.claudeCommand)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.25)))
                HStack {
                    Button(copied == "command" ? "Copied" : "Copy Command") { copy(server.claudeCommand, as: "command") }
                    Button(copied == "json" ? "Copied" : "Copy JSON for Other Apps") { copy(configJSON, as: "json") }
                    Spacer()
                    Button("Make New Token") { server.makeNewToken() }
                        .help("Agents set up with the old token stop working until they're given the new one.")
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Claude Desktop").font(.headline)
                Text("Claude Desktop’s chat starts Compositor as a helper to reach it. Quit Claude Desktop first (it rewrites its settings while open), add Compositor to its settings file (claude_desktop_config.json), then open Claude Desktop again. Agent Access must be on for it to connect.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Add to Claude Desktop…", action: addToClaudeDesktop)
                    Button(copied == "desktop" ? "Copied" : "Copy JSON") {
                        copy(ClaudeDesktopConfig.snippet(executable: executable), as: "desktop")
                    }
                }
                if let desktopResult {
                    Label(desktopResult.message, systemImage: desktopResult.ok ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(desktopResult.ok ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Folders").font(.headline)
                Text("Agents can open, import and save files only inside these folders. Without one, they can still make images and get them back directly.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(folders, id: \.self) { folder in
                    HStack {
                        Image(systemName: "folder")
                        Text(folder.path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove") {
                            AgentFolders.remove(folder)
                            folders = AgentFolders.urls
                        }
                    }
                }
                Button("Add Folder…", action: addFolder)
            }

            Divider()

            HStack {
                Spacer()
                Button("Done", action: close)
                    .configuredNativeShortcut(.return)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var status: String {
        switch server.state {
        case .stopped: "Off"
        case .starting: "Starting…"
        case .running: "On at \(server.endpoint)"
        case .failed(let message): message
        }
    }
    private var statusColor: Color {
        switch server.state {
        case .running: .green
        case .failed: .red
        default: .secondary
        }
    }

    /// The setup most other MCP apps (Cursor, Claude Desktop with a bridge, VS Code…) read.
    private var configJSON: String {
        """
        {
          "mcpServers": {
            "compositor": {
              "type": "http",
              "url": "\(server.endpoint)",
              "headers": { "Authorization": "Bearer \(server.token)" }
            }
          }
        }
        """
    }

    private func copy(_ text: String, as name: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = name
    }

    private func applyPort() {
        guard let port = UInt16(portText), port >= 1024 else { portText = String(server.port); return }
        server.port = port
    }

    /// What Claude Desktop starts: this copy of the app.
    private var executable: String { Bundle.main.executablePath ?? "/Applications/Compositor.app/Contents/MacOS/Compositor" }

    /// The sandbox lets the app into Claude Desktop's folder only once the person picks it, so the panel opens there
    /// and asks; the server's entry then goes into the settings file inside, its other servers kept.
    private func addToClaudeDesktop() {
        guard !ClaudeDesktopConfig.claudeIsRunning else {
            desktopResult = (false, "Quit Claude Desktop first (⌘Q): while it’s open, it writes its own settings back over the file and the change is lost.")
            return
        }
        // Claude Desktop starts the app from where it is now, so it must stay there.
        guard !executable.hasPrefix("/Volumes/") else {
            desktopResult = (false, "Compositor is running from its disk image. Drag it to Applications, open it from there, and add it again.")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = ClaudeDesktopConfig.folder
        panel.prompt = "Add Compositor"
        panel.message = "Choose Claude Desktop’s settings folder (Library › Application Support › Claude) to add Compositor to it."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(ClaudeDesktopConfig.fileName).path)
                || folder.lastPathComponent == "Claude" else {
            desktopResult = (false, "That isn’t Claude Desktop’s folder. It’s Library › Application Support › Claude in your home folder; if it isn’t there, open Claude Desktop once first.")
            return
        }
        do {
            try ClaudeDesktopConfig.install(in: folder, executable: executable)
            desktopResult = (true, "Added. Open Claude Desktop to use it, with Agent Access on. The file as it was is kept beside it as \(ClaudeDesktopConfig.fileName).bak.")
        } catch {
            desktopResult = (false, error.localizedDescription)
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Allow"
        panel.message = "Choose a folder AI agents may open and save files in."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AgentFolders.add(url)
        folders = AgentFolders.urls
    }
}

/// Shows Agent Access as a sheet on the editor window.
enum AgentAccessWindow {
    static func show(over window: NSWindow?) {
        guard let window, window.attachedSheet == nil else { return }
        let sheet = NSWindow()
        sheet.styleMask = [.titled, .fullSizeContentView]
        sheet.title = "Agent Access"
        sheet.contentViewController = NSHostingController(rootView: AgentAccessSheet {
            window.endSheet(sheet)
            sheet.orderOut(nil)
            sheet.contentViewController = nil
        })
        window.beginSheet(sheet)
    }
}
