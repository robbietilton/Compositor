import AppKit
import Foundation

private struct MCPToolFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Translates model-facing tool calls into the same EditorSession operations the interface uses. It stays on the
/// main actor so an MCP edit and a pointer edit can never mutate a document at the same time.
@MainActor
final class MCPToolRouter {
    private let workspace: ProjectWorkspace

    init(workspace: ProjectWorkspace) { self.workspace = workspace }

    static var tools: [[String: Any]] {
        [
            tool("compositor_get_document", "Inspect the current Compositor canvas and its layers.", schema(),
                 readOnly: true, destructive: false, idempotent: true),
            tool("compositor_create_document", "Create a new canvas in a new tab without replacing the current document.", schema(
                properties: [
                    "width": integer("Canvas width in pixels.", minimum: 1, maximum: DocumentLimits.maxSide),
                    "height": integer("Canvas height in pixels.", minimum: 1, maximum: DocumentLimits.maxSide),
                    "resolution": number("Resolution in pixels per inch. Defaults to 72.", minimum: 1, maximum: 9_600),
                    "background": string("Optional #RRGGBB background color, or transparent.")
                ], required: ["width", "height"]), destructive: false),
            tool("compositor_add_vector_path", "Add an editable Pen shape or line to the current canvas. Coordinates are document pixels.", schema(
                properties: [
                    "mode": enumString("A shape is filled and closed; a line is stroked.", ["shape", "line"]),
                    "nodes": ["type": "array", "minItems": 2, "maxItems": 10_000,
                              "description": "Path anchors and optional cubic handles in document pixels.",
                              "items": schema(properties: [
                                "x": number("Anchor x coordinate."), "y": number("Anchor y coordinate."),
                                "in_x": number("Incoming handle x coordinate; defaults to x."),
                                "in_y": number("Incoming handle y coordinate; defaults to y."),
                                "out_x": number("Outgoing handle x coordinate; defaults to x."),
                                "out_y": number("Outgoing handle y coordinate; defaults to y.")
                              ], required: ["x", "y"])],
                    "color": string("Stroke or fill color as #RRGGBB. Defaults to the current foreground color."),
                    "line_width": number("Line width in document pixels. Used for line mode.", minimum: 1, maximum: 5_000),
                    "closed": ["type": "boolean", "description": "Close a line back to its first node. Shapes are always closed."]
                ], required: ["mode", "nodes"]), destructive: false),
            tool("compositor_update_layer", "Update the name, visibility, appearance, or transform of one layer.", schema(
                properties: [
                    "layer_id": string("Layer UUID from compositor_get_document."),
                    "name": string("New layer name."),
                    "visible": ["type": "boolean"],
                    "opacity": number("Opacity from 0 to 1.", minimum: 0, maximum: 1),
                    "blend_mode": enumString("Compositor blend mode.", LayerBlendMode.allCases.map(\.rawValue)),
                    "x": number("Layer origin x in document pixels."), "y": number("Layer origin y in document pixels."),
                    "width": number("Layer width in document pixels.", minimum: 1, maximum: 300_000),
                    "height": number("Layer height in document pixels.", minimum: 1, maximum: 300_000),
                    "rotation": number("Clockwise rotation in degrees."),
                    "flip_x": ["type": "boolean"], "flip_y": ["type": "boolean"]
                ], required: ["layer_id"]), destructive: true),
            tool("compositor_select_layer", "Make one layer the active layer in the current document.", schema(
                properties: ["layer_id": string("Layer UUID from compositor_get_document.")], required: ["layer_id"]),
                 destructive: false, idempotent: true),
            tool("compositor_history", "Undo or redo one Compositor document edit.", schema(
                properties: ["action": enumString("History direction.", ["undo", "redo"])], required: ["action"]),
                 destructive: true),
            tool("compositor_save_document", "Save the current document to its existing .comp project. Unsaved documents require the user to choose a location in Compositor first.", schema(),
                 destructive: false, idempotent: true),
            tool("compositor_render_document", "Render the current canvas as a PNG image for visual inspection.", schema(
                properties: ["max_size": integer("Maximum width or height of the returned preview. Defaults to 2048.", minimum: 64, maximum: 8_192)]),
                 readOnly: true, destructive: false, idempotent: true)
        ]
    }

