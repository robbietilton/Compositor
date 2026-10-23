import AppKit
import UniformTypeIdentifiers

/// Documents: what's open, making and opening them, saving, exporting, and seeing them.
extension AgentTools {
    static var documentTools: [AgentTool] {
        [
            AgentTool(name: "list_documents",
                      description: "The documents open in Compositor's tabs, with their ids, sizes and files. The front one is what the menus act on.",
                      schema: Schema.object([:]), readOnly: true) { call in
                .json(.array(call.workspace.tabs.map { summary(of: $0, front: $0.id == call.workspace.current.id) }))
            },
            AgentTool(name: "get_document",
                      description: """
                        A document in full: canvas size, selection, colors, undo state, and every layer bottom to top with \
                        its id, kind, parent folder, visibility, opacity, blend mode, transform, mask, clipping, effects and \
                        adjustment settings. Settings are the same JSON a .comp manifest holds, and update_layer takes them back.
                        """,
                      schema: Schema.object(["document": Schema.document]), readOnly: true) { call in
                let tab = try call.tab()
                return .json(try describe(tab))
            },
            AgentTool(name: "new_document",
                      description: "Makes a new document in a tab of its own, with one layer: filled with `background`, or empty when it's \"transparent\".",
                      schema: Schema.object([
                        "width": Schema.integer("Canvas width in pixels.", minimum: 1, maximum: DocumentLimits.maxSide),
                        "height": Schema.integer("Canvas height in pixels.", minimum: 1, maximum: DocumentLimits.maxSide),
                        "resolution": Schema.number("Pixels per inch, for printing. Default 72."),
                        "background": Schema.string("\"#RRGGBB\", or \"transparent\". Default white."),
                        "name": Schema.string("The tab's name until it's saved."),
                      ], required: ["width", "height"])) { call in
                let width = try call.int("width") ?? 0, height = try call.int("height") ?? 0
                guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height) else {
                    throw AgentError("Width and height must be 1–\(DocumentLimits.maxSide) pixels.")
                }
                let background = try call.string("background", default: "#FFFFFF")
                let fill: CGColor? = background.lowercased() == "transparent" ? nil : try color(background).nsColor.cgColor
                guard call.workspace.canSwitch else {
                    throw AgentError("Compositor can't open a new tab right now: \(busyReason(call.workspace.current.session) ?? "it's busy").")
                }
                let tab = call.workspace.addTab(reuseEmpty: true)
                if let name = try call.string("name") { tab.defaultName = name }
                tab.session.createNewProject(width: width, height: height, resolution: try call.double("resolution") ?? 72, background: fill)
                guard tab.session.document != nil else { throw AgentError("The canvas couldn't be made: \(busyReason(tab.session) ?? "unknown reason").") }
                return .json(try describe(tab))
            },
            AgentTool(name: "open_document",
                      description: "Opens a Compositor project (.comp) in a tab. The path must be inside a folder the person granted in Agent Access. To bring an image in as a layer, use add_layer instead.",
                      schema: Schema.object(["path": Schema.string("Absolute path of the .comp project.")], required: ["path"])) { call in
                let url = try AgentFolders.url(for: try call.requiredString("path"))
                guard url.pathExtension.lowercased() == "comp" else { throw AgentError("open_document opens .comp projects; add_layer brings images in.") }
                guard FileManager.default.fileExists(atPath: url.path) else { throw AgentError("Nothing at \(url.path).") }
                // Checked first, so a project that can't load is reported here rather than in an alert the person must close.
                do { _ = try await ProjectStore.shared.load(from: url) } catch { throw AgentError("That project can't be opened: \(error.localizedDescription)") }
                guard await call.workspace.open(url), call.workspace.current.session.projectURL?.standardizedFileURL == url else {
                    throw AgentError("Compositor couldn't open it now: \(busyReason(call.workspace.current.session) ?? "it's busy").")
                }
                return .json(try describe(call.workspace.current))
            },
            AgentTool(name: "save_document",
                      description: "Saves the document as a .comp project: to `path` (inside a folder granted in Agent Access), or with no path to the file it came from.",
                      schema: Schema.object(["document": Schema.document,
                                             "path": Schema.string("Where to save, ending in .comp. Omitted: the project's own file.")])) { call in
                let tab = try call.tab()
                _ = try call.session()
                let destination: URL
                if let path = try call.string("path") {
                    destination = try AgentFolders.url(for: path)
                    guard destination.pathExtension.lowercased() == "comp" else { throw AgentError("A project's path ends in .comp.") }
                } else if let url = tab.session.projectURL {
                    destination = url
                } else {
                    throw AgentError("This document hasn't been saved before; give a path.")
                }
                do { try await tab.controller.save(to: destination) }
                catch { throw AgentError("It couldn't be saved: \(error.localizedDescription)") }
                return .text("Saved to \(destination.path).")
            },
            AgentTool(name: "export_image",
                      description: """
                        The whole canvas flattened to a PNG or JPEG: written to `path` (inside a folder granted in Agent \
                        Access), or with no path, returned to you as the image itself.
                        """,
                      schema: Schema.object([
                        "document": Schema.document,
                        "format": Schema.string("Default png.", oneOf: ["png", "jpeg"]),
                        "path": Schema.string("Where to write it. Omitted: the image comes back in the result."),
                        "quality": Schema.number("JPEG quality, 0–1. Default 0.9."),
                        "max_size": Schema.integer("Scale down to this many pixels on the longer side. Default: full size.", minimum: 1),
                      ])) { call in
                let session = try call.session(editing: false)
                let jpeg = try call.string("format", default: "png").lowercased() == "jpeg"
                let image = AgentImage.scaled(try await composite(session), maxSide: try call.int("max_size") ?? 0)
                let data = try AgentImage.encode(image, as: jpeg ? .jpeg : .png, quality: min(1, max(0, try call.double("quality") ?? 0.9)))
                if let path = try call.string("path") {
                    let url = try AgentFolders.url(for: path)
                    do { try data.write(to: url, options: .atomic) } catch { throw AgentError("It couldn't be written: \(error.localizedDescription)") }
                    return .text("Wrote a \(image.width)×\(image.height) \(jpeg ? "JPEG" : "PNG") to \(url.path).")
                }
                var result = AgentResult.text("The canvas, \(image.width)×\(image.height).")
                result.addImage(data, type: jpeg ? "image/jpeg" : "image/png")
                return result
            },
            AgentTool(name: "render",
                      description: """
                        Shows you the canvas as it looks now, as an image: everything, or one layer on its own. Use it to \
                        check your work after each step.
                        """,
                      schema: Schema.object([
                        "document": Schema.document,
                        "layer_id": Schema.string("Render only this layer (and folders above it). Omitted: the whole canvas."),
                        "max_size": Schema.integer("Longer side in pixels. Default 1024.", minimum: 16, maximum: 4096),
                      ]), readOnly: true) { call in
                let session = try call.session(editing: false)
                let only = try call.has("layer_id") ? call.layer(in: session).id : nil
                let full = try await composite(session, only: only)
                let image = AgentImage.scaled(full, maxSide: try call.int("max_size") ?? 1024)
                var result = AgentResult.text("Rendered the \(full.width)×\(full.height) canvas\(only == nil ? "" : " (one layer)") at \(image.width)×\(image.height).")
                result.addImage(try AgentImage.encode(image, as: .png), type: "image/png")
                return result
            },
        ]
    }

    static func summary(of tab: ProjectTab, front: Bool) -> JSONValue {
        let document = tab.session.document
        var summary: [String: JSONValue] = [
            "id": .string(tab.id.uuidString), "title": .string(tab.title), "front": .bool(front),
            "modified": .bool(tab.session.isModified),
            "path": tab.session.projectURL.map { .string($0.path) } ?? .null,
        ]
        if let document {
            summary["width"] = .number(Double(document.width))
            summary["height"] = .number(Double(document.height))
            summary["layer_count"] = .number(Double(document.layers.count))
        }
        return .object(summary)
    }

    static func describe(_ tab: ProjectTab) throws -> JSONValue {
        let session = tab.session
        guard var description = summary(of: tab, front: true).object else { return .null }
        description["front"] = nil
        guard let document = session.document else { return .object(description) }
        description["resolution"] = .number(document.resolution)
        description["active_layer_id"] = session.activeLayerID.map { .string($0.uuidString) } ?? .null
        description["selected_layer_ids"] = .array(document.layers.map(\.id).filter(session.selectedLayerIDs.contains).map { .string($0.uuidString) })
        if let selection = document.selection, !selection.isEmpty {
            let bounds = selection.path.boundingBoxOfPath
            description["selection"] = .object(["x": .number(bounds.minX), "y": .number(bounds.minY),
                                                "width": .number(bounds.width), "height": .number(bounds.height)])
        } else {
            description["selection"] = .null
        }
        description["foreground_color"] = .string("#" + session.foregroundColor.hex)
        description["background_color"] = .string("#" + session.backgroundColor.hex)
        description["undo"] = session.history.canUndo ? .string(session.history.undoName) : .null
        description["redo"] = session.history.canRedo ? .string(session.history.redoName) : .null
        description["layers"] = .array(try document.layers.map { try describe($0, in: session) })
        return .object(description)
    }

    static func describe(_ layer: ImageLayer, in session: EditorSession) throws -> JSONValue {
        let kind = layer.isGroup ? "folder" : layer.adjustment != nil ? "adjustment" : layer.liveText != nil ? "text"
            : layer.liveShape != nil ? "shape" : layer.gifAnimation != nil ? "gif" : layer.asset == nil ? "empty" : "pixels"
        var description: [String: JSONValue] = [
            "id": .string(layer.id.uuidString), "name": .string(layer.name), "kind": .string(kind),
            "parent_id": layer.parentID.map { .string($0.uuidString) } ?? .null,
            "visible": .bool(layer.isVisible), "opacity": .number(layer.opacity), "blend_mode": .string(layer.blendMode.rawValue),
            "transform": try JSONValue.encoding(layer.transform),
            "clipped_to": layer.maskSourceID.map { .string($0.uuidString) } ?? .null,
        ]
        if let image = layer.asset?.image { description["pixel_size"] = .array([.number(Double(image.width)), .number(Double(image.height))]) }
        if let mask = layer.mask { description["mask"] = .object(["enabled": .bool(mask.isEnabled), "linked": .bool(mask.isLinked)]) }
        if let adjustment = layer.adjustment { description["adjustment"] = try JSONValue.encoding(adjustment) }
        if let effects = layer.effects, !effects.isEmpty { description["effects"] = try JSONValue.encoding(effects) }
        if let text = layer.liveText?.style { description["text"] = try JSONValue.encoding(text) }
        if let shape = layer.liveShape?.style { description["shape"] = try JSONValue.encoding(shape) }
        return .object(description)
    }

    /// The canvas flattened as export flattens it; with `only`, that layer alone (with the folders it's in).
    static func composite(_ session: EditorSession, only: UUID? = nil) async throws -> CGImage {
        guard var snapshot = session.projectSnapshot() else { throw AgentError("This document has no canvas yet.") }
        if let only {
            var manifest = snapshot.manifest
            for index in manifest.layers.indices where manifest.layers[index].isGroup != true {
                manifest.layers[index].isVisible = manifest.layers[index].id == only
            }
            snapshot = ProjectSnapshot(manifest: manifest, images: snapshot.images, masks: snapshot.masks, animations: snapshot.animations)
        }
        do { return try await ImageExporter.shared.render(snapshot).image }
        catch { throw AgentError("The canvas couldn't be rendered: \(error.localizedDescription)") }
    }
}
