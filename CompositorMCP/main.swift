import Foundation

// compositor-mcp: the MCP server an AI app starts, over stdin and stdout, to work in Compositor. It ships inside
// Compositor.app (Contents/MacOS) and runs outside the app's sandbox: it reads the files it's asked to import or open
// and writes exports where it's asked to, which the sandboxed app can't.
//
// It hands each tool call to the running app (opening it if need be) the one way a sandboxed app takes files from
// another program: a file-open. Each request is a private folder in a per-user mailbox, opened in Compositor with any
// file it brings; the app answers in the same folder (see EditorAutomation). There's no port, and nothing runs in the
// app between requests.
//
//     compositor-mcp [--app /path/to/Compositor.app] [--timeout seconds]

let bundleID = "com.wonderassembly.compositor"
let protocols = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
let limit = 256 * 1024

typealias Schema = [String: Any]
typealias JSON = [String: Any]

// MARK: Tools

let string: Schema = ["type": "string", "minLength": 1]
let uuid: Schema = ["type": "string", "format": "uuid"]
let number: Schema = ["type": "number"]
let boolean: Schema = ["type": "boolean"]
let dimension: Schema = ["type": "integer", "minimum": 1, "maximum": 30000]
let transform: Schema = [
    "type": "object",
    "properties": ["x": number, "y": number, "width": number, "height": number, "rotation": number,
                   "flip_x": boolean, "flip_y": boolean],
    "additionalProperties": false,
]

var tools: [String: JSON] = [:]
var toolOrder: [String] = []

/// A tool: `required` and `optional` arguments in order; the editing ones take the active project's ID first.
func tool(_ name: String, _ description: String, _ required: KeyValuePairs<String, Schema> = [:],
          _ optional: KeyValuePairs<String, Schema> = [:], active: Bool = true, readOnly: Bool = false) {
    var names: [String] = active ? ["project_id"] : []
    var properties: Schema = active ? ["project_id": uuid] : [:]
    for (key, schema) in required { names.append(key); properties[key] = schema }
    for (key, schema) in optional { properties[key] = schema }
    tools[name] = [
        "name": name, "description": description,
        "inputSchema": ["type": "object", "properties": properties, "required": names, "additionalProperties": false] as JSON,
        "annotations": ["readOnlyHint": readOnly, "openWorldHint": false],
    ]
    toolOrder.append(name)
}

tool("list_projects", "List live Compositor tabs and identify the active one.", active: false, readOnly: true)
tool("new_project", "Create a blank canvas in a new tab. Returns its project ID and layer IDs.",
     ["width": dimension, "height": dimension], active: false)
tool("open_project", "Open a local .comp project in its own tab.", ["path": string], active: false)
tool("select_project", "Switch to an existing tab from list_projects.", ["project_id": uuid], active: false)
tool("get_project", "Inspect the active project. Layer order is bottom to top. Returns IDs, layer metadata, "
     + "current adjustment settings and the supported blend and adjustment names.", readOnly: true)
tool("list_commands", "Discover the editor’s available menus and tool commands with their current enabled state.",
     readOnly: true)
tool("run_command", "Invoke a native editor command by its ID from list_commands. A command that opens a panel or "
     + "dialog brings Compositor forward for the person to finish it.", ["command_id": string])
tool("preview", "Render a flattened PNG preview of the active project, up to 960 pixels on its longer side.",
     readOnly: true)
tool("import_media", "Import a local image, GIF, or movie into the active project as a layer. Movie layers link to "
     + "the original file. RAW and Photoshop imports may need interaction in the app.", ["path": string])
tool("save_project", "Save an already named project to its current .comp file.")
tool("save_project_copy", "Write a .comp copy to a new local path, leaving the open tab attached to its current file.",
     ["path": string])
tool("export_png", "Export the full canvas as a flattened PNG to a new local path.", ["path": string])
tool("add_layer", "Add a blank pixel layer or group above the selection.", [:],
     ["kind": ["enum": ["pixel", "group"]], "name": string])
tool("add_text", "Create an editable text layer. Position is the layer’s top-left corner in canvas pixels.",
     ["text": string, "x": number, "y": number, "font_size": ["type": "number", "minimum": 1, "maximum": 2000],
      "color": string], ["font": string])
tool("add_shape", "Create an editable rectangle or ellipse in canvas pixels.",
     ["kind": ["enum": ["rectangle", "ellipse"]], "x": number, "y": number, "width": dimension, "height": dimension,
      "color": string])
