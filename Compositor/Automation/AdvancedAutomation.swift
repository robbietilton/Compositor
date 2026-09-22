import AppKit
import CoreFoundation

/// Less frequent native editor operations, sharing the main dispatcher's revision/transaction guard.
@MainActor
final class AdvancedAutomation {
    let workspace: ProjectWorkspace
    var session: EditorSession { workspace.current.session }
    init(workspace: ProjectWorkspace) { self.workspace = workspace }
    static var tools: [[String: Any]] {
        let num: [String: Any] = ["type": "number", "minimum": -1_000_000, "maximum": 1_000_000]
        let dim: [String: Any] = ["type": "integer", "minimum": 1, "maximum": 30_000]
        let str: [String: Any] = ["type": "string"]
        let boolean: [String: Any] = ["type": "boolean"]
        let color: [String: Any] = ["type": "object", "properties": Dictionary(uniqueKeysWithValues: ["red", "green", "blue"].map { ($0, ["type": "number", "minimum": 0, "maximum": 1] as [String: Any]) }), "required": ["red", "green", "blue"], "additionalProperties": false]
        func tool(_ name: String, _ description: String, _ props: [String: Any], _ required: [String]) -> [String: Any] {
            var properties = props
            properties["document_id"] = str
            properties["expected_revision"] = ["type": "integer", "minimum": 0]
            return ["name": name, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]
        }
        func choices(_ options: [String]) -> [String: Any] { ["type": "string", "enum": options] }
        return [
            tool("canvas_operation", "Resize canvas, scale all layers nondestructively, crop, flip, or trim. scale_image preserves original image pixels and editable text/shapes.", ["action": choices(["resize_canvas", "scale_image", "crop", "flip_horizontal", "flip_vertical", "trim"]), "width": dim, "height": dim, "x": num, "y": num, "anchor": ["type": "integer", "minimum": 0, "maximum": 8], "resolution": ["type": "number", "minimum": 1, "maximum": 9600]], ["action"]),
            tool("guide_operation", "Add, move, delete, clear, or lock canvas guides.", ["action": choices(["add", "move", "delete", "clear", "lock"]), "guide_id": str, "axis": choices(["horizontal", "vertical"]), "position": num, "locked": boolean], ["action"]),
            tool("gradient_operation", "Apply a linear or radial gradient to layer pixels or the selected mask, respecting selection. One native undo step.", ["layer_id": str, "start_x": num, "start_y": num, "end_x": num, "end_y": num, "shape": choices(GradientShape.allCases.map(\.rawValue)), "style": choices(GradientStyle.allCases.map(\.rawValue)), "foreground": color, "background": color, "opacity": ["type": "number", "minimum": 0, "maximum": 1], "reversed": boolean], ["layer_id", "start_x", "start_y", "end_x", "end_y"]),
            tool("pixel_operation", "Fill, clear, invert, copy, cut, paste, copy merged, or create layer via copy. Clipboard actions use the system clipboard; fill and clear respect selections and masks.", ["action": choices(["fill_foreground", "fill_background", "clear", "invert", "copy", "copy_merged", "cut", "paste", "layer_via_copy"]), "layer_id": str, "color": color], ["action"]),
            tool("sample_selection", "Select similar colors with Magic Wand or the object under a point. Model operations run locally. Use layer pixels or the visible composite.", ["kind": choices(["wand", "object"]), "layer_id": str, "x": num, "y": num, "mode": choices(SelectionMode.allCases.map(\.rawValue)), "tolerance": ["type": "integer", "minimum": 0, "maximum": 255], "contiguous": boolean, "sample_all_layers": boolean], ["kind", "x", "y"])
        ]
    }
    func call(_ name: String, arguments a: [String: Any]) async throws -> String {
        guard !workspace.isManaging, session.canEditLayers else {
            throw RPCError.invalidParams("The workspace or document has an active edit.")
        }
        session.brushError = nil; session.cropError = nil
        let requestedLayerID: UUID?
        if let value = a["layer_id"] as? String {
            guard let id = UUID(uuidString: value), session.document?.layers.contains(where: { $0.id == id }) == true else { throw RPCError.invalidParams("Unknown layer_id") }
            requestedLayerID = id
        } else { requestedLayerID = nil }
        func selectRequestedLayer(required: Bool = false) throws {
            if required, requestedLayerID == nil { throw RPCError.invalidParams("Missing layer_id") }
            if let id = requestedLayerID, session.activeLayerID != id { session.selectLayer(id) }
        }
        switch name {
        case "canvas_operation": try await canvas(a)
        case "guide_operation": try guides(a)
        case "gradient_operation":
            let start = CGPoint(x: try number(a, "start_x"), y: try number(a, "start_y"))
            let end = CGPoint(x: try number(a, "end_x"), y: try number(a, "end_y"))
            guard hypot(end.x-start.x, end.y-start.y) >= 0.5 else { throw RPCError.invalidParams("Gradient endpoints must be at least half a pixel apart") }
            let foreground = try color(a["foreground"]), background = try color(a["background"])
            guard let shape = GradientShape(rawValue: a["shape"] as? String ?? GradientShape.linear.rawValue) else { throw RPCError.invalidParams("Unknown gradient shape") }
            guard let style = GradientStyle(rawValue: a["style"] as? String ?? GradientStyle.foregroundToBackground.rawValue) else { throw RPCError.invalidParams("Unknown gradient style") }
            let opacity = CGFloat(try number(a, "opacity", default: 1, range: 0...1))
            try selectRequestedLayer(required: true)
            if let foreground { session.setPaletteColor(foreground, background: false) }
            if let background { session.setPaletteColor(background, background: true) }
            session.tool = .gradient
            session.gradientSettings.shape = shape
            session.gradientSettings.style = style
            session.gradientSettings.opacity = opacity
            session.gradientSettings.reversed = a["reversed"] as? Bool ?? false
            guard session.canPaint else { throw RPCError.invalidParams("Target is not paintable") }
            session.beginGradient(at: start)
            guard session.gradientEdit != nil else { throw RPCError.invalidParams(session.brushError ?? "Could not start gradient") }
            session.moveGradient(end: end)
            try Task.checkCancellation()
            await session.commitGradient()
        case "pixel_operation":
            let action = a["action"] as? String ?? ""
            let requestedColor = try color(a["color"])
            guard ["fill_foreground", "fill_background", "clear", "invert", "copy", "copy_merged", "cut", "paste", "layer_via_copy"].contains(action) else {
                throw RPCError.invalidParams("Unknown pixel action")
            }
            try selectRequestedLayer()
            if let requestedColor { session.setPaletteColor(requestedColor, background: action == "fill_background") }
            switch action {
            case "fill_foreground", "fill_background":
                guard session.canEditPixels else { throw RPCError.invalidParams("Target is not paintable") }
                try Task.checkCancellation()
                await session.fillSelection(with: action == "fill_background" ? .background : .foreground)
            case "clear":
                guard session.selection != nil, session.canEditPixels else { throw RPCError.invalidParams("Select pixels to clear first") }
                await session.clearSelectedPixels()
            case "invert":
                guard session.canInvert else { throw RPCError.invalidParams("Target cannot be inverted") }
                await session.invertPixels()
            case "copy", "cut", "layer_via_copy":
                guard session.canCopyPixels else { throw RPCError.invalidParams("No pixels can be copied") }
                if action == "cut" { guard session.selection != nil else { throw RPCError.invalidParams("Cut requires a selection") }; try Task.checkCancellation(); await session.cutSelection() }
                else if action == "copy" { session.copySelection() }
                else { session.layerViaCopy() }
            case "copy_merged":
                guard session.document != nil else { throw RPCError.invalidParams("No canvas") }; session.copyMergedSelection()
            case "paste":
                guard session.canPaste else { throw RPCError.invalidParams("The clipboard has no supported image") }; session.paste()
            default: throw RPCError.invalidParams("Unknown pixel action")
            }
        case "sample_selection":
            let p = CGPoint(x: try number(a, "x"), y: try number(a, "y"))
            guard let document = session.document,
                  p.x >= 0, p.y >= 0, p.x < document.size.width, p.y < document.size.height else {
                throw RPCError.invalidParams("The sample point must be inside the canvas.")
            }
            guard let mode = SelectionMode(rawValue: a["mode"] as? String ?? SelectionMode.replace.rawValue) else { throw RPCError.invalidParams("Unknown selection mode") }
            guard let kind = a["kind"] as? String, kind == "object" || kind == "wand" else { throw RPCError.invalidParams("Unknown sample selection kind") }
            let tolerance = kind == "wand" ? Int(try number(a, "tolerance", default: 32, range: 0...255)) : 32
            try selectRequestedLayer()
            if kind == "object" {
                let allLayers = a["sample_all_layers"] as? Bool ?? true
                guard allLayers || (session.activeLayer?.isGroup == false && session.activeLayer?.asset != nil) else {
                    throw RPCError.invalidParams("Select a pixel layer or pass sample_all_layers=true.")
                }
                session.objectSelectionSettings.sampleAllLayers = allLayers
                try Task.checkCancellation()
                await session.selectObject(at: p, mode: mode)
            } else {
                let contiguous = a["contiguous"] as? Bool ?? true
                let allLayers = a["sample_all_layers"] as? Bool ?? false
                guard allLayers || (session.activeLayer?.isGroup == false && session.activeLayer?.asset != nil) else {
                    throw RPCError.invalidParams("Select a pixel layer or pass sample_all_layers=true.")
                }
                session.wandSettings.tolerance = tolerance
                session.wandSettings.contiguous = contiguous
                session.wandSettings.sampleAllLayers = allLayers
                try Task.checkCancellation()
                await session.magicWand(at: p, mode: mode)
            }
        default: throw RPCError.methodNotFound("Unknown advanced operation")
        }
        if let error = session.brushError ?? session.cropError { throw RPCError.invalidParams(error) }
        return "Completed \(name)"
    }
    private func canvas(_ a: [String: Any]) async throws {
        guard let snapshot = session.projectSnapshot() else { throw RPCError.invalidParams("No canvas") }
        let action = a["action"] as? String ?? ""
        if action == "flip_horizontal" || action == "flip_vertical" { session.flipCanvas(horizontally: action == "flip_horizontal"); return }
        if action == "trim" {
            try Task.checkCancellation()
            guard try await session.trim() else { throw RPCError.invalidParams("The canvas has no transparent border to trim.") }
            return
        }
        let width = Int(try number(a, "width", range: 1...30_000)), height = Int(try number(a, "height", range: 1...30_000))
        if action == "scale_image" {
            let sx = CGFloat(width) / CGFloat(snapshot.manifest.width), sy = CGFloat(height) / CGFloat(snapshot.manifest.height)
            let original = session.document!
            var document = CanvasDocument(id: original.id, width: width, height: height, layers: original.layers, resolution: original.resolution, guides: original.guides)
            document.resolution = try number(a, "resolution", default: document.resolution, range: 1...9600)
            let scaling = CGAffineTransform(scaleX: sx, y: sy)
            for i in document.layers.indices {
                document.layers[i].transform = document.layers[i].transform.placing(document.layers[i].transform.unitToDocument.concatenating(scaling))
                guard document.layers[i].transform.isValid else { throw RPCError.invalidParams("Scaled transform exceeds limits") }
                if let placement = document.layers[i].mask?.placement {
                    let scaled = placement.placing(placement.unitToDocument.concatenating(scaling))
                    guard scaled.isValid else { throw RPCError.invalidParams("Scaled mask placement exceeds limits") }
                    document.layers[i].mask?.placement = scaled
                }
            }
            let guides = document.guides.map { $0.scaled(x: sx, y: sy) }
            guard guides.allSatisfy({ $0.position.isFinite && abs($0.position) <= 1_000_000 }) else {
                throw RPCError.invalidParams("Scaled guide position exceeds limits")
            }
            document.guides = guides
            session.beginEdit("Scale Image"); session.document = document; session.endEdit()
            session.viewport.fit(documentSize: document.size)
        } else {
            var options = CanvasSizeOptions(width: width, height: height, anchor: Int(try number(a, "anchor", default: 4, range: 0...8)))
            if action == "crop" { options.contentOffset = CGPoint(x: -(try number(a, "x")), y: -(try number(a, "y"))) }
            else if action != "resize_canvas" { throw RPCError.invalidParams("Unknown canvas action") }
            session.isProjectBusy = true
            defer { session.isProjectBusy = false }
            let result = try await CanvasResizer.shared.resize(snapshot, to: options)
            try Task.checkCancellation()
            session.applyDocumentSize(result, actionName: action == "crop" ? "Crop" : "Canvas Size")
        }
    }
    private func guides(_ a: [String: Any]) throws {
        let action = a["action"] as? String ?? ""
        if action == "lock" { session.locksGuides = a["locked"] as? Bool ?? true; return }
        guard session.canEditGuides else { throw RPCError.invalidParams("Guides are locked or the document is busy") }
        if action == "clear" {
            guard session.canClearGuides else { throw RPCError.invalidParams("The document has no guides to clear") }
            session.clearGuides(); return
        }
        if action == "add" {
            guard let axis = CanvasGuide.Axis(rawValue: a["axis"] as? String ?? "") else { throw RPCError.invalidParams("axis must be horizontal or vertical") }
            session.addGuide(CanvasGuide(id: UUID(), axis: axis, position: try number(a, "position"))); return
        }
        guard let text = a["guide_id"] as? String, let id = UUID(uuidString: text), let guide = session.document?.guides.first(where: { $0.id == id }) else { throw RPCError.invalidParams("Unknown guide_id") }
        if action == "delete" { session.beginGuideMove(guide); session.finishGuideDrag(delete: true) }
        else if action == "move" {
            let position = try number(a, "position")
            session.beginEdit("Move Guide")
            if let i = session.document?.guides.firstIndex(where: { $0.id == id }) { session.document?.guides[i].position = position }
            session.endEdit()
        } else { throw RPCError.invalidParams("Unknown guide action") }
    }
    private func number(_ args: [String: Any], _ key: String, default fallback: Double? = nil, range: ClosedRange<Double> = -1_000_000...1_000_000) throws -> Double {
        guard let value = args[key] else { if let fallback { return fallback }; throw RPCError.invalidParams("Missing \(key)") }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, range.contains(number.doubleValue) else { throw RPCError.invalidParams("Invalid \(key)") }
        return number.doubleValue
    }
    private func color(_ value: Any?) throws -> PaletteColor? {
        guard let value else { return nil }
        guard let object = value as? [String: Any] else { throw RPCError.invalidParams("Color must be an RGB object") }
        return PaletteColor(red: try number(object, "red", range: 0...1), green: try number(object, "green", range: 0...1), blue: try number(object, "blue", range: 0...1))
    }
}
