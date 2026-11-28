import AppKit

enum MCPAccess: String {
    static let defaultsKey = "mcpAccess"
    case undecided, allowed, denied

    static var current: Self {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .undecided }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

/// The companion wakes the editor with a normal file-open event. There is no listener or background work.
@MainActor
final class EditorAutomation {
    private var handling = false

    private static var mailbox: String {
        URL(fileURLWithPath: "/private/tmp/compositor-mcp-\(getuid())", isDirectory: true)
            .standardizedFileURL.path
    }

    static func isRequest(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension == "comp"
            && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
            && url.deletingLastPathComponent().standardizedFileURL.path == mailbox
    }

    func receive(_ requests: [URL], attachments: [URL], workspace: ProjectWorkspace) async {
        for folder in requests {
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            let root = Self.mailbox
            let url = folder.appendingPathComponent("request.json")
            guard folder.deletingLastPathComponent().standardizedFileURL.path == root,
                  let id = UUID(uuidString: folder.deletingPathExtension().lastPathComponent),
                  Self.privateItem(folder, type: .typeDirectory),
                  Self.privateItem(url, type: .typeRegular, maximumSize: 256 * 1024),
                  let data = try? Data(contentsOf: url), data.count <= 256 * 1024,
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  request["id"] as? String == id.uuidString.lowercased() else { continue }
            // Claim once, even if Launch Services delivers the event again.
            guard (try? FileManager.default.removeItem(at: url)) != nil else { continue }
            let reply: [String: Any]
            if handling {
                reply = ["error": "Compositor is handling another request. Try again when it finishes."]
            } else {
                handling = true
                do {
                    guard let deadline = request["deadline"] as? Double, deadline >= Date().timeIntervalSince1970,
                          deadline <= Date().timeIntervalSince1970 + 300,
                          let action = request["action"] as? String,
                          let arguments = request["arguments"] as? [String: Any] else { throw Failure("Invalid request.") }
                    try await authorize(in: workspace.window)
                    guard deadline >= Date().timeIntervalSince1970 else {
                        throw Failure("The MCP request expired. Send it again.")
                    }
                    let input = (request["input"] as? String).flatMap { path in
                        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
                        return attachments.first { $0.isFileURL && $0.standardizedFileURL.path == canonical }
                    }
                    reply = ["result": try await perform(action, arguments, input: input, folder: folder, workspace: workspace)]
                } catch {
                    reply = ["error": error.localizedDescription]
                }
                handling = false
            }
            if let data = try? JSONSerialization.data(withJSONObject: reply) {
                try? data.write(to: folder.appendingPathComponent("response.json"), options: .atomic)
            }
        }
    }

    private func authorize(in window: NSWindow?) async throws {
        if MCPAccess.current == .undecided {
            guard NSApp.modalWindow == nil, window?.attachedSheet == nil else {
                throw Failure("Close the current dialog and try the MCP request again.")
            }
            let alert = NSAlert()
            alert.messageText = "Allow MCP control?"
            alert.informativeText = "Local MCP clients can view and edit open projects, import media, and save or export your work. You can change this in Settings → General."
            alert.addButton(withTitle: "Don’t Allow").keyEquivalent = "\u{1b}"
            alert.addButton(withTitle: "Allow").keyEquivalent = ""
            NSApp.activate()
            let answer: NSApplication.ModalResponse
            if let window, window.isVisible {
                window.makeKeyAndOrderFront(nil)
                answer = await alert.beginSheetModal(for: window)
            } else {
                answer = alert.runModal()
            }
            if MCPAccess.current == .undecided {
                if answer == .alertSecondButtonReturn { MCPAccess.current = .allowed }
                if answer == .alertFirstButtonReturn { MCPAccess.current = .denied }
            }
        }
        guard MCPAccess.current == .allowed else {
            throw Failure("MCP control is off. Enable Allow MCP control in Compositor → Settings → General.")
        }
    }

