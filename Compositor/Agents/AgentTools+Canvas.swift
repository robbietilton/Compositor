import AppKit

/// The canvas itself: its size, the image's size, cropping, trimming, turning and flipping, by value rather than
/// through their dialogs.
extension AgentTools {
    /// Canvas Size's anchors, row by row from the top-left, as the dialog's grid is.
    private static let anchors = ["top-left", "top", "top-right", "left", "center", "right", "bottom-left", "bottom", "bottom-right"]

    static var canvasTools: [AgentTool] {
        [
            AgentTool(name: "canvas_size",
                      description: """
                        Changes the canvas's size without scaling anything, as Image › Canvas Size does: layers keep their \
                        pixels, placed by `anchor`. New room is clear, or filled with `fill` on a new bottom layer.
                        """,
                      schema: Schema.object([
                        "document": Schema.document,
                        "width": Schema.integer("New width in pixels.", minimum: 1, maximum: DocumentLimits.maxSide),
                        "height": Schema.integer("New height in pixels.", minimum: 1, maximum: DocumentLimits.maxSide),
                        "anchor": Schema.string("Which part stays put. Default center.", oneOf: anchors),
                        "fill": Schema.string("#RRGGBB for the new room. Default: clear."),
                      ], required: ["width", "height"])) { call in
                let session = try call.session()
                let width = try call.int("width") ?? 0, height = try call.int("height") ?? 0
                guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height) else {
                    throw AgentError("Width and height must be 1–\(DocumentLimits.maxSide) pixels.")
                }
                let anchorName = try call.string("anchor", default: "center")
                guard let anchor = anchors.firstIndex(of: anchorName) else { throw AgentError("`anchor` is one of: \(anchors.joined(separator: ", ")).") }
                let fill = try call.string("fill").map { try color($0) }.map { CanvasExtensionColor(red: $0.red, green: $0.green, blue: $0.blue) }
                try await resize(session, name: "Canvas Size", keepingZoom: true) { snapshot in
                    try await CanvasResizer.shared.resize(snapshot, to: CanvasSizeOptions(width: width, height: height, anchor: anchor, fill: fill))
                }
                return .text("The canvas is now \(width)×\(height).")
            },
            AgentTool(name: "image_size",
                      description: """
                        Scales the whole image, every layer with it, as Image › Image Size does. Give `width` or `height` \
                        alone to keep the proportions; `resolution` alone changes only the print size.
                        """,
                      schema: Schema.object([
                        "document": Schema.document,
                        "width": Schema.integer("New width in pixels.", minimum: 1, maximum: DocumentLimits.maxSide),
                        "height": Schema.integer("New height in pixels.", minimum: 1, maximum: DocumentLimits.maxSide),
                        "resolution": Schema.number("Pixels per inch, 1–9600."),
                        "sampling": Schema.string("How pixels are resampled. Default High quality.", oneOf: LayerSampling.allCases.map(\.rawValue)),
                      ])) { call in
                let session = try call.session()
                guard let document = session.document else { throw AgentError("No canvas.") }
                let asked = (width: try call.int("width"), height: try call.int("height"))
                let aspect = Double(document.width) / Double(document.height)
                let width = asked.width ?? asked.height.map { max(1, Int((Double($0) * aspect).rounded())) } ?? document.width
                let height = asked.height ?? asked.width.map { max(1, Int((Double($0) / aspect).rounded())) } ?? document.height
                let resolution = try call.double("resolution") ?? document.resolution
                let samplingName = try call.string("sampling", default: LayerSampling.high.rawValue)
                guard let sampling = LayerSampling(rawValue: samplingName) else {
                    throw AgentError("`sampling` is one of: \(LayerSampling.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height), (1...9600).contains(resolution) else {
                    throw AgentError("Sides run 1–\(DocumentLimits.maxSide) pixels, resolution 1–9600.")
                }
                try await resize(session, name: "Image Size", keepingZoom: true) { snapshot in
                    try await ImageResizer.shared.resize(snapshot, to: ImageSizeOptions(width: width, height: height, resolution: resolution, sampling: sampling))
                }
                return .text("The image is now \(width)×\(height) at \(resolution.formatted()) pixels per inch.")
            },
            AgentTool(name: "crop",
                      description: "Crops the canvas to a rectangle, as the Crop tool does: layers keep their pixels past the edge, out of view.",
                      schema: Schema.object([
                        "document": Schema.document,
                        "x": Schema.number("Left edge."), "y": Schema.number("Top edge."),
                        "width": Schema.number("Width."), "height": Schema.number("Height."),
                      ], required: ["x", "y", "width", "height"])) { call in
                let session = try call.session()
                guard let x = try call.double("x"), let y = try call.double("y"), let width = try call.double("width"), let height = try call.double("height")
                else { throw AgentError("Give x, y, width and height.") }
                let rect = CGRect(x: x, y: y, width: width, height: height).integral
                guard CropGeometry.valid(rect) else { throw AgentError("That rectangle can't be a canvas: sides of 1–\(DocumentLimits.maxSide) pixels.") }
                try await resize(session, name: "Crop") { snapshot in
                    try await CanvasResizer.shared.resize(snapshot, to: CanvasSizeOptions(width: Int(rect.width), height: Int(rect.height),
                                                                                          contentOffset: CGPoint(x: -rect.minX, y: -rect.minY)))
                }
                return .text("Cropped to \(Int(rect.width))×\(Int(rect.height)) from (\(Int(rect.minX)), \(Int(rect.minY))).")
            },
            AgentTool(name: "trim",
                      description: "Trims away the canvas's empty edges, as Image › Trim does: clear pixels, or the color of a corner pixel.",
                      schema: Schema.object([
                        "document": Schema.document,
                        "based_on": Schema.string("What counts as empty. Default Transparent Pixels.", oneOf: TrimBasedOn.allCases.map(\.rawValue)),
                        "tolerance": Schema.integer("How far from that a pixel may be and still count, 0–255. Default 0.", minimum: 0, maximum: 255),
                      ])) { call in
                let session = try call.session()
                let basedOnName = try call.string("based_on", default: TrimBasedOn.transparentPixels.rawValue)
                guard let basedOn = TrimBasedOn(rawValue: basedOnName) else { throw AgentError("`based_on` is one of: \(TrimBasedOn.allCases.map(\.rawValue).joined(separator: ", ")).") }
                let tolerance = try call.int("tolerance") ?? 0
                guard (0...255).contains(tolerance) else { throw AgentError("`tolerance` runs 0–255.") }
                var trimmed = true
                try await resize(session, name: "Trim") { snapshot in
                    guard let result = try await ImageTrim.trim(snapshot, options: TrimOptions(basedOn: basedOn, tolerance: UInt8(tolerance))) else {
                        trimmed = false
                        return nil
                    }
                    return result
                }
                guard trimmed, let document = session.document else { return .text("There was nothing to trim.") }
                return .text("Trimmed to \(document.width)×\(document.height).")
            },
            AgentTool(name: "rotate_canvas",
                      description: "Turns the whole canvas a quarter turn, as Image › Rotate does.",
                      schema: Schema.object(["document": Schema.document,
                                             "direction": Schema.string("Which way.", oneOf: ["clockwise", "counterclockwise"])], required: ["direction"])) { call in
                let session = try call.session()
                let direction = try call.requiredString("direction")
                guard direction == "clockwise" || direction == "counterclockwise" else { throw AgentError("`direction` is clockwise or counterclockwise.") }
                let revision = session.history.currentRevision
                session.rotateCanvas(clockwise: direction == "clockwise")
                guard session.history.currentRevision != revision else { throw AgentError(takeError(session) ?? "The canvas couldn't be turned.") }
                return .text("Turned the canvas \(direction); it's now \(session.document?.width ?? 0)×\(session.document?.height ?? 0).")
            },
            AgentTool(name: "flip",
                      description: "Flips the selected layers (or the whole canvas) horizontally or vertically.",
                      schema: Schema.object(["document": Schema.document,
                                             "layer_ids": Schema.array("Layers to flip. Omitted: the selected ones.", of: .object(["type": "string"])),
                                             "canvas": Schema.boolean("Flip the whole canvas instead."),
                                             "direction": Schema.string("Which way.", oneOf: ["horizontal", "vertical"])], required: ["direction"])) { call in
                let session = try call.session()
                let direction = try call.requiredString("direction")
                guard direction == "horizontal" || direction == "vertical" else { throw AgentError("`direction` is horizontal or vertical.") }
                if call.has("layer_ids") {
                    let ids = try existing(call.ids("layer_ids"), in: session)
                    session.selectLayers(Set(ids), primary: ids.first)
                }
                let revision = session.history.currentRevision
                if try call.bool("canvas") == true { session.flipCanvas(horizontally: direction == "horizontal") }
                else { session.flipLayers(horizontally: direction == "horizontal") }
                guard session.history.currentRevision != revision else { throw AgentError(takeError(session) ?? "Nothing was flipped.") }
                return .text("Flipped \(direction == "horizontal" ? "horizontally" : "vertically").")
            },
        ]
    }

    /// Rebuilds the document at a new size from a snapshot, as Canvas Size, Image Size, Crop and Trim do, the editor held
    /// busy meanwhile so nothing else changes it. `make` returns nil when there's nothing to change.
    private static func resize(_ session: EditorSession, name: String, keepingZoom: Bool = false,
                               _ make: (ProjectSnapshot) async throws -> ProjectSnapshot?) async throws {
        guard session.canStartProjectOperation, let snapshot = session.projectSnapshot() else {
            throw AgentError("Compositor is busy: \(busyReason(session) ?? "another operation is running").")
        }
        session.isProjectBusy = true
        defer { session.isProjectBusy = false }
        let result: ProjectSnapshot?
        do { result = try await make(snapshot) }
        catch { throw AgentError("\(name) couldn't be done: \(error.localizedDescription)") }
        guard let result else { return }
        session.applyDocumentSize(result, actionName: name, keepingZoom: keepingZoom)
    }
}
