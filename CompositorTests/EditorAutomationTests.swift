import Foundation
import Testing
@testable import Compositor

/// MCP requests reach the app as file-opens: a request folder in the per-user mailbox, then any file it brings, which
/// macOS may deliver as an open of its own, before or after the request is read.
@MainActor
struct EditorAutomationTests {
    private var mailbox: URL { URL(fileURLWithPath: "/private/tmp/compositor-mcp-\(getuid())", isDirectory: true) }

    @Test func onlyAUUIDFolderInTheMailboxIsARequest() {
        let id = UUID().uuidString.lowercased()
        #expect(EditorAutomation.isRequest(mailbox.appendingPathComponent(id + ".comp")))
        #expect(!EditorAutomation.isRequest(mailbox.appendingPathComponent("Holiday.comp")), "a project, not a request")
        #expect(!EditorAutomation.isRequest(URL(fileURLWithPath: "/private/tmp").appendingPathComponent(id + ".comp")),
                "outside the mailbox")
        #expect(!EditorAutomation.isRequest(mailbox.appendingPathComponent(id + ".png")))
    }

    /// A file opened with no request about is the person's own, and opens as usual; one that comes while a request is
    /// in flight is kept for it, and if no request takes it, it's opened as usual after all.
    @Test func aFileIsKeptOnlyWhileARequestIsInFlight() async {
        let automation = EditorAutomation()
        let image = URL(fileURLWithPath: "/private/tmp/compositor-test-\(UUID().uuidString).png")
        var opened: [URL] = []
        #expect(!automation.claim(image) { opened += $0 }, "no request: the app opens it")
        automation.expect(1)
        #expect(automation.claim(image) { opened += $0 }, "a request in flight: kept for it")
        #expect(opened.isEmpty)
    }
}
