import Foundation
import Network
import Observation

/// Lets AI agents drive Compositor through the Model Context Protocol (MCP): a small HTTP server for this Mac only
/// (the loopback interface), off until the person turns it on in Agent Access, answering only requests that carry its
/// token. Each request is a JSON-RPC message posted to /mcp (MCP's Streamable HTTP transport), answered with plain
/// JSON; no event stream is kept open, as every tool returns its whole result.
@Observable
@MainActor
final class AgentServer {
    static let shared = AgentServer()
    static let defaultPort: UInt16 = 39271

    enum State: Equatable {
        case stopped, starting, running
        case failed(String)
    }
    private(set) var state = State.stopped

    var isEnabled = UserDefaults.standard.bool(forKey: "agentServer.enabled") {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "agentServer.enabled")
            if isEnabled { start() } else { stop() }
        }
    }
    var port = UInt16(exactly: UserDefaults.standard.integer(forKey: "agentServer.port")).flatMap { $0 == 0 ? nil : $0 } ?? AgentServer.defaultPort {
        didSet {
            UserDefaults.standard.set(Int(port), forKey: "agentServer.port")
            if isEnabled { stop(); start() }
        }
    }
    /// The secret every request must present (`Authorization: Bearer …`), so another app or a web page in a browser
    /// can't drive the editor. Made once; Make New Token replaces it, and agents set up with the old one stop working.
    private(set) var token = UserDefaults.standard.string(forKey: "agentServer.token") ?? AgentServer.storeNewToken()
    var endpoint: String { "http://127.0.0.1:\(port)/mcp" }
    /// What sets Claude Code up to use it, to paste in a terminal.
    var claudeCommand: String {
        "claude mcp add --transport http compositor \(endpoint) --header \"Authorization: Bearer \(token)\""
    }

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private weak var workspace: ProjectWorkspace?
    @ObservationIgnored private var handler: MCPHandler?

    /// Called once the editor's workspace exists; starts listening if the person left it on.
    func attach(_ workspace: ProjectWorkspace) {
        self.workspace = workspace
        handler = MCPHandler(tools: AgentTools.all, workspace: workspace)
        if isEnabled { start() }
    }

    func makeNewToken() {
        token = Self.storeNewToken()
    }
    private static func storeNewToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: "agentServer.token")
        return token
    }

    private func start() {
        guard listener == nil, handler != nil, let port = NWEndpoint.Port(rawValue: port) else { return }
        let parameters = NWParameters.tcp
        // This Mac only: nothing on the network can connect, whatever the firewall says.
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters, on: port)
            listener.stateUpdateHandler = { state in
                Task { @MainActor in AgentServer.shared.listenerChanged(state) }
            }
            listener.newConnectionHandler = { connection in
                Task { @MainActor in AgentServer.shared.accept(connection) }
            }
            state = .starting
            self.listener = listener
            listener.start(queue: .global(qos: .userInitiated))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        state = .stopped
    }

    private func listenerChanged(_ newState: NWListener.State) {
        switch newState {
        case .ready: state = .running
        case .failed(let error):
            listener?.cancel()
            listener = nil
            state = .failed(error == .posix(.EADDRINUSE) ? "Port \(port) is in use by another app. Choose another."
                                                          : error.localizedDescription)
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        let token = token
        let reader = HTTPRequestReader(connection: connection) { [weak self] request in
            guard let self else { return HTTPResponse(status: 503) }
            return await self.respond(to: request, token: token)
        }
        reader.start()
    }

    private func respond(to request: HTTPRequest, token: String) async -> HTTPResponse {
        // A web page can reach 127.0.0.1 from a browser; one that names another site as its origin is turned away
        // (DNS rebinding), as MCP asks of local servers.
        if let origin = request.headers["origin"], let host = URL(string: origin)?.host,
           !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) {
            return HTTPResponse(status: 403, body: Data("Forbidden origin".utf8), type: "text/plain")
        }
        guard request.headers["authorization"] == "Bearer \(token)" else {
            return HTTPResponse(status: 401, body: Data("Missing or wrong token: see Compositor › Agent Access".utf8), type: "text/plain",
                                extra: ["WWW-Authenticate": "Bearer"])
        }
        guard request.path.split(separator: "?").first == "/mcp" else { return HTTPResponse(status: 404) }
        guard request.method == "POST" else { return HTTPResponse(status: 405, extra: ["Allow": "POST"]) }
        guard let handler, let reply = await handler.handle(request.body) else { return HTTPResponse(status: 202) }
        return HTTPResponse(status: 200, body: reply, type: "application/json")
    }
}

