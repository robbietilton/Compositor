// RPC error conventions adapted from compositor-mcp (MIT), Copyright 2026 Marcus Horndt.
// See docs/licenses/compositor-mcp-MIT.txt.
import Foundation
import CoreFoundation

struct RPCError: Error, LocalizedError {
    let code: Int
    let message: String
    var errorDescription: String? { message }
    static func invalidParams(_ message: String) -> RPCError { .init(code: -32602, message: message) }
    static func internalError(_ message: String) -> RPCError { .init(code: -32603, message: message) }
    static func methodNotFound(_ message: String) -> RPCError { .init(code: -32601, message: message) }
}

/// MCP is transported over stdio by the small bundled bridge. This router lives in the
/// GUI process so every tool reads and edits the same sessions as the human user.
@MainActor
final class MCPRouter {
    let workspace: ProjectWorkspace
    let editor: EditorAutomation
    private var running = false
    private var htmlSources: [UUID: [String: String]] = [:]
    init(workspace: ProjectWorkspace) {
        self.workspace = workspace
        self.editor = EditorAutomation(workspace: workspace)
    }
    var tools: [[String: Any]] {
        editor.tools + [["name": "import_html", "description": "Import self-contained HTML/CSS as a NEW visible project tab. Simple text and shapes stay editable; unsupported CSS may be rasterized, with warnings. No page scripts, network or local-file URLs. Embed images/fonts as data URLs. Coordinates are canvas pixels. Returns tab state and conversion warnings.",
          "inputSchema": ["type": "object", "additionalProperties": false,
            "properties": ["html": ["type": "string", "maxLength": 2_000_000], "css": ["type": "string", "maxLength": 1_000_000], "name": ["type": "string", "maxLength": 200], "width": ["type": "integer", "minimum": 1, "maximum": 4096], "height": ["type": "integer", "minimum": 1, "maximum": 4096]], "required": ["html", "width", "height"]],
          "annotations": ["readOnlyHint": false, "destructiveHint": false, "openWorldHint": false]]]
    }
    func handle(_ request: [String: Any]) async -> [String: Any]? {
        let id = request["id"] ?? NSNull()
        let isNotification = request["id"] == nil
        guard request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String,
              request["params"] == nil || request["params"] is [String: Any],
              id is NSNull || id is String || (id is NSNumber && CFGetTypeID(id as CFTypeRef) != CFBooleanGetTypeID()) else {
            return error(id, -32600, "Invalid JSON-RPC request")
        }
        if isNotification { return nil }
        let params = request["params"] as? [String: Any] ?? [:]
        do {
            let result: [String: Any]
            switch method {
            case "initialize":
                let versions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
                let requested = params["protocolVersion"] as? String ?? ""
                result = ["protocolVersion": versions.contains(requested) ? requested : versions[0],
                          "capabilities": ["tools": ["listChanged": false], "resources": ["subscribe": false, "listChanged": false]],
                          "serverInfo": ["name": "compositor", "version": "1.0.0"],
                          "instructions": "Edits apply to live Compositor tabs and use native undo. Read list_documents/describe_document before editing. Use document_id explicitly. Busy tools fail rather than interrupting a human edit. import_html creates a new tab. Read compositor://guide for details."]
            case "ping": result = [:]
            case "tools/list": result = ["tools": tools]
            case "tools/call":
                guard let name = params["name"] as? String, tools.contains(where: { $0["name"] as? String == name }) else { throw RPCError.invalidParams("Unknown tool") }
                guard params["arguments"] == nil || params["arguments"] is [String: Any] else { throw RPCError.invalidParams("arguments must be an object") }
                guard !Task.isCancelled else { return success(id, Self.toolError("Operation cancelled before it started.")) }
                guard !running else { return success(id, Self.toolError("Another agent operation is in progress. Retry after it completes.")) }
                running = true
                defer { running = false }
                do {
                    let args = params["arguments"] as? [String: Any] ?? [:]
                    try validateArguments(args, tool: name)
                    try Task.checkCancellation()
                    if name == "import_html" { result = try await importHTML(args) }
                    else { result = try await editor.call(name, arguments: args) }
                } catch { result = Self.toolError(error.localizedDescription) }
            case "resources/list":
                result = ["resources": [["uri": "compositor://guide", "name": "Agent editing guide", "mimeType": "text/plain"]] + workspace.tabs.map { ["uri": "compositor://documents/\($0.id.uuidString)", "name": $0.title, "mimeType": "application/json"] }]
            case "resources/templates/list":
                result = ["resourceTemplates": [["uriTemplate": "compositor://documents/{document_id}", "name": "Live document state", "mimeType": "application/json"], ["uriTemplate": "compositor://html/{document_id}", "name": "Imported HTML/CSS source", "mimeType": "application/json"]]]
            case "resources/read":
                guard let uri = params["uri"] as? String else { throw RPCError.invalidParams("uri is required") }
                let value: String
                if uri == "compositor://guide" {
                    value = "Compositor live editing: list_documents returns stable tab IDs; pass document_id to tools. describe_document exposes the complete layer manifest. Edits use native history. A busy human session or another request is rejected. All coordinates are document pixels, with origin at top left. Import images as base64 data for sandbox-safe access. HTML import accepts self-contained markup/styles, supports embedded data assets, disables author scripts and external resources, and reports raster fallbacks. Complex browser effects cannot always become native editable layers. Imported HTML source is available for this app session at compositor://html/{document_id}. Save your .comp to preserve the editable document. Disable Agent Connection in the app menu to revoke all clients."
                } else if uri.hasPrefix("compositor://documents/"), let uuid = UUID(uuidString: String(uri.dropFirst("compositor://documents/".count))), workspace.tabs.contains(where: { $0.id == uuid }) {
                    let state = try await editor.call("describe_document", arguments: ["document_id": uuid.uuidString])
                    value = String(data: try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), encoding: .utf8)!
                } else if uri.hasPrefix("compositor://html/"), let uuid = UUID(uuidString: String(uri.dropFirst("compositor://html/".count))), let source = htmlSources[uuid], workspace.tabs.contains(where: { $0.id == uuid }) {
                    value = String(data: try JSONSerialization.data(withJSONObject: source), encoding: .utf8)!
                } else { throw RPCError(code: -32002, message: "Resource not found") }
                result = ["contents": [["uri": uri, "mimeType": uri == "compositor://guide" ? "text/plain" : "application/json", "text": value]]]
            default: throw RPCError.methodNotFound("Unknown method: \(method)")
            }
            return success(id, result)
        } catch let e as RPCError { return error(id, e.code, e.message) }
        catch { return self.error(id, -32603, error.localizedDescription) }
    }
    private func importHTML(_ args: [String: Any]) async throws -> [String: Any] {
        try editor.requireWorkspaceReady()
        guard let html = args["html"] as? String, !html.isEmpty,
              let width = args["width"] as? Int, let height = args["height"] as? Int,
              (1...4096).contains(width), (1...4096).contains(height), width * height <= 16_000_000 else { throw RPCError.invalidParams("Supply html and integer width/height up to 4096 and 16 megapixels total.") }
        let css = args["css"] as? String ?? ""
        let name = args["name"] as? String ?? "HTML Design"
        // Reserve workspace during async WebKit rendering; never replace a tab being edited.
        workspace.isManaging = true
        defer { workspace.isManaging = false }
        let imported = try await HTMLDesignImporter.importDesign(html: html, css: css, width: width, height: height, name: name)
        try Task.checkCancellation()
        let tab = workspace.addTab(reuseEmpty: false, name: name)
        tab.session.installProject(imported.snapshot, from: URL(fileURLWithPath: "/\(UUID()).comp"))
        tab.session.projectURL = nil
        tab.session.showsNewDocument = false
        // Installing a new imported document must remain unsaved.
        tab.session.history.reset()
        tab.session.history.begin("Import HTML", document: nil, selection: nil)
        tab.session.history.end(document: tab.session.document, selection: tab.session.activeLayerID)
        htmlSources = htmlSources.filter { id, _ in workspace.tabs.contains(where: { $0.id == id }) }
        htmlSources[tab.id] = ["html": html, "css": css, "name": name]
        let info: [String: Any] = ["document_id": tab.id.uuidString, "name": name, "layer_count": imported.snapshot.manifest.layers.count, "warnings": imported.warnings, "source_uri": "compositor://html/\(tab.id.uuidString)"]
        return ["content": [["type": "text", "text": String(data: try JSONSerialization.data(withJSONObject: info), encoding: .utf8)!]], "structuredContent": info, "isError": false]
    }
    private func validateArguments(_ args: [String: Any], tool: String) throws {
        guard let schema = tools.first(where: { $0["name"] as? String == tool })?["inputSchema"] as? [String: Any] else { return }
        try validate(args, schema: schema, path: "arguments", depth: 0)
    }
    private func validate(_ value: Any, schema: [String: Any], path: String, depth: Int) throws {
        guard depth <= 32 else { throw RPCError.invalidParams("Arguments are nested too deeply") }
        let type = schema["type"] as? String
        var valid = true
        switch type {
        case "object":
            guard let object = value as? [String: Any] else { throw RPCError.invalidParams("\(path) must be an object") }
            let props = schema["properties"] as? [String: [String: Any]] ?? [:]
            for key in schema["required"] as? [String] ?? [] where object[key] == nil { throw RPCError.invalidParams("Missing \(path).\(key)") }
            for (key, child) in object {
                if let rule = props[key] { try validate(child, schema: rule, path: "\(path).\(key)", depth: depth + 1) }
                else if schema["additionalProperties"] as? Bool == false { throw RPCError.invalidParams("Unknown argument \(path).\(key)") }
                else { try validateUntyped(child, depth: depth + 1) }
            }
        case "array":
            guard let array = value as? [Any], array.count <= (schema["maxItems"] as? Int ?? 4096) else { throw RPCError.invalidParams("\(path) must be a bounded array") }
            let rule = schema["items"] as? [String: Any] ?? [:]
            for (index, child) in array.enumerated() { try validate(child, schema: rule, path: "\(path)[\(index)]", depth: depth + 1) }
        case "string":
            valid = value is String
            if let str = value as? String { valid = str.utf8.count <= (schema["maxLength"] as? Int ?? 48_000_000) }
        case "boolean": valid = value is NSNumber && CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
        case "number", "integer":
            if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                let n = number.doubleValue
                valid = n.isFinite && (type != "integer" || n.rounded() == n) && abs(n) <= 1_000_000_000
                if let min = schema["minimum"] as? NSNumber { valid = valid && n >= min.doubleValue }
                if let max = schema["maximum"] as? NSNumber { valid = valid && n <= max.doubleValue }
            } else { valid = false }
        default: try validateUntyped(value, depth: depth)
        }
        if let options = schema["enum"] as? [String], let str = value as? String { valid = valid && options.contains(str) }
        guard valid else { throw RPCError.invalidParams("Invalid \(path): expected \(type ?? "value") within documented limits") }
    }
    private func validateUntyped(_ value: Any, depth: Int) throws {
        guard depth <= 32 else { throw RPCError.invalidParams("Arguments are nested too deeply") }
        if let object = value as? [String: Any] {
            guard object.count <= 1024 else { throw RPCError.invalidParams("Object has too many fields") }
            for child in object.values { try validateUntyped(child, depth: depth + 1) }
        } else if let array = value as? [Any] {
            guard array.count <= 4096 else { throw RPCError.invalidParams("Array has too many elements") }
            for child in array { try validateUntyped(child, depth: depth + 1) }
        } else if let number = value as? NSNumber, !number.doubleValue.isFinite { throw RPCError.invalidParams("Non-finite number") }
    }
    static func toolError(_ message: String) -> [String: Any] { ["isError": true, "content": [["type": "text", "text": message]]] }
    private func success(_ id: Any, _ result: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }
    private func error(_ id: Any, _ code: Int, _ message: String) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]] }
}
