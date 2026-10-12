import Foundation
import Network

nonisolated struct MCPHTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

nonisolated struct MCPHTTPResponse: Sendable {
    let status: Int
    var headers: [String: String] = [:]
    var body = Data()

    static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> MCPHTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        var responseHeaders = headers
        responseHeaders["Content-Type"] = "application/json"
        return MCPHTTPResponse(status: status, headers: responseHeaders, body: data)
    }

    /// Tool results can contain a multi-megabyte image. Encoding that JSON on the main actor visibly stalls canvas
    /// input, so only the small immutable JSON value crosses to a worker here.
    static func jsonOffMain(_ object: Any, status: Int = 200,
                            headers: [String: String] = [:]) async -> MCPHTTPResponse {
        let box = MCPUncheckedJSON(object)
        let data = await Task.detached(priority: .userInitiated) {
            (try? JSONSerialization.data(withJSONObject: box.value,
                options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        }.value
        var responseHeaders = headers
        responseHeaders["Content-Type"] = "application/json"
        return MCPHTTPResponse(status: status, headers: responseHeaders, body: data)
    }
}

nonisolated private final class MCPUncheckedJSON: @unchecked Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
}

nonisolated enum MCPHTTPParseError: Error {
    case invalidRequest
    case requestTooLarge
}

