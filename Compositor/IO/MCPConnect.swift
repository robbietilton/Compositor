import AppKit

/// Settings' Connect buttons for AI apps (see docs/mcp.md). Compositor is sandboxed; its entitlements open exactly
/// what these need and no more:
/// - ChatGPT: Compositor adds itself to ChatGPT's settings (~/.codex/config.toml, read and write) and takes itself out.
/// - Claude: Compositor makes a Claude extension and opens it in Claude, which asks to install it; Claude's extensions
///   folder and settings file (read only) say whether it's there.
/// Claude Code is set up with a line pasted into Terminal (Settings' Copy Setup), which the sandbox can't run.
@MainActor @Observable
final class MCPConnect {
    static let shared = MCPConnect()

    static let chatGPTBundleIDs = ["com.openai.chat", "com.openai.codex"]
    static let claudeBundleID = "com.anthropic.claudefordesktop"
    static let header = "[mcp_servers.compositor]"

    private(set) var chatGPTConnected = false
    /// When Connect added Compositor to ChatGPT's settings, this session: a ChatGPT already running then reads them
    /// only once it's started again.
    private var chatGPTConnectedAt: Date?
    var chatGPTNeedsRestart: Bool {
        guard chatGPTConnected, let at = chatGPTConnectedAt else { return false }
        return NSWorkspace.shared.runningApplications.contains {
            Self.chatGPTBundleIDs.contains($0.bundleIdentifier ?? "") && ($0.launchDate ?? .distantFuture) < at
        }
    }
    /// Compositor's extension is in Claude and hasn't been disconnected here.
    var claudeConnected: Bool { claudeInstalled && !claudeDisconnected }
    private(set) var claudeInstalled = false
    /// Disconnect in Settings: Compositor turns Claude's requests away. Claude's extensions are Claude's to remove, so
    /// the extension stays there, and Connect just lets it back in.
    private(set) var claudeDisconnected = UserDefaults.standard.bool(forKey: claudeDisconnectedKey)
    private static let claudeDisconnectedKey = "mcpClaudeDisconnected"
    /// Waiting for the person to click Install in Claude.
    private(set) var claudeWaiting = false
    var problem: String?
    private var watch: Timer?

    /// The companion inside this app that AI apps start.
    static var helper: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/compositor-mcp").path }

