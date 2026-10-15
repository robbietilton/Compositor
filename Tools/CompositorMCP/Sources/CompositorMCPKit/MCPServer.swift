import Foundation

public final class MCPServer {
    private let editor: PenProjectEditor
    private let encoder: JSONEncoder
    private let maximumMessageBytes = 4 * 1024 * 1024

    public init(editor: PenProjectEditor = PenProjectEditor()) {
        self.editor = editor
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    /// MCP's stdio transport: one UTF-8 JSON-RPC message per line. Content-Length framing is also accepted for
    /// compatibility with older local clients. Nothing except protocol messages is ever written to stdout.
    public func run(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        var buffer = Data()
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            guard buffer.count <= maximumMessageBytes else {
                write(errorResponse(id: NSNull(), code: -32600, message: "MCP message is too large"), to: output)
                return
            }
            while let message = nextMessage(in: &buffer) {
                guard let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any] else {
                    write(errorResponse(id: NSNull(), code: -32700, message: "Invalid JSON"), to: output)
                    continue
                }
                if let response = handle(object) { write(response, to: output) }
            }
        }
    }

    public func handle(_ request: [String: Any]) -> [String: Any]? {
        let id = request["id"] ?? NSNull()
        guard stringValue(request["jsonrpc"]) == "2.0", let method = stringValue(request["method"]) else {
            return errorResponse(id: id, code: -32600, message: "Invalid JSON-RPC request")
        }
        let notification = request["id"] == nil
        switch method {
        case "notifications/initialized", "notifications/cancelled":
            return nil
        case "initialize":
            guard !notification else { return nil }
            let params = request["params"] as? [String: Any]
            let requested = stringValue(params?["protocolVersion"])
            let supported = ["2024-11-05", "2025-03-26", "2025-06-18"]
            let version = requested.flatMap { supported.contains($0) ? $0 : nil } ?? "2025-06-18"
            return successResponse(id: id, result: [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "Compositor", "version": "1.0"],
                "instructions": "Edit Pen paths in saved .comp projects. Coordinates are document pixels. Open projects reload after each successful write."
            ])
        case "ping":
            return notification ? nil : successResponse(id: id, result: [:])
        case "tools/list":
            return notification ? nil : successResponse(id: id, result: ["tools": Self.toolDefinitions])
        case "tools/call":
            guard !notification else { return nil }
            guard let params = request["params"] as? [String: Any], let name = stringValue(params["name"]) else {
                return errorResponse(id: id, code: -32602, message: "Missing tool name")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                return successResponse(id: id, result: try callTool(name, arguments: arguments))
            } catch {
                return successResponse(id: id, result: [
                    "content": [["type": "text", "text": error.localizedDescription]],
                    "isError": true
                ])
            }
        default:
            return notification ? nil : errorResponse(id: id, code: -32601, message: "Method not found")
        }
    }

    private func callTool(_ name: String, arguments: [String: Any]) throws -> [String: Any] {
        let projectURL = try projectURL(arguments)
        switch name {
        case "compositor_list_pen_paths":
            let records = try editor.listPaths(in: projectURL)
            return try toolResult(["paths": jsonObject(records)])

        case "compositor_create_pen_path":
            let mode = try modeValue(arguments["mode"])
            let request = CreatePenPathRequest(
                name: optionalString(arguments["name"]),
                mode: mode,
                color: try colorValue(arguments["color"]) ?? PenColor(red: 0, green: 0, blue: 0),
                lineWidth: numberValue(arguments["line_width"]) ?? 4,
                nodes: try nodesValue(arguments["nodes"]),
                aboveLayerID: try optionalUUID(arguments["above_layer_id"])
            )
            let record = try editor.createPath(in: projectURL, request: request)
            return try toolResult(["path": jsonObject(record)])

        case "compositor_update_pen_path":
            let id = try requiredUUID(arguments["path_id"], name: "path_id")
            let hasChange = ["name", "mode", "color", "line_width", "nodes", "is_visible"].contains {
                arguments[$0] != nil
            }
            guard hasChange else { throw MCPInputError("At least one path property is required") }
            let request = UpdatePenPathRequest(
                name: optionalString(arguments["name"]),
                mode: try arguments["mode"].map { try modeValue($0) },
                color: try colorValue(arguments["color"]),
                lineWidth: numberValue(arguments["line_width"]),
                nodes: try arguments["nodes"].map { try nodesValue($0) },
                isVisible: boolValue(arguments["is_visible"])
            )
            let record = try editor.updatePath(in: projectURL, id: id, request: request)
            return try toolResult(["path": jsonObject(record)])

        case "compositor_delete_pen_path":
            let id = try requiredUUID(arguments["path_id"], name: "path_id")
            try editor.deletePath(in: projectURL, id: id)
            return try toolResult(["deleted_path_id": id.uuidString])

        case "compositor_inspect_pen_path_geometry":
            let id = try requiredUUID(arguments["path_id"], name: "path_id")
            guard let record = try editor.listPaths(in: projectURL).first(where: { $0.id == id }) else {
                throw PenProjectError.pathNotFound
            }
            let fractions = try fractionValues(arguments["fractions"])
            let samples = try editor.samples(for: record, at: fractions)
            return try toolResult(["path": jsonObject(record), "samples": jsonObject(samples)])

        default:
            throw MCPInputError("Unknown tool: \(name)")
        }
    }

    private func toolResult(_ structured: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: structured, options: [.prettyPrinted, .sortedKeys])
        return [
            "content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]],
            "structuredContent": structured,
            "isError": false
        ]
    }

    private func projectURL(_ arguments: [String: Any]) throws -> URL {
        guard let path = optionalString(arguments["project_path"]), !path.isEmpty else {
            throw MCPInputError("project_path is required")
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    private func nodesValue(_ value: Any?) throws -> [PenPathNode] {
        guard let values = value as? [[String: Any]], values.count <= 10_000 else {
            throw MCPInputError("nodes must be an array with at most 10,000 entries")
        }
        return try values.map { value in
            let anchor = try pointValue(value["anchor"], name: "anchor")
            return PenPathNode(anchor: anchor,
                               inHandle: try value["in_handle"].map { try pointValue($0, name: "in_handle") },
                               outHandle: try value["out_handle"].map { try pointValue($0, name: "out_handle") })
        }
    }

    private func pointValue(_ value: Any?, name: String) throws -> PenPoint {
        guard let point = value as? [String: Any], let x = numberValue(point["x"]),
              let y = numberValue(point["y"]) else { throw MCPInputError("\(name) needs numeric x and y") }
        return PenPoint(x: x, y: y)
    }

    private func colorValue(_ value: Any?) throws -> PenColor? {
        guard let value else { return nil }
        guard let color = value as? [String: Any], let red = numberValue(color["red"]),
              let green = numberValue(color["green"]), let blue = numberValue(color["blue"]) else {
            throw MCPInputError("color needs red, green, and blue values")
        }
        return PenColor(red: red, green: green, blue: blue)
    }

    private func modeValue(_ value: Any?) throws -> PenPathMode {
        guard let raw = optionalString(value), let mode = PenPathMode(rawValue: raw) else {
            throw MCPInputError("mode must be Shape or Line")
        }
        return mode
    }

    private func fractionValues(_ value: Any?) throws -> [Double] {
        guard let value else { return [0, 0.25, 0.5, 0.75, 1] }
        guard let values = value as? [Any], values.count <= 1_000 else {
            throw MCPInputError("fractions must be an array with at most 1,000 entries")
        }
        let numbers = try values.map { value -> Double in
            guard let result = numberValue(value) else { throw MCPInputError("fractions must be numbers") }
            return result
        }
        return numbers
    }

    private func requiredUUID(_ value: Any?, name: String) throws -> UUID {
        guard let raw = optionalString(value), let id = UUID(uuidString: raw) else {
            throw MCPInputError("\(name) must be a UUID")
        }
        return id
    }

    private func optionalUUID(_ value: Any?) throws -> UUID? {
        guard value != nil else { return nil }
        return try requiredUUID(value, name: "above_layer_id")
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: encoder.encode(value))
    }

    private func nextMessage(in buffer: inout Data) -> Data? {
        if buffer.starts(with: Data("Content-Length:".utf8)) {
            guard let marker = buffer.range(of: Data("\r\n\r\n".utf8)),
                  let header = String(data: buffer[..<marker.lowerBound], encoding: .utf8) else { return nil }
            let length = header.split(separator: "\n").first(where: { $0.lowercased().hasPrefix("content-length:") })
                .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") }
            guard let length, length <= maximumMessageBytes else { buffer.removeAll(); return nil }
            let start = marker.upperBound
            guard buffer.count >= start + length else { return nil }
            let message = buffer.subdata(in: start..<(start + length))
            buffer.removeSubrange(0..<(start + length))
            return message
        }
        guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
        var message = buffer.subdata(in: 0..<newline)
        buffer.removeSubrange(0...newline)
        if message.last == 0x0D { message.removeLast() }
        return message.isEmpty ? nextMessage(in: &buffer) : message
    }

    private func write(_ response: [String: Any], to output: FileHandle) {
        guard let data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]) else { return }
        var line = data
        line.append(0x0A)
        try? output.write(contentsOf: line)
    }

    private func successResponse(id: Any, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func errorResponse(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private static let pointSchema: [String: Any] = [
        "type": "object",
        "properties": ["x": ["type": "number"], "y": ["type": "number"]],
        "required": ["x", "y"],
        "additionalProperties": false
    ]

    private static let nodeSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "anchor": pointSchema,
            "in_handle": pointSchema,
            "out_handle": pointSchema
        ],
        "required": ["anchor"],
        "additionalProperties": false
    ]

    private static let colorSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "red": ["type": "number", "minimum": 0, "maximum": 1],
            "green": ["type": "number", "minimum": 0, "maximum": 1],
            "blue": ["type": "number", "minimum": 0, "maximum": 1]
        ],
        "required": ["red", "green", "blue"],
        "additionalProperties": false
    ]

    private static let toolDefinitions: [[String: Any]] = [
        [
            "name": "compositor_list_pen_paths",
            "description": "List every editable Pen path in a saved Compositor project. Returns document-pixel anchors and Bezier handles.",
            "inputSchema": objectSchema(properties: ["project_path": ["type": "string"]], required: ["project_path"])
        ],
        [
            "name": "compositor_create_pen_path",
            "description": "Create an editable closed Shape path or open Line path in a .comp project without painting pixels. Handles are optional and default to their anchor. The open Compositor canvas reloads the saved result.",
            "inputSchema": objectSchema(properties: [
                "project_path": ["type": "string"],
                "name": ["type": "string"],
                "mode": ["type": "string", "enum": ["Shape", "Line"]],
                "color": colorSchema,
                "line_width": ["type": "number", "minimum": 1, "maximum": 5_000],
                "nodes": ["type": "array", "items": nodeSchema, "maxItems": 10_000],
                "above_layer_id": ["type": "string", "format": "uuid"]
            ], required: ["project_path", "mode", "nodes"])
        ],
        [
            "name": "compositor_update_pen_path",
            "description": "Edit a Pen path by layer UUID. Supply only properties to change; replacing nodes supports moving, adding or deleting anchors and handles.",
            "inputSchema": objectSchema(properties: [
                "project_path": ["type": "string"],
                "path_id": ["type": "string", "format": "uuid"],
                "name": ["type": "string"],
                "mode": ["type": "string", "enum": ["Shape", "Line"]],
                "color": colorSchema,
                "line_width": ["type": "number", "minimum": 1, "maximum": 5_000],
                "nodes": ["type": "array", "items": nodeSchema, "maxItems": 10_000],
                "is_visible": ["type": "boolean"]
            ], required: ["project_path", "path_id"])
        ],
        [
            "name": "compositor_delete_pen_path",
            "description": "Delete an editable Pen path layer. Refuses deletion when another layer uses it as a live mask source.",
            "inputSchema": objectSchema(properties: [
                "project_path": ["type": "string"],
                "path_id": ["type": "string", "format": "uuid"]
            ], required: ["project_path", "path_id"])
        ],
        [
            "name": "compositor_inspect_pen_path_geometry",
            "description": "Inspect path length and arc-length samples for text-on-path, arrowheads or generated decoration. Samples include position, tangent, normal and angle.",
            "inputSchema": objectSchema(properties: [
                "project_path": ["type": "string"],
                "path_id": ["type": "string", "format": "uuid"],
                "fractions": ["type": "array", "items": ["type": "number", "minimum": 0, "maximum": 1], "maxItems": 1_000]
            ], required: ["project_path", "path_id"])
        ]
    ]

    private static func objectSchema(properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }
}

private struct MCPInputError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func stringValue(_ value: Any?) -> String? { value as? String }
private func optionalString(_ value: Any?) -> String? { value as? String }
private func numberValue(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
private func boolValue(_ value: Any?) -> Bool? { (value as? NSNumber)?.boolValue }
