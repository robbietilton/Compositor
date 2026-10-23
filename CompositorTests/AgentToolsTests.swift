import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Compositor

@MainActor
struct AgentToolsTests {
    /// A solid PNG, base64, as an agent would send it.
    private func png(width: Int, height: Int, _ color: CGColor) throws -> String {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try AgentImage.encode(try #require(context.makeImage()), as: .png).base64EncodedString()
    }

    private func rpc(_ handler: MCPHandler, _ method: String, _ params: JSONValue = [:], id: JSONValue = 1) async throws -> JSONValue {
        let request: JSONValue = ["jsonrpc": "2.0", "id": id, "method": .string(method), "params": params]
        let reply = try #require(await handler.handle(request.data))
        return try JSONDecoder().decode(JSONValue.self, from: reply)
    }

    /// A tool's result, through the whole JSON-RPC path an agent's request takes.
    private func call(_ handler: MCPHandler, _ tool: String, _ arguments: JSONValue = [:]) async throws -> JSONValue {
        let reply = try await rpc(handler, "tools/call", ["name": .string(tool), "arguments": arguments])
        return try #require(reply["result"])
    }

    private func text(_ result: JSONValue) -> String {
        result["content"]?.array?.compactMap { $0["text"]?.string }.joined(separator: "\n") ?? ""
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return bytes
    }

    @Test func httpRequestsAreReadWhole() throws {
        let head = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer abc\r\nContent-Length: 10\r\n\r\n"
        guard case .incomplete = HTTPRequestReader.parse(Data((head + "{\"a\":").utf8)) else { Issue.record("a partial body waits"); return }
        guard case .request(let request) = HTTPRequestReader.parse(Data((head + "{\"a\":true}").utf8)) else { Issue.record("a whole one is read"); return }
        #expect(request.method == "POST" && request.path == "/mcp")
        #expect(request.headers["authorization"] == "Bearer abc", "header names are lowercased")
        #expect(String(data: request.body, encoding: .utf8) == "{\"a\":true}")

        let chunked = "POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n{\"a\"\r\n6\r\n:true}\r\n"
        guard case .incomplete = HTTPRequestReader.parse(Data(chunked.utf8)) else { Issue.record("waits for the last chunk"); return }
        guard case .request(let whole) = HTTPRequestReader.parse(Data((chunked + "0\r\n\r\n").utf8)) else { Issue.record("chunks join"); return }
        #expect(String(data: whole.body, encoding: .utf8) == "{\"a\":true}")
        guard case .invalid = HTTPRequestReader.parse(Data("nonsense\r\n\r\n".utf8)) else { Issue.record("nonsense is refused"); return }
    }

    @Test func patchesMergeKeyByKey() {
        let base: JSONValue = ["stroke": ["size": 4, "red": 0], "shadow": ["blur": 20]]
        let merged = base.merging(["stroke": ["size": 8], "shadow": nil, "colorOverlay": ["red": 1]])
        #expect(merged == ["stroke": ["size": 8, "red": 0], "colorOverlay": ["red": 1]])
    }

    @Test func initializesAndListsTools() async throws {
        let handler = MCPHandler(tools: AgentTools.all, workspace: ProjectWorkspace())
        let asked = try await rpc(handler, "initialize", ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]])
        #expect(asked["result"]?["protocolVersion"] == "2025-03-26", "a version the server speaks is kept")
        #expect(asked["result"]?["capabilities"]?["tools"] != nil)
        let unknown = try await rpc(handler, "initialize", ["protocolVersion": "1999-01-01"])
        #expect(unknown["result"]?["protocolVersion"]?.string == MCPHandler.protocolVersions[0], "any other gets the newest")
        // Notifications get no reply.
        #expect(await handler.handle((["jsonrpc": "2.0", "method": "notifications/initialized"] as JSONValue).data) == nil)