    /// The person's own home folder: in the sandbox, NSHomeDirectory is the app's container.
    static var home: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { return URL(fileURLWithPath: String(cString: dir)) }
        return URL(fileURLWithPath: NSHomeDirectory())
    }

    static func installed(_ bundleIDs: [String]) -> URL? {
        bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    static var chatGPTFolder: URL { home.appendingPathComponent(".codex", isDirectory: true) }
    static var claudeFolder: URL { home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true) }

    func refresh() {
        let text = (try? String(contentsOf: Self.chatGPTFolder.appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
        chatGPTConnected = Self.containsCompositor(text)
        claudeInstalled = Self.claudeHasCompositor(in: Self.claudeFolder)
        if claudeInstalled { claudeWaiting = false }
    }

    // MARK: ChatGPT

    func connectChatGPT() {
        problem = nil
        guard FileManager.default.fileExists(atPath: Self.chatGPTFolder.path) else {
            problem = "Open ChatGPT once first, so it makes its settings, then connect."
            return
        }
        do {
            try Self.addCompositor(in: Self.chatGPTFolder)
            chatGPTConnectedAt = Date()
        } catch { problem = "Couldn't add Compositor to ChatGPT's settings." }
        refresh()
    }

    func disconnectChatGPT() {
        problem = nil
        chatGPTConnectedAt = nil
        do { try Self.removeCompositor(in: Self.chatGPTFolder) } catch { problem = "Couldn't take Compositor out of ChatGPT's settings." }
        refresh()
    }

    /// Adds Compositor's section to config.toml in `folder`, replacing an old one; keeps a copy of the settings as they
    /// were the first time.
    static func addCompositor(in folder: URL) throws {
        let config = folder.appendingPathComponent("config.toml")
        let existing = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
        let backup = folder.appendingPathComponent("config.toml.before-compositor")
        if !existing.isEmpty, !FileManager.default.fileExists(atPath: backup.path) {
            try existing.write(to: backup, atomically: true, encoding: .utf8)
        }
        try adding(helper, to: existing).write(to: config, atomically: true, encoding: .utf8)
    }

    static func removeCompositor(in folder: URL) throws {
        let config = folder.appendingPathComponent("config.toml")
        guard let existing = try? String(contentsOf: config, encoding: .utf8) else { return }
        try (removing(from: existing) + "\n").write(to: config, atomically: true, encoding: .utf8)
    }

    static func containsCompositor(_ text: String) -> Bool {
        text.components(separatedBy: .newlines).contains { $0.trimmingCharacters(in: .whitespaces) == header }
    }

    /// `text` with Compositor's section (and any `[mcp_servers.compositor.*]` under it) taken out; every other line
    /// left exactly as it was.
    static func removing(from text: String) -> String {
        var kept: [String] = []
        var skipping = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { skipping = trimmed == header || trimmed.hasPrefix("[mcp_servers.compositor.") }
            if !skipping { kept.append(line) }
        }
        while let last = kept.last, last.trimmingCharacters(in: .whitespaces).isEmpty { kept.removeLast() }
        return kept.joined(separator: "\n")
    }

    /// `text` with Compositor's section, starting `helper`, at its end (replacing any there was).
    static func adding(_ helper: String, to text: String) -> String {
        var result = removing(from: text)
        if !result.isEmpty { result += "\n\n" }
        let quoted = "\"" + helper.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        return result + "\(header)\ncommand = \(quoted)\nstartup_timeout_sec = 30\ntool_timeout_sec = 300\n"
    }

    // MARK: Claude

    func connectClaude() {
        problem = nil
        setClaudeDisconnected(false)
        // Still installed in Claude: letting it back in is all Connect has to do.
        refresh()
        if claudeInstalled { return }
        guard let claude = Self.installed([Self.claudeBundleID]) else { problem = "Claude isn't on this Mac."; return }
        do {
            let file = try Self.makeClaudeExtension()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([file], withApplicationAt: claude, configuration: configuration)
            claudeWaiting = true
            watchForClaude()
        } catch {
            problem = "Couldn't make the Claude extension."
        }
    }

    func disconnectClaude() {
        problem = nil
        setClaudeDisconnected(true)
    }

    private func setClaudeDisconnected(_ value: Bool) {
        claudeDisconnected = value
        UserDefaults.standard.set(value, forKey: Self.claudeDisconnectedKey)
    }

    /// Whether an AI app's name for itself is Claude's (the Claude app, not Claude Code).
    nonisolated static func isClaude(_ client: String?) -> Bool {
        guard let name = client?.lowercased() else { return false }
        return name.contains("claude") && !name.contains("code")
    }

    /// Notices the person clicking Install in Claude, for five minutes.
    private func watchForClaude() {
        watch?.invalidate()
        let started = Date()
        watch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                self.refresh()
                if self.claudeInstalled || Date().timeIntervalSince(started) > 300 {
                    timer.invalidate()
                    self.claudeWaiting = false
                }
            }
        }
    }

    /// Compositor's extension among Claude's, or Compositor in Claude's settings file (set up by hand).
    static func claudeHasCompositor(in folder: URL) -> Bool {
        let fm = FileManager.default
        let extensions = folder.appendingPathComponent("Claude Extensions", isDirectory: true)
        for item in (try? fm.contentsOfDirectory(at: extensions, includingPropertiesForKeys: nil)) ?? [] {
            if let data = try? Data(contentsOf: item.appendingPathComponent("manifest.json")),
               let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               manifest["name"] as? String == "compositor" { return true }
        }
        if let data = try? Data(contentsOf: folder.appendingPathComponent("claude_desktop_config.json")),
           let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (config["mcpServers"] as? [String: Any])?["compositor"] != nil { return true }
        return false
    }

    /// A Claude extension (.mcpb, a zip): a manifest and a small script that starts the companion in this app, or
    /// in Compositor wherever it has since moved.
    static func makeClaudeExtension() throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("claude-extension-\(UUID().uuidString)", isDirectory: true)
        let stage = work.appendingPathComponent("stage", isDirectory: true)
        try fm.createDirectory(at: stage.appendingPathComponent("server"), withIntermediateDirectories: true)
        let script = stage.appendingPathComponent("server/compositor-mcp")
        try launcher(helper).write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var manifest: [String: Any] = [
            "manifest_version": "0.3",
            "name": "compositor",
            "display_name": "Compositor",
            "version": semver(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"),
            "description": "Edit images in Compositor: layers, text, shapes, painting, adjustments, masks and export.",
            "author": ["name": "Compositor"],
            "server": ["type": "binary", "entry_point": "server/compositor-mcp",
                       "mcp_config": ["command": "/bin/sh", "args": ["${__dirname}/server/compositor-mcp"]]],
            "compatibility": ["platforms": ["darwin"]],
        ]
        if let tiff = NSApp?.applicationIconImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: stage.appendingPathComponent("icon.png"))
            manifest["icon"] = "icon.png"
        }
        let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try json.write(to: stage.appendingPathComponent("manifest.json"))
        let file = work.appendingPathComponent("Compositor.mcpb")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = stage
        zip.arguments = ["-qrX", file.path, "."]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        return file
    }

    /// The extension's start script: the companion at `helper`, or in Compositor wherever macOS finds it now.
    static func launcher(_ helper: String) -> String {
        let quoted = "'" + helper.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
        #!/bin/sh
        # Starts the companion of the Compositor that's running, else the one in Applications, else the one this was
        # made with, else any Compositor this Mac has: an old copy left elsewhere mustn't win over the one in use.
        helper() { echo "$1/Contents/MacOS/compositor-mcp"; }
        running=$(/bin/ps -axo comm= | /usr/bin/grep '/Contents/MacOS/Compositor$' | /usr/bin/head -n 1)
        app=
        [ -n "$running" ] && app=$(helper "${running%/Contents/MacOS/Compositor}")
        [ -x "$app" ] || app=$(helper /Applications/Compositor.app)
        [ -x "$app" ] || app=\(quoted)
        if [ ! -x "$app" ]; then
          found=$(/usr/bin/mdfind 'kMDItemCFBundleIdentifier == "com.wonderassembly.compositor"' | /usr/bin/head -n 1)
          [ -n "$found" ] && app=$(helper "$found")
        fi
        exec "$app"

        """
    }

    private static func semver(_ version: String) -> String {
        var parts = version.split(separator: ".").map(String.init).filter { Int($0) != nil }
        while parts.count < 3 { parts.append("0") }
        return parts.prefix(3).joined(separator: ".")
    }
}
