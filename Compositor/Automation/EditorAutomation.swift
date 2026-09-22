import AppKit
import CoreFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum EditorAutomationError: LocalizedError {
    case invalidParams(String)
    case busy(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidParams(let message), .busy(let message), .unavailable(let message): message
        }
    }
}

/// The typed bridge between MCP and the native editor model. It deliberately calls the same
/// semantic operations as the UI, so every mutation uses the app's validation and undo history.
@MainActor
final class EditorAutomation {
    let workspace: ProjectWorkspace
    private var observedFingerprint = ""
    private var revision = 0
    /// Data-opened projects have no filesystem save destination, so keep them visibly dirty and
    /// protect them from a silent close even though installing a snapshot resets native history.
    private var transportDirtyTabs: Set<UUID> = []

    init(workspace: ProjectWorkspace) {
        self.workspace = workspace
        syncRevision()
    }

    var tools: [[String: Any]] {
        [
            tool("get_capabilities", "Read native enum values and complete default settings models for automation.", properties: [:]),
            tool("list_documents", "List open document tabs and the selected document.", properties: [:]),
            tool("describe_document", "Read one document's canvas, layers, selection, history, and editability.", properties: [
                "document_id": string("Stable tab identifier; defaults to the selected document.")
            ]),
            tool("get_editor_state", "Read all open documents and full state for the selected document.", properties: [:]),
            tool("new_document", "Create a native editable canvas.", properties: [
                "width": integer("Canvas width in pixels.", minimum: 1, maximum: 30_000),
                "height": integer("Canvas height in pixels.", minimum: 1, maximum: 30_000),
                "new_tab": boolean("Open in a new tab. Defaults to true."),
                "discard_changes": boolean("Required to replace a modified document when new_tab is false."),
                "expected_revision": integer("Reject if editor state has changed since this revision.", minimum: 0)
            ], required: ["width", "height"]),
            tool("close_document", "Close a tab. Modified documents require discard_changes=true.", properties: [
                "document_id": string("Stable tab identifier; defaults to the selected document."),
                "discard_changes": boolean("Explicitly discard unsaved changes."),
                "expected_revision": integer("Optimistic concurrency revision.", minimum: 0)
            ]),
            tool("read_project_data", "Serialize a complete editable project as a base64 transport envelope.", properties: [
                "document_id": string("Stable tab identifier; defaults to the selected document.")
            ]),
            tool("open_project_data", "Open project data returned by read_project_data in a new native tab.", properties: [
                "data": string("Base64 project transport envelope."),
                "expected_revision": integer("Optimistic concurrency revision.", minimum: 0)
            ], required: ["data"]),
            tool("import_image", "Decode base64 image data and insert it as a real pixel layer, or import a layered PSD with native conversion warnings.", properties: [
                "data": string("Base64 PNG, JPEG, HEIC, TIFF, or PSD data."),
                "filename": string("Filename with a supported image or .psd extension."),
                "x": number("Optional document-space center x."), "y": number("Optional document-space center y."),
                "expected_revision": integer("Optimistic concurrency revision.", minimum: 0)
            ], required: ["data", "filename"]),
            tool("render_document", "Render the actual compositor result as PNG.", properties: [
                "document_id": string("Stable tab identifier; defaults to the selected document."),
                "max_dimension": integer("Longest output side. Defaults to 1600; pass 0 for full resolution.", minimum: 0, maximum: 30_000)
            ]),
            tool("layer_operation", "Create, select, rename, delete, duplicate, group, merge, move, parent, hide, blend, or change layer opacity.", properties: [
                "action": enumeration("Layer operation.", ["add", "add_group", "select", "rename", "delete", "duplicate", "group_selected", "merge", "move", "place", "visibility", "opacity", "blend"]),
                "layer_id": string("Target layer UUID."), "layer_ids": array(string("Layer UUID.")),
                "name": string("Layer name."), "visible": boolean("Visibility."),
                "opacity": number("Opacity from 0 to 1.", minimum: 0, maximum: 1),
                "blend_mode": enumeration("Native blend mode.", LayerBlendMode.allCases.map(\.rawValue)),
                "offset": integer("Sibling move: -1 down or 1 up.", minimum: -1, maximum: 1),
                "parent_id": string("Destination group UUID; omit/null for root."),
                "above_id": string("Place immediately above this sibling."),
                "at_bottom": boolean("Place at the bottom of the destination."),
                "expected_revision": integer("Optimistic concurrency revision.", minimum: 0)
            ], required: ["action"]),
            tool("text_operation", "Create or edit a live editable text layer.", properties: [
                "action": enumeration("Text operation.", ["create", "update"]),
                "layer_id": string("Text layer UUID for update."), "content": string("Text content."),
                "x": number("Create-only document x."), "y": number("Create-only document y."),
                "width": number("Create-only paragraph width; requires height.", minimum: 16, maximum: 30_000),
                "height": number("Create-only paragraph height; requires width.", minimum: 16, maximum: 30_000),
                "font_name": string("PostScript font name."), "font_size": number("Font size.", minimum: 1, maximum: 2_000),
                "alignment": enumeration("Paragraph alignment.", TextAlignment.allCases.map(\.rawValue)),
                "tracking": number("Tracking.", minimum: -100, maximum: 1_000),
                "leading": number("Leading; 0 means automatic.", minimum: 0, maximum: 5_000),
                "color": colorSchema(), "expected_revision": integer("Optimistic concurrency revision.", minimum: 0)
            ], required: ["action", "content"]),
            tool("shape_operation", "Create a live editable rectangle, ellipse, or line layer.", properties: [
                "kind": enumeration("Shape kind.", ShapeKind.allCases.map(\.rawValue)),
                "x": number("Origin x."), "y": number("Origin y."), "width": number("Width or line delta x."), "height": number("Height or line delta y."),
                "color": colorSchema(), "corner_radius": number("Rectangle corner radius.", minimum: 0),
                "line_width": number("Line thickness.", minimum: 0.1, maximum: 5_000),
                "expected_revision": integer("Optimistic concurrency revision.", minimum: 0)
            ], required: ["kind", "x", "y", "width", "height"]),
            tool("adjustment_operation", "Add or update a native nondestructive adjustment layer.", properties: [
                "action": enumeration("Adjustment operation.", ["add", "update"]),
                "layer_id": string("Adjustment layer UUID for update."),
                "kind": enumeration("Adjustment kind.", AdjustmentKind.allCases.map(\.rawValue)),
                "hue": number("Hue shift.", minimum: -360, maximum: 360), "saturation": number("Saturation.", minimum: -100, maximum: 100),
                "lightness": number("Lightness.", minimum: -100, maximum: 100), "colorize": boolean("Colorize hue/saturation."),
                "radius": number("Gaussian blur radius.", minimum: 0.1, maximum: 250), "angle": number("Motion angle.", minimum: -90, maximum: 90),
                "distance": number("Motion distance.", minimum: 1, maximum: 2_000), "amount": number("Noise amount.", minimum: 0.1, maximum: 400),
                "gaussian": boolean("Gaussian noise."), "monochromatic": boolean("Monochromatic noise."),
                "value": ["type": "object", "description": "Complete LayerAdjustment JSON value; replaces individual settings when present."],
                "expected_revision": integer("Optimistic concurrency revision.", minimum: 0)
            ], required: ["action"]),
            tool("effect_operation", "Add, update, enable, or remove a nondestructive layer effect.", properties: [
                "action": enumeration("Effect operation.", ["add", "update", "remove", "enable"]),
                "layer_id": string("Target layer UUID."), "kind": enumeration("Effect kind.", LayerEffectKind.allCases.map(\.rawValue)),
                "enabled": boolean("Effect enabled state."), "size": number("Stroke/glow size.", minimum: 0, maximum: 500),
                "angle": number("Shadow light angle.", minimum: -360, maximum: 360), "distance": number("Shadow distance.", minimum: 0, maximum: 5_000),
                "blur": number("Shadow blur.", minimum: 0, maximum: 500), "opacity": number("Effect opacity.", minimum: 0, maximum: 1),
                "inside": boolean("Put stroke inside."), "color": colorSchema(),
                "value": ["type": "object", "description": "Complete LayerEffects JSON value; replaces individual settings when present."],
                "expected_revision": integer("Optimistic concurrency revision.", minimum: 0)
            ], required: ["action", "kind"]),
            tool("transform_operation", "Set a layer or unlinked mask transform as one undo step.", properties: [
                "layer_id": string("Target layer UUID."), "target": enumeration("Transform target.", ["layer", "mask"]),
                "x": number("Origin x."), "y": number("Origin y."), "width": number("Width.", minimum: 1), "height": number("Height.", minimum: 1),
                "rotation": number("Rotation in degrees."), "flip_x": boolean("Horizontal flip."), "flip_y": boolean("Vertical flip."),
                "expected_revision": integer("Optimistic concurrency revision.", minimum: 0)
            ], required: ["layer_id"]),
            tool("mask_operation", "Add, delete, enable, link, unlink, copy, select, or change whether a layer mask moves with its layer.", properties: [
                "action": enumeration("Mask operation.", ["add", "delete", "enable", "link", "unlink", "copy", "select", "set_linked"]),
                "layer_id": string("Target layer UUID."), "source_id": string("Mask source UUID for link/copy."),
                "revealing": boolean("New mask starts white when true."), "from_selection": boolean("Use the selection to paint the opposite mask value and consume the selection, as the native Add Mask command does."), "enabled": boolean("Mask enabled state."),
                "linked": boolean("Whether the layer's own mask moves with the layer."),
                "target": enumeration("Select layer pixels or mask.", ["layer", "mask"]),
                "expected_revision": integer("Optimistic concurrency revision.", minimum: 0)
            ], required: ["action", "layer_id"]),
            tool("selection_operation", "Create or modify the document selection.", properties: [
                "action": enumeration("Selection operation.", ["rectangle", "ellipse", "polygon", "all", "deselect", "invert", "expand", "contract", "feather"]),
                "mode": enumeration("How a new shape combines with the selection.", SelectionMode.allCases.map(\.rawValue)),
                "x": number("Rectangle x."), "y": number("Rectangle y."), "width": number("Rectangle width."), "height": number("Rectangle height."),
                "points": array(pointSchema()), "amount": integer("Expand, contract, or feather pixels.", minimum: 0, maximum: 30_000),
                "antialiased": boolean("Antialias a new selection."), "expected_revision": integer("Optimistic concurrency revision.", minimum: 0)
            ], required: ["action"]),
            tool("paint_stroke", "Paint, erase, heal, clone, blur, smudge, or liquify through the native raster engine.", properties: [
                "mode": enumeration("Stroke mode.", ["paint", "erase", "heal", "clone", "blur", "smudge", "liquify"]),
                "layer_id": string("Target pixel layer UUID."), "target": enumeration("Paint layer pixels or its mask; defaults to the current target.", ["layer", "mask"]), "points": array(pointSchema()),
                "diameter": number("Brush diameter.", minimum: 1, maximum: 30_000), "hardness": number("Hardness 0 to 1.", minimum: 0, maximum: 1),
                "opacity": number("Opacity/strength 0 to 1.", minimum: 0, maximum: 1), "color": colorSchema(),
                "clone_source": pointSchema(), "expected_revision": integer("Optimistic concurrency revision.", minimum: 0)
            ], required: ["mode", "layer_id", "points"]),
            tool("filter_operation", "Apply a native destructive filter to layer pixels or its mask as one undo step.", properties: [
                "layer_id": string("Target pixel layer UUID."), "target": enumeration("Filter layer pixels or its mask; defaults to layer.", ["layer", "mask"]),
                "kind": enumeration("Filter kind.", FilterKind.allCases.map(\.rawValue)),
                "radius": number("Gaussian radius.", minimum: 0.1, maximum: 250), "angle": number("Motion angle.", minimum: -90, maximum: 90),
                "distance": number("Motion distance.", minimum: 1, maximum: 2_000), "amount": number("Noise amount.", minimum: 0.1, maximum: 400),
                "gaussian": boolean("Gaussian noise."), "monochromatic": boolean("Monochromatic noise."),
                "distortion": number("Lens distortion.", minimum: -100, maximum: 100),
                "background_quality": enumeration("Remove-background quality.", BackgroundQuality.allCases.map(\.rawValue)),
                "refine_edges": number("Edge refinement.", minimum: 0, maximum: 40), "matte_contrast": number("Matte contrast.", minimum: 0, maximum: 100),
                "shift_edge": number("Mask edge shift.", minimum: -10, maximum: 10),
                "parameters": ["type": "object", "description": "Kind-specific native settings. Use get_capabilities for the complete default shape."],
                "expected_revision": integer("Optimistic concurrency revision.", minimum: 0)
            ], required: ["layer_id", "kind"]),
            tool("history_operation", "Undo or redo the selected document.", properties: [
                "action": enumeration("History operation.", ["undo", "redo"]),
                "expected_revision": integer("Optimistic concurrency revision.", minimum: 0)
            ], required: ["action"]),
            tool("settings_operation", "Set editor tool, palette, snapping, or viewport settings.", properties: [
                "tool": enumeration("Active navigation tool.", NavigationTool.allCases.map(\.rawValue)),
                "foreground": colorSchema(), "background": colorSchema(), "snapping_enabled": boolean("Enable transform snapping."),
                "show_grid": boolean("Show layout grid."), "show_guides": boolean("Show guides."), "show_rulers": boolean("Show rulers."),
                "zoom": number("Viewport zoom factor.", minimum: 0.001, maximum: 32),
                "expected_revision": integer("Optimistic concurrency revision.", minimum: 0)
            ])
        ] + AdvancedAutomation.tools
    }