    func call(name: String, arguments: [String: Any]) async -> [String: Any] {
        do {
            switch name {
            case "compositor_get_document": return try result(documentSummary())
            case "compositor_create_document": return try createDocument(arguments)
            case "compositor_add_vector_path": return try addVectorPath(arguments)
            case "compositor_update_layer": return try updateLayer(arguments)
            case "compositor_select_layer": return try selectLayer(arguments)
            case "compositor_history": return try history(arguments)
            case "compositor_save_document": return try await saveDocument()
            case "compositor_render_document": return try await renderDocument(arguments)
            default: throw MCPToolFailure(message: "Unknown tool: \(name)")
            }
        } catch {
            return failure(error.localizedDescription)
        }
    }

    private func createDocument(_ arguments: [String: Any]) throws -> [String: Any] {
        guard workspace.canSwitch else { throw MCPToolFailure(message: "Compositor is busy with another edit or dialog.") }
        let width = try arguments.requiredInteger("width", range: 1...DocumentLimits.maxSide)
        let height = try arguments.requiredInteger("height", range: 1...DocumentLimits.maxSide)
        let resolution = try arguments.optionalNumber("resolution") ?? 72
        guard (1...9_600).contains(resolution) else { throw MCPToolFailure(message: "resolution must be between 1 and 9600.") }
        let background: CGColor?
        if let value = try arguments.optionalString("background"), value.lowercased() != "transparent" {
            guard let color = PaletteColor(hex: value) else { throw MCPToolFailure(message: "background must be transparent or a color such as #3366FF.") }
            background = CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
        } else { background = nil }
        let tab = workspace.addTab(reuseEmpty: true)
        tab.session.createNewProject(width: width, height: height, resolution: resolution, background: background)
        guard tab.session.document != nil else { throw MCPToolFailure(message: "The canvas could not be created.") }
        return try result(documentSummary())
    }

    private func addVectorPath(_ arguments: [String: Any]) throws -> [String: Any] {
        let session = workspace.current.session
        guard session.document != nil else { throw MCPToolFailure(message: "Create or open a document first.") }
        guard session.canEditLayers, session.penDraft == nil else {
            throw MCPToolFailure(message: "Finish the current canvas edit before adding a vector path.")
        }
        guard let modeName = try arguments.optionalString("mode"), let mode = PenMode(rawValue: modeName.capitalized) else {
            throw MCPToolFailure(message: "mode must be shape or line.")
        }
        guard let rawNodes = arguments["nodes"] as? [[String: Any]], rawNodes.count <= 10_000 else {
            throw MCPToolFailure(message: "nodes must be an array containing at most 10000 points.")
        }
        let minimum = mode == .shape ? 3 : 2
        guard rawNodes.count >= minimum else { throw MCPToolFailure(message: "\(modeName) mode needs at least \(minimum) nodes.") }
        let nodes = try rawNodes.map { node -> VectorPathNode in
            let x = try node.requiredNumber("x"), y = try node.requiredNumber("y")
            let inX = try node.optionalNumber("in_x") ?? x, inY = try node.optionalNumber("in_y") ?? y
            let outX = try node.optionalNumber("out_x") ?? x, outY = try node.optionalNumber("out_y") ?? y
            let pathNode = VectorPathNode(anchor: CGPoint(x: x, y: y),
                                          inHandle: CGPoint(x: inX, y: inY),
                                          outHandle: CGPoint(x: outX, y: outY))
            guard pathNode.isFinite else { throw MCPToolFailure(message: "Every node coordinate must be finite.") }
            return pathNode
        }
        let color: PaletteColor
        if let value = try arguments.optionalString("color") {
            guard let parsed = PaletteColor(hex: value) else { throw MCPToolFailure(message: "color must look like #3366FF.") }
            color = parsed
        } else { color = session.foregroundColor }
        let lineWidth = try arguments.optionalNumber("line_width") ?? 4
        guard (1...5_000).contains(lineWidth) else { throw MCPToolFailure(message: "line_width must be between 1 and 5000.") }
        let closed = try arguments.optionalBoolean("closed") ?? (mode == .shape)
        session.penDraft = PenDraft(mode: mode, color: color, lineWidth: lineWidth, nodes: nodes, hoverPoint: nil)
        guard session.finishPen(closed: closed), let layer = session.activeLayer else {
            session.penDraft = nil
            throw MCPToolFailure(message: session.brushError ?? "The vector path could not be created.")
        }
        return try result(["layer": layerSummary(layer), "document_id": session.document!.id.uuidString])
    }

