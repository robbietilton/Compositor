import Foundation
import Testing
@testable import Compositor

@MainActor
struct MCPServerTests {
    @Test func parsesOneStreamableHTTPRequest() throws {
        let body = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}".utf8)
        let bytes = Data(("POST /mcp HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n").utf8) + body
        let parsed = try MCPHTTPServer.parse(bytes)
        let request = try #require(parsed)
        #expect(request.method == "POST")
        #expect(request.path == "/mcp")
        #expect(request.headers["content-type"] == "application/json")
        #expect(request.body == body)
    }

    @Test func requiresAuthenticationAndCompletesTheMCPLifecycle() async throws {
        let handler = MCPProtocolHandler(workspace: ProjectWorkspace(), token: "test-token")
        let initialize = try request(method: "initialize", id: 1, params: [
            "protocolVersion": MCPProtocolHandler.currentProtocolVersion,
            "capabilities": [:],
            "clientInfo": ["name": "Tests", "version": "1"]
        ])
        #expect(await handler.handle(initialize).status == 401)

        var authenticated = initialize
        authenticated = MCPHTTPRequest(method: authenticated.method, path: authenticated.path,
            headers: authenticated.headers.merging(["authorization": "Bearer test-token"]) { _, new in new }, body: authenticated.body)
        let initializedResponse = await handler.handle(authenticated)
        #expect(initializedResponse.status == 200)
        let sessionID = try #require(initializedResponse.headers["MCP-Session-Id"])
        let initialized = try request(method: "notifications/initialized", headers: sessionHeaders(sessionID))
        #expect(await handler.handle(initialized).status == 202)

        let list = try request(method: "tools/list", id: 2, params: [:], headers: sessionHeaders(sessionID))
        let listResponse = await handler.handle(list)
        #expect(listResponse.status == 200)
        let object = try #require(try JSONSerialization.jsonObject(with: listResponse.body) as? [String: Any])
        let result = try #require(object["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        #expect(tools.count == 8)
        #expect(tools.contains { $0["name"] as? String == "compositor_add_vector_path" })
    }

    @Test func createsAndEditsALiveVectorPathThroughTools() async throws {
        let workspace = ProjectWorkspace()
        let router = MCPToolRouter(workspace: workspace)
        let created = await router.call(name: "compositor_create_document", arguments: ["width": 320, "height": 240])
        #expect(created["isError"] as? Bool == false)
        #expect(workspace.current.session.document?.size == CGSize(width: 320, height: 240))

        let added = await router.call(name: "compositor_add_vector_path", arguments: [
            "mode": "line", "color": "#3366FF", "line_width": 8,
            "nodes": [
                ["x": 20, "y": 30, "out_x": 70, "out_y": 10],
                ["x": 280, "y": 190, "in_x": 230, "in_y": 220]
            ]
        ])
        #expect(added["isError"] as? Bool == false)
        let layer = try #require(workspace.current.session.activeLayer)
        #expect(layer.liveVectorPath?.style.mode == .line)
        #expect(layer.liveVectorPath?.style.lineWidth == 8)

        let updated = await router.call(name: "compositor_update_layer", arguments: [
            "layer_id": layer.id.uuidString, "name": "AI curve", "opacity": 0.5, "rotation": 15
        ])
        #expect(updated["isError"] as? Bool == false)
        #expect(workspace.current.session.activeLayer?.name == "AI curve")
        #expect(workspace.current.session.activeLayer?.opacity == 0.5)
        #expect(workspace.current.session.activeLayer?.transform.rotation == 15)

        let undone = await router.call(name: "compositor_history", arguments: ["action": "undo"])
        #expect(undone["isError"] as? Bool == false)
        #expect(workspace.current.session.activeLayer?.name != "AI curve")
    }

    private func sessionHeaders(_ sessionID: String) -> [String: String] {
        [
            "authorization": "Bearer test-token",
            "content-type": "application/json",
            "mcp-session-id": sessionID,
            "mcp-protocol-version": MCPProtocolHandler.currentProtocolVersion
        ]
    }

    private func request(method: String, id: Int? = nil, params: [String: Any]? = nil,
                         headers: [String: String] = ["content-type": "application/json"]) throws -> MCPHTTPRequest {
        var object: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let id { object["id"] = id }
        if let params { object["params"] = params }
        return MCPHTTPRequest(method: "POST", path: "/mcp", headers: headers,
                              body: try JSONSerialization.data(withJSONObject: object))
    }
}