    private static func privateItem(_ url: URL, type: FileAttributeType, maximumSize: Int? = nil) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == type,
              let owner = attributes[.ownerAccountID] as? NSNumber, owner.uint32Value == getuid(),
              let permissions = attributes[.posixPermissions] as? NSNumber else { return false }
        guard permissions.intValue & 0o077 == 0 else { return false }
        if let maximumSize { return ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= maximumSize }
        return true
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private func perform(_ action: String, _ args: [String: Any], input: URL?, folder: URL,
                         workspace: ProjectWorkspace) async throws -> [String: Any] {
        let session = workspace.current.session
        switch action {
        case "list_projects":
            return ["projects": workspace.tabs.map { tab in
                ["id": tab.id.uuidString, "title": tab.title, "active": tab.id == workspace.selectedID,
                 "modified": tab.session.isModified, "has_document": tab.session.document != nil] as [String: Any]
            }]
        case "new_project":
            guard workspace.canSwitch else { throw busy }
            let width = try dimension(args, "width"), height = try dimension(args, "height")
            let tab = workspace.addTab()
            guard tab.session.createNewProject(width: width, height: height) else { throw busy }
            return project(tab)
        case "open_project":
            guard workspace.canSwitch else { throw busy }
            guard let input, input.pathExtension.lowercased() == "comp" else { throw Failure("Attach a .comp project to open.") }
            guard await workspace.open(input) else { throw Failure("Compositor couldn’t open the project.") }
            return project(workspace.current)
        case "select_project":
            guard workspace.canSwitch else { throw busy }
            let id = try identifier(args, "project_id")
            guard workspace.tabs.contains(where: { $0.id == id }) else { throw Failure("Project tab was not found.") }
            workspace.select(id)
            return project(workspace.current)
        default:
            break
        }

        guard try identifier(args, "project_id") == workspace.selectedID else {
            throw Failure("The active tab changed. Call select_project before editing.")
        }
        if action == "get_project" { return project(workspace.current) }
        if action == "list_commands" {
            return ["commands": commands(session).map { ["id": $0.id, "title": $0.title, "enabled": $0.isEnabled] as [String: Any] }]
        }
        guard workspace.canSwitch, session.canEditLayers, let document = session.document else { throw busy }

        switch action {
        case "import_media":
            guard let input else { throw Failure("Attach a file to import.") }
            let before = Set(document.layers.map(\.id))
            await session.importImages([input])
            let inserted = session.document?.layers.filter { !before.contains($0.id) } ?? []
            guard !inserted.isEmpty else { throw Failure(session.importError ?? "No layer was imported into this tab.") }
            return ["layers": inserted.map(layer)]
        case "save_project":
            guard session.projectURL != nil else { throw Failure("Use save_project_copy to write an untitled project.") }
            guard await workspace.current.controller.save() else { throw Failure("The project wasn’t saved.") }
            return project(workspace.current)
        case "save_project_copy", "export_png", "preview":
            guard let snapshot = session.projectSnapshot() else { throw busy }
            if action == "save_project_copy" {
                try await ProjectStore.shared.save(snapshot, to: folder.appendingPathComponent("result.comp"))
            } else if action == "export_png" {
                try await ImageExporter.shared.exportPNG(snapshot, to: folder.appendingPathComponent("result.png"))
            } else {
                let preview = try await ImageExporter.shared.automationPreview(snapshot)
                try preview.write(to: folder.appendingPathComponent("result.png"), options: .atomic)
            }
            return ["completed": true]
        case "add_layer":
            guard document.layers.count < 10_000 else { throw Failure("The document has reached its layer limit.") }
            if let name = args["name"] as? String { try validateName(name) }
            let kind = args["kind"] as? String ?? "pixel"
            guard kind == "pixel" || kind == "group" else { throw Failure("Use pixel or group for kind.") }
            session.beginEdit(kind == "pixel" ? "New Blank Layer" : "New Group")
            defer { session.endEdit() }
            if kind == "pixel" { session.addBlankLayer() }
            else { session.addGroup() }
            if let name = args["name"] as? String, let id = session.activeLayerID { session.renameLayer(id, to: name) }
        case "add_text":
            guard document.layers.count < 10_000, let content = args["text"] as? String,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure("Provide non-empty text and a canvas with room for a layer.") }
            let color = try color(args)
            let fontSize = try number(args, "font_size")
            var style = LayerTextStyle()
            style.content = content
            if let font = args["font"] as? String {
                guard font.utf8.count <= 200 else { throw Failure("Font name is too long.") }
                style.fontName = font
            }
            style.fontSize = fontSize
            style.red = color.red; style.green = color.green; style.blue = color.blue
            let origin = CGPoint(x: try number(args, "x"), y: try number(args, "y"))
            guard session.applyText(TextDraft(documentID: document.id, layerID: nil, origin: origin, style: style)),
                  session.document?.layers.count == document.layers.count + 1 else { throw Failure("Compositor couldn’t create the text layer.") }
        case "add_shape":
            guard document.layers.count < 10_000 else { throw Failure("The document has reached its layer limit.") }
            let kind: ShapeKind
            switch args["kind"] as? String {
            case "rectangle": kind = .rectangle
            case "ellipse": kind = .ellipse
            default: throw Failure("Use rectangle or ellipse for kind.")
            }
            let rect = CGRect(x: try number(args, "x"), y: try number(args, "y"),
                              width: Double(try dimension(args, "width")), height: Double(try dimension(args, "height")))
            guard rect.width * rect.height <= DocumentLimits.maxSurfaceExtent else { throw Failure("The shape is too large.") }
            session.shapeDraft = ShapeDraft(kind: kind, anchor: rect.origin, rect: rect, fill: try color(args))
            session.finishShape()
            guard session.document?.layers.count == document.layers.count + 1 else { throw Failure("Compositor couldn’t create the shape layer.") }
        case "run_command":
            guard let id = args["command_id"] as? String,
                  let command = commands(session).first(where: { $0.id == id && $0.isEnabled }) else {
                throw Failure("That editor command is unavailable. Call list_commands to get the current IDs.")
            }
            command.perform()
            return ["started": true, "command": command.title]
        case "select_layer", "edit_layer", "delete_layer", "duplicate_layer", "move_layer":
            let id = try identifier(args, "layer_id")
            guard let target = document.layers.first(where: { $0.id == id }) else { throw Failure("Layer was not found.") }
            switch action {
            case "select_layer": session.selectLayer(id)
            case "edit_layer": try editLayer(target, in: session, arguments: args)
            case "delete_layer":
                guard !target.isGroup, !document.layers.contains(where: { $0.maskSourceID == id }) else {
                    throw Failure("Delete groups and live mask sources in the editor to review their dependent layers.")
                }
                session.deleteLayer(id)
            case "duplicate_layer": session.duplicateLayers([id])
            default:
                guard let direction = args["direction"] as? String, ["up", "down"].contains(direction) else {
                    throw Failure("Use up or down for direction.")
                }
                session.selectLayer(id)
                session.moveActiveLayer(by: direction == "up" ? 1 : -1)
            }
        case "add_adjustment":
            guard let name = args["kind"] as? String, let kind = AdjustmentKind(rawValue: name) else {
                throw Failure("Unknown adjustment. See adjustment_kinds in get_project.")
            }
            guard document.layers.count < 10_000 else { throw Failure("The document has reached its layer limit.") }
            session.addAdjustment(kind, opensEditor: false)
        case "set_adjustment":
            let id = try identifier(args, "layer_id")
            guard let old = document.layers.first(where: { $0.id == id })?.adjustment,
                  let fields = args["settings"] as? [String: Any],
                  let serialized = encoded(old) as? [String: Any] else { throw Failure("Select an adjustment layer and provide a settings object.") }
            let merged = serialized.merging(fields) { _, update in update }
            let data = try JSONSerialization.data(withJSONObject: merged)
            let value = try JSONDecoder().decode(LayerAdjustment.self, from: data)
            guard value.kind == old.kind, value.isValid else { throw Failure("Invalid settings for this adjustment.") }
            session.beginEdit("Edit \(old.kind.rawValue)")
            session.updateAdjustment(id, value: value)
            session.endEdit()
        case "set_selection":
            switch args["mode"] as? String {
            case "all": session.selectAll()
            case "none": session.setSelection(nil, name: "Deselect")
            case "rectangle":
                let bounds = CGRect(x: try number(args, "x"), y: try number(args, "y"),
                                    width: try number(args, "width"), height: try number(args, "height"))
                guard bounds.width > 0, bounds.height > 0, !CGRect(origin: .zero, size: document.size).intersection(bounds).isEmpty else {
                    throw Failure("The rectangle must overlap the canvas and have positive dimensions.")
                }
                session.applySelection(CGPath(rect: bounds, transform: nil), mode: .replace, name: "Select Rectangle")
            default: throw Failure("Use all, none, or rectangle for mode.")
            }
        case "invert_pixels":
            guard session.activeLayer != nil else { throw Failure("Select a pixel layer first.") }
            await session.invertPixels()
        case "brush_stroke":
            guard session.canPaint, let target = session.activeLayer, target.movie == nil,
                  let samples = args["points"] as? [[String: Any]], (1...256).contains(samples.count) else {
                throw Failure("Select a paintable layer or mask and provide between 1 and 256 brush points.")
            }
            let points = try samples.map { sample in
                CGPoint(x: try number(sample, "x"), y: try number(sample, "y"))
            }
            let diameter = try number(args, "diameter")
            let hardness = try number(args, "hardness")
            let opacity = try number(args, "opacity")
            guard (1...2000).contains(diameter), (0...1).contains(hardness), (0.01...1).contains(opacity),
                  points.allSatisfy({ CGRect(origin: .zero, size: document.size).insetBy(dx: -diameter, dy: -diameter).contains($0) }) else {
                throw Failure("Brush settings are out of range or a point is too far outside the canvas.")
            }
            let fill = try color(args)
            let tool = session.tool, settings = session.brushSettings, mode = session.brushMode
            let previousError = session.brushError
            defer {
                session.tool = tool
                session.brushSettings = settings
                session.brushMode = mode
                session.brushError = previousError
            }
            session.tool = .brush
            session.brushMode = .paint
            session.brushSettings = BrushSettings(diameter: diameter, hardness: hardness, red: fill.red,
                                                   green: fill.green, blue: fill.blue, opacity: opacity)
            session.brushError = nil
            session.beginBrush(at: points[0])
            for point in points.dropFirst() { session.continueBrush(at: point) }
            session.finishBrushImmediately()
            if let error = session.brushError { throw Failure(error) }
        case "add_mask": session.addMask(revealing: args["reveal"] as? Bool ?? true)
        case "undo":
            guard session.canUndo else { throw Failure("There is nothing to undo.") }
            session.undo()
        case "redo":
            guard session.canRedo else { throw Failure("There is nothing to redo.") }
            session.redo()
        case "select_gif_frame":
            guard let index = args["frame"] as? Int, index > 0, session.gifTimelineFrames.indices.contains(index - 1) else {
                throw Failure("Select a GIF layer and supply a valid one-based frame number.")
            }
            if let id = session.activeLayerID { session.stopGIFPlayback(for: id) }
            await session.selectGIFTimelineFrame(session.gifTimelineFrames[index - 1].index)
        case "set_gif_delay":
            guard let id = session.activeLayerID, session.activeLayer?.gifAnimation != nil else {
                throw Failure("Select a GIF layer first.")
            }
            var timing = session.gifTimelineTiming
            if args["milliseconds"] is NSNull {
                timing.mode = .perFrame
            } else {
                timing.mode = .uniform
                timing.uniformDelay = try number(args, "milliseconds") / 1000
                guard timing.isValid else { throw Failure("The delay must be between 20 and 655350 milliseconds.") }
            }
            session.setGIFFrameTiming(timing, for: id)
        default: throw Failure("Unknown Compositor operation.")
        }
        return project(workspace.current)
    }