/// The small HTTP/1.1 surface needed by Streamable HTTP. Connections are deliberately closed after one request:
/// MCP sends each JSON-RPC message as its own POST, and this keeps the listener independent of browser behavior.
nonisolated final class MCPHTTPServer: @unchecked Sendable {
    enum State: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    static let maximumHeaderBytes = 64 * 1_024
    static let maximumBodyBytes = 4 * 1_024 * 1_024
    static let maximumRequestBytes = maximumHeaderBytes + maximumBodyBytes + 4
    static let maximumConnections = 32
    static let readTimeout: TimeInterval = 15
    private let port: UInt16
    private let handler: @MainActor (MCPHTTPRequest) async -> MCPHTTPResponse
    private let stateChanged: @MainActor (State) -> Void
    private let queue = DispatchQueue(label: "com.wonderassembly.compositor.mcp")
    private var listener: NWListener?
    private final class ConnectionState: @unchecked Sendable {
        let connection: NWConnection
        var data = Data()
        init(_ connection: NWConnection) { self.connection = connection }
    }
    /// Accessed only on `queue`. A limit and a fixed header deadline prevent a broken local client from retaining an
    /// unbounded number of four-megabyte receive buffers or holding the listener open one byte at a time.
    private var connections: [ObjectIdentifier: ConnectionState] = [:]
    private var reading: Set<ObjectIdentifier> = []

    init(port: UInt16,
         handler: @escaping @MainActor (MCPHTTPRequest) async -> MCPHTTPResponse,
         stateChanged: @escaping @MainActor (State) -> Void) {
        self.port = port
        self.handler = handler
        self.stateChanged = stateChanged
    }

    func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            let publicState: State
            switch state {
            case .setup, .waiting: publicState = .starting
            case .ready: publicState = .running
            case .failed(let error): publicState = .failed(error.localizedDescription)
            case .cancelled: publicState = .stopped
            @unknown default: publicState = .starting
            }
            Task { @MainActor in self.stateChanged(publicState) }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        Task { @MainActor in stateChanged(.starting) }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.async { [self] in
            for state in connections.values { state.connection.cancel() }
            connections.removeAll(keepingCapacity: true)
            reading.removeAll(keepingCapacity: true)
        }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < Self.maximumConnections else {
            connection.start(queue: queue)
            Self.sendAndClose(MCPHTTPResponse(status: 503), on: connection)
            return
        }
        let id = ObjectIdentifier(connection)
        let state = ConnectionState(connection)
        connections[id] = state
        reading.insert(id)
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.readTimeout) { [weak self, weak state] in
            guard let self, let state, self.reading.remove(id) != nil else { return }
            self.send(MCPHTTPResponse(status: 408), on: state.connection)
        }
        receive(state)
    }

    private func receive(_ state: ConnectionState) {
        let connection = state.connection
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self, weak state] data, _, complete, error in
            guard let self, let state else { connection.cancel(); return }
            if let data { state.data.append(data) }
            guard state.data.count <= Self.maximumRequestBytes else {
                self.reading.remove(ObjectIdentifier(connection))
                self.send(MCPHTTPResponse(status: 413), on: connection)
                return
            }
            do {
                if let request = try Self.parse(state.data) {
                    state.data.removeAll(keepingCapacity: false)
                    self.reading.remove(ObjectIdentifier(connection))
                    let handler = self.handler
                    Task { @MainActor [self] in
                        let response = await handler(request)
                        self.send(response, on: connection)
                    }
                } else if complete || error != nil {
                    self.reading.remove(ObjectIdentifier(connection))
                    self.send(MCPHTTPResponse(status: 400), on: connection)
                } else {
                    self.receive(state)
                }
            } catch MCPHTTPParseError.requestTooLarge {
                self.reading.remove(ObjectIdentifier(connection))
                self.send(MCPHTTPResponse(status: 413), on: connection)
            } catch {
                self.reading.remove(ObjectIdentifier(connection))
                self.send(MCPHTTPResponse(status: 400), on: connection)
            }
        }
    }

    static func parse(_ data: Data) throws -> MCPHTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else {
            if data.count > maximumHeaderBytes { throw MCPHTTPParseError.requestTooLarge }
            return nil
        }
        guard headerRange.lowerBound <= maximumHeaderBytes else { throw MCPHTTPParseError.requestTooLarge }
        guard let header = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            throw MCPHTTPParseError.invalidRequest
        }
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw MCPHTTPParseError.invalidRequest }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2] == "HTTP/1.0" || parts[2] == "HTTP/1.1" else {
            throw MCPHTTPParseError.invalidRequest
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw MCPHTTPParseError.invalidRequest }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw MCPHTTPParseError.invalidRequest }
            headers[name] = headers[name].map { $0 + ", " + value } ?? value
        }
        guard headers["transfer-encoding"] == nil else { throw MCPHTTPParseError.invalidRequest }
        let length: Int
        if let raw = headers["content-length"] {
            guard let parsed = Int(raw), parsed >= 0 else { throw MCPHTTPParseError.invalidRequest }
            length = parsed
        } else {
            length = 0
        }
        guard length <= maximumBodyBytes else { throw MCPHTTPParseError.requestTooLarge }
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + length else { return nil }
        guard data.count == bodyStart + length else { throw MCPHTTPParseError.invalidRequest }
        let body = data.subdata(in: bodyStart..<(bodyStart + length))
        return MCPHTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers, body: body)
    }

    private func send(_ response: MCPHTTPResponse, on connection: NWConnection) {
        Self.sendAndClose(response, on: connection) { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.queue.async {
                let id = ObjectIdentifier(connection)
                self.reading.remove(id)
                self.connections.removeValue(forKey: id)
            }
        }
    }

    private static func sendAndClose(_ response: MCPHTTPResponse, on connection: NWConnection,
                                     completion: @escaping @Sendable () -> Void = {}) {
        let reason: String = switch response.status {
        case 200: "OK"
        case 202: "Accepted"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 406: "Not Acceptable"
        case 408: "Request Timeout"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        case 503: "Service Unavailable"
        default: "Error"
        }
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        headers["Cache-Control"] = "no-store"
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        let body = response.body
        connection.send(content: Data(head.utf8), completion: .contentProcessed { error in
            guard error == nil, !body.isEmpty else {
                connection.cancel()
                completion()
                return
            }
            // Keep the large response body in its existing Data allocation. Concatenating it with the HTTP header on
            // the main actor doubled peak memory and paused input while returning rendered previews.
            connection.send(content: body, completion: .contentProcessed { _ in
                connection.cancel()
                completion()
            })
        })
    }
}