    func call(_ name: String, arguments: [String: Any]) async throws -> [String: Any] {
        switch name {
        case "get_capabilities": return response("Editor capabilities", capabilities())
        case "list_documents": return response("Open documents", documentsSummary())
        case "describe_document":
            let tab = try tab(arguments["document_id"])
            return response("Document \(tab.title)", describe(tab))
        case "get_editor_state": return response("Editor state", editorState())
        case "new_document": return try mutate(arguments) { try newDocument(arguments) }
        case "close_document": return try mutate(arguments) { try closeDocument(arguments) }
        case "read_project_data": return try await readProjectData(arguments)
        case "open_project_data": return try await mutateAsync(arguments) { try await openProjectData(arguments) }
        case "import_image": return try await mutateAsync(arguments) { try await importImage(arguments) }
        case "render_document": return try await renderDocument(arguments)
        case "layer_operation": return try mutate(arguments) { try layerOperation(arguments) }
        case "text_operation": return try mutate(arguments) { try textOperation(arguments) }
        case "shape_operation": return try mutate(arguments) { try shapeOperation(arguments) }
        case "adjustment_operation": return try mutate(arguments) { try adjustmentOperation(arguments) }
        case "effect_operation": return try mutate(arguments) { try effectOperation(arguments) }
        case "transform_operation": return try mutate(arguments) { try transformOperation(arguments) }
        case "mask_operation": return try mutate(arguments) { try maskOperation(arguments) }
        case "selection_operation": return try mutate(arguments) { try selectionOperation(arguments) }
        case "paint_stroke": return try await mutateAsync(arguments) { try await paintStroke(arguments) }
        case "filter_operation": return try await mutateAsync(arguments) { try await filterOperation(arguments) }
        case "history_operation": return try mutate(arguments) { try historyOperation(arguments) }
        case "settings_operation": return try mutate(arguments) { try settingsOperation(arguments) }
        default:
            if AdvancedAutomation.tools.contains(where: { $0["name"] as? String == name }) {
                return try await mutateAsync(arguments) { try requireEditable(); return try await AdvancedAutomation(workspace: workspace).call(name, arguments: arguments) }
            }
            throw EditorAutomationError.invalidParams("Unknown editor tool: \(name)")
        }
    }

    // MARK: - Documents and serialization

    private func newDocument(_ a: [String: Any]) throws -> String {
        try requireWorkspaceReady()
        let width = try int(a, "width", range: 1...30_000), height = try int(a, "height", range: 1...30_000)
        let opensTab = a["new_tab"] as? Bool ?? true
        let current = workspace.current
        if !opensTab, current.session.isModified || transportDirtyTabs.contains(current.id), a["discard_changes"] as? Bool != true {
            throw invalid("The selected document has unsaved changes; pass discard_changes=true to replace it.")
        }
        let target = opensTab ? workspace.addTab() : current
        if !opensTab { transportDirtyTabs.remove(target.id) }
        target.session.createNewProject(width: width, height: height)
        guard target.session.document?.width == width, target.session.document?.height == height else { throw unavailable("Could not create the canvas.") }
        return "Created \(width)×\(height) document"
    }

    private func closeDocument(_ a: [String: Any]) throws -> String {
        try requireWorkspaceReady()
        let target = try tab(a["document_id"])
        try requireSessionReady(target.session)
        guard !(target.session.isModified || transportDirtyTabs.contains(target.id)) || a["discard_changes"] as? Bool == true else {
            throw invalid("Document has unsaved changes; pass discard_changes=true to close it.")
        }
        transportDirtyTabs.remove(target.id)
        workspace.removeTab(target.id)
        return "Closed \(target.title)"
    }

    private struct ProjectEnvelope: Codable {
        let format: String
        let manifest: Data
        let images: [String: Data]
    }

