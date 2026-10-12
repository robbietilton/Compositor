import Foundation

nonisolated private final class MCPDecodedJSON: @unchecked Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
}

/// MCP's JSON-RPC lifecycle and Streamable HTTP session rules. The server intentionally offers tools only: the
/// current document changes too frequently to be a stable resource, and tools let clients refresh it explicitly.
@MainActor
final class MCPProtocolHandler {
    static let currentProtocolVersion = "2025-11-25"
    static let supportedProtocolVersions = [currentProtocolVersion, "2025-06-18", "2025-03-26"]
    static let maximumSessions = 32

    private struct Session {
        var initialized = false
        var lastUsed = Date()
        let protocolVersion: String
    }

    private let token: String
    private let callTool: @MainActor (String, [String: Any]) async -> [String: Any]
    private var sessions: [String: Session] = [:]
    private var toolCallActive = false

    init(workspace: ProjectWorkspace, token: String) {
        self.token = token
        let router = MCPToolRouter(workspace: workspace)
        callTool = { name, arguments in await router.call(name: name, arguments: arguments) }
    }

    init(token: String, callTool: @escaping @MainActor (String, [String: Any]) async -> [String: Any]) {
        self.token = token
        self.callTool = callTool
    }

    func handle(_ request: MCPHTTPRequest) async -> MCPHTTPResponse {
        guard request.path == "/mcp" else { return MCPHTTPResponse(status: 404) }
        guard validHost(request.headers["host"]) else { return MCPHTTPResponse(status: 403) }
        guard validOrigin(request.headers["origin"]) else { return MCPHTTPResponse(status: 403) }
        guard request.headers["authorization"] == "Bearer \(token)" else {
            return MCPHTTPResponse(status: 401, headers: ["WWW-Authenticate": "Bearer"])
        }
        discardExpiredSessions()

        switch request.method.uppercased() {
        case "GET": return MCPHTTPResponse(status: 405, headers: ["Allow": "POST, DELETE"])
        case "DELETE": return deleteSession(request)
        case "POST": return await post(request)
        default: return MCPHTTPResponse(status: 405, headers: ["Allow": "POST, DELETE"])
        }
    }

