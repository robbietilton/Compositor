import Foundation
import Network

nonisolated struct MCPHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

nonisolated struct MCPHTTPResponse {
    let status: Int
    var headers: [String: String] = [:]
    var body = Data()

    static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> MCPHTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        var responseHeaders = headers
        responseHeaders["Content-Type"] = "application/json"
        return MCPHTTPResponse(status: status, headers: responseHeaders, body: data)
    }
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

    static let maximumRequestBytes = 4 * 1_024 * 1_024
    private let port: UInt16
    private let handler: @MainActor (MCPHTTPRequest) async -> MCPHTTPResponse
    private let stateChanged: @MainActor (State) -> Void
    private let queue = DispatchQueue(label: "com.wonderassembly.compositor.mcp")
    private var listener: NWListener?

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
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(from: connection, accumulated: Data())
    }

    private func receive(from connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = accumulated
            if let data { accumulated.append(data) }
            guard accumulated.count <= Self.maximumRequestBytes else {
                Self.send(MCPHTTPResponse(status: 413), on: connection)
                return
            }
            do {
                if let request = try Self.parse(accumulated) {
                    let handler = self.handler
                    Task { @MainActor in
                        let response = await handler(request)
                        Self.send(response, on: connection)
                    }
                } else if complete || error != nil {
                    Self.send(MCPHTTPResponse(status: 400), on: connection)
                } else {
                    self.receive(from: connection, accumulated: accumulated)
                }
            } catch MCPHTTPParseError.requestTooLarge {
                Self.send(MCPHTTPResponse(status: 413), on: connection)
            } catch {
                Self.send(MCPHTTPResponse(status: 400), on: connection)
            }
        }
    }

    static func parse(_ data: Data) throws -> MCPHTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else {
            if data.count > 64 * 1_024 { throw MCPHTTPParseError.requestTooLarge }
            return nil
        }
        guard let header = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            throw MCPHTTPParseError.invalidRequest
        }
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw MCPHTTPParseError.invalidRequest }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { throw MCPHTTPParseError.invalidRequest }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw MCPHTTPParseError.invalidRequest }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { $0 + ", " + value } ?? value
        }
        let length: Int
        if let raw = headers["content-length"] {
            guard let parsed = Int(raw), parsed >= 0 else { throw MCPHTTPParseError.invalidRequest }
            length = parsed
        } else {
            length = 0
        }
        guard length <= maximumRequestBytes else { throw MCPHTTPParseError.requestTooLarge }
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + length else { return nil }
        let body = data.subdata(in: bodyStart..<(bodyStart + length))
        return MCPHTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers, body: body)
    }

    private static func send(_ response: MCPHTTPResponse, on connection: NWConnection) {
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
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        default: "Error"
        }
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        headers["Cache-Control"] = "no-store"
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}
