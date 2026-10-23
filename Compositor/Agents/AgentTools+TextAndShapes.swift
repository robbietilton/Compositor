import AppKit

/// Text and shape layers, which stay editable: their words, face, color and corners can change after they're made.
extension AgentTools {
    static var textAndShapeTools: [AgentTool] {
        [
            AgentTool(name: "add_text",
                      description: """
                        Adds a text layer above the selected layer. `x`, `y` place the layer's top-left corner; the letters \
                        sit 12 pixels in from it. Without `box_width` the text runs on one line per line break; with it, \
                        it wraps inside a box that wide. The text stays editable with update_text.
                        """,
                      schema: Schema.object(textProperties.merging([
                        "document": Schema.document,
                        "text": Schema.string("The words; \\n starts a new line."),
                        "x": Schema.number("Left edge of the layer."),
                        "y": Schema.number("Top edge of the layer."),
                        "above_layer_id": Schema.string("Put it above this layer. Omitted: above the selected one."),
                      ]) { $1 }, required: ["text", "x", "y"])) { call in
                let session = try call.session()
                guard let document = session.document else { throw AgentError("No canvas.") }
                if let above = try call.id("above_layer_id") {
                    guard document.layers.contains(where: { $0.id == above }) else { throw AgentError("No layer has id \(above.uuidString).") }
                    session.selectLayer(above)
                }
                var style = session.textDefaults
                style.colorRuns = nil
                style.fontRuns = nil
                style.boxSize = nil
                style.content = try call.requiredString("text")
                let foreground = session.foregroundColor
                style.red = foreground.red; style.green = foreground.green; style.blue = foreground.blue
                try applyTextArguments(call, to: &style)
                guard let x = try call.double("x"), let y = try call.double("y") else { throw AgentError("Give `x` and `y`.") }
                let before = Set(document.layers.map(\.id))
                try apply(TextDraft(documentID: document.id, layerID: nil, origin: CGPoint(x: x, y: y), style: style), in: session)
                guard let added = session.document?.layers.first(where: { !before.contains($0.id) }) else {
                    throw AgentError("No text was added: it may be only spaces.")
                }
                return .json(try describe(added, in: session))
            },
            AgentTool(name: "update_text",
                      description: """
                        Changes a text layer, keeping it text: its words, font, size, color, alignment, spacing or box, as \
                        one undo step. Its top-left corner stays put. `style` takes the layer's text record partially, as \
                        get_document shows it, for colorRuns and fontRuns (letters in another color or face).
                        """,
                      schema: Schema.object(textProperties.merging([
                        "document": Schema.document,
                        "layer_id": Schema.layer,
                        "text": Schema.string("New words."),
                        "style": Schema.anyObject("Fields of the text record to change, e.g. colorRuns."),
                      ]) { $1 })) { call in
                let session = try call.session()
                let layer = try call.layer(in: session)
                guard let text = layer.liveText, let document = session.document else {
                    throw AgentError("“\(layer.name)” isn't editable text (anymore): painting or filtering it made it pixels.")
                }
                var style = text.style
                if let content = try call.string("text") {
                    style.content = content
                    // Runs past the new end of the text would make it invalid; changed words take the text's own color and face.
                    if content != text.style.content { style.colorRuns = nil; style.fontRuns = nil }
                }
                try applyTextArguments(call, to: &style)
                if let patch = call.arguments["style"], !patch.isNull { style = try patched(style, with: patch) }
                // Without a transform, the layer keeps its scale and top-left corner and grows or shrinks to the new text.
                try apply(TextDraft(documentID: document.id, layerID: layer.id, origin: layer.origin, style: style), in: session)
                return .json(try describe(session.document?.layers.first { $0.id == layer.id } ?? layer, in: session))
            },
            AgentTool(name: "list_fonts",
                      description: "The fonts on this Mac, by the PostScript names add_text and update_text take, with their display names.",
                      schema: Schema.object(["query": Schema.string("Only names containing this, e.g. \"Helvetica\" or \"Bold\"."),
                                             "limit": Schema.integer("At most this many. Default 100.", minimum: 1, maximum: 5000)]),
                      readOnly: true) { call in
                let query = try call.string("query")?.lowercased() ?? ""
                let fonts = NSFontManager.shared.availableFonts.compactMap { name -> JSONValue? in
                    let display = NSFont(name: name, size: 12)?.displayName ?? name
                    guard query.isEmpty || name.lowercased().contains(query) || display.lowercased().contains(query) else { return nil }
                    return .object(["font": .string(name), "name": .string(display)])
                }
                return .json(.array(Array(fonts.prefix(try call.int("limit") ?? 100))))
            },
            AgentTool(name: "add_shape",
                      description: """
                        Draws a shape on a new layer above the selected one, as the Shape tool does: a "rectangle" or \
                        "ellipse" filling x, y, width, height, or a "line" from `from` to `to`. It stays a shape, so it \
                        redraws sharply when scaled, and update_shape changes its color and corners.
                        """,
                      schema: Schema.object([
                        "document": Schema.document,
                        "kind": Schema.string("Which shape.", oneOf: ["rectangle", "ellipse", "line"]),
                        "x": Schema.number("Left edge."), "y": Schema.number("Top edge."),
                        "width": Schema.number("Width."), "height": Schema.number("Height."),
                        "from": Schema.point("A line's start."), "to": Schema.point("A line's end."),
                        "color": Schema.string("#RRGGBB. Default the foreground color."),
                        "corner_radius": Schema.number("A rectangle's corner radius in pixels."),
                        "smoothing": Schema.boolean("A rectangle's corners smoothed as iOS's are, rather than circular."),
                        "line_width": Schema.number("A line's thickness. Default 4."),
                        "line_style": Schema.string("A line's dashes.", oneOf: ShapeLineStyle.allCases.map(\.rawValue)),
                        "line_cap": Schema.string("A line's ends.", oneOf: ShapeLineCap.allCases.map(\.rawValue)),
                        "name": Schema.string("The layer's name."),
                        "above_layer_id": Schema.string("Put it above this layer. Omitted: above the selected one."),
                      ], required: ["kind"])) { call in
                let session = try call.session()
                if let above = try call.id("above_layer_id") {
                    guard session.document?.layers.contains(where: { $0.id == above }) == true else { throw AgentError("No layer has id \(above.uuidString).") }
                    session.selectLayer(above)
                }
                let kindName = try call.requiredString("kind").lowercased()
                guard let kind = ShapeKind.allCases.first(where: { $0.rawValue.lowercased() == kindName }) else {
                    throw AgentError("`kind` is rectangle, ellipse or line.")
                }
                let start: CGPoint, end: CGPoint
                if kind == .line {
                    guard let from = try call.point("from"), let to = try call.point("to") else { throw AgentError("A line needs `from` and `to`.") }
                    start = from; end = to
                } else {
                    guard let x = try call.double("x"), let y = try call.double("y"), let width = try call.double("width"),
                          let height = try call.double("height"), width >= 1, height >= 1 else {
                        throw AgentError("A \(kind.rawValue.lowercased()) needs x, y, and a width and height of at least 1.")
                    }
                    start = CGPoint(x: x, y: y); end = CGPoint(x: x + width, y: y + height)
                }
                let kept = (tool: session.tool, kind: session.shapeKind, radius: session.shapeCornerRadius, smoothing: session.shapeSmoothing,
                            width: session.shapeLineWidth, style: session.shapeLineStyle, cap: session.shapeLineCap,
                            foreground: session.foregroundColor)
                defer {
                    session.selectTool(kept.tool)
                    session.shapeKind = kept.kind; session.shapeCornerRadius = kept.radius; session.shapeSmoothing = kept.smoothing
                    session.shapeLineWidth = kept.width; session.shapeLineStyle = kept.style; session.shapeLineCap = kept.cap
                    session.foregroundColor = kept.foreground
                }
                session.selectTool(.shape)
                session.shapeKind = kind
                session.shapeCornerRadius = try call.double("corner_radius") ?? 0
                session.shapeSmoothing = try call.bool("smoothing") ?? false
                session.shapeLineWidth = try call.double("line_width") ?? 4
                guard session.shapeCornerRadius >= 0, (0.5...2000).contains(session.shapeLineWidth) else {
                    throw AgentError("corner_radius can't be negative, and line_width runs 0.5–2000.")
                }
                session.shapeLineStyle = try choice(call, "line_style", default: .solid)
                session.shapeLineCap = try choice(call, "line_cap", default: .square)
                if let hex = try call.string("color") { session.foregroundColor = try color(hex) }
                let before = Set(session.document?.layers.map(\.id) ?? [])
                session.beginShape(at: start)
                session.dragShape(to: end, square: false, fromCenter: false)
                session.finishShape()
                guard let added = session.document?.layers.first(where: { !before.contains($0.id) }) else {
                    throw AgentError(takeError(session) ?? "No shape was drawn: it may be smaller than a pixel.")
                }
                if let name = try call.string("name") { session.renameLayer(added.id, to: name) }
                return .json(try describe(session.document?.layers.first { $0.id == added.id } ?? added, in: session))
            },
            AgentTool(name: "update_shape",
                      description: "Changes a shape layer's color, a rectangle's corners, or a line's dashes and ends, keeping it a shape, as one undo step.",
                      schema: Schema.object([
                        "document": Schema.document,
                        "layer_id": Schema.layer,
                        "color": Schema.string("#RRGGBB."),
                        "corner_radius": Schema.number("A rectangle's corner radius in pixels."),
                        "smoothing": Schema.boolean("A rectangle's corners smoothed as iOS's are."),
                        "line_style": Schema.string("A line's dashes.", oneOf: ShapeLineStyle.allCases.map(\.rawValue)),
                        "line_cap": Schema.string("A line's ends.", oneOf: ShapeLineCap.allCases.map(\.rawValue)),
                      ])) { call in
                let session = try call.session()
                let layer = try call.layer(in: session)
                guard let shape = layer.liveShape, let asset = layer.asset,
                      let index = session.document?.layers.firstIndex(where: { $0.id == layer.id }) else {
                    throw AgentError("“\(layer.name)” isn't a shape (anymore): painting or filtering it made it pixels.")
                }
                var style = shape.style
                if let hex = try call.string("color") { let color = try color(hex); style.red = color.red; style.green = color.green; style.blue = color.blue }
                if style.kind == .rectangle {
                    if let radius = try call.double("corner_radius") {
                        guard radius >= 0 else { throw AgentError("corner_radius can't be negative.") }
                        style.cornerRadius = radius
                    }
                    if let smoothing = try call.bool("smoothing") { style.smoothing = smoothing ? true : nil }
                } else if call.has("corner_radius") || call.has("smoothing") {
                    throw AgentError("Only a rectangle has corners.")
                }
                if style.kind == .line {
                    if call.has("line_style") { let value: ShapeLineStyle = try choice(call, "line_style", default: .solid); style.lineStyle = value == .solid ? nil : value }
                    if call.has("line_cap") { let value: ShapeLineCap = try choice(call, "line_cap", default: .round); style.lineCap = value == .round ? nil : value }
                } else if call.has("line_style") || call.has("line_cap") {
                    throw AgentError("Only a line has dashes and ends.")
                }
                guard style != shape.style else { return .text("“\(layer.name)” already looks like that.") }
                let image: CGImage
                do {
                    image = try EditorSession.shapeImage(style.kind, size: CGSize(width: asset.image.width, height: asset.image.height),
                                                         color: style.color, cornerRadius: style.cornerRadius, smoothing: style.smoothing == true,
                                                         lineWidth: style.lineWidth ?? 0, start: style.start, end: style.end,
                                                         lineStyle: style.lineStyle ?? .solid, lineCap: style.lineCap ?? .round)
                } catch { throw AgentError("The shape couldn't be drawn: \(error.localizedDescription)") }
                session.beginEdit("Change Shape")
                session.document?.layers[index].asset = ImportedImage(image: image, thumbnail: try PixelInvert.thumbnail(of: image), name: asset.name)
                session.document?.layers[index].shape = LayerShape(style: style, image: image)
                session.endEdit()
                return .json(try describe(session.document?.layers[index] ?? layer, in: session))
            },
        ]
    }

