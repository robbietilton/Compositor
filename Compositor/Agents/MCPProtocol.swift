import Foundation

/// A JSON value as the Model Context Protocol carries it: requests and tool arguments in, results out.
nonisolated enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        // Whole numbers go out without a fraction, so ids and sizes read as the integers they are.
        case .number(let value):
            if value.rounded() == value, abs(value) < 9e15 { try container.encode(Int64(value)) } else { try container.encode(value) }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { object[key] } else { nil }
    }
    var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var number: Double? { if case .number(let value) = self { value } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var isNull: Bool { self == .null }

    static func encoding<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
    func decoded<T: Decodable>(as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
    var data: Data { (try? JSONEncoder.sorted.encode(self)) ?? Data("null".utf8) }

    /// `self` with `patch` written over it: objects merge key by key, all the way down, and a null in the patch
    /// takes its key away. Anything else in the patch replaces what was there.
    func merging(_ patch: JSONValue) -> JSONValue {
        guard case .object(var base) = self, case .object(let changes) = patch else { return patch }
        for (key, value) in changes {
            if value.isNull { base[key] = nil }
            else { base[key] = base[key].map { $0.merging(value) } ?? value }
        }
        return .object(base)
    }
}

/// Written as JSON is: `["width": 100, "name": "Sky"]`.
extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral,
                     ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    nonisolated init(stringLiteral value: String) { self = .string(value) }
    nonisolated init(integerLiteral value: Int) { self = .number(Double(value)) }
    nonisolated init(floatLiteral value: Double) { self = .number(value) }
    nonisolated init(booleanLiteral value: Bool) { self = .bool(value) }
    nonisolated init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    nonisolated init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(elements) { $1 }) }
    nonisolated init(nilLiteral: ()) { self = .null }
}

extension JSONEncoder {
    /// Keys in order, so the same value always reads the same way.
    nonisolated static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

/// The Model Context Protocol's JSON-RPC: initialize, ping, tools/list and tools/call. Stateless: each message stands
/// on its own, so no session is kept between requests and any number of agents can talk to the app at once.
@MainActor
final class MCPHandler {
    /// Newest first. A client asking for one of these gets it; any other gets the newest, and decides for itself.
    static let protocolVersions = ["2025-06-18", "2025-03-26"]
    let tools: [String: AgentTool]
    private let order: [String]
    private let workspace: ProjectWorkspace

    init(tools: [AgentTool], workspace: ProjectWorkspace) {
        self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        order = tools.map(\.name)
        self.workspace = workspace
    }

    /// The reply to a posted body, or nil when it held only notifications and responses, which get none.
    func handle(_ body: Data) async -> Data? {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: body) else {
            return Self.error(id: .null, code: -32700, message: "Parse error: the body isn't JSON.").data
        }
        if case .array(let batch) = message {
            var replies: [JSONValue] = []
            for item in batch { if let reply = await reply(to: item) { replies.append(reply) } }
            return replies.isEmpty ? nil : JSONValue.array(replies).data
        }
        return await reply(to: message)?.data
    }

    private func reply(to message: JSONValue) async -> JSONValue? {
        guard let method = message["method"]?.string else {
            // A response to something the server asked (it never asks), or nonsense: neither is answered.
            return message["id"] == nil || message["result"] != nil || message["error"] != nil
                ? nil : Self.error(id: message["id"] ?? .null, code: -32600, message: "Invalid request: no method.")
        }
        // Notifications (no id) are only listened to.
        guard let id = message["id"] else { return nil }
        let params = message["params"] ?? .object([:])
        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.string ?? ""
            let version = Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0]
            return Self.result(id: id, .object([
                "protocolVersion": .string(version),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object([
                    "name": .string("compositor"), "title": .string("Compositor"),
                    "version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"),
                ]),
                "instructions": .string(AgentTools.instructions),
            ]))
        case "ping":
            return Self.result(id: id, .object([:]))
        case "tools/list":
            return Self.result(id: id, .object(["tools": .array(order.compactMap { tools[$0]?.listing })]))
        case "tools/call":
            guard let name = params["name"]?.string else {
                return Self.error(id: id, code: -32602, message: "tools/call needs a tool name.")
            }
            guard let tool = tools[name] else {
                return Self.error(id: id, code: -32602, message: "No tool called “\(name)”. tools/list names them all.")
            }
            let arguments = params["arguments"] ?? .object([:])
            do {
                let result = try await tool.run(AgentCall(arguments: arguments.isNull ? .object([:]) : arguments, workspace: workspace))
                return Self.result(id: id, result.json)
            } catch {
                // Failures a tool reports are results the agent reads and acts on, not protocol errors.
                return Self.result(id: id, AgentResult.failure(error.localizedDescription).json)
            }
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method).")
        }
    }

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }
    static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }
}
