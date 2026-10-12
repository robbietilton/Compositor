import Foundation
import CoreGraphics
import Testing
@testable import Compositor

@MainActor
struct MCPServerTests {
    @Test func parsesOneStreamableHTTPRequest() throws {
        let body = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}".utf8)
        let bytes = Data(("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:49678\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n").utf8) + body
        let parsed = try MCPHTTPServer.parse(bytes)
        let request = try #require(parsed)
        #expect(request.method == "POST")
        #expect(request.path == "/mcp")
        #expect(request.headers["content-type"] == "application/json")
        #expect(request.body == body)
    }

    @Test func rejectsAmbiguousOrOversizedHTTPFraming() {
        let trailing = Data("POST /mcp HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}extra".utf8)
        #expect(throws: (any Error).self) { try MCPHTTPServer.parse(trailing) }

        let header = "X-Fill: " + String(repeating: "a", count: MCPHTTPServer.maximumHeaderBytes)
        let oversized = Data("POST /mcp HTTP/1.1\r\n\(header)\r\n\r\n".utf8)
        #expect(throws: (any Error).self) { try MCPHTTPServer.parse(oversized) }
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

    @Test func rejectsNonLoopbackHostsAndCapsSessions() async throws {
        let handler = MCPProtocolHandler(workspace: ProjectWorkspace(), token: "test-token")
        var hostile = try request(method: "initialize", id: 1, params: [
            "protocolVersion": MCPProtocolHandler.currentProtocolVersion
        ])
        hostile = MCPHTTPRequest(method: hostile.method, path: hostile.path,
            headers: hostile.headers.merging(["authorization": "Bearer test-token", "host": "example.com"]) { _, new in new },
            body: hostile.body)
        #expect(await handler.handle(hostile).status == 403)

        var sessionIDs: [String] = []
        for id in 0...MCPProtocolHandler.maximumSessions {
            var initialize = try request(method: "initialize", id: id, params: [
                "protocolVersion": MCPProtocolHandler.currentProtocolVersion
            ])
            initialize = MCPHTTPRequest(method: initialize.method, path: initialize.path,
                headers: initialize.headers.merging(["authorization": "Bearer test-token"]) { _, new in new },
                body: initialize.body)
            let response = await handler.handle(initialize)
            sessionIDs.append(try #require(response.headers["MCP-Session-Id"]))
        }
        let expired = try request(method: "ping", id: 100,
                                  headers: sessionHeaders(sessionIDs[0]))
        #expect(await handler.handle(expired).status == 400)
        let newest = try request(method: "ping", id: 101,
                                 headers: sessionHeaders(try #require(sessionIDs.last)))
        #expect(await handler.handle(newest).status == 200)
    }

    @Test func refusesASecondToolCallWhileOneIsSuspended() async throws {
        var release: CheckedContinuation<Void, Never>?
        let handler = MCPProtocolHandler(token: "test-token") { _, _ in
            await withCheckedContinuation { release = $0 }
            return ["content": [["type": "text", "text": "done"]], "isError": false]
        }
        var initialize = try request(method: "initialize", id: 1, params: [
            "protocolVersion": MCPProtocolHandler.currentProtocolVersion
        ])
        initialize = MCPHTTPRequest(method: initialize.method, path: initialize.path,
            headers: initialize.headers.merging(["authorization": "Bearer test-token"]) { _, new in new },
            body: initialize.body)
        let initializedResponse = await handler.handle(initialize)
        let sessionID = try #require(initializedResponse.headers["MCP-Session-Id"])
        let initialized = try request(method: "notifications/initialized", headers: sessionHeaders(sessionID))
        #expect(await handler.handle(initialized).status == 202)

        let call = try request(method: "tools/call", id: 2,
                               params: ["name": "slow", "arguments": [:]], headers: sessionHeaders(sessionID))
        let first = Task { await handler.handle(call) }
        while release == nil { await Task.yield() }
        let second = await handler.handle(try request(method: "tools/call", id: 3,
            params: ["name": "other", "arguments": [:]], headers: sessionHeaders(sessionID)))
        release?.resume()
        let firstResponse = await first.value
        let envelope = try #require(try JSONSerialization.jsonObject(with: second.body) as? [String: Any])
        let result = try #require(envelope["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        #expect(firstResponse.status == 200)
    }

    @Test func refusesOversizedCanvasesAndShapesWithoutMutatingTheDocument() async {
        let workspace = ProjectWorkspace()
        let router = MCPToolRouter(workspace: workspace)
        let canvas = await router.call(name: "compositor_create_document", arguments: [
            "width": DocumentLimits.maxSide, "height": DocumentLimits.maxSide
        ])
        #expect(canvas["isError"] as? Bool == true)
        #expect(workspace.current.session.document == nil)

        _ = await router.call(name: "compositor_create_document", arguments: ["width": 100, "height": 100])
        let shape = await router.call(name: "compositor_add_shape", arguments: [
            "kind": "rectangle", "start_x": -1e300, "start_y": -1e300,
            "end_x": 1e300, "end_y": 1e300
        ])
        #expect(shape["isError"] as? Bool == true)
        #expect(workspace.current.session.document?.layers.count == 1)

        let session = workspace.current.session
        session.selectTool(.shape)
        session.beginShape(at: CGPoint(x: -1e300, y: -1e300))
        session.dragShape(to: CGPoint(x: 1e300, y: 1e300), square: false, fromCenter: false)
        session.finishShape()
        #expect(session.brushError != nil)
        #expect(session.document?.layers.count == 1)
    }

    @Test func rendersLargeCanvasPreviewAtTheRequestedSize() async throws {
        let workspace = ProjectWorkspace()
        let router = MCPToolRouter(workspace: workspace)
        let created = await router.call(name: "compositor_create_document", arguments: [
            "width": 12_000, "height": 8_000
        ])
        #expect(created["isError"] as? Bool == false)
        let rendered = await router.call(name: "compositor_render_document", arguments: ["max_size": 128])
        #expect(rendered["isError"] as? Bool == false)
        let summary = try #require(rendered["structuredContent"] as? [String: Any])
        #expect(summary["width"] as? Int == 128)
        #expect(summary["height"] as? Int == 85)
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
        let compact = router.layerSummary(layer, vectorNodeLimit: 1)
        let compactPath = try #require(compact["vector_path"] as? [String: Any])
        #expect((compactPath["nodes"] as? [[String: Any]])?.count == 1)
        #expect(compactPath["node_count"] as? Int == 2)
        #expect(compactPath["nodes_truncated"] as? Bool == true)

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

    @Test func documentInspectionPaginatesLargeLayerLists() async throws {
        let workspace = ProjectWorkspace()
        let router = MCPToolRouter(workspace: workspace)
        _ = await router.call(name: "compositor_create_document", arguments: ["width": 32, "height": 32])
        _ = await router.call(name: "compositor_manage_layer", arguments: ["action": "add_blank"])
        _ = await router.call(name: "compositor_manage_layer", arguments: ["action": "add_blank"])

        let response = await router.call(name: "compositor_get_document", arguments: [
            "layer_offset": 1, "layer_limit": 1
        ])
        let document = try #require(response["structuredContent"] as? [String: Any])
        #expect(document["layer_count"] as? Int == 3)
        #expect(document["layer_offset"] as? Int == 1)
        #expect(document["layers_truncated"] as? Bool == true)
        #expect((document["layers"] as? [[String: Any]])?.count == 1)
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
        let layer = try #require(workspace.current.session.activeLayer)
        #expect(layer.liveText?.style.content == "Made through MCP")
        let compact = router.layerSummary(layer, textCharacterLimit: 4)
        let compactText = try #require(compact["text"] as? [String: Any])
        #expect(compactText["content"] as? String == "Made")
        #expect(compactText["content_truncated"] as? Bool == true)
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
            "host": "127.0.0.1:49678",
            "mcp-session-id": sessionID,
            "mcp-protocol-version": MCPProtocolHandler.currentProtocolVersion
        ]
    }

    private func request(method: String, id: Int? = nil, params: [String: Any]? = nil,
                         headers: [String: String] = ["content-type": "application/json", "host": "127.0.0.1:49678"]) throws -> MCPHTTPRequest {
        var object: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let id { object["id"] = id }
        if let params { object["params"] = params }
        return MCPHTTPRequest(method: "POST", path: "/mcp", headers: headers,
                              body: try JSONSerialization.data(withJSONObject: object))
    }
}