    private func updateLayer(_ arguments: [String: Any]) throws -> [String: Any] {
        let session = workspace.current.session
        guard session.canEditLayers else { throw MCPToolFailure(message: "Compositor is busy with another edit or dialog.") }
        let id = try arguments.requiredUUID("layer_id")
        guard let index = session.document?.layers.firstIndex(where: { $0.id == id }), var layer = session.document?.layers[index] else {
            throw MCPToolFailure(message: "No layer has id \(id.uuidString).")
        }
        var changed = false
        if arguments.keys.contains("name") {
            let name = try arguments.requiredString("name").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw MCPToolFailure(message: "name cannot be empty.") }
            layer.name = name; changed = true
        }
        if arguments.keys.contains("visible") { layer.isVisible = try arguments.requiredBoolean("visible"); changed = true }
        if arguments.keys.contains("opacity") {
            let opacity = try arguments.requiredNumber("opacity")
            guard (0...1).contains(opacity) else { throw MCPToolFailure(message: "opacity must be between 0 and 1.") }
            layer.opacity = opacity; changed = true
        }
        if arguments.keys.contains("blend_mode") {
            let name = try arguments.requiredString("blend_mode")
            guard let mode = LayerBlendMode.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw MCPToolFailure(message: "Unknown blend_mode: \(name).")
            }
            layer.blendMode = mode; changed = true
        }
        var transform = layer.transform
        if arguments.keys.contains("x") { transform.origin.x = try arguments.requiredNumber("x"); changed = true }
        if arguments.keys.contains("y") { transform.origin.y = try arguments.requiredNumber("y"); changed = true }
        if arguments.keys.contains("width") { transform.size.width = try arguments.requiredNumber("width"); changed = true }
        if arguments.keys.contains("height") { transform.size.height = try arguments.requiredNumber("height"); changed = true }
        if arguments.keys.contains("rotation") { transform.rotation = try arguments.requiredNumber("rotation"); changed = true }
        if arguments.keys.contains("flip_x") { transform.flipX = try arguments.requiredBoolean("flip_x"); changed = true }
        if arguments.keys.contains("flip_y") { transform.flipY = try arguments.requiredBoolean("flip_y"); changed = true }
        guard transform.isValid else { throw MCPToolFailure(message: "The requested layer transform is outside Compositor's limits.") }
        layer.transform = transform
        guard changed else { throw MCPToolFailure(message: "No layer properties were supplied.") }
        session.finishOpacityEdit()
        session.beginEdit("MCP Update Layer")
        session.document?.layers[index] = layer
        session.activeLayerID = id
        session.endEdit()
        return try result(["layer": layerSummary(layer)])
    }

    private func selectLayer(_ arguments: [String: Any]) throws -> [String: Any] {
        let session = workspace.current.session
        guard session.canEditLayers else { throw MCPToolFailure(message: "Compositor is busy with another edit or dialog.") }
        let id = try arguments.requiredUUID("layer_id")
        guard let layer = session.document?.layers.first(where: { $0.id == id }) else {
            throw MCPToolFailure(message: "No layer has id \(id.uuidString).")
        }
        session.selectLayer(id)
        guard session.activeLayerID == id else { throw MCPToolFailure(message: "The layer could not be selected while another edit is active.") }
        return try result(["layer": layerSummary(layer)])
    }

    private func history(_ arguments: [String: Any]) throws -> [String: Any] {
        let action = try arguments.requiredString("action").lowercased()
        let session = workspace.current.session
        switch action {
        case "undo":
            guard session.canUndo else { throw MCPToolFailure(message: "There is no edit available to undo.") }
            session.undo()
        case "redo":
            guard session.canRedo else { throw MCPToolFailure(message: "There is no edit available to redo.") }
            session.redo()
        default: throw MCPToolFailure(message: "action must be undo or redo.")
        }
        return try result(documentSummary())
    }

    private func saveDocument() async throws -> [String: Any] {
        let tab = workspace.current
        guard let url = tab.session.projectURL else {
            throw MCPToolFailure(message: "This document has no project location yet. Save it once in Compositor, then call this tool again.")
        }
        guard await tab.controller.save() else { throw MCPToolFailure(message: "Compositor could not save the project.") }
        return try result(["saved": true, "project_path": url.path])
    }

    private func renderDocument(_ arguments: [String: Any]) async throws -> [String: Any] {
        guard let snapshot = workspace.current.session.projectSnapshot() else {
            throw MCPToolFailure(message: "Create or open a document first.")
        }
        let maxSize = try arguments.optionalInteger("max_size", range: 64...8_192) ?? 2_048
        var raster = try await ImageExporter.shared.render(snapshot)
        let longest = max(raster.image.width, raster.image.height)
        if longest > maxSize {
            let scale = Double(maxSize) / Double(longest)
            raster = try await ImageExporter.shared.resized(raster,
                width: max(1, Int((Double(raster.image.width) * scale).rounded())),
                height: max(1, Int((Double(raster.image.height) * scale).rounded())))
        }
        let data = try await ImageExporter.shared.pngData(raster)
        return [
            "content": [
                ["type": "text", "text": "Rendered \(raster.image.width) × \(raster.image.height) PNG preview."],
                ["type": "image", "data": data.base64EncodedString(), "mimeType": "image/png"]
            ],
            "structuredContent": ["width": raster.image.width, "height": raster.image.height, "mime_type": "image/png"],
            "isError": false
        ]
    }

    private func documentSummary() throws -> [String: Any] {
        let tab = workspace.current
        guard let document = tab.session.document else { throw MCPToolFailure(message: "No document is open.") }
        var summary: [String: Any] = [
            "document_id": document.id.uuidString,
            "tab_name": tab.title,
            "width": document.width,
            "height": document.height,
            "resolution": document.resolution,
            "modified": tab.session.isModified,
            "active_layer_id": tab.session.activeLayerID?.uuidString ?? NSNull(),
            "layer_order": "bottom_to_top",
            "layers": document.layers.map(layerSummary)
        ]
        if let url = tab.session.projectURL { summary["project_path"] = url.path }
        return summary
    }

    private func layerSummary(_ layer: ImageLayer) -> [String: Any] {
        var summary: [String: Any] = [
            "id": layer.id.uuidString,
            "name": layer.name,
            "kind": layerKind(layer),
            "visible": layer.isVisible,
            "opacity": layer.opacity,
            "blend_mode": layer.blendMode.rawValue,
            "parent_id": layer.parentID?.uuidString ?? NSNull(),
            "transform": [
                "x": layer.transform.origin.x, "y": layer.transform.origin.y,
                "width": layer.transform.size.width, "height": layer.transform.size.height,
                "rotation": layer.transform.rotation,
                "flip_x": layer.transform.flipX, "flip_y": layer.transform.flipY
            ]
        ]
        if let vector = layer.liveVectorPath?.style {
            summary["vector_path"] = [
                "mode": vector.mode.rawValue.lowercased(), "closed": vector.closed,
                "color": "#" + vector.color.hex, "line_width": vector.lineWidth,
                "coordinate_space": "normalized_layer_bounds",
                "nodes": vector.nodes.map { [
                    "x": $0.anchor.x, "y": $0.anchor.y,
                    "in_x": $0.inHandle.x, "in_y": $0.inHandle.y,
                    "out_x": $0.outHandle.x, "out_y": $0.outHandle.y
                ] }
            ]
        }
        return summary
    }

    private func layerKind(_ layer: ImageLayer) -> String {
        if layer.isGroup { return "group" }
        if layer.liveVectorPath != nil { return "vector_path" }
        if layer.liveShape != nil { return "shape" }
        if layer.liveText != nil { return "text" }
        if layer.adjustment != nil { return "adjustment" }
        return layer.asset == nil ? "empty" : "raster"
    }

    private func result(_ structured: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: structured, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return [
            "content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]],
            "structuredContent": structured,
            "isError": false
        ]
    }

    private func failure(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    private static func tool(_ name: String, _ description: String, _ inputSchema: [String: Any],
                             readOnly: Bool = false, destructive: Bool, idempotent: Bool = false) -> [String: Any] {
        [
            "name": name, "description": description, "inputSchema": inputSchema,
            "annotations": ["readOnlyHint": readOnly, "destructiveHint": destructive,
                            "idempotentHint": idempotent, "openWorldHint": false]
        ]
    }

    private static func schema(properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        var value: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
        if !required.isEmpty { value["required"] = required }
        return value
    }

    private static func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
    private static func enumString(_ description: String, _ values: [String]) -> [String: Any] {
        ["type": "string", "description": description, "enum": values]
    }
    private static func number(_ description: String, minimum: Double? = nil, maximum: Double? = nil) -> [String: Any] {
        var value: [String: Any] = ["type": "number", "description": description]
        if let minimum { value["minimum"] = minimum }
        if let maximum { value["maximum"] = maximum }
        return value
    }
    private static func integer(_ description: String, minimum: Int, maximum: Int) -> [String: Any] {
        ["type": "integer", "description": description, "minimum": minimum, "maximum": maximum]
    }
}

