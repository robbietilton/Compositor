import AppKit
import Foundation

/// Model-facing operations for every tool in Compositor's tool rail. These call the same session methods as pointer
/// input, but accept document coordinates so an MCP client can describe the intended result directly.
@MainActor
extension MCPToolRouter {
    func addShape(_ arguments: [String: Any]) throws -> [String: Any] {
        let session = try editableSession()
        let kindName = try arguments.requiredString("kind")
        guard let kind = ShapeKind.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(kindName) == .orderedSame }) else {
            throw MCPToolFailure(message: "kind must be rectangle, ellipse, or line.")
        }
        let start = try arguments.point(x: "start_x", y: "start_y")
        let end = try arguments.point(x: "end_x", y: "end_y")
        if kind != .line {
            guard abs(end.x - start.x) >= 1, abs(end.y - start.y) >= 1 else {
                throw MCPToolFailure(message: "A rectangle or ellipse must be at least 1 pixel wide and high.")
            }
        } else if hypot(end.x - start.x, end.y - start.y) < 0.5 {
            throw MCPToolFailure(message: "A line needs two different endpoints.")
        }
        if let value = try arguments.optionalString("color") { session.foregroundColor = try parseColor(value, key: "color") }
        let cornerRadius = try arguments.optionalNumber("corner_radius") ?? 0
        let lineWidth = try arguments.optionalNumber("line_width") ?? 4
        guard (0...150_000).contains(cornerRadius), (1...5_000).contains(lineWidth) else {
            throw MCPToolFailure(message: "corner_radius or line_width is outside the supported range.")
        }
        let previous = Set(session.document?.layers.map(\.id) ?? [])
        session.brushError = nil
        session.selectTool(.shape)
        session.shapeKind = kind
        session.shapeCornerRadius = cornerRadius
        session.shapeLineWidth = lineWidth
        session.beginShape(at: start)
        session.dragShape(to: end, square: false, fromCenter: false)
        session.finishShape()
        if let error = session.brushError { throw MCPToolFailure(message: error) }
        guard let layer = session.activeLayer, !previous.contains(layer.id), layer.liveShape != nil else {
            throw MCPToolFailure(message: "The shape could not be created.")
        }
        return try result(["layer": layerSummary(layer)])
    }

    func addText(_ arguments: [String: Any]) throws -> [String: Any] {
        let session = try editableSession()
        let content = try arguments.requiredString("content")
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPToolFailure(message: "content cannot be empty.")
        }
        let origin = try arguments.point(x: "x", y: "y")
        var style = session.textDefaults
        style.content = content
        style.colorRuns = nil
        style.fontRuns = nil
        if let fontName = try arguments.optionalString("font_name") {
            guard !fontName.isEmpty, fontName.count <= 200, !fontName.contains(where: \.isNewline) else {
                throw MCPToolFailure(message: "font_name is invalid.")
            }
            style.fontName = fontName
        }
        style.fontSize = try arguments.optionalNumber("font_size") ?? style.fontSize
        style.tracking = try arguments.optionalNumber("tracking") ?? style.tracking
        style.leading = try arguments.optionalNumber("leading") ?? style.leading
        if let value = try arguments.optionalString("color") {
            let color = try parseColor(value, key: "color")
            style.red = color.red; style.green = color.green; style.blue = color.blue
        }
        if let value = try arguments.optionalString("alignment") {
            guard let alignment = TextAlignment.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(value) == .orderedSame }) else {
                throw MCPToolFailure(message: "alignment must be left, center, or right.")
            }
            style.alignment = alignment
        }
        let boxWidth = try arguments.optionalNumber("box_width")
        let boxHeight = try arguments.optionalNumber("box_height")
        guard (boxWidth == nil) == (boxHeight == nil) else {
            throw MCPToolFailure(message: "box_width and box_height must be supplied together.")
        }
        if let boxWidth, let boxHeight { style.boxSize = CGSize(width: boxWidth, height: boxHeight) }
        guard style.isValid, let document = session.document else {
            throw MCPToolFailure(message: "The requested text settings are outside Compositor's limits.")
        }
        let previous = Set(document.layers.map(\.id))
        session.brushError = nil
        session.selectTool(.type)
        let draft = TextDraft(documentID: document.id, layerID: nil, origin: origin, style: style)
        guard session.applyText(draft), let layer = session.activeLayer,
              !previous.contains(layer.id), layer.liveText != nil else {
            throw MCPToolFailure(message: session.brushError ?? "The text layer could not be created.")
        }
        return try result(["layer": layerSummary(layer)])
    }

    func setSelection(_ arguments: [String: Any]) async throws -> [String: Any] {
        let session = try editableSession()
        if let id = try arguments.optionalUUID("layer_id") { try select(id, in: session) }
        let action = try arguments.requiredString("action").lowercased()
        let mode = try selectionMode(arguments)
        session.selectionAntialiased = try arguments.optionalBoolean("antialiased") ?? session.selectionAntialiased
        session.brushError = nil
        switch action {
        case "all": session.selectAll()
        case "none": session.deselect()
        case "invert": session.invertSelection()
        case "rectangle", "ellipse":
            let rect = try arguments.rect()
            let path = action == "ellipse" ? CGPath(ellipseIn: rect, transform: nil) : CGPath(rect: rect, transform: nil)
            session.applySelection(path, mode: mode, name: action == "ellipse" ? "Elliptical Marquee" : "Rectangular Marquee")
        case "polygon":
            let points = try arguments.points("points", minimum: 3)
            let path = CGMutablePath()
            path.addLines(between: points)
            path.closeSubpath()
            guard path.boundingBoxOfPath.width >= 0.5, path.boundingBoxOfPath.height >= 0.5 else {
                throw MCPToolFailure(message: "The polygon must enclose an area.")
            }
            session.applySelection(path, mode: mode, name: "Polygonal Lasso")
        case "wand":
            session.selectTool(.wand)
            session.wandMode = .wand
            session.wandSettings.tolerance = try arguments.optionalInteger("tolerance", range: 0...255) ?? 32
            session.wandSettings.contiguous = try arguments.optionalBoolean("contiguous") ?? true
            session.wandSettings.sampleAllLayers = try arguments.optionalBoolean("sample_all_layers") ?? false
            if let size = try arguments.optionalString("sample_size") {
                guard let sample = ["point": WandSampleSize.point, "3x3": .threeByThree, "5x5": .fiveByFive][size.lowercased()] else {
                    throw MCPToolFailure(message: "sample_size must be point, 3x3, or 5x5.")
                }
                session.wandSettings.sampleSize = sample
            }
            await session.magicWand(at: try arguments.point(x: "x", y: "y"), mode: mode)
        case "object":
            session.selectTool(.wand)
            session.wandMode = .object
            session.objectSelectionSettings.sampleAllLayers = try arguments.optionalBoolean("sample_all_layers") ?? true
            session.objectSelectionSettings.edgeOffset = try arguments.optionalInteger("edge_offset", range: -10...10) ?? 0
            await session.selectObject(at: try arguments.point(x: "x", y: "y"), mode: mode)
        default:
            throw MCPToolFailure(message: "Unknown selection action: \(action).")
        }
        if let error = session.brushError { throw MCPToolFailure(message: error) }
        if let feather = try arguments.optionalInteger("feather", range: 0...250), feather > 0,
           session.selection?.isEmpty == false {
            session.featherSelection(by: feather)
        }
        return try result(["selection": selectionSummary(session.selection)])
    }

    func paintStroke(_ arguments: [String: Any]) throws -> [String: Any] {
        let session = try editableSession()
        let points = try arguments.points("points", minimum: 1)
        if let id = try arguments.optionalUUID("layer_id") { try select(id, in: session) }
        guard let layer = session.activeLayer else { throw MCPToolFailure(message: "Select a layer before painting.") }
        let target = try arguments.optionalString("target")?.lowercased() ?? "layer"
        guard target == "layer" || target == "mask" else { throw MCPToolFailure(message: "target must be layer or mask.") }
        if target == "mask" {
            guard layer.mask != nil else { throw MCPToolFailure(message: "The target layer does not have a mask.") }
            session.selectLayerTarget(layer.id, mask: true)
        } else {
            session.selectLayerTarget(layer.id, mask: false)
        }

        let mode = try arguments.requiredString("mode").lowercased()
        let tool: NavigationTool
        switch mode {
        case "paint": tool = .brush; session.brushMode = .paint
        case "erase": tool = .brush; session.brushMode = .erase
        case "spot_healing": tool = .spotHealing
        case "clone_stamp": tool = .cloneStamp
        case "blur": tool = .blur; session.blurMode = .blur
        case "smudge": tool = .blur; session.blurMode = .smudge
        case "liquify": tool = .blur; session.blurMode = .liquify
        default: throw MCPToolFailure(message: "Unknown paint mode: \(mode).")
        }
        if target == "mask", !["paint", "blur"].contains(mode) {
            throw MCPToolFailure(message: "Only paint and blur modes can edit a layer mask.")
        }
        session.selectTool(tool)
        var settings = session.brushSettings
        settings.diameter = try arguments.optionalNumber("size") ?? settings.diameter
        settings.hardness = try arguments.optionalNumber("hardness") ?? settings.hardness
        settings.opacity = try arguments.optionalNumber("opacity") ?? settings.opacity
        settings.blurRadius = try arguments.optionalNumber("blur_radius") ?? settings.blurRadius
        settings.smoothing = 0
        guard (1...2_000).contains(settings.diameter), (0...1).contains(settings.hardness),
              (0.01...1).contains(settings.opacity), (0.1...250).contains(settings.blurRadius) else {
            throw MCPToolFailure(message: "One or more brush settings are outside the supported range.")
        }
        if let value = try arguments.optionalString("color") {
            let color = try parseColor(value, key: "color")
            settings.red = color.red; settings.green = color.green; settings.blue = color.blue
            session.maskPaintWhite = color.red + color.green + color.blue >= 1.5
        }
        session.brushSettings = settings
        if mode == "clone_stamp" {
            let source = try arguments.point(x: "source_x", y: "source_y")
            session.setCloneSource(source)
            session.cloneSettings.aligned = try arguments.optionalBoolean("aligned") ?? true
            session.cloneSettings.sampleAllLayers = try arguments.optionalBoolean("sample_all_layers") ?? false
        }
        session.brushError = nil
        session.beginBrush(at: points[0])
        guard session.brushStroke != nil || session.warpStroke != nil else {
            throw MCPToolFailure(message: session.brushError ?? session.paintRefusal ?? "The stroke could not start.")
        }
        for point in points.dropFirst() { session.continueBrush(at: point) }
        guard session.finishBrushImmediately() else { throw MCPToolFailure(message: "Compositor is busy finishing the stroke.") }
        if let error = session.brushError { throw MCPToolFailure(message: error) }
        guard let updated = session.document?.layers.first(where: { $0.id == layer.id }) else {
            throw MCPToolFailure(message: "The painted layer is no longer available.")
        }
        return try result(["layer": layerSummary(updated), "mode": mode, "points": points.count])
    }

    func applyGradient(_ arguments: [String: Any]) async throws -> [String: Any] {
        let session = try editableSession()
        if let id = try arguments.optionalUUID("layer_id") { try select(id, in: session) }
        guard let layer = session.activeLayer else { throw MCPToolFailure(message: "Select a layer before applying a gradient.") }
        let target = try arguments.optionalString("target")?.lowercased() ?? "layer"
        if target == "mask" {
            guard layer.mask != nil else { throw MCPToolFailure(message: "The target layer does not have a mask.") }
            session.selectLayerTarget(layer.id, mask: true)
        } else if target == "layer" { session.selectLayerTarget(layer.id, mask: false) }
        else { throw MCPToolFailure(message: "target must be layer or mask.") }
        let start = try arguments.point(x: "start_x", y: "start_y")
        let end = try arguments.point(x: "end_x", y: "end_y")
        guard hypot(end.x - start.x, end.y - start.y) >= 0.5 else {
            throw MCPToolFailure(message: "The gradient start and end must be different.")
        }
        if let value = try arguments.optionalString("foreground") { session.foregroundColor = try parseColor(value, key: "foreground") }
        if let value = try arguments.optionalString("background") { session.backgroundColor = try parseColor(value, key: "background") }
        var settings = session.gradientSettings
        if let value = try arguments.optionalString("shape") {
            guard let shape = GradientShape.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(value) == .orderedSame }) else {
                throw MCPToolFailure(message: "shape must be linear or radial.")
            }
            settings.shape = shape
        }
        if let value = try arguments.optionalString("style") {
            switch value.lowercased() {
            case "color_to_color": settings.style = .foregroundToBackground
            case "color_to_transparent": settings.style = .foregroundToTransparent
            default: throw MCPToolFailure(message: "style must be color_to_color or color_to_transparent.")
            }
        }
        settings.opacity = try arguments.optionalNumber("opacity") ?? settings.opacity
        settings.reversed = try arguments.optionalBoolean("reversed") ?? false
        guard (0...1).contains(settings.opacity) else { throw MCPToolFailure(message: "opacity must be between 0 and 1.") }
        session.gradientSettings = settings
        session.brushError = nil
        session.selectTool(.gradient)
        session.beginGradient(at: start)
        session.moveGradient(end: end)
        guard session.gradientEdit != nil else {
            throw MCPToolFailure(message: session.brushError ?? session.paintRefusal ?? "The gradient could not start.")
        }
        await session.commitGradient()
        if let error = session.brushError { throw MCPToolFailure(message: error) }
        guard let updated = session.document?.layers.first(where: { $0.id == layer.id }) else {
            throw MCPToolFailure(message: "The gradient target is no longer available.")
        }
        return try result(["layer": layerSummary(updated)])
    }

    func crop(_ arguments: [String: Any]) async throws -> [String: Any] {
        let session = try editableSession()
        let rect = try arguments.rect()
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy({ $0.rounded() == $0 }),
              CropGeometry.valid(rect), Int(rect.width) <= DocumentLimits.maxSide,
              Int(rect.height) <= DocumentLimits.maxSide else {
            throw MCPToolFailure(message: "Crop coordinates and dimensions must be whole pixels inside Compositor's limits.")
        }
        session.cropError = nil
        session.selectTool(.crop)
        session.cropRect = rect
        await session.commitCrop()
        if let error = session.cropError { throw MCPToolFailure(message: error) }
        guard let document = session.document, document.width == Int(rect.width), document.height == Int(rect.height) else {
            throw MCPToolFailure(message: "The crop could not be applied.")
        }
        return try result(["width": document.width, "height": document.height])
    }

    func sampleColor(_ arguments: [String: Any]) throws -> [String: Any] {
        let session = try documentSession()
        let point = try arguments.point(x: "x", y: "y")
        guard let color = session.sampleCompositeColor(at: point) else {
            throw MCPToolFailure(message: "The sample point is outside the canvas or fully transparent.")
        }
        return try result([
            "hex": "#" + color.hex,
            "red": color.red, "green": color.green, "blue": color.blue,
            "x": point.x, "y": point.y
        ])
    }

    func setView(_ arguments: [String: Any]) throws -> [String: Any] {
        let session = try documentSession()
        let action = try arguments.requiredString("action").lowercased()
        switch action {
        case "fit": session.selectTool(.hand); session.fit()
        case "zoom":
            let zoom = try arguments.requiredNumber("zoom")
            guard CanvasViewport.zoomRange.contains(zoom) else { throw MCPToolFailure(message: "zoom must be between 0.001 and 32.") }
            session.selectTool(.zoom)
            session.zoom(to: zoom)
        case "pan":
            let dx = try arguments.requiredNumber("dx"), dy = try arguments.requiredNumber("dy")
            session.selectTool(.hand)
            session.viewport.translate(by: CGSize(width: dx, height: dy))
        default: throw MCPToolFailure(message: "action must be fit, zoom, or pan.")
        }
        return try result(viewSummary(session))
    }

    func manageLayer(_ arguments: [String: Any]) throws -> [String: Any] {
        let session = try editableSession()
        let action = try arguments.requiredString("action").lowercased()
        let suppliedID = try arguments.optionalUUID("layer_id")
        if let suppliedID { try select(suppliedID, in: session) }
        let targetID = session.activeLayerID
        let before = Set(session.document?.layers.map(\.id) ?? [])
        switch action {
        case "add_blank": session.addBlankLayer()
        case "add_group": session.addGroup()
        case "duplicate":
            guard session.activeLayer != nil else { throw MCPToolFailure(message: "layer_id is required when no layer is active.") }
            session.duplicateActiveLayer()
        case "rename":
            guard let id = session.activeLayerID else { throw MCPToolFailure(message: "layer_id is required.") }
            let name = try arguments.requiredString("name").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw MCPToolFailure(message: "name cannot be empty.") }
            session.renameLayer(id, to: name)
        case "delete":
            guard let id = session.activeLayerID else { throw MCPToolFailure(message: "layer_id is required.") }
            let dependents = session.document?.layers.filter { $0.maskSourceID == id }.map(\.name) ?? []
            guard dependents.isEmpty else {
                throw MCPToolFailure(message: "This layer supplies live masks to \(dependents.joined(separator: ", ")). Remove those links in Compositor first.")
            }
            session.deleteLayer(id)
        case "add_mask":
            guard session.activeLayer != nil else { throw MCPToolFailure(message: "layer_id is required.") }
            session.addLayerMask(revealing: try arguments.optionalBoolean("reveal") ?? true)
        case "remove_mask":
            guard session.activeLayer?.mask != nil else { throw MCPToolFailure(message: "The target layer does not have a mask.") }
            session.deleteLayerMask()
        case "place":
            guard let id = session.activeLayerID else { throw MCPToolFailure(message: "layer_id is required.") }
            let parent = try arguments.optionalUUID("parent_id")
            let above = try arguments.optionalUUID("above_layer_id")
            guard session.placeLayer(id, in: parent, above: above) else {
                throw MCPToolFailure(message: "The layer cannot be placed at that hierarchy location.")
            }
        default: throw MCPToolFailure(message: "Unknown layer action: \(action).")
        }
        if let name = try arguments.optionalString("name"), ["add_blank", "add_group"].contains(action),
           let id = session.activeLayerID {
            session.renameLayer(id, to: name)
        }
        if action == "delete" {
            guard let targetID, session.document?.layers.contains(where: { $0.id == targetID }) == false else {
                throw MCPToolFailure(message: "The layer could not be deleted.")
            }
            return try result(["deleted_layer_id": targetID.uuidString])
        }
        guard let layer = session.activeLayer else { throw MCPToolFailure(message: "The layer operation did not produce an active layer.") }
        if ["add_blank", "add_group", "duplicate"].contains(action), before.contains(layer.id) {
            throw MCPToolFailure(message: "The layer could not be created.")
        }
        return try result(["layer": layerSummary(layer)])
    }

    private func editableSession() throws -> EditorSession {
        let session = try documentSession()
        guard session.canEditLayers else { throw MCPToolFailure(message: "Finish the current canvas edit or dialog before using this tool.") }
        return session
    }

    private func documentSession() throws -> EditorSession {
        let session = workspace.current.session
        guard session.document != nil else { throw MCPToolFailure(message: "Create or open a document first.") }
        return session
    }

    private func select(_ id: UUID, in session: EditorSession) throws {
        guard session.document?.layers.contains(where: { $0.id == id }) == true else {
            throw MCPToolFailure(message: "No layer has id \(id.uuidString).")
        }
        session.selectLayer(id)
        guard session.activeLayerID == id else { throw MCPToolFailure(message: "The layer could not be selected.") }
    }

    private func parseColor(_ value: String, key: String) throws -> PaletteColor {
        guard let color = PaletteColor(hex: value) else { throw MCPToolFailure(message: "\(key) must look like #3366FF.") }
        return color
    }

    private func selectionMode(_ arguments: [String: Any]) throws -> SelectionMode {
        switch try arguments.optionalString("mode")?.lowercased() ?? "replace" {
        case "replace": .replace
        case "add": .add
        case "subtract": .subtract
        default: throw MCPToolFailure(message: "mode must be replace, add, or subtract.")
        }
    }

    private func selectionSummary(_ selection: DocumentSelection?) -> Any {
        guard let selection else { return NSNull() }
        if selection.isEmpty {
            return ["empty": true, "antialiased": selection.antialiased,
                    "feather": selection.feather] as [String: Any]
        }
        let bounds = selection.path.boundingBoxOfPath
        return ["empty": false, "x": bounds.minX, "y": bounds.minY,
                "width": bounds.width, "height": bounds.height,
                "antialiased": selection.antialiased, "feather": selection.feather] as [String: Any]
    }

    private func viewSummary(_ session: EditorSession) -> [String: Any] {
        ["active_tool": session.tool.rawValue, "zoom": session.viewport.zoom,
         "pan_x": session.viewport.pan.width, "pan_y": session.viewport.pan.height,
         "follows_fit": session.viewport.followsFit]
    }
}

extension Dictionary where Key == String, Value == Any {
    func optionalUUID(_ key: String) throws -> UUID? {
        guard self[key] != nil else { return nil }
        return try requiredUUID(key)
    }

    func point(x: String, y: String) throws -> CGPoint {
        CGPoint(x: try requiredNumber(x), y: try requiredNumber(y))
    }

    func rect() throws -> CGRect {
        let x = try requiredNumber("x"), y = try requiredNumber("y")
        let width = try requiredNumber("width"), height = try requiredNumber("height")
        guard width >= 0.5, height >= 0.5, width <= 300_000, height <= 300_000 else {
            throw MCPToolFailure(message: "width and height must be between 0.5 and 300000.")
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    func points(_ key: String, minimum: Int) throws -> [CGPoint] {
        guard let values = self[key] as? [[String: Any]], (minimum...10_000).contains(values.count) else {
            throw MCPToolFailure(message: "\(key) must contain from \(minimum) through 10000 points.")
        }
        return try values.map { try $0.point(x: "x", y: "y") }
    }
}
