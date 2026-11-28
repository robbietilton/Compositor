import Foundation
import Testing
@testable import Compositor

/// Settings' Connect buttons: ChatGPT's settings gain and lose Compositor's section with everything else left exactly
/// as it was; Claude's extension is a working package.
@MainActor
struct MCPConnectTests {
    private let theirs = """
    model = "gpt-6"

    [mcp_servers.other]
    command = "/usr/local/bin/other"

    [profiles.work]
    model = "gpt-6-mini"
    """

    @Test func connectingAddsOnlyCompositorsSectionAndDisconnectingTakesItBackOut() {
        let helper = "/Applications/Compositor.app/Contents/MacOS/compositor-mcp"
        let connected = MCPConnect.adding(helper, to: theirs)
        #expect(connected.hasPrefix(theirs), "their settings are untouched")
        #expect(connected.contains("[mcp_servers.compositor]\ncommand = \"\(helper)\""))
        #expect(MCPConnect.containsCompositor(connected) && !MCPConnect.containsCompositor(theirs))
        // Connecting again replaces the section rather than adding a second.
        let again = MCPConnect.adding("/Other/Compositor.app/Contents/MacOS/compositor-mcp", to: connected)
        #expect(again.components(separatedBy: "[mcp_servers.compositor]").count == 2)
        #expect(!again.contains(helper))
        #expect(MCPConnect.removing(from: again) == theirs, "disconnecting leaves exactly what was there")
        #expect(MCPConnect.adding(helper, to: "").hasPrefix("[mcp_servers.compositor]"), "a new settings file")
    }

    /// A section of Compositor's own, with settings under it, goes when it's removed; another server's doesn't.
    @Test func removingLeavesOtherServersAlone() {
        let text = theirs + "\n\n[mcp_servers.compositor]\ncommand = \"x\"\n\n[mcp_servers.compositor.env]\nA = \"1\"\n\n[mcp_servers.compositorx]\ncommand = \"y\""
        let removed = MCPConnect.removing(from: text)
        #expect(!removed.contains("[mcp_servers.compositor]") && !removed.contains("[mcp_servers.compositor.env]"))
        #expect(removed.contains("[mcp_servers.compositorx]") && removed.contains("[mcp_servers.other]"))
    }

    @Test func connectingWritesTheSettingsAndKeepsABackup() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let config = folder.appendingPathComponent("config.toml")
        try theirs.write(to: config, atomically: true, encoding: .utf8)
        try MCPConnect.addCompositor(in: folder)
        #expect(MCPConnect.containsCompositor(try String(contentsOf: config, encoding: .utf8)))
        #expect(try String(contentsOf: folder.appendingPathComponent("config.toml.before-compositor"), encoding: .utf8) == theirs)
        try MCPConnect.removeCompositor(in: folder)
        #expect(try String(contentsOf: config, encoding: .utf8) == theirs + "\n")
    }

    /// The extension unpacks to a manifest naming its start script, and the script runs the companion it was made with.
    @Test func theClaudeExtensionIsAPackageClaudeCanInstall() throws {
        let file = try MCPConnect.makeClaudeExtension()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let unpacked = file.deletingLastPathComponent().appendingPathComponent("unpacked", isDirectory: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", file.path, "-d", unpacked.path]
        try unzip.run()
        unzip.waitUntilExit()
        #expect(unzip.terminationStatus == 0)
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: unpacked.appendingPathComponent("manifest.json"))) as? [String: Any])
        #expect(manifest["name"] as? String == "compositor")
        let server = try #require(manifest["server"] as? [String: Any])
        #expect(server["entry_point"] as? String == "server/compositor-mcp")
        let script = try String(contentsOf: unpacked.appendingPathComponent("server/compositor-mcp"), encoding: .utf8)
        #expect(script.contains(MCPConnect.helper) && script.contains("exec \"$app\""))
        let mode = try FileManager.default.attributesOfItem(atPath: unpacked.appendingPathComponent("server/compositor-mcp").path)[.posixPermissions] as? Int
        #expect((mode ?? 0) & 0o111 != 0, "executable")
    }

    /// The sandbox lets Compositor into ChatGPT's settings folder and Claude's extensions (a Mac without them just has
    /// no such folder).
    @Test func theSandboxReachesChatGPTAndClaudesSettings() {
        func refused(_ url: URL) -> Bool {
            do { _ = try FileManager.default.contentsOfDirectory(atPath: url.path); return false } catch {
                return (error as NSError).code != NSFileReadNoSuchFileError
            }
        }
        #expect(!refused(MCPConnect.chatGPTFolder), "ChatGPT's settings folder")
        #expect(!refused(MCPConnect.claudeFolder.appendingPathComponent("Claude Extensions")), "Claude's extensions")
    }

    /// Disconnecting Claude turns its requests away by the name it gives itself: the Claude app's, not Claude Code's
    /// or ChatGPT's.
    @Test func onlyTheClaudeAppIsTurnedAwayWhenDisconnected() {
        #expect(MCPConnect.isClaude("claude-ai") && MCPConnect.isClaude("Claude"))
        #expect(!MCPConnect.isClaude("claude-code") && !MCPConnect.isClaude("codex-mcp-client") && !MCPConnect.isClaude(nil))
    }
}
