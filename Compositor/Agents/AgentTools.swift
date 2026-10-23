import AppKit
import ImageIO
import UniformTypeIdentifiers

/// One thing an agent can do, as MCP lists it: its name, what it does, the arguments it takes (a JSON Schema), and
/// the work. Tools run on the main actor, as the editor does, one step of the person's undo history each where they
/// change the document.
struct AgentTool {
    let name: String
    let description: String
    let schema: JSONValue
    /// Only looks: MCP clients may run it without asking.
    var readOnly = false
    let perform: (AgentCall) async throws -> AgentResult

    var listing: JSONValue {
        .object(["name": .string(name), "description": .string(description), "inputSchema": schema,
                 "annotations": .object(["readOnlyHint": .bool(readOnly), "destructiveHint": .bool(false)])])
    }

    /// Runs it, after turning away arguments it doesn't take, so a misspelled one isn't silently ignored.
    func run(_ call: AgentCall) async throws -> AgentResult {
        guard let given = call.arguments.object else { throw AgentError("Arguments must be a JSON object.") }
        let known = Set(schema["properties"]?.object?.keys.map { $0 } ?? [])
        if let unknown = given.keys.sorted().first(where: { !known.contains($0) }) {
            throw AgentError("\(name) takes no argument “\(unknown)”. It takes: \(known.sorted().joined(separator: ", ")).")
        }
        return try await perform(call)
    }
}

/// What a tool hands back: text the agent reads, images it sees, and the same facts as JSON for clients that read it.
struct AgentResult {
    var content: [JSONValue] = []
    var structured: JSONValue?
    var isError = false

    static func text(_ text: String) -> AgentResult { AgentResult(content: [.object(["type": .string("text"), "text": .string(text)])]) }
    static func json(_ value: JSONValue) -> AgentResult {
        var result = text(String(data: value.data, encoding: .utf8) ?? "{}")
        result.structured = value
        return result
    }
    static func failure(_ message: String) -> AgentResult {
        var result = text(message)
        result.isError = true
        return result
    }
    mutating func addImage(_ data: Data, type: String) {
        content.append(.object(["type": .string("image"), "data": .string(data.base64EncodedString()), "mimeType": .string(type)]))
    }

    var json: JSONValue {
        var result: [String: JSONValue] = ["content": .array(content), "isError": .bool(isError)]
        // MCP's structured content is an object; a list goes in one.
        if let structured { result["structuredContent"] = structured.object == nil ? .object(["result": structured]) : structured }
        return .object(result)
    }
}

/// A tool's failure, worded for the agent: what was wrong, and what to do instead.
nonisolated struct AgentError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// One call to a tool: its arguments, read with their types checked, and the projects it acts on.
struct AgentCall {
    let arguments: JSONValue
    let workspace: ProjectWorkspace

    func has(_ key: String) -> Bool { arguments[key].map { !$0.isNull } ?? false }
    func string(_ key: String) throws -> String? {
        guard let value = arguments[key], !value.isNull else { return nil }
        guard let string = value.string else { throw AgentError("“\(key)” must be a string.") }
        return string
    }
    func string(_ key: String, default fallback: String) throws -> String { try string(key) ?? fallback }
    func requiredString(_ key: String) throws -> String {
        guard let value = try string(key) else { throw AgentError("“\(key)” is required.") }
        return value
    }
    func double(_ key: String) throws -> Double? {
        guard let value = arguments[key], !value.isNull else { return nil }
        guard let number = value.number, number.isFinite else { throw AgentError("“\(key)” must be a number.") }
        return number
    }
    func int(_ key: String) throws -> Int? {
        guard let number = try double(key) else { return nil }
        guard number.rounded() == number, abs(number) < 1e9 else { throw AgentError("“\(key)” must be a whole number.") }
        return Int(number)
    }
    func bool(_ key: String) throws -> Bool? {
        guard let value = arguments[key], !value.isNull else { return nil }
        guard let bool = value.bool else { throw AgentError("“\(key)” must be true or false.") }
        return bool
    }
    func id(_ key: String) throws -> UUID? {
        guard let string = try string(key) else { return nil }
        guard let id = UUID(uuidString: string) else { throw AgentError("“\(key)” must be a layer or document id, as get_document gives them.") }
        return id
    }
    func ids(_ key: String) throws -> [UUID] {
        guard let value = arguments[key], !value.isNull else { return [] }
        guard let items = value.array else { throw AgentError("“\(key)” must be an array of ids.") }
        return try items.map {
            guard let id = $0.string.flatMap(UUID.init(uuidString:)) else { throw AgentError("“\(key)” holds something that isn't an id.") }
            return id
        }
    }
    /// A point given as [x, y].
    func point(_ key: String) throws -> CGPoint? {
        guard let value = arguments[key], !value.isNull else { return nil }
        guard let pair = value.array, pair.count == 2, let x = pair[0].number, let y = pair[1].number else {
            throw AgentError("“\(key)” must be [x, y] in document pixels.")
        }
        return CGPoint(x: x, y: y)
    }

