import Testing
import Foundation
@testable import Compositor

@MainActor
struct MCPProtocolTests {
    private func router() -> MCPRouter { MCPRouter(workspace: ProjectWorkspace()) }

    @Test func initializeAndPing() async {
        let r = router()
        let initResponse = await r.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])!
        #expect((initResponse["jsonrpc"] as? String) == "2.0")
        #expect((initResponse["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18")
        let ping = await r.handle(["jsonrpc": "2.0", "id": "p", "method": "ping"])!
        #expect((ping["result"] as? [String: Any])?.isEmpty == true)
    }

    @Test func toolsHaveClosedSchemas() async {
        let r = router()
        let response = await r.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])!
        let result = response["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]]
        #expect((tools?.isEmpty == false))
        #expect(tools?.contains { ($0["name"] as? String) == "import_html" } == true)
        let names = (tools ?? []).compactMap { $0["name"] as? String }
        #expect(Set(names).count == names.count)
        for tool in tools ?? [] {
            #expect(tool["inputSchema"] is [String: Any])
            let schema = tool["inputSchema"] as? [String: Any]
            #expect(schema?["type"] as? String == "object")
            #expect(schema?["properties"] is [String: Any])
            #expect(schema?["additionalProperties"] as? Bool == false)
            let required = schema?["required"] as? [String] ?? []
            let properties = schema?["properties"] as? [String: Any] ?? [:]
            #expect(required.allSatisfy { properties[$0] != nil })
        }
    }

    @Test func invalidRequestsAndNotifications() async {
        let r = router()
        #expect(await r.handle(["jsonrpc": "1.0", "id": 1, "method": "ping"])?["error"] != nil)
        #expect(await r.handle(["jsonrpc": "2.0", "id": true, "method": "ping"])?["error"] != nil)
        #expect(await r.handle(["jsonrpc": "2.0", "id": 1, "method": "ping", "params": "bad"])?["error"] != nil)
        #expect(await r.handle(["jsonrpc": "2.0", "method": "ping"]) == nil)
        #expect((await r.handle(["jsonrpc": "2.0", "id": 1, "method": "nope"])?["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    @Test func resourcesAndToolArgumentValidation() async {
        let r = router()
        let missing = await r.handle(["jsonrpc": "2.0", "id": 1, "method": "resources/read", "params": ["uri": "compositor://documents/nope"]])!
        #expect((missing["error"] as? [String: Any])?["code"] as? Int == -32002)
        let unknown = await r.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "import_html", "arguments": ["html": "<p>x</p>", "width": 100, "height": 100, "extra": 1]]])!
        #expect((unknown["result"] as? [String: Any])?["isError"] as? Bool == true)
        let boolAsInt = await r.handle(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "import_html", "arguments": ["html": "x", "width": true, "height": 100]]])!
        #expect((boolAsInt["result"] as? [String: Any])?["isError"] as? Bool == true)
    }

    @Test func importHTMLSizeLimits() async {
        let r = router()
        let tooLarge = await r.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "import_html", "arguments": ["html": "x", "width": 8192, "height": 8192]]])!
        #expect((tooLarge["result"] as? [String: Any])?["isError"] as? Bool == true)
        let zero = await r.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "import_html", "arguments": ["html": "x", "width": 0, "height": 100]]])!
        #expect((zero["result"] as? [String: Any])?["isError"] as? Bool == true)
    }

    @Test func cancelledQueuedToolCallDoesNotMutate() async {
        let workspace = ProjectWorkspace()
        let r = MCPRouter(workspace: workspace)
        let originalTabs = workspace.tabs.map(\.id)
        let task = Task { @MainActor in
            await r.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": [
                "name": "import_html", "arguments": ["html": "<p>must not import</p>", "width": 100, "height": 100]
            ]])
        }
        task.cancel()
        let response = await task.value
        #expect((response?["result"] as? [String: Any])?["isError"] as? Bool == true)
        #expect(workspace.tabs.map(\.id) == originalTabs)
    }
}