    private func readProjectData(_ a: [String: Any]) async throws -> [String: Any] {
        let target = try tab(a["document_id"])
        guard canSnapshot(target.session) else { throw busy("Finish the active edit before reading project data.") }
        guard let snapshot = target.session.projectSnapshot() else { throw unavailable("The document has no canvas.") }
        var files: [String: Data] = [:]
        for layer in snapshot.manifest.layers {
            if let name = layer.imageFile, let image = snapshot.images[layer.id]?.image { files[name] = try png(image) }
            if let name = layer.maskFile, let image = snapshot.masks[layer.id]?.image { files[name] = try png(image) }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let envelope = ProjectEnvelope(format: "com.compositor.mcp-project", manifest: try encoder.encode(snapshot.manifest), images: files)
        let data = try encoder.encode(envelope)
        guard data.count <= 24 * 1024 * 1024 else { throw unavailable("The encoded project exceeds the 24 MB automation transport limit.") }
        syncRevision()
        return response("Serialized \(target.title)", ["document_id": target.id.uuidString, "revision": revision,
            "data": data.base64EncodedString(), "byte_length": data.count])
    }

    private func openProjectData(_ a: [String: Any]) async throws -> String {
        try requireWorkspaceReady()
        let sourceSession = session
        workspace.isManaging = true
        sourceSession.isProjectBusy = true
        defer { sourceSession.isProjectBusy = false; workspace.isManaging = false }
        guard let encoded = a["data"] as? String, encoded.utf8.count <= 32 * 1024 * 1024,
              let raw = Data(base64Encoded: encoded), raw.count <= 24 * 1024 * 1024 else {
            throw invalid("data must be valid base64 project data no larger than 24 MB.")
        }
        let envelope: ProjectEnvelope
        do { envelope = try JSONDecoder().decode(ProjectEnvelope.self, from: raw) }
        catch { throw invalid("data is not a valid Compositor project envelope.") }
        guard envelope.format == "com.compositor.mcp-project" else { throw invalid("Unsupported project envelope format.") }
        let manifest: ProjectManifest
        do { manifest = try JSONDecoder().decode(ProjectManifest.self, from: envelope.manifest) }
        catch { throw invalid("The project manifest is invalid.") }
        let expectedFiles = Set(manifest.layers.flatMap { [$0.imageFile, $0.maskFile].compactMap { $0 } })
        guard Set(envelope.images.keys) == expectedFiles,
              envelope.images.keys.allSatisfy({ !$0.contains("/") && !$0.contains("\\") && !$0.contains("..") }) else {
            throw invalid("Project image filenames do not exactly match the manifest.")
        }
        let package = FileWrapper(directoryWithFileWrappers: [
            "manifest.json": FileWrapper(regularFileWithContents: envelope.manifest),
            "images": FileWrapper(directoryWithFileWrappers: envelope.images.mapValues(FileWrapper.init(regularFileWithContents:)))
        ])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try package.write(to: url, options: .atomic, originalContentsURL: nil)
        let snapshot = try await ProjectStore.shared.load(from: url)
        try Task.checkCancellation()
        let target = workspace.addTab(reuseEmpty: false)
        target.session.installProject(snapshot, from: url)
        target.session.projectURL = nil
        target.session.history.begin("Import Project", document: nil, selection: nil)
        target.session.history.end(document: target.session.document, selection: target.session.activeLayerID)
        transportDirtyTabs.insert(target.id)
        return "Opened project in \(target.defaultName)"
    }

    private func importImage(_ a: [String: Any]) async throws -> String {
        if session.document == nil { try requireWorkspaceReady() } else { try requireEditable() }
        guard let encoded = a["data"] as? String, encoded.utf8.count <= 32 * 1024 * 1024,
              let data = Data(base64Encoded: encoded), data.count <= 24 * 1024 * 1024 else {
            throw invalid("data must be valid base64 image data no larger than 24 MB.")
        }
        let filename = try nonempty(a, "filename")
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "heic", "tif", "tiff", "psd"].contains(ext) else { throw invalid("filename must have a supported image extension.") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url, options: .atomic)
        if ext == "psd" {
            return try await PhotoshopAutomation.importData(url: url, filename: filename,
                point: try optionalPoint(a, x: "x", y: "y"), workspace: workspace)
        }
        let used = session.document?.layers.reduce(0) { $0 + ($1.asset.map { $0.image.width * $0.image.height } ?? 0) } ?? 0
        session.isProjectBusy = true
        let asset: ImportedImage
        do {
            asset = try await ImageImporter.shared.decode(url, remainingPixels: 100_000_000 - used)
            try Task.checkCancellation()
        }
        catch { session.isProjectBusy = false; throw error }
        session.isProjectBusy = false
        let point = try optionalPoint(a, x: "x", y: "y")
        let before = session.document?.layers.count ?? 0
        session.insert(ImportedImage(image: asset.image, thumbnail: asset.thumbnail, name: URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent), centeredAt: point)
        guard (session.document?.layers.count ?? 0) == before + 1 else { throw unavailable("The decoded image could not be inserted.") }
        return "Imported \(filename)"
    }

    private func renderDocument(_ a: [String: Any]) async throws -> [String: Any] {
        let target = try tab(a["document_id"])
        guard canSnapshot(target.session) else { throw busy("Finish the active edit before rendering the document.") }
        syncRevision()
        let snapshotRevision = revision
        guard let snapshot = target.session.projectSnapshot() else { throw unavailable("The document has no canvas.") }
        let raster = try await ImageExporter.shared.render(snapshot)
        try Task.checkCancellation()
        let maxDimension = try optionalInt(a["max_dimension"]) ?? 1_600
        guard (0...30_000).contains(maxDimension) else { throw invalid("max_dimension must be 0...30,000.") }
        let image = try scaledPreview(raster.image, maxDimension: maxDimension)
        let data = try png(image)
        guard data.count <= 24 * 1024 * 1024 else { throw unavailable("Rendered PNG exceeds the 24 MB automation transport limit; use a smaller max_dimension.") }
        syncRevision()
        return ["content": [
            ["type": "text", "text": "Rendered \(target.title) at \(snapshot.manifest.width)×\(snapshot.manifest.height)."],
            ["type": "image", "data": data.base64EncodedString(), "mimeType": "image/png"]
        ], "structuredContent": ["document_id": target.id.uuidString, "revision": snapshotRevision,
            "current_revision": revision, "stale": snapshotRevision != revision,
            "width": image.width, "height": image.height, "source_width": snapshot.manifest.width, "source_height": snapshot.manifest.height,
            "mime_type": "image/png", "byte_length": data.count]]
    }

    // MARK: - Editing operations

    private func layerOperation(_ a: [String: Any]) throws -> String {
        try requireEditable()
        let action = try nonempty(a, "action")
        switch action {
        case "add": session.addBlankLayer()
        case "add_group": session.addGroup()
        case "select":
            if let values = a["layer_ids"] as? [Any] {
                let ids = try Set(values.map(uuid)); guard !ids.isEmpty else { throw invalid("layer_ids cannot be empty.") }
                for id in ids { _ = try layer(id) }
                session.selectLayers(ids, primary: try optionalUUID(a["layer_id"]) ?? ids.first)
            } else { session.selectLayer(try requiredLayerID(a)) }
        case "rename": session.renameLayer(try requiredLayerID(a), to: try nonempty(a, "name"))
        case "delete":
            let id = try requiredLayerID(a)
            let removed = session.descendantIDs(of: id).union([id])
            let dependents = (session.document?.layers ?? []).filter {
                !removed.contains($0.id) && $0.maskSourceID.map(removed.contains) == true
            }.map(\.id)
            guard dependents.isEmpty else {
                let ids = dependents.map(\.uuidString).joined(separator: ", ")
                throw invalid("Cannot delete a layer that supplies a live mask to dependent layers (\(ids)). Unlink those layers with mask_operation first.")
            }
            session.selectLayer(id); session.deleteActiveLayer()
        case "duplicate": session.selectLayer(try requiredLayerID(a)); session.duplicateActiveLayer()
        case "group_selected": session.groupSelectedLayers()
        case "merge": session.mergeLayers()
        case "move": session.selectLayer(try requiredLayerID(a)); session.moveActiveLayer(by: try int(a, "offset", range: -1...1))
        case "place":
            let id = try requiredLayerID(a), parent = try optionalUUID(a["parent_id"]), above = try optionalUUID(a["above_id"])
            guard session.placeLayer(id, in: parent, above: above, atBottom: a["at_bottom"] as? Bool ?? false) else { throw invalid("That layer placement is not valid.") }
        case "visibility":
            let id = try requiredLayerID(a), desired = try bool(a, "visible"), current = try layer(id).isVisible
            if desired != current { session.toggleLayerVisibility(id) }
        case "opacity": session.selectLayer(try requiredLayerID(a)); session.setLayerOpacity(try double(a, "opacity", range: 0...1))
        case "blend":
            session.selectLayer(try requiredLayerID(a)); session.setLayerBlendMode(try enumValue(a, "blend_mode", LayerBlendMode.allCases))
        default: throw invalid("Unknown layer action \(action).")
        }
        return "Layer \(action) completed"
    }

    private func textOperation(_ a: [String: Any]) throws -> String {
        try requireEditable()
        let action = try nonempty(a, "action"), content = try string(a, "content")
        if action == "create" {
            guard (a["width"] == nil) == (a["height"] == nil) else {
                throw invalid("width and height must be provided together for paragraph text.")
            }
            let x = try optionalDouble(a["x"]) ?? 0, y = try optionalDouble(a["y"]) ?? 0
            if let width = try optionalDouble(a["width"]), let height = try optionalDouble(a["height"]) {
                session.beginText(in: CGRect(x: x, y: y, width: width, height: height))
            } else { session.beginText(at: CGPoint(x: x, y: y), newLayer: true) }
        } else if action == "update" {
            guard ["x", "y", "width", "height"].allSatisfy({ a[$0] == nil }) else {
                throw invalid("Text geometry is create-only; use transform_operation to move or resize an existing text layer.")
            }
            session.selectLayer(try requiredLayerID(a)); session.editActiveText()
        } else { throw invalid("Unknown text action \(action).") }
        guard var draft = session.textDraft else { throw unavailable("The target is not editable text.") }
        defer { if session.textDraft != nil { session.cancelText() } }
        draft.style.content = content
        if let value = a["font_name"] as? String { draft.style.fontName = value }
        if let value = try optionalDouble(a["font_size"]) { draft.style.fontSize = value }
        if let value = a["alignment"] as? String, let alignment = TextAlignment.allCases.first(where: { matches($0.rawValue, value) }) { draft.style.alignment = alignment }
        if let value = try optionalDouble(a["tracking"]) { draft.style.tracking = value }
        if let value = try optionalDouble(a["leading"]) { draft.style.leading = value }
        if let color = try optionalColor(a["color"]) { draft.style.red = color.red; draft.style.green = color.green; draft.style.blue = color.blue }
        guard session.applyText(draft) else {
            let message = session.brushError ?? "Text could not be applied."
            session.cancelText()
            throw unavailable(message)
        }
        return "Text \(action) completed"
    }

