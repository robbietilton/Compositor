import AppKit
import Observation
@preconcurrency import Network

/// Loopback-only authenticated rendezvous for the stdio bridge. This private wire
/// is deliberately not an HTTP endpoint (web pages cannot invoke editor commands).
@MainActor @Observable
final class AutomationService {
    private(set) var isEnabled = false
    private(set) var status = "Disabled"
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connections: [UUID: NWConnection] = [:]
    @ObservationIgnored private var requestTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var router: MCPRouter
    @ObservationIgnored private var token = ""
    @ObservationIgnored private var generation = UUID()
    static let maximumBytes = 40 * 1024 * 1024
    static let maximumConnections = 4
    static var endpointURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Compositor/automation.json")
    }
    init(workspace: ProjectWorkspace) { router = MCPRouter(workspace: workspace) }
    func restore() {
        guard NSClassFromString("XCTestCase") == nil, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        if UserDefaults.standard.bool(forKey: "CompositorAutomationEnabled") || ProcessInfo.processInfo.arguments.contains("--enable-automation") { start() }
    }
    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            let epoch = UUID()
            generation = epoch
            token = UUID().uuidString + UUID().uuidString
            self.listener = listener
            isEnabled = true
            status = "Starting…"
            UserDefaults.standard.set(true, forKey: "CompositorAutomationEnabled")
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor [weak self, weak listener] in
                    guard let self, self.generation == epoch else { return }
                    switch state {
                    case .ready:
                        guard let port = listener?.port else { self.fail("No local port assigned"); return }
                        do {
                            let url = Self.endpointURL
                            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                            let data = try JSONSerialization.data(withJSONObject: ["port": Int(port.rawValue), "token": self.token, "pid": ProcessInfo.processInfo.processIdentifier, "protocol": 1])
                            // Restrictive permissions apply before credentials are written.
                            let temporary = url.deletingLastPathComponent().appendingPathComponent(".endpoint-\(epoch)")
                            guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
                            try data.write(to: temporary)
                            if rename(temporary.path, url.path) != 0 { try? FileManager.default.removeItem(at: temporary); throw CocoaError(.fileWriteUnknown) }
                            self.status = "Connected locally · port \(port.rawValue)"
                        } catch { self.fail(error.localizedDescription) }
                    case .failed(let error): self.fail(error.localizedDescription)
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == epoch, self.connections.count < Self.maximumConnections else { connection.cancel(); return }
                    let id = UUID()
                    self.connections[id] = connection
                    connection.start(queue: .main)
                    self.receive(connection, id: id, data: Data())
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(120))
                        self?.finish(id)
                    }
                }
            }
            listener.start(queue: .main)
        } catch { fail(error.localizedDescription) }
    }
    func stop() {
        generation = UUID()
        listener?.cancel(); listener = nil
        for task in requestTasks.values { task.cancel() }
        requestTasks.removeAll()
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        // Do not remove a rendezvous file owned by a different app process.
        if let data = try? Data(contentsOf: Self.endpointURL), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["token"] as? String == token { try? FileManager.default.removeItem(at: Self.endpointURL) }
        token = ""; isEnabled = false; status = "Disabled"
        UserDefaults.standard.set(false, forKey: "CompositorAutomationEnabled")
    }
    func shutdown() {
        let restoreOnLaunch = isEnabled
        stop()
        UserDefaults.standard.set(restoreOnLaunch, forKey: "CompositorAutomationEnabled")
    }
    private func fail(_ message: String) { stop(); status = "Connection error: \(message)" }
    private func finish(_ id: UUID) {
        requestTasks.removeValue(forKey: id)?.cancel()
        connections.removeValue(forKey: id)?.cancel()
    }
    private func receive(_ connection: NWConnection, id: UUID, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] chunk, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, self.connections[id] != nil else { return }
                var buffer = data
                if let chunk { buffer.append(chunk) }
                guard buffer.count <= Self.maximumBytes else { self.finish(id); return }
                if let end = buffer.firstIndex(of: 10) {
                    guard buffer.index(after: end) == buffer.endIndex,
                          let object = try? JSONSerialization.jsonObject(with: buffer[..<end]) as? [String: Any],
                          let supplied = object["token"] as? String, self.matchesToken(supplied),
                          let request = object["request"] as? [String: Any] else { self.finish(id); return }
                    let task = Task { @MainActor [weak self] in
                        guard let self, self.connections[id] != nil, !Task.isCancelled else { return }
                        let response = await self.router.handle(request)
                        guard self.connections[id] != nil, !Task.isCancelled else { return }
                        let envelope: [String: Any] = ["response": response as Any? ?? NSNull()]
                        guard var bytes = try? JSONSerialization.data(withJSONObject: envelope), bytes.count <= Self.maximumBytes else { self.finish(id); return }
                        bytes.append(10)
                        connection.send(content: bytes, completion: .contentProcessed { [weak self] _ in Task { @MainActor [weak self] in self?.finish(id) } })
                    }
                    self.requestTasks[id] = task
                } else if complete || error != nil { self.finish(id) }
                else { self.receive(connection, id: id, data: buffer) }
            }
        }
    }
    private func matchesToken(_ supplied: String) -> Bool {
        let a = Array(supplied.utf8), b = Array(token.utf8)
        guard a.count == b.count, !b.isEmpty else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    func copyConfiguration() {
        guard let script = Bundle.main.url(forResource: "compositor-mcp", withExtension: "py") else { status = "Bridge resource missing from this build"; return }
        let config: [String: Any] = ["mcpServers": ["compositor": ["command": "/usr/bin/python3", "args": [script.path, "--endpoint", Self.endpointURL.path]]]]
        if let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        }
    }
}
