import Foundation

/// MCP's JSON-RPC lifecycle and Streamable HTTP session rules. The server intentionally offers tools only: the
/// current document changes too frequently to be a stable resource, and tools let clients refresh it explicitly.
@MainActor
final class MCPProtocolHandler {
    static let currentProtocolVersion = "2025-11-25"
    static let supportedProtocolVersions = [currentProtocolVersion, "2025-06-18", "2025-03-26"]

    private struct Session {
        var initialized = false
        var lastUsed = Date()
        let protocolVersion: String
    }

    private let token: String
    private let router: MCPToolRouter
    private var sessions: [String: Session] = [:]

    init(workspace: ProjectWorkspace, token: String) {
        self.token = token
        router = MCPToolRouter(workspace: workspace)
    }

    func handle(_ request: MCPHTTPRequest) async -> MCPHTTPResponse {
        guard request.path == "/mcp" else { return MCPHTTPResponse(status: 404) }
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
            guard let decoded = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
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
        case "tools/list": return rpcResult(id: id, result: ["tools": MCPToolRouter.tools])
        case "tools/call":
            guard let params = object["params"] as? [String: Any], let name = params["name"] as? String else {
                return rpcError(id: id, code: -32_602, message: "tools/call requires a tool name.")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return rpcResult(id: id, result: await router.call(name: name, arguments: arguments))
        default: return rpcError(id: id, code: -32_601, message: "Method not found: \(method)")
        }
    }

    private func initialize(_ object: [String: Any]) -> MCPHTTPResponse {
        guard let id = object["id"], let params = object["params"] as? [String: Any],
              let requested = params["protocolVersion"] as? String else {
            return rpcError(id: object["id"] ?? NSNull(), code: -32_602, message: "initialize requires protocolVersion.")
        }
        let negotiated = Self.supportedProtocolVersions.contains(requested) ? requested : Self.currentProtocolVersion
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
            "instructions": "Use compositor_get_document before editing. Tool calls affect the current Compositor tab and are visible immediately. Use compositor_history to undo a change."
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

    private func validOrigin(_ origin: String?) -> Bool {
        guard let origin else { return true }
        guard let url = URL(string: origin), let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private func discardExpiredSessions() {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        sessions = sessions.filter { $0.value.lastUsed >= cutoff }
    }

    private func rpcResult(id: Any, result: [String: Any], headers: [String: String] = [:]) -> MCPHTTPResponse {
        MCPHTTPResponse.json(["jsonrpc": "2.0", "id": id, "result": result], headers: headers)
    }

    private func rpcError(id: Any, code: Int, message: String, status: Int = 200) -> MCPHTTPResponse {
        MCPHTTPResponse.json(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]], status: status)
    }
}