    private func shapeOperation(_ a: [String: Any]) throws -> String {
        try requireEditable()
        let kind: ShapeKind = try enumValue(a, "kind", ShapeKind.allCases)
        let x = try double(a, "x"), y = try double(a, "y"), width = try double(a, "width"), height = try double(a, "height")
        guard width != 0 || height != 0 else { throw invalid("Shape width and height cannot both be zero.") }
        guard abs(width) <= 30_000, abs(height) <= 30_000, abs(width * height) <= 100_000_000 else {
            throw invalid("Shape exceeds the 30,000-pixel side or 100-megapixel limit.")
        }
        let before = session.document?.layers.count ?? 0
        session.selectTool(.shape); session.shapeKind = kind
        if let color = try optionalColor(a["color"]) { session.foregroundColor = color }
        if let radius = try optionalDouble(a["corner_radius"]) { session.shapeCornerRadius = radius }
        if let line = try optionalDouble(a["line_width"]) { session.shapeLineWidth = line }
        session.beginShape(at: CGPoint(x: x, y: y)); session.dragShape(to: CGPoint(x: x + width, y: y + height), square: false, fromCenter: false); session.finishShape()
        guard (session.document?.layers.count ?? 0) == before + 1 else { throw unavailable(session.brushError ?? "The shape could not be created.") }
        return "Created \(kind.rawValue)"
    }

    private func adjustmentOperation(_ a: [String: Any]) throws -> String {
        try requireEditable()
        let action = try nonempty(a, "action")
        guard action == "add" || action == "update" else { throw invalid("Unknown adjustment action \(action).") }
        let id: UUID?
        var value: LayerAdjustment
        if action == "add" {
            id = nil
            value = LayerAdjustment(kind: try enumValue(a, "kind", AdjustmentKind.allCases))
            if value.kind == .gradientMap {
                value.gradientMap = GradientMapSettings(shadows: AdjustmentColor(session.foregroundColor), highlights: AdjustmentColor(session.backgroundColor))
            }
            if value.kind == .grain { value.grain.seed = .random(in: .min ... .max) }
            if value.kind == .addNoise { value.resolvedNoiseSeed = .random(in: .min ... .max) }
        } else {
            id = try requiredLayerID(a)
            guard let existing = try layer(id!).adjustment else { throw invalid("layer_id is not an adjustment layer.") }
            value = existing
        }
        let kind = value.kind
        if let object = a["value"] as? [String: Any] {
            try validateNestedJSON(object)
            do {
                let data = try JSONSerialization.data(withJSONObject: object)
                guard data.count <= 64 * 1024 else { throw invalid("value exceeds 64 KB.") }
                value = try JSONDecoder().decode(LayerAdjustment.self, from: data)
            }
            catch { throw invalid("value is not a valid LayerAdjustment object.") }
        }
        if let v = try optionalDouble(a["hue"]) { value.hue = v }
        if let v = try optionalDouble(a["saturation"]) { value.saturation = v }
        if let v = try optionalDouble(a["lightness"]) { value.lightness = v }
        if let v = a["colorize"] as? Bool { value.colorize = v }
        if let v = try optionalDouble(a["radius"]) { value.gaussianRadius = v }
        if let v = try optionalDouble(a["angle"]) { value.resolvedMotionAngle = v }
        if let v = try optionalDouble(a["distance"]) { value.resolvedMotionDistance = v }
        if let v = try optionalDouble(a["amount"]) { value.resolvedNoiseAmount = v }
        if let v = a["gaussian"] as? Bool { value.resolvedNoiseGaussian = v }
        if let v = a["monochromatic"] as? Bool { value.resolvedNoiseMonochromatic = v }
        guard value.isValid else { throw invalid("Adjustment settings are out of range.") }
        guard value.kind == kind else { throw invalid("value.kind must match the adjustment kind.") }
        if let id {
            session.beginEdit("Edit \(value.kind.rawValue) Adjustment"); session.updateAdjustment(id, value: value); session.endEdit()
        } else {
            let count = session.document?.layers.count
            session.addAdjustment(kind, value: value)
            session.adjustmentEditingID = nil
            guard session.document?.layers.count == (count ?? 0) + 1 else { throw unavailable("Could not add the adjustment layer.") }
        }
        return "Adjustment \(action) completed"
    }

    private func effectOperation(_ a: [String: Any]) throws -> String {
        try requireEditable()
        let action = try nonempty(a, "action"), kind: LayerEffectKind = try enumValue(a, "kind", LayerEffectKind.allCases)
        guard let id = try optionalUUID(a["layer_id"]) ?? session.activeLayerID else { throw invalid("layer_id is required when no layer is selected.") }
        let target = try layer(id)
        guard !target.isGroup, target.asset != nil else { throw invalid("Layer effects require a pixel, text, or shape layer.") }
        session.selectLayer(id)
        var effects = session.activeEffects
        if let object = a["value"] as? [String: Any] {
            try validateNestedJSON(object)
            do {
                let data = try JSONSerialization.data(withJSONObject: object)
                guard data.count <= 64 * 1024 else { throw invalid("value exceeds 64 KB.") }
                effects = try JSONDecoder().decode(LayerEffects.self, from: data)
            }
            catch { throw invalid("value is not a valid LayerEffects object.") }
        }
        if action == "add" {
            addDefaultEffect(kind, to: &effects)
            try updateEffect(kind, effects: &effects, arguments: a)
        }
        else if action == "remove" { effects.remove(kind) }
        else if action == "enable" { effects.setEnabled(try bool(a, "enabled"), for: kind) }
        else if action == "update" {
            guard effects.contains(kind) else { throw invalid("The layer does not have that effect.") }
            try updateEffect(kind, effects: &effects, arguments: a)
        } else { throw invalid("Unknown effect action \(action).") }
        guard effects.isValid else { throw invalid("Effect settings are out of range.") }
        session.setEffects(effects, on: id, name: "\(action.capitalized) \(kind.rawValue)")
        return "Effect \(action) completed"
    }

    private func transformOperation(_ a: [String: Any]) throws -> String {
        try requireEditable()
        let id = try requiredLayerID(a)
        let wantsMask = a["target"] as? String == "mask"
        if wantsMask {
            guard let mask = try layer(id).mask else { throw invalid("The layer has no mask to transform.") }
            guard !mask.isLinked else { throw invalid("Unlink the layer mask before transforming it independently.") }
        }
        // Always set the target explicitly. Selecting the already-active layer does not clear a
        // previously selected mask, which could otherwise transform the wrong target.
        session.selectLayerTarget(id, mask: wantsMask)
        session.beginTransform(persistent: false)
        guard var value = session.transformEdit?.draft,
              !wantsMask || session.transformEdit?.mask == true else {
            session.cancelTransform()
            throw unavailable("The target cannot be transformed.")
        }
        if let v = try optionalDouble(a["x"]) { value.origin.x = v }
        if let v = try optionalDouble(a["y"]) { value.origin.y = v }
        if let v = try optionalDouble(a["width"]) { value.size.width = v }
        if let v = try optionalDouble(a["height"]) { value.size.height = v }
        if let v = try optionalDouble(a["rotation"]) { value.rotation = v }
        if let v = a["flip_x"] as? Bool { value.flipX = v }
        if let v = a["flip_y"] as? Bool { value.flipY = v }
        guard value.isValid else { session.cancelTransform(); throw invalid("Transform is invalid or exceeds editor limits.") }
        session.previewTransform(value); session.commitTransform()
        return "Transformed layer"
    }

    private func maskOperation(_ a: [String: Any]) throws -> String {
        try requireEditable()
        let action = try nonempty(a, "action"), id = try requiredLayerID(a)
        let target = try layer(id)
        switch action {
        case "add":
            guard target.mask == nil else { throw unavailable("The layer already has a mask or cannot accept one.") }
            if a["from_selection"] as? Bool == true, session.selection == nil {
                throw invalid("from_selection requires an active selection.")
            }
            session.selectLayer(id)
            guard session.canEditMask else { throw unavailable("The layer cannot accept a mask.") }
            session.brushError = nil
            if a["from_selection"] as? Bool == true {
                session.addMask(revealing: a["revealing"] as? Bool ?? true)
            } else { session.addLayerMask(revealing: a["revealing"] as? Bool ?? true) }
            guard try layer(id).mask != nil else { throw unavailable(session.brushError ?? "Could not create the mask.") }
        case "delete":
            guard target.mask != nil else { throw invalid("The layer has no mask.") }
            session.selectLayer(id); session.deleteLayerMask()
        case "enable":
            guard let mask = target.mask else { throw invalid("The layer has no mask.") }
            let desired = try bool(a, "enabled"), current = mask.isEnabled
            session.selectLayer(id)
            if desired != current { session.toggleLayerMask() }
        case "set_linked":
            guard let mask = target.mask else { throw invalid("The layer has no mask.") }
            let desired = try bool(a, "linked")
            session.selectLayer(id)
            if desired != mask.isLinked { session.toggleMaskLink(id) }
        case "link":
            let source = try uuid(a["source_id"])
            guard session.canLinkMask(source: source, target: id) else { throw invalid("The live mask link would be invalid.") }
            session.selectLayer(id)
            guard session.linkMask(source: source, target: id) else { throw invalid("The live mask link would be invalid.") }
        case "unlink":
            guard target.maskSourceID != nil else { throw invalid("The layer has no live mask link.") }
            session.selectLayer(id)
            session.removeLiveMask(from: id)
        case "copy":
            let source = try uuid(a["source_id"])
            guard session.canCopyMask(from: source, to: id) else { throw invalid("The source mask cannot be copied to this layer.") }
            session.copyMask(from: source, to: id)
        case "select":
            let mask = a["target"] as? String == "mask"
            guard !mask || target.mask != nil else { throw invalid("The layer has no mask.") }
            session.selectLayerTarget(id, mask: mask)
        default: throw invalid("Unknown mask action \(action).")
        }
        return "Mask \(action) completed"
    }