nonisolated struct HTTPRequest: Sendable {
    var method: String
    var path: String
    /// Names in lowercase.
    var headers: [String: String]
    var body: Data
}

nonisolated struct HTTPResponse: Sendable {
    var status: Int
    var body = Data()
    var type: String?
    var extra: [String: String] = [:]

    var data: Data {
        let reasons = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                       405: "Method Not Allowed", 413: "Content Too Large", 503: "Service Unavailable"]
        var head = "HTTP/1.1 \(status) \(reasons[status] ?? "Status")\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if let type { head += "Content-Type: \(type)\r\n" }
        for (name, value) in extra { head += "\(name): \(value)\r\n" }
        return Data((head + "\r\n").utf8) + body
    }
}

/// Reads one HTTP/1.1 request off a connection (a Content-Length or chunked body), answers it, and closes the
/// connection: clients open a new one for each message, which keeps this small.
nonisolated final class HTTPRequestReader: @unchecked Sendable {
    /// A layer's image comes in as base64, so a request can be large; this is far beyond any canvas the app takes.
    static let maxRequestSize = 768 * 1024 * 1024
    private let connection: NWConnection
    private let respond: @Sendable (HTTPRequest) async -> HTTPResponse
    private var buffer = Data()

    init(connection: NWConnection, respond: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
        self.connection = connection
        self.respond = respond
    }

    func start() {
        connection.start(queue: .global(qos: .userInitiated))
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, complete, error in
            if let data { buffer.append(data) }
            if buffer.count > Self.maxRequestSize { send(HTTPResponse(status: 413)); return }
            switch Self.parse(buffer) {
            case .request(let request):
                Task { send(await respond(request)) }
            case .invalid:
                send(HTTPResponse(status: 400))
            case .incomplete:
                if complete || error != nil { connection.cancel() } else { receive() }
            }
        }
    }

    private func send(_ response: HTTPResponse) {
        connection.send(content: response.data, completion: .contentProcessed { [connection] _ in connection.cancel() })
    }

    enum Parsed { case request(HTTPRequest), incomplete, invalid }

    static func parse(_ buffer: Data) -> Parsed {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let rest = buffer[end.upperBound...]
        let body: Data
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let decoded = dechunk(rest) else { return .incomplete }
            body = decoded
        } else {
            let length = Int(headers["content-length"] ?? "0") ?? -1
            guard length >= 0 else { return .invalid }
            guard rest.count >= length else { return .incomplete }
            body = Data(rest.prefix(length))
        }
        return .request(HTTPRequest(method: String(start[0]), path: String(start[1]), headers: headers, body: body))
    }

    /// A chunked body put back together, or nil until its last (empty) chunk has arrived.
    static func dechunk(_ data: Data) -> Data? {
        var body = Data()
        var index = data.startIndex
        let newline = Data("\r\n".utf8)
        while true {
            guard let lineEnd = data.range(of: newline, in: index..<data.endIndex),
                  let line = String(data: data[index..<lineEnd.lowerBound], encoding: .ascii),
                  let size = Int(line.split(separator: ";").first.map(String.init) ?? "", radix: 16) else { return nil }
            let chunkStart = lineEnd.upperBound
            if size == 0 { return body }
            guard data.distance(from: chunkStart, to: data.endIndex) >= size + 2 else { return nil }
            let chunkEnd = data.index(chunkStart, offsetBy: size)
            body.append(data[chunkStart..<chunkEnd])
            index = data.index(chunkEnd, offsetBy: 2)
        }
    }
}