private extension Dictionary where Key == String, Value == Any {
    func requiredString(_ key: String) throws -> String {
        guard let value = self[key] as? String else { throw MCPToolFailure(message: "\(key) must be a string.") }
        return value
    }

    func optionalString(_ key: String) throws -> String? {
        guard let value = self[key] else { return nil }
        guard let string = value as? String else { throw MCPToolFailure(message: "\(key) must be a string.") }
        return string
    }

    func requiredBoolean(_ key: String) throws -> Bool {
        guard let value = self[key] as? Bool else { throw MCPToolFailure(message: "\(key) must be true or false.") }
        return value
    }

    func optionalBoolean(_ key: String) throws -> Bool? {
        guard let value = self[key] else { return nil }
        guard let boolean = value as? Bool else { throw MCPToolFailure(message: "\(key) must be true or false.") }
        return boolean
    }

    func requiredNumber(_ key: String) throws -> Double {
        guard let value = number(key) else { throw MCPToolFailure(message: "\(key) must be a finite number.") }
        return value
    }

    func optionalNumber(_ key: String) throws -> Double? {
        guard self[key] != nil else { return nil }
        guard let value = number(key) else { throw MCPToolFailure(message: "\(key) must be a finite number.") }
        return value
    }

    func requiredInteger(_ key: String, range: ClosedRange<Int>) throws -> Int {
        guard let value = integer(key), range.contains(value) else {
            throw MCPToolFailure(message: "\(key) must be an integer from \(range.lowerBound) through \(range.upperBound).")
        }
        return value
    }

    func optionalInteger(_ key: String, range: ClosedRange<Int>) throws -> Int? {
        guard self[key] != nil else { return nil }
        guard let value = integer(key), range.contains(value) else {
            throw MCPToolFailure(message: "\(key) must be an integer from \(range.lowerBound) through \(range.upperBound).")
        }
        return value
    }

    func requiredUUID(_ key: String) throws -> UUID {
        let value = try requiredString(key)
        guard let uuid = UUID(uuidString: value) else { throw MCPToolFailure(message: "\(key) must be a UUID.") }
        return uuid
    }

    private func number(_ key: String) -> Double? {
        guard let number = self[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    private func integer(_ key: String) -> Int? {
        guard let value = number(key), value.rounded() == value,
              value >= Double(Int.min), value <= Double(Int.max) else { return nil }
        return Int(value)
    }
}
