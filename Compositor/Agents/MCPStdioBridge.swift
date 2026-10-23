import Foundation

/// Compositor's MCP server for apps that only start servers as commands talking over stdin and stdout, as Claude
/// Desktop's chat does: `Compositor --mcp-stdio` passes each JSON-RPC line on to the running editor's HTTP server (see
/// AgentServer) and writes back its reply, one line each. It starts no window and no Dock icon, and needs no Node.
/// Being the same app, it reads the port and token from the editor's own settings, so neither is written anywhere else.
enum MCPStdioBridge {
    static let argument = "--mcp-stdio"

    static func run() -> Never {
        while let line = readLine(strippingNewline: true) {
            guard let reply = reply(to: line, send: post) else { continue }
            FileHandle.standardOutput.write(Data((reply + "\n").utf8))
        }
        exit(0)
    }

    /// The line to write back for `line`, or nil when there's none (a notification, or a blank line). `send` posts a
    /// body to the server and returns the HTTP status and body; a failure becomes a JSON-RPC error saying what to do.
    static func reply(to line: String, send: (Data) throws -> (status: Int, body: Data)) -> String? {
        guard !line.allSatisfy(\.isWhitespace) else { return nil }
        let id = (try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)))?["id"]
        func failure(_ message: String) -> String? {
            // Only requests are answered; a notification that couldn't be delivered is simply lost.
            guard let id else { return nil }
            return String(data: MCPHandler.error(id: id, code: -32000, message: message).data, encoding: .utf8)
        }
        do {
            let (status, body) = try send(Data(line.utf8))
            switch status {
            case 200: return String(data: body, encoding: .utf8)?.trimmingCharacters(in: .newlines)
            case 202: return nil
            case 401: return failure("Compositor turned the token down: in Compositor › Agent Access, add Compositor to Claude Desktop again.")
            default: return failure("Compositor answered HTTP \(status).")
            }
        } catch {
            return failure("Compositor isn't answering. Open it and turn on Compositor › Agent Access › Let AI agents use Compositor.")
        }
    }

    /// Posts to the editor's server, as Agent Access set it up, and waits for the answer.
    private static func post(_ body: Data) throws -> (status: Int, body: Data) {
        let defaults = UserDefaults.standard
        let port = defaults.integer(forKey: "agentServer.port")
        guard let token = defaults.string(forKey: "agentServer.token"),
              let url = URL(string: "http://127.0.0.1:\(port == 0 ? Int(AgentServer.defaultPort) : port)/mcp") else {
            throw URLError(.userAuthenticationRequired)
        }
        var request = URLRequest(url: url, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<(Int, Data), Error> = .failure(URLError(.unknown))
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { result = .failure(error) }
            else { result = .success(((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data())) }
            done.signal()
        }.resume()
        done.wait()
        return try result.get()
    }
}