    /// The tab `document` names, else the one in front. A named tab comes to the front, since the menus (and the
    /// person watching) act on that one.
    func tab() throws -> ProjectTab {
        guard let id = try id("document") else { return workspace.current }
        guard let tab = workspace.tabs.first(where: { $0.id == id }) else {
            throw AgentError("No open document has id \(id.uuidString). list_documents shows them.")
        }
        if tab.id != workspace.current.id {
            workspace.select(id)
            guard workspace.current.id == id else { throw AgentError("Compositor can't switch documents right now: \(AgentTools.busyReason(workspace.current.session) ?? "it's busy").") }
        }
        return tab
    }

    /// The session of the document the call acts on, which must have a canvas. `editing` also asks that nothing be
    /// in progress that would block a change (a dialog, text being typed, a save); a pending transform or crop is
    /// settled first, as the app does before saving.
    func session(editing: Bool = true) throws -> EditorSession {
        let session = try tab().session
        guard session.document != nil else { throw AgentError("This document has no canvas yet. Make one with new_document, or open a project.") }
        if editing {
            session.cancelCrop()
            session.commitTransform()
            if let reason = AgentTools.busyReason(session) { throw AgentError("Compositor is busy: \(reason). Ask the person to finish it, then try again.") }
        }
        return session
    }

    /// The layer named by `key`, or with none given, the active layer.
    func layer(_ key: String = "layer_id", in session: EditorSession) throws -> ImageLayer {
        guard let id = try id(key) ?? session.activeLayerID else { throw AgentError("No layer is selected; name one with “\(key)”.") }
        guard let layer = session.document?.layers.first(where: { $0.id == id }) else {
            throw AgentError("No layer has id \(id.uuidString). get_document lists them.")
        }
        return layer
    }
}

/// JSON Schemas for the tools' arguments.
enum Schema {
    static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("object"), "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return .object(schema)
    }
    static func string(_ description: String, oneOf choices: [String]? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("string"), "description": .string(description)]
        if let choices { schema["enum"] = .array(choices.map { .string($0) }) }
        return .object(schema)
    }
    static func number(_ description: String) -> JSONValue {
        .object(["type": .string("number"), "description": .string(description)])
    }
    static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("integer"), "description": .string(description)]
        if let minimum { schema["minimum"] = .number(Double(minimum)) }
        if let maximum { schema["maximum"] = .number(Double(maximum)) }
        return .object(schema)
    }
    static func boolean(_ description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }
    static func array(_ description: String, of items: JSONValue) -> JSONValue {
        .object(["type": .string("array"), "description": .string(description), "items": items])
    }
    static func anyObject(_ description: String) -> JSONValue {
        .object(["type": .string("object"), "description": .string(description), "additionalProperties": .bool(true)])
    }
    static func point(_ description: String) -> JSONValue {
        .object(["type": .string("array"), "description": .string(description), "items": .object(["type": .string("number")]),
                 "minItems": .number(2), "maxItems": .number(2)])
    }
    static let document = string("The document's id from list_documents. Omitted: the document in front.")
    static let layer = string("A layer id from get_document. Omitted: the selected layer.")
    static let layers = array("Layer ids from get_document.", of: .object(["type": .string("string")]))
}