tool("select_layer", "Select a layer by its ID.", ["layer_id": uuid])
tool("edit_layer", "Edit layer appearance and placement in one undo step. Transform coordinates and unrotated "
     + "dimensions use canvas pixels, with a top-left origin. Rotation is clockwise in degrees.", ["layer_id": uuid],
     ["name": string, "visible": boolean, "opacity": ["type": "number", "minimum": 0, "maximum": 1],
      "blend_mode": string, "transform": transform])
tool("duplicate_layer", "Duplicate a layer using the editor's native duplication rules.", ["layer_id": uuid])
tool("move_layer", "Move a layer one position up or down among its siblings.",
     ["layer_id": uuid, "direction": ["enum": ["up", "down"]]])
tool("delete_layer", "Delete a layer as an undoable edit. Groups and live mask sources are handled in the editor.",
     ["layer_id": uuid])
tool("add_adjustment", "Add a non-destructive adjustment or filter layer, using a kind from get_project.",
     ["kind": string])
tool("set_adjustment", "Update fields on a native adjustment layer. Read the existing settings with get_project. "
     + "Nested settings values replace their corresponding objects.", ["layer_id": uuid, "settings": ["type": "object"]])
tool("add_mask", "Add a layer mask using the current selection, or fill it to reveal or hide the whole layer.", [:],
     ["reveal": boolean])
tool("set_selection", "Select all, deselect, or select a rectangle using canvas pixel coordinates.",
     ["mode": ["enum": ["all", "none", "rectangle"]]], ["x": number, "y": number, "width": number, "height": number])
tool("invert_pixels", "Invert the active layer's pixels within the current selection.")
tool("brush_stroke", "Paint an undoable stroke using canvas pixel coordinates. The points are in drawing order.", [
    "points": ["type": "array", "minItems": 1, "maxItems": 256,
               "items": ["type": "object", "properties": ["x": number, "y": number], "required": ["x", "y"],
                         "additionalProperties": false] as Schema],
    "diameter": ["type": "number", "minimum": 1, "maximum": 2000],
    "hardness": ["type": "number", "minimum": 0, "maximum": 1],
    "opacity": ["type": "number", "minimum": 0.01, "maximum": 1], "color": string,
])
tool("select_gif_frame", "Show a GIF frame by one-based position in the filmstrip.",
     ["frame": ["type": "integer", "minimum": 1]])
tool("set_gif_delay", "Set a uniform GIF frame delay in milliseconds, or pass null to restore original timing.",
     ["milliseconds": ["type": ["number", "null"], "minimum": 20, "maximum": 655350]])
tool("undo", "Undo the last edit in the active project.")
tool("redo", "Redo the last undone edit in the active project.")

// MARK: Arguments

struct Problem: Error { let message: String; init(_ message: String) { self.message = message } }