    /// The text settings add_text and update_text share.
    private static let textProperties: [String: JSONValue] = [
        "font": Schema.string("A PostScript font name from list_fonts, e.g. \"Helvetica-Bold\"."),
        "size": Schema.number("Font size in pixels, 1–2000."),
        "color": Schema.string("#RRGGBB. Default the foreground color."),
        "alignment": Schema.string("Default left.", oneOf: TextAlignment.allCases.map(\.rawValue)),
        "tracking": Schema.number("Letter spacing, −100–1000, in thousandths of the size."),
        "leading": Schema.number("Baseline to baseline in pixels; 0 is auto, 120% of the size."),
        "box_width": Schema.number("Wrap inside a box this wide."),
        "box_height": Schema.number("The box's height. Default: tall enough for the text."),
    ]

    private static func applyTextArguments(_ call: AgentCall, to style: inout LayerTextStyle) throws {
        if let font = try call.string("font") {
            guard NSFont(name: font, size: 12) != nil else { throw AgentError("There's no font “\(font)” on this Mac. list_fonts finds them.") }
            style.fontName = font
            style.fontRuns = nil
        }
        if let size = try call.double("size") { style.fontSize = size }
        if let hex = try call.string("color") {
            let color = try color(hex)
            style.setColor(color, in: NSRange(location: 0, length: 0))
        }
        if let alignment = try call.string("alignment") {
            guard let value = TextAlignment(rawValue: alignment) else { throw AgentError("`alignment` is Left, Center or Right.") }
            style.alignment = value
        }
        if let tracking = try call.double("tracking") { style.tracking = tracking }
        if let leading = try call.double("leading") { style.leading = leading }
        if let width = try call.double("box_width") {
            let measured = EditorSession.attributedText(style).boundingRect(
                with: CGSize(width: max(1, width - LayerTextStyle.padding * 2), height: 100_000), options: [.usesLineFragmentOrigin, .usesFontLeading])
            let height = try call.double("box_height") ?? ceil(max(measured.height, style.lineHeight) + LayerTextStyle.padding * 2)
            style.boxSize = CGSize(width: width, height: height)
        } else if call.has("box_height") {
            guard let box = style.boxSize else { throw AgentError("Give `box_width` too: text without a box sizes itself.") }
            style.boxSize = CGSize(width: box.width, height: try call.double("box_height") ?? box.height)
        }
        guard style.isValid else { throw AgentError("Those text settings are out of range: size 1–2000, tracking −100–1000, leading 0–5000, a box 16 pixels or more.") }
    }

    /// Applies a text draft as pressing Return on the canvas does, keeping the Type tool's own settings as the person left them.
    private static func apply(_ draft: TextDraft, in session: EditorSession) throws {
        let defaults = session.textDefaults
        defer { session.textDefaults = defaults }
        guard session.applyText(draft) else { throw AgentError(takeError(session) ?? "The text couldn't be set: \(busyReason(session) ?? "it may be too large").") }
        if let error = takeError(session) { throw AgentError(error) }
    }

    private static func choice<Value: RawRepresentable & CaseIterable>(_ call: AgentCall, _ key: String, default fallback: Value) throws -> Value
        where Value.RawValue == String {
        guard let raw = try call.string(key) else { return fallback }
        guard let value = Value.allCases.first(where: { $0.rawValue.lowercased() == raw.lowercased() }) else {
            throw AgentError("`\(key)` is one of: \(Value.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return value
    }
}