        let tools = try #require(try await rpc(handler, "tools/list")["result"]?["tools"]?.array)
        let names = Set(tools.compactMap { $0["name"]?.string })
        for name in ["new_document", "get_document", "add_layer", "update_layer", "apply_filter", "render", "run_command"] {
            #expect(names.contains(name))
        }
        #expect(names.count == tools.count, "names are unique")
        #expect(tools.allSatisfy { $0["inputSchema"]?["type"] == "object" && $0["description"]?.string?.isEmpty == false })
        #expect(try await rpc(handler, "nope")["error"]?["code"] == -32601)
    }

    @Test func mistakesAreReportedToTheAgent() async throws {
        let handler = MCPHandler(tools: AgentTools.all, workspace: ProjectWorkspace())
        #expect(try await rpc(handler, "tools/call", ["name": "paint_mona_lisa"])["error"]?["code"] == -32602)
        let misspelled = try await call(handler, "new_document", ["width": 10, "height": 10, "colour": "#FFFFFF"])
        #expect(misspelled["isError"] == true)
        #expect(text(misspelled).contains("takes no argument “colour”"))
        let noCanvas = try await call(handler, "get_document")
        #expect(noCanvas["isError"] == false, "an empty tab is described, not refused")
        let noLayer = try await call(handler, "update_layer", ["opacity": 0.5])
        #expect(noLayer["isError"] == true)
    }

    @Test func buildsAnImageLayerByLayer() async throws {
        let workspace = ProjectWorkspace()
        let handler = MCPHandler(tools: AgentTools.all, workspace: workspace)
        let made = try await call(handler, "new_document", ["width": 64, "height": 32, "background": "#FF0000", "name": "Poster"])
        #expect(made["isError"] == false)
        let session = workspace.current.session
        #expect(session.document?.width == 64 && session.document?.layers.count == 1)

        let added = try await call(handler, "add_layer", ["type": "image", "name": "Blue", "image_data": .string(try png(width: 8, height: 8, CGColor(red: 0, green: 0, blue: 1, alpha: 1))),
                                                          "x": 4, "y": 2, "width": 16])
        #expect(added["isError"] == false, "\(text(added))")
        let blue = try #require(session.document?.layers.last)
        #expect(blue.name == "Blue")
        #expect(blue.transform.origin == CGPoint(x: 4, y: 2) && blue.transform.size == CGSize(width: 16, height: 16), "height follows width")

        let changed = try await call(handler, "update_layer", [
            "layer_id": .string(blue.id.uuidString), "opacity": 0.5, "blend_mode": "Multiply",
            "transform": ["rotation": 90], "effects": ["stroke": ["size": 3, "green": 1]],
        ])
        #expect(changed["isError"] == false, "\(text(changed))")
        let edited = try #require(session.document?.layers.last)
        #expect(edited.opacity == 0.5 && edited.blendMode == .multiply && edited.transform.rotation == 90)
        #expect(edited.transform.origin == CGPoint(x: 4, y: 2), "fields not named keep their values")
        #expect(edited.effects?.stroke?.size == 3 && edited.effects?.stroke?.green == 1 && edited.effects?.stroke?.opacity == 1,
                "an effect not there before starts from its defaults")
        #expect(session.history.undoName == "Change Layer", "one undo step")
        let removed = try await call(handler, "update_layer", ["effects": ["stroke": nil]])
        #expect(removed["isError"] == false && session.document?.layers.last?.effects == nil)
        let wrongMode = try await call(handler, "update_layer", ["blend_mode": "Glow"])
        #expect(wrongMode["isError"] == true && text(wrongMode).contains("Multiply"), "the modes there are are listed")

        let described = try await call(handler, "get_document")
        #expect(described["structuredContent"]?["layers"]?.array?.count == 2)
        #expect(described["structuredContent"]?["layers"]?.array?.last?["blend_mode"] == "Multiply")

        let rendered = try await call(handler, "render", ["max_size": 32])
        let image = try #require(rendered["content"]?.array?.first { $0["type"] == "image" })
        #expect(image["mimeType"] == "image/png")
        let data = try #require(Data(base64Encoded: image["data"]?.string ?? ""))
        let decoded = try #require(NSBitmapImageRep(data: data))
        #expect(decoded.pixelsWide == 32 && decoded.pixelsHigh == 16)

        #expect(try await call(handler, "undo", ["steps": 2])["isError"] == false)
        #expect(session.document?.layers.last?.opacity == 1, "undone")
    }

    @Test func selectsFillsAndFilters() async throws {
        let workspace = ProjectWorkspace()
        let handler = MCPHandler(tools: AgentTools.all, workspace: workspace)
        _ = try await call(handler, "new_document", ["width": 40, "height": 40, "background": "#FFFFFF"])
        let session = workspace.current.session
        let background = try #require(session.document?.layers.first)

        #expect(try await call(handler, "select", ["shape": "rectangle", "x": 0, "y": 0, "width": 20, "height": 40])["isError"] == false)
        #expect(session.selection?.path.boundingBoxOfPath == CGRect(x: 0, y: 0, width: 20, height: 40))
        let filled = try await call(handler, "fill", ["color": "#000000"])
        #expect(filled["isError"] == false, "\(text(filled))")
        let image = try #require(session.document?.layers.first?.asset?.image)
        #expect(try pixel(image, x: 5, y: 20)[0] == 0 && pixel(image, x: 35, y: 20)[0] == 255, "only the selection")
        _ = try await call(handler, "select", ["shape": "none"])
        #expect(session.selection == nil)

        let misplaced = try await call(handler, "apply_filter", ["filter": "Gaussian Blur", "settings": ["amount": 5]])
        #expect(misplaced["isError"] == true && text(misplaced).contains("radius"), "a setting of another filter is named, with the right ones")
        #expect(session.filterEdit == nil, "and the panel isn't left open")

        let blurred = try await call(handler, "apply_filter", ["layer_id": .string(background.id.uuidString), "filter": "gaussian blur",
                                                               "settings": ["radius": 4]])
        #expect(blurred["isError"] == false, "\(text(blurred))")
        #expect(session.history.undoName == "Gaussian Blur")
        let soft = try #require(session.document?.layers.first?.asset?.image)
        let edge = try pixel(soft, x: 20, y: 20)[0]
        #expect(edge > 0 && edge < 255, "the hard edge is blurred")
    }

    @Test func addsAdjustmentLayersWithTheirSettings() async throws {
        let workspace = ProjectWorkspace()
        let handler = MCPHandler(tools: AgentTools.all, workspace: workspace)
        _ = try await call(handler, "new_document", ["width": 20, "height": 20])
        let session = workspace.current.session
        let hue = try await call(handler, "add_adjustment_layer", ["kind": "Hue/Saturation", "settings": ["hue": 30], "name": "Warm"])
        #expect(hue["isError"] == false, "\(text(hue))")
        #expect(session.activeLayer?.adjustment?.hue == 30 && session.activeLayer?.name == "Warm")
        #expect(session.adjustmentEditingID == nil, "no editor is left open for the person")
        #expect(session.canEditLayers)

        let exposure = try await call(handler, "add_adjustment_layer", ["kind": "Exposure", "settings": ["exposureSettings": ["exposure": 0.5]]])
        #expect(exposure["isError"] == false, "\(text(exposure))")
        #expect(session.activeLayer?.adjustment?.exposure.exposure == 0.5, "a settings group not stored yet starts from its defaults")

        let tooFar = try await call(handler, "update_layer", ["adjustment": ["exposureSettings": ["exposure": 99]]])
        #expect(tooFar["isError"] == true)
        #expect(session.activeLayer?.adjustment?.exposure.exposure == 0.5, "nothing changes on an error")
    }

    @Test func runsCommandsByName() async throws {
        let workspace = ProjectWorkspace()
        let handler = MCPHandler(tools: AgentTools.all, workspace: workspace)
        _ = try await call(handler, "new_document", ["width": 20, "height": 20])
        let ran = try await call(handler, "run_command", ["command": "Tool › Brush"])
        #expect(ran["isError"] == false, "\(text(ran))")
        #expect(workspace.current.session.tool == .brush)
        let unknown = try await call(handler, "run_command", ["command": "Tool › Brsh"])
        #expect(unknown["isError"] == true && text(unknown).contains("Tool › Brush"), "close names are suggested")
    }

    @Test func paintsStrokesAndLeavesThePersonsBrushAlone() async throws {
        let workspace = ProjectWorkspace()
        let handler = MCPHandler(tools: AgentTools.all, workspace: workspace)
        _ = try await call(handler, "new_document", ["width": 60, "height": 60, "background": "#FFFFFF"])
        let session = workspace.current.session
        let tool = session.tool, diameter = session.brushSettings.diameter
        let painted = try await call(handler, "paint", ["tool": "brush", "color": "#000000", "size": 6,
                                                        "strokes": [[[10, 30], [50, 30]], [[30, 5], [30, 15, 0.5]]]])
        #expect(painted["isError"] == false, "\(text(painted))")
        let image = try #require(session.document?.layers.first?.asset?.image)
        #expect(try pixel(image, x: 30, y: 30)[0] < 40, "points between the given ones are painted")
        #expect(try pixel(image, x: 30, y: 45)[0] == 255, "and nothing else")
        #expect(session.tool == tool && session.brushSettings.diameter == diameter, "the person's tool and brush are as they were")

        let cloned = try await call(handler, "paint", ["tool": "clone_stamp", "clone_source": [30, 30], "size": 8,
                                                       "strokes": [[[30, 50]]]])
        #expect(cloned["isError"] == false, "\(text(cloned))")
        #expect(try pixel(try #require(session.document?.layers.first?.asset?.image), x: 30, y: 50)[0] < 40, "the line is copied below")
        let noSource = try await call(handler, "paint", ["tool": "clone_stamp", "strokes": [[[5, 5]]]])
        #expect(noSource["isError"] == true && text(noSource).contains("clone_source"))
        let smudged = try await call(handler, "paint", ["tool": "smudge", "size": 10, "strokes": [[[20, 30], [20, 45]]]])
        #expect(smudged["isError"] == false, "\(text(smudged))")
    }

    @Test func textAndShapesStayEditable() async throws {
        let workspace = ProjectWorkspace()
        let handler = MCPHandler(tools: AgentTools.all, workspace: workspace)
        _ = try await call(handler, "new_document", ["width": 400, "height": 200])
        let session = workspace.current.session
        let defaults = session.textDefaults
        let added = try await call(handler, "add_text", ["text": "Hello", "x": 20, "y": 30, "font": "Helvetica-Bold", "size": 48, "color": "#FF0000"])
        #expect(added["isError"] == false, "\(text(added))")
        #expect(added["structuredContent"]?["kind"] == "text")
        let layer = try #require(session.activeLayer)
        #expect(layer.liveText?.style.fontName == "Helvetica-Bold" && layer.liveText?.style.red == 1 && layer.transform.origin == CGPoint(x: 20, y: 30))
        #expect(session.textDefaults == defaults, "the Type tool's own settings are left alone")

        let updated = try await call(handler, "update_text", ["text": "Hello there", "size": 24])
        #expect(updated["isError"] == false, "\(text(updated))")
        #expect(session.activeLayer?.liveText?.style.content == "Hello there" && session.activeLayer?.transform.origin == CGPoint(x: 20, y: 30))
        let wrapped = try await call(handler, "update_text", ["box_width": 120])
        #expect(wrapped["isError"] == false && session.activeLayer?.liveText?.style.boxSize?.width == 120)
        let noFont = try await call(handler, "add_text", ["text": "x", "x": 0, "y": 0, "font": "No Such Font"])
        #expect(noFont["isError"] == true && text(noFont).contains("list_fonts"))
        let fonts = try await call(handler, "list_fonts", ["query": "helvetica"])
        #expect(fonts["structuredContent"]?["result"]?.array?.isEmpty == false)

        let shape = try await call(handler, "add_shape", ["kind": "rectangle", "x": 10, "y": 10, "width": 40, "height": 20,
                                                          "color": "#00FF00", "corner_radius": 6, "name": "Button"])
        #expect(shape["isError"] == false, "\(text(shape))")
        let rectangle = try #require(session.activeLayer)
        #expect(rectangle.name == "Button" && rectangle.liveShape?.style.cornerRadius == 6 && rectangle.transform.size == CGSize(width: 40, height: 20))
        #expect(try await call(handler, "update_shape", ["color": "#0000FF"])["isError"] == false)
        #expect(session.activeLayer?.liveShape?.style.blue == 1 && session.activeLayer?.liveShape?.style.green == 0)
        let line = try await call(handler, "add_shape", ["kind": "line", "from": [0, 100], "to": [200, 100], "line_width": 6, "line_style": "Dashed"])
        #expect(line["isError"] == false && session.activeLayer?.liveShape?.style.lineStyle == .dashed)
        #expect(try await call(handler, "update_shape", ["corner_radius": 4])["isError"] == true, "a line has no corners")
    }

    @Test func resizesCropsAndTurnsTheCanvas() async throws {
        let workspace = ProjectWorkspace()
        let handler = MCPHandler(tools: AgentTools.all, workspace: workspace)
        _ = try await call(handler, "new_document", ["width": 80, "height": 40])
        let session = workspace.current.session
        #expect(try await call(handler, "canvas_size", ["width": 100, "height": 50, "anchor": "top-left", "fill": "#000000"])["isError"] == false)
        #expect(session.document?.width == 100 && session.document?.height == 50)
        let image = try await call(handler, "image_size", ["width": 50])
        #expect(image["isError"] == false, "\(text(image))")
        #expect(session.document?.width == 50 && session.document?.height == 25, "the height follows")
        #expect(try await call(handler, "crop", ["x": 5, "y": 5, "width": 20, "height": 10])["isError"] == false)
        #expect(session.document?.width == 20 && session.document?.height == 10)
        #expect(try await call(handler, "rotate_canvas", ["direction": "clockwise"])["isError"] == false)
        #expect(session.document?.width == 10 && session.document?.height == 20)
        #expect(session.history.undoName == "Rotate Canvas" || session.history.canUndo)
        #expect(try await call(handler, "canvas_size", ["width": 10, "height": 10, "anchor": "middle"])["isError"] == true)
    }

    @Test func cameraRawTakesEveryPanel() throws {
        var settings = FilterSettings()
        try AgentFilterSettings.apply(["cameraRaw": [
            "exposure": 0.5, "whiteBalance": "Auto",
            "curve": ["shadows": 20, "rgb": [["x": 0, "y": 0.1], ["x": 1, "y": 0.9]]],
            "mixer": ["saturation": ["Oranges": -30]],
            "grading": ["shadows": ["hue": 200, "saturation": 30], "balance": 10],
            "detail": ["sharpenAmount": 40], "optics": ["removeChromaticAberration": true],
            "geometry": ["rotate": 2], "calibration": ["process": "Version 5"],
        ]], for: .cameraRaw, to: &settings)
        let raw = settings.cameraRaw
        #expect(raw.exposure == 0.5 && raw.whiteBalance == .auto)
        #expect(raw.curve.shadows == 20 && raw.curve.rgb == [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 0.9)])
        #expect(raw.mixer.saturation[1] == -30 && raw.mixer.saturation[0] == 0)
        #expect(raw.grading.shadows.hue == 200 && raw.grading.balance == 10)
        #expect(raw.detail.sharpenAmount == 40 && raw.optics.removeChromaticAberration && raw.geometry.rotate == 2 && raw.calibration.process == .version5)
        #expect(throws: AgentError.self) { try AgentFilterSettings.apply(["cameraRaw": ["grading": ["shadows": ["tint": 1]]]], for: .cameraRaw, to: &settings) }
        #expect(throws: AgentError.self) { try AgentFilterSettings.apply(["cameraRaw": ["mixer": ["hue": ["Teals": 1]]]], for: .cameraRaw, to: &settings) }
    }

    /// An animated GIF of solid frames, base64, as an agent would send it.
    private func gif(_ colors: [CGColor], size: Int = 8) throws -> String {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, colors.count, nil))
        for color in colors {
            let context = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()),
                                       [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return (data as Data).base64EncodedString()
    }

    @Test func laysGradients() async throws {
        let workspace = ProjectWorkspace()
        let handler = MCPHandler(tools: AgentTools.all, workspace: workspace)
        _ = try await call(handler, "new_document", ["width": 100, "height": 10, "background": "#FFFFFF"])
        let session = workspace.current.session
        let foreground = session.foregroundColor, tool = session.tool
        let laid = try await call(handler, "gradient", ["from": [0, 5], "to": [100, 5], "start_color": "#000000", "end_color": "#FFFFFF"])
        #expect(laid["isError"] == false, "\(text(laid))")
        let image = try #require(session.document?.layers.first?.asset?.image)
        let left = try pixel(image, x: 2, y: 5)[0], middle = try pixel(image, x: 50, y: 5)[0], right = try pixel(image, x: 97, y: 5)[0]
        #expect(left < 20 && right > 235 && middle > 100 && middle < 155, "dark to light along the line")
        #expect(session.foregroundColor == foreground && session.tool == tool, "the person's colors and tool are as they were")
        #expect(session.gradientEdit == nil, "nothing is left pending")
        #expect(try await call(handler, "gradient", ["from": [5, 5], "to": [5, 5]])["isError"] == true)
    }

    @Test func editsGIFFrames() async throws {
        let workspace = ProjectWorkspace()
        let handler = MCPHandler(tools: AgentTools.all, workspace: workspace)
        _ = try await call(handler, "new_document", ["width": 8, "height": 8])
        let session = workspace.current.session
        let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1), green = CGColor(red: 0, green: 1, blue: 0, alpha: 1)
        let added = try await call(handler, "add_layer", ["type": "image", "name": "Blink", "image_data": .string(try gif([red, green, red]))])
        #expect(added["isError"] == false, "\(text(added))")
        #expect(added["structuredContent"]?["kind"] == "gif")

        let listed = try await call(handler, "gif_frames")
        let frames = try #require(listed["structuredContent"]?["frames"]?.array)
        #expect(frames.count == 3 && listed["structuredContent"]?["selected_frame"] == 0)
        #expect(try await call(handler, "edit_gif", ["action": "select", "frame": 1])["isError"] == false)
        let shown = try #require(session.activeLayer.flatMap { session.displayedAsset(for: $0) }?.image)
        #expect(try pixel(shown, x: 4, y: 4)[1] > 200, "the canvas shows the green frame")

        #expect(try await call(handler, "edit_gif", ["action": "duplicate", "frame": 1])["isError"] == false)
        #expect(session.activeLayer?.gifAnimation?.frames.count == 4)
        #expect(try await call(handler, "edit_gif", ["action": "delete", "frames": [0]])["isError"] == false)
        #expect(session.activeLayer?.gifAnimation?.frames.count == 3)
        let timed = try await call(handler, "edit_gif", ["action": "set_delays", "delay": 0.5])
        #expect(timed["isError"] == false, "\(text(timed))")
        #expect(session.activeLayer?.gifAnimation?.timing.mode == .uniform && session.activeLayer?.gifAnimation?.timing.uniformDelay == 0.5)
        #expect(try await call(handler, "edit_gif", ["action": "select", "frame": 99])["isError"] == true)
    }

    @Test func cameraRawPicksColorsAndDrawsGuides() throws {
        var settings = FilterSettings()
        try AgentFilterSettings.apply(["cameraRaw": [
            "mixer": ["points": [["color": "#FF8000", "saturationShift": -40], ["hue": 200, "saturation": 0.5, "luminance": 0.4]]],
            "geometry": ["guides": [["start": [0.1, 0.2], "end": [0.9, 0.25]]]],
        ]], for: .cameraRaw, to: &settings)
        let points = settings.cameraRaw.mixer.points
        #expect(points.count == 2)
        #expect(abs(points[0].hue - 30) < 0.5 && points[0].saturation == 1 && points[0].saturationShift == -40, "picked as the eyedropper picks orange")
        #expect(points[1].hue == 200 && points[1].luminance == 0.4)
        let guide = try #require(settings.cameraRaw.geometry.guides.first)
        #expect(settings.cameraRaw.geometry.upright == .guided)
        #expect(abs(guide.startY - 0.8) < 1e-9 && guide.startX == 0.1, "kept from the lower-left, as the filter keeps them")
        #expect(throws: AgentError.self) {
            try AgentFilterSettings.apply(["cameraRaw": ["geometry": ["guides": [["start": [0, 0], "end": [2, 0]]]]]], for: .cameraRaw, to: &settings)
        }
    }

    @Test func claudeDesktopKeepsItsOtherSettings() throws {
        let existing = Data(#"{"globalShortcut": "Cmd+Space", "mcpServers": {"files": {"command": "files-mcp"}, "compositor": {"command": "old"}}}"#.utf8)
        let app = "/Applications/Compositor.app/Contents/MacOS/Compositor"
        let merged = try ClaudeDesktopConfig.merged(existing, executable: app)
        let config = try #require(try JSONSerialization.jsonObject(with: merged) as? [String: Any])
        let servers = try #require(config["mcpServers"] as? [String: Any])
        #expect(config["globalShortcut"] as? String == "Cmd+Space", "its other settings stay")
        #expect((servers["files"] as? [String: Any])?["command"] as? String == "files-mcp", "and its other servers")
        let compositor = try #require(servers["compositor"] as? [String: Any])
        #expect(compositor["command"] as? String == app, "an old entry is replaced")
        #expect(compositor["args"] as? [String] == ["--mcp-stdio"])
        #expect(compositor["env"] == nil, "no token is written into another app's settings")

        let fresh = try JSONSerialization.jsonObject(with: try ClaudeDesktopConfig.merged(nil, executable: app)) as? [String: Any]
        #expect((fresh?["mcpServers"] as? [String: Any])?.keys.sorted() == ["compositor"], "no file yet: a new one")
        #expect(throws: (any Error).self) { try ClaudeDesktopConfig.merged(Data("{ not json".utf8), executable: app) }
        #expect(ClaudeDesktopConfig.snippet(executable: app).contains("\"--mcp-stdio\""))
    }

    @Test func stdioBridgePassesLinesThroughAndExplainsFailures() {
        let request = #"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#
        var sent: [Data] = []
        let reply = MCPStdioBridge.reply(to: request) { body in sent.append(body); return (200, Data("{\"id\":7,\"result\":{}}\n".utf8)) }
        #expect(reply == #"{"id":7,"result":{}}"#, "one line, as stdio needs")
        #expect(sent == [Data(request.utf8)])
        #expect(MCPStdioBridge.reply(to: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) { _ in (202, Data()) } == nil)
        #expect(MCPStdioBridge.reply(to: "   ") { _ in Issue.record("blank lines aren't sent"); return (200, Data()) } == nil)
        let down = MCPStdioBridge.reply(to: request) { _ in throw URLError(.cannotConnectToHost) }
        #expect(down?.contains("\"id\":7") == true && down?.contains("Agent Access") == true, "the agent is told what to turn on")
        #expect(MCPStdioBridge.reply(to: #"{"jsonrpc":"2.0","method":"notifications/x"}"#) { _ in throw URLError(.cannotConnectToHost) } == nil)
        #expect(MCPStdioBridge.reply(to: request) { _ in (401, Data()) }?.contains("token") == true)
    }

    @Test func claudeDesktopFileIsBackedUpBeforeItChanges() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = Data(#"{"mcpServers": {}}"#.utf8)
        try original.write(to: folder.appendingPathComponent(ClaudeDesktopConfig.fileName))
        try ClaudeDesktopConfig.install(in: folder, executable: "/Applications/Compositor.app/Contents/MacOS/Compositor")
        #expect(try Data(contentsOf: folder.appendingPathComponent("claude_desktop_config.json.bak")) == original)
        #expect(try String(contentsOf: folder.appendingPathComponent(ClaudeDesktopConfig.fileName), encoding: .utf8).contains("--mcp-stdio"))
    }
}
