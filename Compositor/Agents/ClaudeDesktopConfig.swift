import AppKit

/// Claude Desktop's own chat starts the MCP servers it uses as commands talking over stdin and stdout, so it starts
/// Compositor itself as one, with `--mcp-stdio` (see MCPStdioBridge). This is that entry in its
/// `claude_desktop_config.json`, and the file with the entry put in, everything else in it kept.
enum ClaudeDesktopConfig {
    static let serverName = "compositor"
    static let fileName = "claude_desktop_config.json"
    /// Where Claude Desktop keeps it.
    static var folder: URL {
        URL(fileURLWithPath: AgentFolders.home).appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
    }

    static let bundleIdentifier = "com.anthropic.claudefordesktop"
    /// Claude Desktop keeps its settings in memory and writes them back over the file, so a change made while it runs is lost.
    static var claudeIsRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty }

    /// No port or token: the bridge reads them from Compositor's own settings, so they stay current and private.
    static func entry(executable: String) -> [String: Any] {
        ["command": executable, "args": [MCPStdioBridge.argument]]
    }

    /// The whole file, for pasting into one that has no other servers.
    static func snippet(executable: String) -> String {
        let data = (try? merged(nil, executable: executable)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// `existing` (the file's bytes, or nil when there's no file yet) with Compositor's entry added or replaced. Its
    /// other servers and settings stay as they were; a file that isn't a JSON object is refused rather than overwritten.
    static func merged(_ existing: Data?, executable: String) throws -> Data {
        var config: [String: Any] = [:]
        if let existing, !existing.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            guard let object = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey:
                    "Claude Desktop’s \(fileName) isn’t valid JSON, so it was left alone. Fix it, or add the entry by hand with Copy JSON."])
            }
            config = object
        }
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = entry(executable: executable)
        config["mcpServers"] = servers
        return try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Writes the entry into the config file in `folder` (Claude Desktop's, as the person granted it), keeping the file
    /// as it was beside it, in a `.bak`, before replacing it.
    static func install(in folder: URL, executable: String) throws {
        let file = folder.appendingPathComponent(fileName)
        let existing = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
        let updated = try merged(existing, executable: executable)
        if let existing { try existing.write(to: folder.appendingPathComponent(fileName + ".bak"), options: .atomic) }
        try updated.write(to: file, options: .atomic)
    }
}