enum AgentTools {
    /// Every tool, in the order tools/list gives them.
    static var all: [AgentTool] { documentTools + layerTools + textAndShapeTools + paintingTools + editingTools + canvasTools + commandTools }

    /// What MCP clients pass on to the agent about the server as a whole.
    static let instructions = """
        Compositor is a macOS image editor, open on the person's screen: they watch every change as you make it, and \
        can undo it. Coordinates are document pixels, origin top-left, y down. Layers are listed bottom to top, as in \
        a .comp project's manifest. Start with list_documents or get_document; look at your work with render. Most \
        tools act on the document in front unless you pass `document`, and on the selected layer unless you pass \
        `layer_id`. Anything without a tool of its own can be found with list_commands and run with run_command.
        """

    /// Why `session` can't take an edit now, in words for the agent; nil when it can.
    static func busyReason(_ session: EditorSession) -> String? {
        if session.textDraft != nil { return "text is being typed on the canvas" }
        if session.filterEdit != nil || session.levels != nil || session.hueSaturation != nil || session.adjustmentEditingID != nil
            || session.colorRange != nil || session.selectionAmountOperation != nil { return "a dialog or filter panel is open" }
        if session.isImporting || session.showsConversionSheet || session.showsRawDevelop { return "an import is in progress" }
        if session.isProjectBusy || session.showsBusy { return "an operation is still running" }
        if session.showsNewDocument || session.showsImporter { return "a sheet is open" }
        if session.renamingLayerID != nil { return "a layer is being renamed" }
        if session.brushStroke != nil || session.warpStroke != nil || session.pixelMove != nil { return "a stroke is being painted" }
        if session.gradientEdit != nil { return "a gradient is being placed" }
        return nil
    }

    /// The error the app noted for the last operation, if any, taken so it isn't also shown to the person as theirs.
    static func takeError(_ session: EditorSession) -> String? {
        let errors = [session.brushError, session.importError, session.cropError].compactMap { $0 }
        session.brushError = nil
        session.importError = nil
        session.cropError = nil
        return errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    /// `current` with `patch` written over it, field by field, as JSON in a project's manifest. A field the patch
    /// names that `current` leaves out starts from its value in `seeds`, so a patch can give part of a group that
    /// wasn't there before. Null takes a field away.
    static func patched<T: Codable>(_ current: T, with patch: JSONValue, seeds: T? = nil) throws -> T {
        guard let changes = patch.object else { throw AgentError("Settings must be a JSON object.") }
        var base = try JSONValue.encoding(current).object ?? [:]
        let defaults = try seeds.map { try JSONValue.encoding($0).object ?? [:] } ?? [:]
        for key in changes.keys where base[key] == nil || base[key]?.isNull == true {
            if let seed = defaults[key] { base[key] = seed }
        }
        do { return try JSONValue.object(base).merging(patch).decoded(as: T.self) }
        catch { throw AgentError("Those settings don't fit: \(Self.describe(error)). get_document shows the current ones, field by field.") }
    }

    static func describe(_ error: Error) -> String {
        switch error as? DecodingError {
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        case .keyNotFound(let key, let context):
            return "missing \((context.codingPath.map(\.stringValue) + [key.stringValue]).joined(separator: "."))"
        default: return error.localizedDescription
        }
    }

    /// A color written "#RRGGBB" (or "RRGGBB").
    static func color(_ hex: String) throws -> PaletteColor {
        guard let color = PaletteColor(hex: hex) else { throw AgentError("“\(hex)” isn't a color; write it as #RRGGBB.") }
        return color
    }
}

/// Folders the person has let agents read and write (Agent Access › Add Folder…), kept as security-scoped bookmarks
/// so the sandbox lets the app back into them after a relaunch. A path an agent names must be inside one of them.
enum AgentFolders {
    private static let key = "agentServer.folders"
    private static var opened: [URL] = []