    private func selectionOperation(_ a: [String: Any]) throws -> String {
        try requireEditable()
        let action = try nonempty(a, "action")
        switch action {
        case "all": session.selectAll()
        case "deselect": session.deselect()
        case "invert": session.invertSelection()
        case "expand": session.expandSelection(by: try int(a, "amount", range: 0...30_000))
        case "contract": session.contractSelection(by: try int(a, "amount", range: 0...30_000))
        case "feather": session.featherSelection(by: try int(a, "amount", range: 0...30_000))
        case "rectangle", "ellipse":
            let rect = CGRect(x: try double(a, "x"), y: try double(a, "y"), width: try double(a, "width"), height: try double(a, "height")).standardized
            guard !rect.isEmpty else { throw invalid("Selection rectangle must have positive area.") }
            let path = action == "ellipse" ? CGPath(ellipseIn: rect, transform: nil) : CGPath(rect: rect, transform: nil)
            session.selectionAntialiased = a["antialiased"] as? Bool ?? true
            session.applySelection(path, mode: try selectionMode(a), name: action == "ellipse" ? "Elliptical Marquee" : "Rectangular Marquee")
        case "polygon":
            let points = try points(a["points"]); guard points.count >= 3 else { throw invalid("Polygon selection needs at least three points.") }
            let path = CGMutablePath(); path.move(to: points[0]); for point in points.dropFirst() { path.addLine(to: point) }; path.closeSubpath()
            session.selectionAntialiased = a["antialiased"] as? Bool ?? true
            session.applySelection(path, mode: try selectionMode(a), name: "Polygonal Lasso")
        default: throw invalid("Unknown selection action \(action).")
        }
        return "Selection \(action) completed"
    }

    private func paintStroke(_ a: [String: Any]) async throws -> String {
        try requireEditable()
        let id = try requiredLayerID(a), mode = try nonempty(a, "mode"), strokePoints = try points(a["points"])
        guard !strokePoints.isEmpty else { throw invalid("points cannot be empty.") }
        session.selectLayer(id)
        if let target = a["target"] as? String {
            guard target != "mask" || session.activeLayer?.mask != nil else { throw invalid("The layer has no mask.") }
            session.selectLayerTarget(id, mask: target == "mask")
        }
        guard session.canPaint else { throw unavailable("The selected target is not paintable.") }
        guard !session.isMaskSelected || !["heal", "clone", "smudge", "liquify"].contains(mode) else { throw invalid("This brush mode requires layer pixels.") }
        session.brushError = nil
        switch mode {
        case "paint": session.selectTool(.brush); session.brushMode = .paint
        case "erase": session.selectTool(.brush); session.brushMode = .erase
        case "heal": session.selectTool(.spotHealing)
        case "clone": session.selectTool(.cloneStamp)
        case "blur", "smudge", "liquify": session.selectTool(.blur)
        default: throw invalid("Unknown paint mode \(mode).")
        }
        var settings = session.brushSettings
        if let v = try optionalDouble(a["diameter"]) { guard (1...30_000).contains(v) else { throw invalid("diameter is out of range.") }; settings.diameter = v }
        if let v = try optionalDouble(a["hardness"]) { settings.hardness = v }
        if let v = try optionalDouble(a["opacity"]) { settings.opacity = v }
        if let c = try optionalColor(a["color"]) { settings.red = c.red; settings.green = c.green; settings.blue = c.blue }
        session.brushSettings = settings
        var completed = false
        defer { if !completed { session.cancelBrush() } }
        if ["smudge", "liquify"].contains(mode) {
            session.blurMode = mode == "smudge" ? .smudge : .liquify
            session.beginWarp(at: strokePoints[0]); guard session.warpStroke != nil else { throw unavailable(session.brushError ?? "Could not start the warp stroke.") }; for point in strokePoints.dropFirst() { session.warpStroke?.append(point) }; session.finishWarp()
        } else {
            switch mode {
            case "paint", "erase", "heal": break
            case "clone":
                session.setCloneSource(try point(a["clone_source"]))
            case "blur": session.blurMode = .blur
            default: throw invalid("Unknown paint mode \(mode).")
            }
            session.beginBrush(at: strokePoints[0]); guard session.brushStroke != nil else { throw unavailable(session.brushError ?? "Could not start the brush stroke.") }; for point in strokePoints.dropFirst() { session.continueBrush(at: point) }; try Task.checkCancellation(); await session.finishBrush()
        }
        if let error = session.brushError { session.brushError = nil; throw unavailable(error) }
        completed = true
        return "Painted \(mode) stroke"
    }

    private func filterOperation(_ a: [String: Any]) async throws -> String {
        try requireEditable()
        let id = try requiredLayerID(a), kind: FilterKind = try enumValue(a, "kind", FilterKind.allCases)
        let wantsMask = a["target"] as? String == "mask"
        if wantsMask, try layer(id).mask == nil { throw invalid("The layer has no mask to filter.") }
        session.selectLayerTarget(id, mask: wantsMask)
        session.beginFilter(kind)
        guard let edit = session.filterEdit else { throw unavailable("That filter is unavailable for this layer or selection.") }
        var completed = false
        defer { if !completed { session.cancelFilter() } }
        var settings = edit.settings
        if let v = try optionalDouble(a["radius"]) { settings.radius = v }
        if let v = try optionalDouble(a["angle"]) { settings.angle = v }
        if let v = try optionalDouble(a["distance"]) { settings.distance = v }
        if let v = try optionalDouble(a["amount"]) { settings.amount = v }
        if let v = a["gaussian"] as? Bool { settings.gaussian = v }
        if let v = a["monochromatic"] as? Bool { settings.monochromatic = v }
        if let v = try optionalDouble(a["distortion"]) { settings.distortion = v }
        if let v = a["background_quality"] as? String, let quality = BackgroundQuality.allCases.first(where: { matches($0.rawValue, v) }) { settings.backgroundQuality = quality }
        if let v = try optionalDouble(a["refine_edges"]) { settings.refineEdges = v }
        if let v = try optionalDouble(a["matte_contrast"]) { settings.matteContrast = v }
        if let v = try optionalDouble(a["shift_edge"]) { settings.shiftEdge = v }
        if let parameters = a["parameters"] as? [String: Any] {
            try validateNestedJSON(parameters)
            switch kind {
            case .curves: settings.curves = try decodeParameters(parameters, as: CurvesSettings.self)
            case .exposure: settings.exposure = try decodeParameters(parameters, as: ExposureSettings.self)
            case .gradientMap: settings.gradientMap = try decodeParameters(parameters, as: GradientMapSettings.self)
            case .grain: settings.grain = try decodeParameters(parameters, as: GrainSettings.self)
            case .blackWhite: settings.blackWhite = try decodeParameters(parameters, as: BlackWhiteSettings.self)
            case .colorBalance: settings.colorBalance = try decodeParameters(parameters, as: ColorBalanceSettings.self)
            case .cameraRaw:
                guard let defaults = jsonObject(settings.cameraRaw) as? [String: Any] else { throw unavailable("Camera Raw settings could not be encoded.") }
                let merged = try deepMerge(defaults: defaults, patch: parameters)
                let decoded: CameraRawSettings = try decodeParameters(merged, as: CameraRawSettings.self)
                guard decoded.isValid, decoded.mixer.hue.count == 8, decoded.mixer.saturation.count == 8,
                      decoded.mixer.luminance.count == 8, decoded.mixer.points.count <= 256,
                      decoded.geometry.guides.count <= 32 else {
                    throw invalid("Camera Raw parameters have invalid values or array lengths.")
                }
                settings.cameraRaw = decoded
            default: break
            }
        }
        session.updateFilter(settings, preview: false); try Task.checkCancellation(); await session.commitFilter()
        guard session.filterEdit == nil else { session.cancelFilter(); throw unavailable(session.brushError ?? "Filter could not be committed.") }
        completed = true
        return "Applied \(kind.rawValue)"
    }

    private func historyOperation(_ a: [String: Any]) throws -> String {
        let action = try nonempty(a, "action")
        guard session.canUseHistory else { throw busy("History is unavailable while another edit is active.") }
        if action == "undo" { guard session.canUndo else { throw unavailable("Nothing to undo.") }; session.undo() }
        else if action == "redo" { guard session.canRedo else { throw unavailable("Nothing to redo.") }; session.redo() }
        else { throw invalid("Unknown history action \(action).") }
        return action.capitalized
    }

    private func settingsOperation(_ a: [String: Any]) throws -> String {
        try requireWorkspaceReady()
        if let value = a["tool"] as? String, let tool = NavigationTool.allCases.first(where: { matches($0.rawValue, value) }) { session.selectTool(tool) }
        if let value = try optionalColor(a["foreground"]) { session.setPaletteColor(value, background: false) }
        if let value = try optionalColor(a["background"]) { session.setPaletteColor(value, background: true) }
        if let value = a["snapping_enabled"] as? Bool { session.snapEnabled = value }
        if let value = a["show_grid"] as? Bool { session.showsGrid = value }
        if let value = a["show_guides"] as? Bool { session.showsGuides = value }
        if let value = a["show_rulers"] as? Bool { session.showsRulers = value }
        if let value = try optionalDouble(a["zoom"]) { guard (0.001...32).contains(value) else { throw invalid("zoom is out of range.") }; session.zoom(to: value) }
        return "Updated editor settings"
    }

