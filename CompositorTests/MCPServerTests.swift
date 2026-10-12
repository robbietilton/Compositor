import Foundation
import CoreGraphics
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
        #expect(tools.count == 18)
        #expect(tools.contains { $0["name"] as? String == "compositor_add_vector_path" })
        #expect(tools.contains { $0["name"] as? String == "compositor_paint_stroke" })
        #expect(tools.contains { $0["name"] as? String == "compositor_add_text" })
        #expect(tools.contains { $0["name"] as? String == "compositor_manage_mask" })
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

    @Test func createsEditableShapeThroughTool() async throws {
        let workspace = ProjectWorkspace()
        let router = MCPToolRouter(workspace: workspace)
        _ = await router.call(name: "compositor_create_document", arguments: [
            "width": 200, "height": 120, "background": "#FFFFFF"
        ])

        let shape = await router.call(name: "compositor_add_shape", arguments: [
            "kind": "rectangle", "start_x": 10, "start_y": 10, "end_x": 70, "end_y": 60,
            "color": "#FF0000", "corner_radius": 8
        ])
        #expect(shape["isError"] as? Bool == false)
        let shapeLayer = try #require(workspace.current.session.activeLayer)
        #expect(shapeLayer.liveShape?.style.kind == .rectangle)
        #expect(shapeLayer.liveShape?.style.cornerRadius == 8)
    }

    @Test func createsEditableTextThroughTool() async throws {
        let workspace = ProjectWorkspace()
        let router = MCPToolRouter(workspace: workspace)
        _ = await router.call(name: "compositor_create_document", arguments: ["width": 200, "height": 120])
        let text = await router.call(name: "compositor_add_text", arguments: [
            "content": "Made through MCP", "x": 85, "y": 20, "font_size": 18,
            "color": "#003366", "alignment": "left"
        ])
        #expect(text["isError"] as? Bool == false)
        #expect(workspace.current.session.activeLayer?.liveText?.style.content == "Made through MCP")
    }

    @Test func selectsAndSamplesThroughTools() async throws {
        let workspace = ProjectWorkspace()
        let router = MCPToolRouter(workspace: workspace)
        _ = await router.call(name: "compositor_create_document", arguments: [
            "width": 200, "height": 120, "background": "#FF0000"
        ])
        let selection = await router.call(name: "compositor_set_selection", arguments: [
            "action": "rectangle", "x": 5, "y": 5, "width": 80, "height": 70, "feather": 2
        ])
        #expect(selection["isError"] as? Bool == false)
        #expect(workspace.current.session.selection?.path.boundingBoxOfPath == CGRect(x: 5, y: 5, width: 80, height: 70))
        #expect(workspace.current.session.selection?.feather == 2)

        let sampled = await router.call(name: "compositor_sample_color", arguments: ["x": 20, "y": 20])
        #expect(sampled["isError"] as? Bool == false)
        #expect((sampled["structuredContent"] as? [String: Any])?["hex"] as? String == "#FF0000")
    }

    @Test func paintsGradientsMasksCropsAndControlsTheViewThroughTools() async throws {
        let workspace = ProjectWorkspace()
        let router = MCPToolRouter(workspace: workspace)
        _ = await router.call(name: "compositor_create_document", arguments: [
            "width": 96, "height": 72, "background": "#FFFFFF"
        ])
        let layerID = try #require(workspace.current.session.activeLayerID)

        let painted = await router.call(name: "compositor_paint_stroke", arguments: [
            "mode": "paint", "layer_id": layerID.uuidString, "color": "#0066FF",
            "size": 12, "hardness": 1, "points": [["x": 10, "y": 12], ["x": 70, "y": 12]]
        ])
        #expect(painted["isError"] as? Bool == false)

        let masked = await router.call(name: "compositor_manage_layer", arguments: [
            "action": "add_mask", "layer_id": layerID.uuidString, "reveal": true
        ])
        #expect(masked["isError"] as? Bool == false)
        let maskPaint = await router.call(name: "compositor_paint_stroke", arguments: [
            "mode": "paint", "layer_id": layerID.uuidString, "target": "mask", "color": "#000000",
            "size": 10, "points": [["x": 30, "y": 30]]
        ])
        #expect(maskPaint["isError"] as? Bool == false)

        let gradient = await router.call(name: "compositor_apply_gradient", arguments: [
            "layer_id": layerID.uuidString, "target": "layer",
            "start_x": 0, "start_y": 50, "end_x": 90, "end_y": 50,
            "style": "color_to_color", "foreground": "#000000", "background": "#FFFFFF"
        ])
        #expect(gradient["isError"] as? Bool == false)

        let view = await router.call(name: "compositor_set_view", arguments: ["action": "zoom", "zoom": 2])
        #expect(view["isError"] as? Bool == false)
        #expect(workspace.current.session.viewport.zoom == 2)

        let cropped = await router.call(name: "compositor_crop", arguments: [
            "x": 8, "y": 6, "width": 64, "height": 48
        ])
        #expect(cropped["isError"] as? Bool == false)
        #expect(workspace.current.session.document?.size == CGSize(width: 64, height: 48))
    }

    @Test func managesRasterAndLiveMasksThroughTool() async throws {
        let workspace = ProjectWorkspace()
        let router = MCPToolRouter(workspace: workspace)
        _ = await router.call(name: "compositor_create_document", arguments: [
            "width": 64, "height": 48, "background": "#FFFFFF"
        ])
        let sourceID = try #require(workspace.current.session.activeLayerID)
        _ = await router.call(name: "compositor_set_selection", arguments: [
            "action": "rectangle", "x": 8, "y": 6, "width": 32, "height": 24
        ])

        let added = await router.call(name: "compositor_manage_mask", arguments: [
            "action": "add", "layer_id": sourceID.uuidString, "reveal": true
        ])
        #expect(added["isError"] as? Bool == false)
        #expect(workspace.current.session.activeLayer?.mask?.asset.image.width == 64)
        #expect(workspace.current.session.selection == nil)

        _ = await router.call(name: "compositor_manage_mask", arguments: [
            "action": "disable", "layer_id": sourceID.uuidString
        ])
        #expect(workspace.current.session.activeLayer?.mask?.isEnabled == false)
        _ = await router.call(name: "compositor_manage_mask", arguments: [
            "action": "enable", "layer_id": sourceID.uuidString
        ])
        _ = await router.call(name: "compositor_manage_mask", arguments: [
            "action": "unlink", "layer_id": sourceID.uuidString
        ])
        #expect(workspace.current.session.activeLayer?.mask?.isLinked == false)
        _ = await router.call(name: "compositor_manage_mask", arguments: [
            "action": "link", "layer_id": sourceID.uuidString
        ])

        let inverted = await router.call(name: "compositor_manage_mask", arguments: [
            "action": "invert", "layer_id": sourceID.uuidString
        ])
        #expect(inverted["isError"] as? Bool == false)
        let loaded = await router.call(name: "compositor_manage_mask", arguments: [
            "action": "load_selection", "layer_id": sourceID.uuidString, "mode": "replace"
        ])
        #expect(loaded["isError"] as? Bool == false)
        #expect(workspace.current.session.selection != nil)

        _ = await router.call(name: "compositor_manage_layer", arguments: [
            "action": "add_blank", "name": "Mask target"
        ])
        let targetID = try #require(workspace.current.session.activeLayerID)
        let copied = await router.call(name: "compositor_manage_mask", arguments: [
            "action": "copy", "layer_id": targetID.uuidString, "source_layer_id": sourceID.uuidString
        ])
        #expect(copied["isError"] as? Bool == false)
        #expect(workspace.current.session.activeLayer?.mask != nil)

        let live = await router.call(name: "compositor_manage_mask", arguments: [
            "action": "set_live_source", "layer_id": targetID.uuidString, "source_layer_id": sourceID.uuidString
        ])
        #expect(live["isError"] as? Bool == false)
        #expect(workspace.current.session.activeLayer?.maskSourceID == sourceID)
        _ = await router.call(name: "compositor_manage_mask", arguments: [
            "action": "remove_live_source", "layer_id": targetID.uuidString
        ])
        #expect(workspace.current.session.activeLayer?.maskSourceID == nil)

        let removed = await router.call(name: "compositor_manage_mask", arguments: [
            "action": "remove", "layer_id": targetID.uuidString
        ])
        #expect(removed["isError"] as? Bool == false)
        #expect(workspace.current.session.activeLayer?.mask == nil)
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