    static var urls: [URL] {
        if opened.isEmpty { opened = resolveBookmarks() }
        return opened
    }

    static func add(_ url: URL) {
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return }
        UserDefaults.standard.set(bookmarks + [bookmark], forKey: key)
        if url.startAccessingSecurityScopedResource() { opened.append(url) }
    }

    static func remove(_ url: URL) {
        let kept = bookmarks.filter { resolve($0)?.standardizedFileURL != url.standardizedFileURL }
        UserDefaults.standard.set(kept, forKey: key)
        url.stopAccessingSecurityScopedResource()
        opened.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
    }

    private static var bookmarks: [Data] { UserDefaults.standard.array(forKey: key) as? [Data] ?? [] }
    private static func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
    }
    /// Each folder opened once, for as long as the app runs.
    private static func resolveBookmarks() -> [URL] {
        bookmarks.compactMap { resolve($0) }.filter { $0.startAccessingSecurityScopedResource() }
    }

    /// The person's own home folder: in the sandbox, `~` would otherwise mean the app's container.
    static var home: String {
        getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
    }

    /// `path` as a file URL the app may use, or why not.
    static func url(for path: String) throws -> URL {
        let expanded = path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst() : path
        guard expanded.hasPrefix("/") else { throw AgentError("Give an absolute path (or one starting with ~/): “\(path)” isn't one.") }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let inside = urls.contains { url.path == $0.standardizedFileURL.path || url.path.hasPrefix($0.standardizedFileURL.path + "/") }
            || url.path.hasPrefix(URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path)
        guard inside else {
            let granted = urls.map(\.path)
            throw AgentError("Compositor may only use files inside the folders the person has granted in Compositor › Agent Access"
                + (granted.isEmpty ? " (none yet). Ask them to add one, or pass the image itself as base64." : ": \(granted.joined(separator: ", ")).")
            )
        }
        return url
    }
}

/// Images to and from the agent.
nonisolated enum AgentImage {
    /// `image` no larger than `maxSide` on its longer side.
    static func scaled(_ image: CGImage, maxSide: Int) -> CGImage {
        let longer = max(image.width, image.height)
        guard maxSide > 0, longer > maxSide else { return image }
        let scale = Double(maxSide) / Double(longer)
        let width = max(1, Int((Double(image.width) * scale).rounded())), height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    static func encode(_ image: CGImage, as type: UTType, quality: Double = 0.9) throws -> Data {
        var image = image
        // JPEG has no transparency: what's clear goes on white, as Export JPEG puts it, rather than black.
        if type == .jpeg, let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            image = context.makeImage() ?? image
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { throw ExportError.encode }
        var options: [CFString: Any] = [:]
        if type == .jpeg { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encode }
        return data as Data
    }

    /// The file extension an image's bytes call for, from their first bytes; nil for what the app can't read.
    static func fileExtension(of data: Data) -> String? {
        let bytes = [UInt8](data.prefix(16))
        func starts(_ prefix: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + prefix.count && Array(bytes[offset..<offset + prefix.count]) == prefix
        }
        if starts([0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if starts([0xFF, 0xD8, 0xFF]) { return "jpg" }
        if starts(Array("GIF8".utf8)) { return "gif" }
        if starts(Array("RIFF".utf8)) && starts(Array("WEBP".utf8), at: 8) { return "webp" }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return "tiff" }
        if starts(Array("ftyp".utf8), at: 4) { return "heic" }
        if starts(Array("%PDF".utf8)) { return "pdf" }
        if starts(Array("8BPS".utf8)) { return bytes.count > 5 && bytes[5] == 2 ? "psb" : "psd" }
        if let text = String(data: data.prefix(512), encoding: .utf8), text.contains("<svg") { return "svg" }
        return nil
    }
}