    private var busy: Failure { Failure("Finish the current editor operation and make sure a project is open.") }

    private func commands(_ session: EditorSession) -> [CommandPaletteEntry] {
        let editorMenus = Set(["Image", "Layer", "Select", "Filter", "View"])
        let menuEntries = NSApp.mainMenu.map { menu in
            CommandPaletteMenu.entries(in: menu, skipping: ["File", "Edit", "Window", "Help"])
                .filter { editorMenus.contains(String($0.title.split(separator: "›", maxSplits: 1)[0]).trimmingCharacters(in: .whitespaces)) }
        } ?? []
        return menuEntries + CommandPaletteEntry.tools(for: session)
    }

    private func editLayer(_ layer: ImageLayer, in session: EditorSession, arguments args: [String: Any]) throws {
        guard let index = session.document?.layers.firstIndex(where: { $0.id == layer.id }) else { return }
        var updated = layer
        if let name = args["name"] as? String { try validateName(name); updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let visible = args["visible"] as? Bool { updated.isVisible = visible }
        if args["opacity"] != nil {
            let amount = try number(args, "opacity")
            guard (0...1).contains(amount) else { throw Failure("Opacity must be between 0 and 1.") }
            updated.opacity = amount
        }
        if let name = args["blend_mode"] as? String {
            guard !layer.isGroup, let mode = LayerBlendMode(rawValue: name) else {
                throw Failure("Blend mode must be listed in get_project and applies to non-group layers.")
            }
            updated.blendMode = mode
        }
        if let fields = args["transform"] as? [String: Any] {
            guard !layer.isGroup, layer.adjustment == nil, layer.mask?.placement == nil else {
                throw Failure("Use the editor to transform groups, adjustment layers, or layers with independently placed masks.")
            }
            var t = layer.transform
            if fields["x"] != nil { t.origin.x = try number(fields, "x") }
            if fields["y"] != nil { t.origin.y = try number(fields, "y") }
            if fields["width"] != nil { t.size.width = try number(fields, "width") }
            if fields["height"] != nil { t.size.height = try number(fields, "height") }
            if fields["rotation"] != nil { t.rotation = try number(fields, "rotation") }
            if let flip = fields["flip_x"] as? Bool { t.flipX = flip }
            if let flip = fields["flip_y"] as? Bool { t.flipY = flip }
            guard t.isValid else { throw Failure("Invalid layer transform.") }
            updated.transform = t
        }
        session.beginEdit("Edit Layer")
        session.document?.layers[index] = updated
        session.endEdit()
    }

    private func project(_ tab: ProjectTab) -> [String: Any] {
        let session = tab.session
        return ["id": tab.id.uuidString, "title": tab.title, "modified": session.isModified,
                "canvas": session.document.map { ["width": $0.width, "height": $0.height, "resolution": $0.resolution] as [String: Any] } as Any? ?? NSNull(),
                "active_layer_id": session.activeLayerID?.uuidString as Any? ?? NSNull(),
                "layers": session.document?.layers.map(layer) ?? [],
                "adjustment_kinds": AdjustmentKind.allCases.map(\.rawValue),
                "blend_modes": LayerBlendMode.allCases.map(\.rawValue),
                "gif_frame_count": session.gifTimelineFrames.count]
    }

    private func layer(_ layer: ImageLayer) -> [String: Any] {
        let t = layer.transform
        return ["id": layer.id.uuidString, "name": layer.name,
                "parent_id": layer.parentID?.uuidString as Any? ?? NSNull(), "visible": layer.isVisible,
                "kind": layer.isGroup ? "group" : layer.adjustment != nil ? "adjustment" : layer.movie != nil ? "video" :
                    layer.gifAnimation != nil ? "gif" : layer.text != nil ? "text" : layer.shape != nil ? "shape" : "pixel",
                "opacity": layer.opacity, "blend_mode": layer.blendMode.rawValue, "has_mask": layer.mask != nil,
                "transform": ["x": t.origin.x, "y": t.origin.y, "width": t.size.width, "height": t.size.height,
                              "rotation": t.rotation, "flip_x": t.flipX, "flip_y": t.flipY] as [String: Any],
                "adjustment": layer.adjustment.flatMap { encoded($0) } ?? NSNull(),
                "text_style": layer.liveText.flatMap { encoded($0.style) } ?? NSNull(),
                "shape_style": layer.liveShape.flatMap { encoded($0.style) } ?? NSNull()]
    }

    private func encoded(_ value: some Encodable) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func identifier(_ args: [String: Any], _ key: String) throws -> UUID {
        guard let text = args[key] as? String, let id = UUID(uuidString: text) else { throw Failure("Invalid \(key).") }
        return id
    }

    private func number(_ args: [String: Any], _ key: String) throws -> Double {
        guard let value = args[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
              abs(value.doubleValue) <= 1_000_000 else { throw Failure("Invalid \(key).") }
        return value.doubleValue
    }

    private func dimension(_ args: [String: Any], _ key: String) throws -> Int {
        let value = try number(args, key)
        guard value == value.rounded(), (1...Double(DocumentLimits.maxSide)).contains(value) else { throw Failure("Invalid canvas \(key).") }
        return Int(value)
    }

    private func color(_ args: [String: Any]) throws -> PaletteColor {
        guard let hex = args["color"] as? String, hex.count == 7, hex.first == "#",
              let value = UInt32(hex.dropFirst(), radix: 16) else { throw Failure("Use #RRGGBB for color.") }
        return PaletteColor(red: CGFloat((value >> 16) & 255) / 255,
                            green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255)
    }

    private func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 1024 else {
            throw Failure("Layer name must contain between 1 and 1024 bytes.")
        }
    }
}