func isBool(_ value: Any) -> Bool { (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }
func numeric(_ value: Any) -> Double? { isBool(value) ? nil : (value as? NSNumber)?.doubleValue }

/// The arguments checked against a tool's schema before anything reaches the app.
func validate(_ value: Any, _ schema: Schema, _ label: String) throws {
    let kinds: [String] = (schema["type"] as? String).map { [$0] } ?? (schema["type"] as? [String] ?? [])
    func matches(_ kind: String) -> Bool {
        switch kind {
        case "object": return value is JSON
        case "string": return value is String
        case "number": return numeric(value)?.isFinite == true
        case "integer": return numeric(value).map { $0.isFinite && $0 == $0.rounded() } ?? false
        case "boolean": return isBool(value)
        case "null": return value is NSNull
        case "array": return value is [Any]
        default: return false
        }
    }
    guard kinds.isEmpty || kinds.contains(where: matches) else { throw Problem("Invalid \(label).") }
    if let options = schema["enum"] as? [String] {
        guard let text = value as? String, options.contains(text) else { throw Problem("Invalid \(label).") }
    }
    if let object = value as? JSON {
        let properties = schema["properties"] as? Schema ?? [:]
        if (schema["required"] as? [String] ?? []).contains(where: { object[$0] == nil }) {
            throw Problem("Missing required fields in \(label).")
        }
        if schema["additionalProperties"] as? Bool == false, object.keys.contains(where: { properties[$0] == nil }) {
            throw Problem("Unexpected fields in \(label).")
        }
        for (key, item) in object { if let rule = properties[key] as? Schema { try validate(item, rule, key) } }
    }
    if let array = value as? [Any], let items = schema["items"] as? Schema {
        guard ((schema["minItems"] as? Int ?? 0)...(schema["maxItems"] as? Int ?? limit)).contains(array.count) else {
            throw Problem("Invalid \(label).")
        }
        for item in array { try validate(item, items, label) }
    }
    if let text = value as? String, text.count < schema["minLength"] as? Int ?? 0 { throw Problem("Invalid \(label).") }
    if let value = numeric(value) {
        let low = (schema["minimum"] as? Double) ?? Double(schema["minimum"] as? Int ?? Int(-1e12))
        let high = (schema["maximum"] as? Double) ?? Double(schema["maximum"] as? Int ?? Int(1e12))
        guard abs(value) <= 1e12, value >= low, value <= high else { throw Problem("Invalid \(label).") }
    }
}

// MARK: The app

struct Options {
    /// The Compositor.app to use: given, or the one this program sits in, or else whichever macOS knows by its ID.
    var app: URL?
    var timeout: TimeInterval = 90

    init(_ arguments: [String]) {
        var arguments = arguments.dropFirst()[...]
        while let flag = arguments.popFirst() {
            if flag == "--app", let path = arguments.popFirst() { app = URL(fileURLWithPath: path) }
            else if flag == "--timeout", let text = arguments.popFirst(), let seconds = Double(text), (5...300).contains(seconds) {
                timeout = seconds
            }
        }
        if app == nil {
            let enclosing = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            if enclosing.pathExtension == "app" { app = enclosing }
        }
    }
}

/// The AI app on the other end, as it named itself in its hello: passed with each request, so Compositor can turn away
/// one the person has disconnected.
nonisolated(unsafe) var clientName = ""

struct Editor {
    let options: Options
    let mailbox = URL(fileURLWithPath: "/private/tmp/compositor-mcp-\(getuid())", isDirectory: true)

    /// The mailbox, made if need be: a directory this user owns that no one else can read.
    func secureMailbox() throws {
        mkdir(mailbox.path, 0o700)
        var info = stat()
        guard lstat(mailbox.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0 else {
            throw Problem("The MCP mailbox must be a private directory owned by the current user.")
        }
    }

    func call(_ action: String, _ given: JSON) throws -> JSON {
        guard let definition = tools[action], let schema = definition["inputSchema"] as? Schema else {
            throw Problem("Unknown Compositor tool.")
        }
        try validate(given, schema, "arguments")
        var arguments = given
        var source: URL?, destination: URL?
        if action == "open_project" || action == "import_media", let path = arguments.removeValue(forKey: "path") as? String {
            // The real path, as the app sees the file it's handed (`resolvingSymlinksInPath` drops /private, so a
            // file in /tmp didn't match).
            let expanded = (path as NSString).expandingTildeInPath
            guard let real = realpath(expanded, nil) else { throw Problem("No file at \(expanded).") }
            let url = URL(fileURLWithPath: String(cString: real))
            free(real)
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else {
                throw Problem("No file at \(url.path).")
            }
            if action == "import_media", directory.boolValue { throw Problem("Import requires one regular file.") }
            source = url
        }
        if action == "save_project_copy" || action == "export_png", let path = arguments.removeValue(forKey: "path") as? String {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
            let suffix = action == "save_project_copy" ? "comp" : "png"
            var directory: ObjCBool = false
            guard url.pathExtension.lowercased() == suffix,
                  FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &directory),
                  directory.boolValue else { throw Problem("Choose a .\(suffix) path inside an existing directory.") }
            guard (try? url.checkResourceIsReachable()) != true,
                  (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else {
                throw Problem("The destination already exists. Choose a new path.")
            }
            destination = url
        }

        try secureMailbox()
        let id = UUID().uuidString.lowercased()
        let folder = mailbox.appendingPathComponent(id + ".comp", isDirectory: true)
        guard mkdir(folder.path, 0o700) == 0 else { throw Problem("Couldn’t make the request folder.") }
        defer { try? FileManager.default.removeItem(at: folder) }

        var payload: JSON = ["id": id, "action": action, "arguments": arguments,
                             "deadline": Date().timeIntervalSince1970 + options.timeout]
        if let source { payload["input"] = source.path }
        if !clientName.isEmpty { payload["client"] = clientName }
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard data.count <= limit else { throw Problem("Compositor request is too large.") }
        // Made new and readable by this user only: the app refuses a request anyone else could have written.
        let request = folder.appendingPathComponent("request.json").path
        let descriptor = open(request, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw Problem("Couldn’t write the request.") }
        let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, data.count) }
        close(descriptor)
        guard written == data.count else { throw Problem("Couldn’t write the request.") }

        // Opened in the background: the request, then the file it brings, so the sandboxed app may read it. Two
        // opens, in that order: given together, macOS sometimes handed the app them as separate events, and the
        // file was opened as a document of its own. The app waits for the file a request names.
        try openInApp(folder)
        if let source { try openInApp(source) }

        let response = folder.appendingPathComponent("response.json")
        let until = Date().addingTimeInterval(options.timeout)
        while !FileManager.default.fileExists(atPath: response.path) {
            guard Date() < until else {
                throw Problem("Compositor didn’t respond. Check for an open dialog, and inspect the project before "
                              + "retrying an edit.")
            }
            usleep(25_000)
        }
        guard let reply = try JSONSerialization.jsonObject(with: Data(contentsOf: response)) as? JSON else {
            throw Problem("Compositor's reply couldn't be read.")
        }
        if let error = reply["error"] as? String { throw Problem(error) }
        if action == "preview" {
            let image = try Data(contentsOf: folder.appendingPathComponent("result.png"))
            return ["content": [["type": "image", "mimeType": "image/png", "data": image.base64EncodedString()]]]
        }
        var value = reply["result"] as? JSON ?? [:]
        if let destination {
            // Copied into place, never over anything: the copy fails if something has appeared there since.
            let produced = folder.appendingPathComponent(action == "save_project_copy" ? "result.comp" : "result.png")
            try FileManager.default.copyItem(at: produced, to: destination)
            value["path"] = destination.path
        }
        let text = (try? JSONSerialization.data(withJSONObject: value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return ["content": [["type": "text", "text": text]], "structuredContent": value]
    }
}

extension Editor {
    func openInApp(_ url: URL) throws {
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = ["-g"] + (options.app.map { ["-a", $0.path] } ?? ["-b", bundleID]) + [url.path]
        let errors = Pipe()
        opener.standardError = errors
        opener.standardOutput = FileHandle.nullDevice
        try opener.run()
        opener.waitUntilExit()
        guard opener.terminationStatus == 0 else {
            let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw Problem(text.isEmpty ? "macOS couldn’t open Compositor." : text)
        }
    }
}

// MARK: JSON-RPC over stdio

func handle(_ editor: Editor, _ message: Any) -> JSON? {
    guard let request = message as? JSON, request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
        return ["id": NSNull(), "error": ["code": -32600, "message": "Invalid request"]]
    }
    // A notification gets no answer.
    guard let id = request["id"] else { return nil }
    guard let params = (request["params"] ?? JSON()) as? JSON else {
        return ["id": id, "error": ["code": -32602, "message": "Invalid params"]]
    }
    let result: JSON
    switch method {
    case "initialize":
        clientName = (params["clientInfo"] as? JSON)?["name"] as? String ?? ""
        let asked = params["protocolVersion"] as? String
        result = ["protocolVersion": asked.flatMap { protocols.contains($0) ? $0 : nil } ?? protocols[0],
                  "capabilities": ["tools": JSON()], "serverInfo": ["name": "compositor", "version": "1.0.0"],
                  "instructions": "Start with list_projects. Tools that edit require the active project ID. "
                      + "Use preview to inspect the canvas and undo to reverse edits."]
    case "ping":
        result = [:]
    case "tools/list":
        result = ["tools": toolOrder.compactMap { tools[$0] }]
    case "tools/call":
        do {
            guard let name = params["name"] as? String else { throw Problem("Missing tool name.") }
            result = try editor.call(name, params["arguments"] as? JSON ?? [:])
        } catch {
            let message = (error as? Problem)?.message ?? error.localizedDescription
            result = ["isError": true, "content": [["type": "text", "text": message]]]
        }
    default:
        return ["id": id, "error": ["code": -32601, "message": "Method not found"]]
    }
    return ["id": id, "result": result]
}

setvbuf(stdout, nil, _IOLBF, 0)
let editor = Editor(options: Options(CommandLine.arguments))
while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    var response: JSON?
    if line.utf8.count > limit {
        response = ["id": NSNull(), "error": ["code": -32600, "message": "Request too large"]]
    } else if let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) {
        response = handle(editor, message)
    } else {
        response = ["id": NSNull(), "error": ["code": -32700, "message": "Parse error"]]
    }
    guard var response else { continue }
    response["jsonrpc"] = "2.0"
    if let data = try? JSONSerialization.data(withJSONObject: response), let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}