    // MARK: - State and response

    /// Internal extension seam for advanced automation families implemented in sibling files.
    var session: EditorSession { workspace.current.session }

    private func capabilities() -> [String: Any] {
        var adjustments: [String: Any] = [:]
        for kind in AdjustmentKind.allCases { adjustments[kind.rawValue] = jsonObject(LayerAdjustment(kind: kind)) ?? [:] }
        var effects: [String: Any] = [:]
        for kind in LayerEffectKind.allCases {
            var value = LayerEffects(); addDefaultEffect(kind, to: &value)
            effects[kind.rawValue] = jsonObject(value) ?? [:]
        }
        let defaults = FilterSettings()
        let filters: [String: Any] = [
            FilterKind.gaussianBlur.rawValue: ["radius": defaults.radius],
            FilterKind.motionBlur.rawValue: ["angle": defaults.angle, "distance": defaults.distance],
            FilterKind.addNoise.rawValue: ["amount": defaults.amount, "gaussian": defaults.gaussian, "monochromatic": defaults.monochromatic],
            FilterKind.lensCorrection.rawValue: ["distortion": defaults.distortion],
            FilterKind.removeBackground.rawValue: ["backgroundQuality": defaults.backgroundQuality.rawValue, "refineEdges": defaults.refineEdges,
                "matteContrast": defaults.matteContrast, "shiftEdge": defaults.shiftEdge],
            FilterKind.curves.rawValue: jsonObject(defaults.curves) ?? [:],
            FilterKind.exposure.rawValue: jsonObject(defaults.exposure) ?? [:],
            FilterKind.gradientMap.rawValue: jsonObject(defaults.gradientMap) ?? [:],
            FilterKind.grain.rawValue: jsonObject(defaults.grain) ?? [:],
            FilterKind.blackWhite.rawValue: jsonObject(defaults.blackWhite) ?? [:],
            FilterKind.colorBalance.rawValue: jsonObject(defaults.colorBalance) ?? [:],
            FilterKind.cameraRaw.rawValue: jsonObject(defaults.cameraRaw) ?? [:],
            FilterKind.contentAwareFill.rawValue: [:]
        ]
        return [
            "adjustment_models": adjustments, "effect_models": effects, "filter_models": filters,
            "enums": ["tools": NavigationTool.allCases.map(\.rawValue), "blend_modes": LayerBlendMode.allCases.map(\.rawValue),
                "adjustments": AdjustmentKind.allCases.map(\.rawValue), "effects": LayerEffectKind.allCases.map(\.rawValue),
                "filters": FilterKind.allCases.map(\.rawValue), "shapes": ShapeKind.allCases.map(\.rawValue)],
            "limits": ["canvas_side": 30_000, "canvas_pixels": 100_000_000, "transport_bytes": 24 * 1024 * 1024,
                "stroke_points": 4_096],
            "camera_raw_note": "Camera Raw parameters deep-merge into this complete native model. Mixer hue, saturation, and luminance arrays must each contain exactly eight values."
        ]
    }