    private func post(_ request: MCPHTTPRequest) async -> MCPHTTPResponse {
        guard request.headers["content-type"]?.lowercased().contains("application/json") == true else {
            return MCPHTTPResponse(status: 415)
        }
        let object: [String: Any]
        do {
            let data = request.body
            let decoded = try await Task.detached(priority: .userInitiated) {
                MCPDecodedJSON(try JSONSerialization.jsonObject(with: data))
            }.value
            guard let decoded = decoded.value as? [String: Any] else {
                return rpcError(id: NSNull(), code: -32_600, message: "Invalid Request", status: 400)
            }
            object = decoded
        } catch {
            return rpcError(id: NSNull(), code: -32_700, message: "Parse error", status: 400)
        }
        guard object["jsonrpc"] as? String == "2.0", let method = object["method"] as? String else {
            return rpcError(id: object["id"] ?? NSNull(), code: -32_600, message: "Invalid Request", status: 400)
        }
        if method == "initialize" { return initialize(object) }

        guard validProtocolHeader(request) else {
            return rpcError(id: object["id"] ?? NSNull(), code: -32_602, message: "Unsupported MCP-Protocol-Version", status: 400)
        }
        guard let sessionID = request.headers["mcp-session-id"], var session = sessions[sessionID] else {
            return rpcError(id: object["id"] ?? NSNull(), code: -32_600, message: "A valid MCP-Session-Id header is required.", status: 400)
        }
        if let version = request.headers["mcp-protocol-version"], version != session.protocolVersion {
            return rpcError(id: object["id"] ?? NSNull(), code: -32_602,
                            message: "MCP-Protocol-Version does not match this session.", status: 400)
        }
        session.lastUsed = Date()

        if method == "notifications/initialized" {
            session.initialized = true
            sessions[sessionID] = session
            return MCPHTTPResponse(status: 202)
        }
        sessions[sessionID] = session
        // Notifications carry no id and receive only the transport acknowledgement.
        guard let id = object["id"] else { return MCPHTTPResponse(status: 202) }
        if method == "ping" { return rpcResult(id: id, result: [:]) }
        guard session.initialized else {
            return rpcError(id: id, code: -32_000, message: "Send notifications/initialized before using tools.")
        }
        switch method {
        case "tools/list": return await rpcResultOffMain(id: id, result: ["tools": MCPToolRouter.tools])
        case "tools/call":
            guard let params = object["params"] as? [String: Any], let name = params["name"] as? String else {
                return rpcError(id: id, code: -32_602, message: "tools/call requires a tool name.")
            }
            guard !toolCallActive else {
                return rpcResult(id: id, result: toolFailure("Another MCP tool is still running. Try again when it finishes."))
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            toolCallActive = true
            let result = await callTool(name, arguments)
            toolCallActive = false
            return await rpcResultOffMain(id: id, result: result)
        default: return rpcError(id: id, code: -32_601, message: "Method not found: \(method)")
        }
    }

    private func initialize(_ object: [String: Any]) -> MCPHTTPResponse {
        guard let id = object["id"], let params = object["params"] as? [String: Any],
              let requested = params["protocolVersion"] as? String else {
            return rpcError(id: object["id"] ?? NSNull(), code: -32_602, message: "initialize requires protocolVersion.")
        }
        let negotiated = Self.supportedProtocolVersions.contains(requested) ? requested : Self.currentProtocolVersion
        if sessions.count >= Self.maximumSessions,
           let oldest = sessions.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
            sessions.removeValue(forKey: oldest)
        }
        let sessionID = UUID().uuidString.lowercased()
        sessions[sessionID] = Session(protocolVersion: negotiated)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let result: [String: Any] = [
            "protocolVersion": negotiated,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": [
                "name": "compositor",
                "title": "Compositor",
                "version": version,
                "description": "Create and edit the current Compositor canvas."
            ],
            "instructions": "Use compositor_get_document before editing. Coordinates use document pixels with the origin at the top-left. Prefer editable shape, text, and vector-path tools over painting when possible. Use compositor_manage_mask to create or select a layer mask before painting or applying a gradient to the mask target. Tool calls affect the current Compositor tab and are visible immediately. Render after meaningful edits to inspect the result, use compositor_history to undo, and save only when the user asks."
        ]
        return rpcResult(id: id, result: result, headers: [
            "MCP-Session-Id": sessionID,
            "MCP-Protocol-Version": negotiated
        ])
    }

    private func deleteSession(_ request: MCPHTTPRequest) -> MCPHTTPResponse {
        guard let sessionID = request.headers["mcp-session-id"] else { return MCPHTTPResponse(status: 400) }
        guard sessions.removeValue(forKey: sessionID) != nil else { return MCPHTTPResponse(status: 404) }
        return MCPHTTPResponse(status: 204)
    }

    private func validProtocolHeader(_ request: MCPHTTPRequest) -> Bool {
        guard let version = request.headers["mcp-protocol-version"] else { return true }
        return Self.supportedProtocolVersions.contains(version)
    }

    private func validHost(_ value: String?) -> Bool {
        guard let value, !value.contains(","),
              let url = URL(string: "http://\(value)"), let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private func validOrigin(_ origin: String?) -> Bool {
        guard let origin else { return true }
        guard let url = URL(string: origin), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private func discardExpiredSessions() {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        sessions = sessions.filter { $0.value.lastUsed >= cutoff }
    }

    private func rpcResult(id: Any, result: [String: Any], headers: [String: String] = [:]) -> MCPHTTPResponse {
        MCPHTTPResponse.json(["jsonrpc": "2.0", "id": id, "result": result], headers: headers)
    }

    private func rpcResultOffMain(id: Any, result: [String: Any]) async -> MCPHTTPResponse {
        await MCPHTTPResponse.jsonOffMain(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func rpcError(id: Any, code: Int, message: String, status: Int = 200) -> MCPHTTPResponse {
        MCPHTTPResponse.json(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]], status: status)
    }

    private func toolFailure(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }
}