    private func decodeParameters<T: Decodable>(_ object: [String: Any], as type: T.Type) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard data.count <= 64 * 1024 else { throw invalid("parameters exceeds 64 KB.") }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw invalid("parameters does not match the native settings model.") }
    }

    private func deepMerge(defaults: [String: Any], patch: [String: Any]) throws -> [String: Any] {
        var result = defaults
        for (key, value) in patch {
            guard let original = defaults[key] else { throw invalid("Unknown Camera Raw parameter \(key).") }
            if let childPatch = value as? [String: Any] {
                guard let childDefaults = original as? [String: Any] else { throw invalid("Camera Raw parameter \(key) is not an object.") }
                result[key] = try deepMerge(defaults: childDefaults, patch: childPatch)
            } else { result[key] = value }
        }
        return result
    }

    private func updateCameraRaw(_ value: inout CameraRawSettings, from object: [String: Any]) throws {
        var result = value
        func set(_ key: String, _ range: ClosedRange<Double>, _ apply: (Double) -> Void) throws {
            guard let number = try optionalDouble(object[key]) else { return }
            guard range.contains(number) else { throw invalid("Camera Raw \(key) is out of range.") }
            apply(number)
        }
        if let text = object["whiteBalance"] as? String, let item = CameraRawWhiteBalance.allCases.first(where: { matches($0.rawValue, text) }) { result.whiteBalance = item }
        if let text = object["glowStyle"] as? String, let item = CameraRawGlowStyle.allCases.first(where: { matches($0.rawValue, text) }) { result.glowStyle = item }
        if let text = object["vignetteStyle"] as? String, let item = CameraRawVignetteStyle.allCases.first(where: { matches($0.rawValue, text) }) { result.vignetteStyle = item }
        try set("temperature", -100...100) { result.temperature = $0 }; try set("tint", -100...100) { result.tint = $0 }
        try set("exposure", -5...5) { result.exposure = $0 }; try set("contrast", -100...100) { result.contrast = $0 }
        try set("highlights", -100...100) { result.highlights = $0 }; try set("shadows", -100...100) { result.shadows = $0 }
        try set("whites", -100...100) { result.whites = $0 }; try set("blacks", -100...100) { result.blacks = $0 }
        try set("vibrance", -100...100) { result.vibrance = $0 }; try set("saturation", -100...100) { result.saturation = $0 }
        try set("texture", -100...100) { result.texture = $0 }; try set("clarity", -100...100) { result.clarity = $0 }
        try set("dehaze", -100...100) { result.dehaze = $0 }; try set("glow", 0...100) { result.glow = $0 }
        try set("glowRange", -100...100) { result.glowRange = $0 }; try set("glowSpread", -100...100) { result.glowSpread = $0 }
        try set("glowWarmth", -100...100) { result.glowWarmth = $0 }; try set("vignetteAmount", -100...100) { result.vignetteAmount = $0 }
        try set("vignetteMidpoint", 0...100) { result.vignetteMidpoint = $0 }; try set("vignetteRoundness", -100...100) { result.vignetteRoundness = $0 }
        try set("vignetteFeather", 0...100) { result.vignetteFeather = $0 }; try set("vignetteHighlights", 0...100) { result.vignetteHighlights = $0 }
        try set("grainAmount", 0...100) { result.grainAmount = $0 }; try set("grainSize", 0...100) { result.grainSize = $0 }
        try set("grainRoughness", 0...100) { result.grainRoughness = $0 }
        guard result.isValid else { throw invalid("Camera Raw parameters are invalid.") }
        value = result
    }

    private func documentsSummary() -> [String: Any] {
        syncRevision()
        return ["revision": revision, "selected_document_id": workspace.selectedID.uuidString,
            "documents": workspace.tabs.map { ["document_id": $0.id.uuidString, "title": $0.title,
                "selected": $0.id == workspace.selectedID, "modified": $0.session.isModified || transportDirtyTabs.contains($0.id),
                "has_canvas": $0.session.document != nil] as [String: Any] }]
    }

    private func editorState() -> [String: Any] {
        var result = documentsSummary(); result["selected_document"] = describe(workspace.current); result["workspace_busy"] = workspace.isManaging
        return result
    }

    private func describe(_ tab: ProjectTab) -> [String: Any] {
        syncRevision()
        let s = tab.session
        var value: [String: Any] = [
            "document_id": tab.id.uuidString, "title": tab.title, "revision": revision,
            "selected": tab.id == workspace.selectedID, "modified": s.isModified || transportDirtyTabs.contains(tab.id), "busy": s.isProjectBusy,
            "can_edit": s.canEditLayers, "can_undo": s.canUndo, "can_redo": s.canRedo,
            "undo_name": s.history.undoName, "redo_name": s.history.redoName,
            "active_layer_id": s.activeLayerID?.uuidString ?? NSNull(), "selected_layer_ids": s.selectedLayerIDs.map(\.uuidString),
            "tool": s.tool.rawValue, "foreground": color(s.foregroundColor), "background": color(s.backgroundColor)
        ]
        value["is_mask_selected"] = s.isMaskSelected
        value["guides_locked"] = s.locksGuides
        value["viewport"] = ["zoom": s.viewport.zoom, "pan_x": s.viewport.pan.width, "pan_y": s.viewport.pan.height,
            "follows_fit": s.viewport.followsFit, "view_width": s.viewport.viewSize.width, "view_height": s.viewport.viewSize.height,
            "backing_scale": s.viewport.backingScale]
        value["brush"] = ["diameter": s.brushSettings.diameter, "hardness": s.brushSettings.hardness,
            "opacity": s.brushSettings.opacity, "smoothing": s.brushSettings.smoothing, "healing_mode": s.spotHealingMode.rawValue]
        value["gradient"] = ["shape": s.gradientSettings.shape.rawValue, "style": s.gradientSettings.style.rawValue,
            "reversed": s.gradientSettings.reversed, "opacity": s.gradientSettings.opacity]
        value["wand"] = ["tolerance": s.wandSettings.tolerance, "contiguous": s.wandSettings.contiguous,
            "sample_all_layers": s.wandSettings.sampleAllLayers]
        value["view_options"] = ["grid": s.showsGrid, "guides": s.showsGuides, "rulers": s.showsRulers,
            "pixel_grid": s.showsPixelGrid, "snapping": s.snapEnabled]
        guard let document = s.document else { value["canvas"] = NSNull(); value["layers"] = []; return value }
        value["guides"] = document.guides.map { ["id": $0.id.uuidString, "axis": $0.axis.rawValue, "position": $0.position] as [String: Any] }
        value["canvas"] = ["width": document.width, "height": document.height, "resolution": document.resolution]
        value["selection"] = s.selection.map { ["empty": $0.isEmpty, "antialiased": $0.antialiased, "feather": $0.feather,
            "bounds": rect($0.path.boundingBoxOfPath)] as [String: Any] } ?? NSNull()
        value["layers"] = document.layers.reversed().map { layerState($0) }
        return value
    }

    private func layerState(_ layer: ImageLayer) -> [String: Any] {
        var value: [String: Any] = [
            "id": layer.id.uuidString, "name": layer.name, "visible": layer.isVisible, "group": layer.isGroup,
            "parent_id": layer.parentID?.uuidString ?? NSNull(), "opacity": layer.opacity, "blend_mode": layer.blendMode.rawValue,
            "transform": transform(layer.transform), "has_pixels": layer.asset != nil, "pixel_width": layer.asset?.image.width ?? 0,
            "pixel_height": layer.asset?.image.height ?? 0, "mask": layer.mask.map { ["enabled": $0.isEnabled, "linked": $0.isLinked,
                "width": $0.asset.image.width, "height": $0.asset.image.height, "placement": $0.placement.map(transform) ?? NSNull()] as [String: Any] } ?? NSNull(),
            "mask_source_id": layer.maskSourceID?.uuidString ?? NSNull(), "adjustment": layer.adjustment.flatMap(jsonObject) ?? NSNull(),
            "shape": layer.liveShape?.style.kind.rawValue ?? NSNull(), "text": layer.liveText?.style.content ?? NSNull(),
            "effects": layer.effects.flatMap(jsonObject) ?? NSNull()
        ]
        value["shape_style"] = layer.liveShape.map { jsonObject($0.style) ?? NSNull() } ?? NSNull()
        if let style = layer.liveText?.style { value["text_style"] = ["font_name": style.fontName, "font_size": style.fontSize,
            "alignment": style.alignment.rawValue, "tracking": style.tracking, "leading": style.leading,
            "color": color(PaletteColor(red: style.red, green: style.green, blue: style.blue))] }
        return value
    }

    private func response(_ text: String, _ structured: [String: Any]) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "structuredContent": structured]
    }

    func mutate(_ a: [String: Any], _ body: () throws -> String) throws -> [String: Any] {
        try checkRevision(a); try selectDocumentIfRequested(a); let message = try body(); syncRevision()
        return response(message, ["revision": revision, "document_id": workspace.selectedID.uuidString, "state": describe(workspace.current)])
    }

    func mutateAsync(_ a: [String: Any], _ body: () async throws -> String) async throws -> [String: Any] {
        try checkRevision(a); try selectDocumentIfRequested(a); let message = try await body(); syncRevision()
        return response(message, ["revision": revision, "document_id": workspace.selectedID.uuidString, "state": describe(workspace.current)])
    }

    func checkRevision(_ a: [String: Any]) throws {
        syncRevision()
        if let expected = try optionalInt(a["expected_revision"]), expected != revision {
            throw invalid("Editor revision is \(revision), not expected_revision \(expected). Read state and retry.")
        }
    }

    private func selectDocumentIfRequested(_ a: [String: Any]) throws {
        guard a["document_id"] != nil else { return }
        let target = try tab(a["document_id"])
        if target.id != workspace.selectedID {
            try requireWorkspaceReady()
            workspace.select(target.id)
            guard workspace.selectedID == target.id else { throw busy("The requested document could not be selected.") }
        }
    }

    private func syncRevision() {
        let current = fingerprint()
        if !observedFingerprint.isEmpty, current != observedFingerprint { revision += 1 }
        observedFingerprint = current
    }

    private func fingerprint() -> String {
        var parts = [workspace.selectedID.uuidString, String(workspace.tabs.count), String(workspace.isManaging)]
        for tab in workspace.tabs {
            let s = tab.session
            parts += [tab.id.uuidString, String(s.isProjectBusy), String(s.isModified || transportDirtyTabs.contains(tab.id)), String(s.history.undoCount), s.history.undoName, s.history.redoName,
                s.activeLayerID?.uuidString ?? "", String(describing: s.selection), String(s.isMaskSelected),
                s.selectedLayerIDs.map(\.uuidString).sorted().joined(separator: ","), String(s.locksGuides),
                s.tool.rawValue, String(describing: s.brushSettings), String(describing: s.gradientSettings),
                String(describing: s.foregroundColor), String(describing: s.backgroundColor),
                String(s.snapEnabled), String(s.showsGuides), String(s.showsGrid), String(s.showsRulers)]
            if let d = s.document {
                parts += [d.id.uuidString, String(d.width), String(d.height), String(d.resolution), String(d.layers.count), String(describing: d.guides)]
                for l in d.layers {
                    parts += [l.id.uuidString, l.name, String(l.isVisible), String(describing: l.transform), String(l.opacity), l.blendMode.rawValue,
                        l.parentID?.uuidString ?? "", String(describing: l.adjustment), String(describing: l.effects), String(describing: l.text),
                        l.asset.map { String(ObjectIdentifier($0.image).hashValue) } ?? "", l.mask.map { String(ObjectIdentifier($0.asset.image).hashValue) } ?? "",
                        String(describing: l.liveShape?.style), String(describing: l.mask?.isEnabled), String(describing: l.mask?.isLinked),
                        String(describing: l.mask?.placement), l.maskSourceID?.uuidString ?? ""]
                }
            }
        }
        return parts.joined(separator: "|")
    }

    // MARK: - Validation and model helpers

    func requireWorkspaceReady() throws {
        guard workspace.canSwitch else { throw busy("The workspace has an active edit, sheet, import, or project operation.") }
        try requireSessionReady(session)
    }

    private func requireSessionReady(_ session: EditorSession) throws {
        guard session.canStartProjectOperation, !hasHumanEdit(session), session.transformEdit == nil,
              session.cropRect == nil, session.hueSaturation == nil, session.filterEdit == nil,
              session.gradientEdit == nil, session.pixelMove == nil, session.colorPicker == nil else {
            throw busy("The workspace has an active edit, sheet, import, or project operation.")
        }
    }

    func requireEditable() throws {
        guard !workspace.isManaging, session.canEditLayers, !hasHumanEdit(session), session.colorPicker == nil else { throw busy("The selected document is busy or has an unfinished modal edit.") }
    }

    private func hasHumanEdit(_ session: EditorSession) -> Bool {
        session.opacityEditLayerID != nil || session.effectsEditing != nil || session.shapeDraft != nil
            || session.lassoDraft != nil || session.guideDrag != nil || session.selectionMoveOrigin != nil
    }

    private func canSnapshot(_ session: EditorSession) -> Bool {
        !hasHumanEdit(session) && session.canStartProjectOperation && session.transformEdit == nil && session.hueSaturation == nil
            && session.filterEdit == nil && session.gradientEdit == nil && session.pixelMove == nil
            && session.colorPicker == nil && session.cropRect == nil
    }

    private func tab(_ value: Any?) throws -> ProjectTab {
        guard let value else { return workspace.current }
        let id = try uuid(value)
        guard let tab = workspace.tabs.first(where: { $0.id == id }) else { throw invalid("Unknown document_id \(id.uuidString).") }
        return tab
    }

    private func layer(_ id: UUID) throws -> ImageLayer {
        guard let layer = session.document?.layers.first(where: { $0.id == id }) else { throw invalid("Unknown layer_id \(id.uuidString).") }
        return layer
    }

    private func requiredLayerID(_ a: [String: Any]) throws -> UUID { let id = try uuid(a["layer_id"]); _ = try layer(id); return id }
    private func uuid(_ value: Any) throws -> UUID {
        guard let string = value as? String, let id = UUID(uuidString: string) else { throw invalid("Expected a UUID string.") }
        return id
    }
    private func uuid(_ value: Any?) throws -> UUID { guard let value else { throw invalid("Missing UUID.") }; return try uuid(value) }
    private func optionalUUID(_ value: Any?) throws -> UUID? { guard let value, !(value is NSNull) else { return nil }; return try uuid(value) }
    private func string(_ a: [String: Any], _ key: String) throws -> String { guard let value = a[key] as? String else { throw invalid("\(key) must be a string.") }; return value }
    private func nonempty(_ a: [String: Any], _ key: String) throws -> String { let value = try string(a, key).trimmingCharacters(in: .whitespacesAndNewlines); guard !value.isEmpty else { throw invalid("\(key) cannot be empty.") }; return value }
    private func bool(_ a: [String: Any], _ key: String) throws -> Bool { guard let value = a[key] as? Bool else { throw invalid("\(key) must be a boolean.") }; return value }
    private func double(_ a: [String: Any], _ key: String, range: ClosedRange<Double>? = nil) throws -> Double { guard let value = try optionalDouble(a[key]) else { throw invalid("\(key) must be a number.") }; if let range, !range.contains(value) { throw invalid("\(key) is out of range.") }; return value }
    private func optionalDouble(_ value: Any?) throws -> Double? {
        guard let value else { return nil }
        guard let object = value as? NSNumber, CFGetTypeID(object) != CFBooleanGetTypeID() else { throw invalid("Expected a number, not a boolean.") }
        let number = object.doubleValue
        guard number.isFinite, abs(number) <= 1_000_000 else { throw invalid("Expected a finite number between -1,000,000 and 1,000,000.") }
        return number
    }
    private func int(_ a: [String: Any], _ key: String, range: ClosedRange<Int>) throws -> Int { guard let value = try optionalInt(a[key]), range.contains(value) else { throw invalid("\(key) must be an integer in \(range).") }; return value }
    private func optionalInt(_ value: Any?) throws -> Int? { guard let number = try optionalDouble(value) else { return nil }; guard number.rounded() == number, number >= Double(Int.min), number <= Double(Int.max) else { throw invalid("Expected an integer.") }; return Int(number) }
    private func optionalPoint(_ a: [String: Any], x: String, y: String) throws -> CGPoint? { let px = try optionalDouble(a[x]), py = try optionalDouble(a[y]); if px == nil && py == nil { return nil }; guard let px, let py else { throw invalid("\(x) and \(y) must be provided together.") }; return CGPoint(x: px, y: py) }
    private func point(_ value: Any?) throws -> CGPoint { guard let object = value as? [String: Any], let x = try optionalDouble(object["x"]), let y = try optionalDouble(object["y"]) else { throw invalid("Expected a point with numeric x and y.") }; return CGPoint(x: x, y: y) }
    private func points(_ value: Any?) throws -> [CGPoint] {
        guard let values = value as? [Any], values.count <= 4_096 else { throw invalid("points must be an array of at most 4,096 points.") }
        return try values.map(point)
    }
    private func optionalColor(_ value: Any?) throws -> PaletteColor? {
        guard let value else { return nil }; guard let object = value as? [String: Any] else { throw invalid("Color must be an object with red, green, and blue.") }
        let red = try double(object, "red", range: 0...1), green = try double(object, "green", range: 0...1), blue = try double(object, "blue", range: 0...1)
        return PaletteColor(red: red, green: green, blue: blue)
    }
    private func enumValue<T: RawRepresentable>(_ a: [String: Any], _ key: String, _ values: [T]) throws -> T where T.RawValue == String {
        let text = try nonempty(a, key); guard let value = values.first(where: { matches($0.rawValue, text) }) else { throw invalid("Unsupported \(key): \(text).") }; return value
    }
    private func selectionMode(_ a: [String: Any]) throws -> SelectionMode { guard a["mode"] != nil else { return .replace }; return try enumValue(a, "mode", SelectionMode.allCases) }
    private func matches(_ lhs: String, _ rhs: String) -> Bool { lhs.caseInsensitiveCompare(rhs) == .orderedSame || lhs.lowercased().replacingOccurrences(of: " ", with: "_") == rhs.lowercased().replacingOccurrences(of: " ", with: "_") }
    private func invalid(_ message: String) -> EditorAutomationError { .invalidParams(message) }
    private func busy(_ message: String) -> EditorAutomationError { .busy(message) }
    private func unavailable(_ message: String) -> EditorAutomationError { .unavailable(message) }

    private func addDefaultEffect(_ kind: LayerEffectKind, to effects: inout LayerEffects) {
        switch kind {
        case .stroke: effects.stroke = effects.stroke ?? StrokeEffect()
        case .shadow: effects.shadow = effects.shadow ?? ShadowEffect()
        case .colorOverlay: effects.colorOverlay = effects.colorOverlay ?? ColorOverlayEffect()
        case .innerShadow: effects.innerShadow = effects.innerShadow ?? InnerShadowEffect()
        case .outerGlow: effects.outerGlow = effects.outerGlow ?? OuterGlowEffect()
        case .innerGlow: effects.innerGlow = effects.innerGlow ?? InnerGlowEffect()
        }
    }

    private func updateEffect(_ kind: LayerEffectKind, effects: inout LayerEffects, arguments a: [String: Any]) throws {
        let color = try optionalColor(a["color"]), opacity = try optionalDouble(a["opacity"]), size = try optionalDouble(a["size"])
        let angle = try optionalDouble(a["angle"]), distance = try optionalDouble(a["distance"]), blur = try optionalDouble(a["blur"])
        switch kind {
        case .stroke:
            if let v = size { effects.stroke?.size = v }; if let v = opacity { effects.stroke?.opacity = v }; if let v = a["inside"] as? Bool { effects.stroke?.inside = v }
        case .shadow:
            if let v = angle { effects.shadow?.angle = v }; if let v = distance { effects.shadow?.distance = v }; if let v = blur { effects.shadow?.blur = v }; if let v = opacity { effects.shadow?.opacity = v }
        case .colorOverlay: if let v = opacity { effects.colorOverlay?.opacity = v }
        case .innerShadow:
            if let v = angle { effects.innerShadow?.angle = v }; if let v = distance { effects.innerShadow?.distance = v }; if let v = blur { effects.innerShadow?.blur = v }; if let v = opacity { effects.innerShadow?.opacity = v }
        case .outerGlow: if let v = size { effects.outerGlow?.size = v }; if let v = opacity { effects.outerGlow?.opacity = v }
        case .innerGlow: if let v = size { effects.innerGlow?.size = v }; if let v = opacity { effects.innerGlow?.opacity = v }
        }
        if let color { effects.setColor(color, for: kind) }
        if let enabled = a["enabled"] as? Bool { effects.setEnabled(enabled, for: kind) }
        guard effects.isValid else { throw invalid("Effect settings are out of range.") }
    }

    private func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw ExportError.encode }
        CGImageDestinationAddImage(target, image, nil); guard CGImageDestinationFinalize(target) else { throw ExportError.encode }
        return data as Data
    }

    private func scaledPreview(_ image: CGImage, maxDimension: Int) throws -> CGImage {
        guard maxDimension > 0, max(image.width, image.height) > maxDimension else { return image }
        let scale = CGFloat(maxDimension) / CGFloat(max(image.width, image.height))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.interpolationQuality = .high
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        guard let result = context.makeImage() else { throw ExportError.render }
        return result
    }

    private func jsonObject<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func validateNestedJSON(_ value: Any) throws {
        var nodes = 0
        try validateNestedJSON(value, depth: 0, nodes: &nodes)
    }

    private func validateNestedJSON(_ value: Any, depth: Int, nodes: inout Int) throws {
        nodes += 1
        guard depth <= 16, nodes <= 10_000 else { throw invalid("Nested value is too deep or complex.") }
        if let object = value as? [String: Any] {
            guard object.count <= 1_000 else { throw invalid("Nested object has too many fields.") }
            for (key, child) in object {
                guard key.utf8.count <= 1_024 else { throw invalid("Nested object key is too long.") }
                try validateNestedJSON(child, depth: depth + 1, nodes: &nodes)
            }
        } else if let array = value as? [Any] {
            guard array.count <= 4_096 else { throw invalid("Nested array has too many values.") }
            for child in array { try validateNestedJSON(child, depth: depth + 1, nodes: &nodes) }
        } else if let string = value as? String {
            guard string.utf8.count <= 64 * 1024 else { throw invalid("Nested string is too long.") }
        } else if let number = value as? NSNumber {
            guard CFGetTypeID(number) == CFBooleanGetTypeID() || number.doubleValue.isFinite else { throw invalid("Nested value contains a non-finite number.") }
        } else if !(value is NSNull) { throw invalid("Nested value contains an unsupported type.") }
    }

    private func color(_ value: PaletteColor) -> [String: Any] { ["red": value.red, "green": value.green, "blue": value.blue] }
    private func rect(_ value: CGRect) -> [String: Any] { ["x": value.origin.x, "y": value.origin.y, "width": value.width, "height": value.height] }
    private func transform(_ value: LayerTransform) -> [String: Any] { ["x": value.origin.x, "y": value.origin.y, "width": value.size.width, "height": value.size.height,
        "rotation": value.rotation, "flip_x": value.flipX, "flip_y": value.flipY, "sampling": value.sampling.rawValue] }

    // MARK: - JSON Schema helpers

    private func tool(_ name: String, _ description: String, properties: [String: Any], required: [String] = []) -> [String: Any] {
        var fields = properties
        if fields["document_id"] == nil { fields["document_id"] = string("Stable tab identifier; defaults to the selected document.") }
        var schema: [String: Any] = ["type": "object", "properties": fields, "additionalProperties": false]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": description, "inputSchema": schema]
    }
    private func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
    private func boolean(_ description: String) -> [String: Any] { ["type": "boolean", "description": description] }
    private func number(_ description: String, minimum: Double? = nil, maximum: Double? = nil) -> [String: Any] { var v: [String: Any] = ["type": "number", "description": description]; v["minimum"] = minimum; v["maximum"] = maximum; return v.compactMapValues { $0 } }
    private func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> [String: Any] { var v: [String: Any] = ["type": "integer", "description": description]; v["minimum"] = minimum; v["maximum"] = maximum; return v.compactMapValues { $0 } }
    private func enumeration(_ description: String, _ values: [String]) -> [String: Any] { ["type": "string", "description": description, "enum": values] }
    private func array(_ item: [String: Any]) -> [String: Any] { ["type": "array", "items": item] }
    private func pointSchema() -> [String: Any] { ["type": "object", "properties": ["x": number("Document x."), "y": number("Document y.")], "required": ["x", "y"], "additionalProperties": false] }
    private func colorSchema() -> [String: Any] { ["type": "object", "properties": ["red": number("Red 0 to 1.", minimum: 0, maximum: 1), "green": number("Green 0 to 1.", minimum: 0, maximum: 1), "blue": number("Blue 0 to 1.", minimum: 0, maximum: 1)], "required": ["red", "green", "blue"], "additionalProperties": false] }
}
