import AppKit

nonisolated enum ShapeKind: String, CaseIterable, Codable, Sendable {
    case rectangle = "Rectangle"
    case ellipse = "Ellipse"
    case line = "Line"
    /// The shape filling `rect`. A rectangle's corners round by `cornerRadius`, at most half its shorter
    /// side (so a large radius makes a pill); ellipses ignore it. A line runs corner to corner and is stroked,
    /// not filled (see `linePath`).
    func path(in rect: CGRect, cornerRadius: CGFloat = 0, smoothing: Bool = false) -> CGPath {
        if self == .ellipse { return CGPath(ellipseIn: rect, transform: nil) }
        let radius = min(max(0, cornerRadius), rect.width / 2, rect.height / 2)
        guard radius > 0 else { return CGPath(rect: rect, transform: nil) }
        if self == .rectangle, smoothing {
            return smoothedRectangle(in: rect, radius: radius)
        }
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// Figma's cubic–arc–cubic corner construction at 60% smoothing (the iOS squircle match).
    /// https://www.figma.com/blog/desperately-seeking-squircles/
    /// Back off smoothing when the corners run out of room, keeping the requested radius.
    private func smoothedRectangle(in rect: CGRect, radius: CGFloat) -> CGPath {
        let smoothing = min(CGFloat(0.6), max(0, min(rect.width, rect.height) / (2 * radius) - 1))
        guard smoothing > 0 else {
            return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        let reach = (1 + smoothing) * radius
        let angle = smoothing * .pi / 4
        let tangent = radius * tan(angle / 2)
        let c = tangent * cos(angle)
        let d = tangent * sin(angle)
        let arcLength = radius * sqrt(2) * sin((1 - smoothing) * .pi / 4)
        let b = (reach - arcLength - c - d) / 3
        let a = 2 * b
        let path = CGMutablePath()
        let corners = [CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY),
                       CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.minY)]
        for (index, corner) in corners.enumerated() {
            let rotation = CGFloat(index) * .pi / 2
            let transform = CGAffineTransform(translationX: corner.x, y: corner.y).rotated(by: rotation)
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y).applying(transform) }
            let start = point(-reach, 0)
            if index == 0 { path.move(to: start) } else { path.addLine(to: start) }
            path.addCurve(to: point(-reach + a + b + c, d),
                          control1: point(-reach + a, 0), control2: point(-reach + a + b, 0))
            path.addArc(center: CGPoint(x: -radius, y: radius), radius: radius,
                        startAngle: -.pi / 2 + angle, endAngle: -angle, clockwise: false, transform: transform)
            path.addCurve(to: point(0, reach), control1: point(0, reach - a - b), control2: point(0, reach - a))
        }
        path.closeSubpath()
        return path
    }
}

/// How a Line shape's stroke is broken up.
nonisolated enum ShapeLineStyle: String, CaseIterable, Codable, Sendable {
    case solid = "Solid"
    case dotted = "Dotted"
    case dashed = "Dashed"
    case longDash = "Long Dash"

    /// Alternating dash and gap lengths, in multiples of the line's width, as they look with their caps on: a dot
    /// is exactly as long as the line is wide. Empty for a solid line.
    var pattern: [CGFloat] {
        switch self {
        case .solid: []
        case .dashed: [3, 2]
        case .longDash: [7, 2]
        case .dotted: [1, 1]
        }
    }

    /// `pattern` for Core Graphics at `width`, with round caps (see `strokeShapeLine`). Caps add half the width to each end of every dash, so
    /// the dashes are drawn that much shorter and the gaps that much longer; a dot is a dash of (almost) no length,
    /// kept just long enough to have a direction.
    func dashes(width: CGFloat) -> [CGFloat] {
        pattern.enumerated().map { index, length in
            index % 2 == 0 ? max(0.001, (length - 1) * width) : (length + 1) * width
        }
    }
}

/// How the ends of a Line shape, and of each of its dashes, are finished.
nonisolated enum ShapeLineCap: String, CaseIterable, Codable, Sendable {
    case square = "Square"
    case round = "Round"
    var cgLineCap: CGLineCap { self == .round ? .round : .square }

    /// How far past its two points a line of `width` reaches along each axis. A round cap reaches half the width
    /// every way; a square one's corners reach further when the line runs at an angle. The extra is in whole pixels,
    /// so the layer's pixels hold all of the corners and the line sits on the pixel grid as a round-capped one does:
    /// a 1-pixel line stays one crisp row rather than two half-strength ones.
    func reach(from start: CGPoint, to end: CGPoint, width: CGFloat) -> CGFloat {
        let length = hypot(end.x - start.x, end.y - start.y)
        guard self == .square, length > 0 else { return width / 2 }
        let corner = width / 2 * (abs(end.x - start.x) + abs(end.y - start.y)) / length
        return width / 2 + (corner - width / 2 - 0.0001).rounded(.up)
    }
}

extension CGContext {
    /// Strokes a Line shape from `start` to `end`, in the current stroke and fill color. Its dashes are laid out here
    /// rather than by Core Graphics, whose caps on a dot (a dash of almost no length) cover only a quarter of it, so
    /// 1-pixel dots came out gray. A square cap is a flat-ended line reaching half the width past each end, cut into
    /// full-length dashes; with round caps each dash is its own stroke, and each dot a circle.
    nonisolated func strokeShapeLine(from start: CGPoint, to end: CGPoint, width: CGFloat, style: ShapeLineStyle, cap: ShapeLineCap) {
        setLineWidth(width)
        setLineDash(phase: 0, lengths: [])
        let length = hypot(end.x - start.x, end.y - start.y)
        let direction = length > 0 ? CGPoint(x: (end.x - start.x) / length, y: (end.y - start.y) / length) : CGPoint(x: 1, y: 0)
        // A point `distance` along the line, measured from where its first cap begins, half the width before `start`.
        func along(_ distance: CGFloat) -> CGPoint {
            CGPoint(x: start.x + direction.x * (distance - width / 2), y: start.y + direction.y * (distance - width / 2))
        }
        let total = length + width
        if cap == .square {
            setLineCap(.butt)
            setLineDash(phase: 0, lengths: style.pattern.map { $0 * width })
            move(to: along(0))
            addLine(to: along(total))
            strokePath()
            return
        }
        setLineCap(.round)
        let pattern = style.pattern.map { $0 * width }
        guard !pattern.isEmpty else {
            if length > 0 { move(to: start); addLine(to: end); strokePath() }
            else { fillEllipse(in: CGRect(x: start.x - width / 2, y: start.y - width / 2, width: width, height: width)) }
            return
        }
        let dashes = CGMutablePath(), dots = CGMutablePath()
        var distance: CGFloat = 0, index = 0
        while distance < total {
            let next = min(total, distance + pattern[index % pattern.count])
            if index % 2 == 0 {
                // The dash's own line runs between its two caps' centers.
                let a = distance + width / 2, b = next - width / 2
                if b - a > 0.001 {
                    dashes.move(to: along(a))
                    dashes.addLine(to: along(b))
                } else {
                    let middle = along((distance + next) / 2)
                    dots.addEllipse(in: CGRect(x: middle.x - width / 2, y: middle.y - width / 2, width: width, height: width))
                }
            }
            distance = next
            index += 1
        }
        addPath(dashes)
        strokePath()
        addPath(dots)
        fillPath()
    }
}

/// What a shape layer draws, kept so the shape can be drawn again at a new size.
nonisolated struct LayerShapeStyle: Codable, Equatable, Sendable {
    var kind: ShapeKind
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    /// Document pixels, whatever size the shape is scaled to.
    var cornerRadius: CGFloat
    /// Nil in older projects means ordinary circular corners. True uses 60% smoothing.
    var smoothing: Bool? = nil
    /// A line's thickness, and its two ends as fractions of the layer's box (0–1), so the line lands on exactly the
    /// points it was dragged between and still redraws correctly at another size. Nil on other shapes.
    var lineWidth: CGFloat? = nil
    var start: CGPoint? = nil
    var end: CGPoint? = nil
    /// A line's dash pattern and caps (format version 15). A nil style is solid; a nil cap is round, as every line
    /// was before caps could be chosen, so those save as lines always have.
    var lineStyle: ShapeLineStyle? = nil
    var lineCap: ShapeLineCap? = nil
    /// A rectangle or ellipse's stroke, drawn inside its box (format version 22). Nil means no stroke, as every
    /// shape was before one could be set. Width is document pixels; the color is kept only while the width is above 0.
    var strokeWidth: CGFloat? = nil
    var strokeRed: CGFloat? = nil
    var strokeGreen: CGFloat? = nil
    var strokeBlue: CGFloat? = nil
    var color: PaletteColor { PaletteColor(red: red, green: green, blue: blue) }
    var strokeColor: PaletteColor? {
        guard let strokeRed, let strokeGreen, let strokeBlue else { return nil }
        return PaletteColor(red: strokeRed, green: strokeGreen, blue: strokeBlue)
    }

    /// Remembers a stroke, or forgets it when the width is 0. Lines have none: their thickness is `lineWidth`.
    mutating func setStroke(width: CGFloat, color: PaletteColor) {
        guard kind != .line, width.isFinite, width > 0, width <= 5000,
              color.red.isFinite, color.green.isFinite, color.blue.isFinite else {
            strokeWidth = nil
            strokeRed = nil
            strokeGreen = nil
            strokeBlue = nil
            return
        }
        strokeWidth = width
        strokeRed = min(1, max(0, color.red))
        strokeGreen = min(1, max(0, color.green))
        strokeBlue = min(1, max(0, color.blue))
    }
}

/// A layer made with the Shape tool. Its pixels are an ordinary raster, so it clips, masks, blends and filters like
/// any layer; `image` is the raster the shape drew. Once anything else changes those pixels (painting, a filter),
/// the layer's image is no longer this one and the layer is plain pixels from then on.
nonisolated struct LayerShape: Equatable, @unchecked Sendable {
    var style: LayerShapeStyle
    let image: CGImage
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.style == rhs.style && lhs.image === rhs.image }
    static func loaded(_ style: LayerShapeStyle?, image: CGImage?) -> LayerShape? {
        guard let style, let image else { return nil }
        return LayerShape(style: style, image: image)
    }
}

extension ImageLayer {
    /// The shape this layer still is: nil once its pixels were edited some other way.
    var liveShape: LayerShape? {
        guard let shape, let image = asset?.image, image === shape.image else { return nil }
        return shape
    }
}

/// A shape being dragged out with the Shape tool, in whole document pixels.
struct ShapeDraft: Equatable {
    let kind: ShapeKind
    let anchor: CGPoint
    var rect: CGRect
    /// Where a line is being dragged to, so its ends stay exactly where they were put.
    var end: CGPoint? = nil
    /// Document pixels, fixed when the drag starts; rectangles only.
    var cornerRadius: CGFloat = 0
    var smoothing = false
    /// A line's dashes and caps, fixed when the drag starts.
    var lineStyle = ShapeLineStyle.solid
    var lineCap = ShapeLineCap.square
    /// The fill, a line's thickness, and a rectangle or ellipse's inside stroke, fixed when the drag starts.
    var fill = PaletteColor.black
    var lineWidth: CGFloat = 4
    var strokeWidth: CGFloat = 0
    var strokeColor = PaletteColor.black
}

extension EditorSession {
    /// Pixels one shape layer may hold, the same budget as an import.
    nonisolated static let maxShapePixels = DocumentLimits.maxSurfacePixels

    func beginShape(at point: CGPoint) {
        guard tool == .shape, canEditLayers, point.x.isFinite, point.y.isFinite else { return }
        let anchor = CGPoint(x: point.x.rounded(), y: point.y.rounded())
        // A line uses the Line bar: the selected line's width when one is being edited, otherwise the width set for
        // the next line. A selected rectangle's settings must not shape the line.
        // Every new shape is the foreground color — or the fill last picked in the bar, until the foreground changes —
        // never the selected shape's fill: the swatches are for what's drawn next.
        let editing = shapeKind == .line ? nil : editingShapeLayer?.liveShape?.style
        let line = shapeKind == .line ? editingLineLayer?.liveShape?.style : nil
        let radius = editing?.kind == .rectangle ? editing?.cornerRadius : nil
        let smooth = editing?.kind == .rectangle ? editing?.smoothing == true : nil
        shapeDraft = ShapeDraft(kind: shapeKind, anchor: anchor, rect: CGRect(origin: anchor, size: .zero),
                                cornerRadius: shapeKind == .rectangle ? (radius ?? CGFloat(shapeCornerRadius)) : 0,
                                smoothing: shapeKind == .rectangle && (smooth ?? shapeSmoothing),
                                lineStyle: line.map { $0.lineStyle ?? .solid } ?? shapeLineStyle,
                                lineCap: line.map { $0.lineCap ?? .round } ?? shapeLineCap,
                                fill: nextShapeFill,
                                lineWidth: line?.lineWidth ?? CGFloat(shapeLineWidth),
                                strokeWidth: shapeKind == .line ? 0 : (editing == nil ? CGFloat(shapeStrokeWidth) : (editing?.strokeWidth ?? 0)),
                                strokeColor: editing?.strokeColor ?? shapeStrokeColor)
    }

    /// The line being dragged, from where it began to where the pointer is, in document pixels.
    var shapeLineEnds: (start: CGPoint, end: CGPoint)? {
        guard let draft = shapeDraft, draft.kind == .line, let end = draft.end else { return nil }
        let shift = Self.lineGridShift(width: draft.lineWidth)
        return (CGPoint(x: draft.anchor.x + shift, y: draft.anchor.y + shift), CGPoint(x: end.x + shift, y: end.y + shift))
    }

    /// How far a line of `width` is nudged off the whole-pixel points it's dragged between, so its edges land on
    /// pixel edges: half a pixel for an odd width, putting a 1-pixel line in the middle of one row rather than
    /// across two at half strength; nothing for an even one.
    nonisolated static func lineGridShift(width: CGFloat) -> CGFloat {
        let half = width / 2
        return half - half.rounded(.down)
    }

    /// Shift makes a square or circle; Option grows the shape from its center, as in Photoshop.
    func dragShape(to point: CGPoint, square: Bool, fromCenter: Bool) {
        guard var draft = shapeDraft, point.x.isFinite, point.y.isFinite else { return }
        // Shift on a line snaps its angle to eighths of a turn — flat, upright, or 45° — rather than squaring a box.
        if draft.kind == .line, square {
            let dx = point.x - draft.anchor.x, dy = point.y - draft.anchor.y
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let length = hypot(dx, dy)
            // Whole pixels, like the anchor; a 45° line rounds both ways alike, so it stays at 45°.
            let snapped = CGPoint(x: (draft.anchor.x + cos(angle) * length).rounded(), y: (draft.anchor.y + sin(angle) * length).rounded())
            draft.end = snapped
            draft.rect = DragBox.rect(from: draft.anchor, to: snapped, square: false, fromCenter: fromCenter)
            shapeDraft = draft
            return
        }
        if draft.kind == .line { draft.end = CGPoint(x: point.x.rounded(), y: point.y.rounded()) }
        draft.rect = DragBox.rect(from: draft.anchor, to: point, square: square, fromCenter: fromCenter)
        shapeDraft = draft
    }

    /// What's being dragged out, for the label beside the pointer: a Marquee's, a shape's or a resized layer's width and
    /// height, or a line's length, with the point being dragged, in document pixels. Nil between drags.
    var dragOutSize: (text: String, corner: CGPoint)? {
        if let resizeSize, transformEdit != nil { return resizeSize }
        func farthest(_ points: [CGPoint], from anchor: CGPoint) -> CGPoint? {
            points.max { hypot($0.x - anchor.x, $0.y - anchor.y) < hypot($1.x - anchor.x, $1.y - anchor.y) }
        }
        if let draft = shapeDraft {
            if draft.kind == .line {
                guard let end = draft.end else { return nil }
                return ("\(Int(hypot(end.x - draft.anchor.x, end.y - draft.anchor.y).rounded())) px", end)
            }
            let rect = draft.rect
            let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                           CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
            guard let corner = farthest(corners, from: draft.anchor) else { return nil }
            return ("\(Int(rect.width.rounded())) × \(Int(rect.height.rounded())) px", corner)
        }
        if let draft = lassoDraft, let anchor = draft.anchor, draft.points.count == 4, let size = selectionSize,
           let corner = farthest(draft.points, from: anchor) {
            return ("\(size.width) × \(size.height) px", corner)
        }
        return nil
    }

    func cancelShape() {
        if shapeDraft != nil { shapeDraft = nil }
    }

    /// The Shape tool opens on the kind of the live shape that is selected, so a line is not edited as a rectangle.
    func adoptShapeKindFromSelection() {
        guard selectedLayerIDs.count <= 1, let kind = activeLayer?.liveShape?.style.kind else { return }
        if shapeKind != kind { cancelShape() }
        shapeKind = kind
    }

    /// Shift-U (and Tab): the Shape tool steps through Rectangle, Ellipse and Line.
    func toggleShapeKind() {
        cancelShape()
        let kinds = ShapeKind.allCases
        shapeKind = kinds[((kinds.firstIndex(of: shapeKind) ?? 0) + 1) % kinds.count]
    }

    /// Fills the dragged shape on a new layer above the active one, in one undo step. The fill and stroke are the
    /// ones the bar is showing. A click without a drag makes nothing; the selection is left alone.
    func finishShape() {
        guard let draft = shapeDraft else { return }
        shapeDraft = nil
        var rect = draft.rect
        let thickness = draft.kind == .line ? draft.lineWidth : CGFloat(shapeLineWidth)
        // A line keeps the two points it was dragged between; the layer is their box with room for the stroke's own
        // thickness (and its caps) around them.
        var ends: (start: CGPoint, end: CGPoint)?
        if draft.kind == .line {
            let shift = Self.lineGridShift(width: thickness), end = draft.end ?? draft.anchor
            let from = CGPoint(x: draft.anchor.x + shift, y: draft.anchor.y + shift), to = CGPoint(x: end.x + shift, y: end.y + shift)
            let reach = draft.lineCap.reach(from: from, to: to, width: thickness)
            rect = CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
                          width: abs(to.x - from.x), height: abs(to.y - from.y)).insetBy(dx: -reach, dy: -reach)
            ends = (from, to)
        }
        guard canEditLayers, document != nil, rect.width >= 1, rect.height >= 1 else { return }
        guard Int(rect.width) * Int(rect.height) <= Self.maxShapePixels else {
            brushError = "That shape is too large. A shape can cover up to \(DocumentLimits.maxSurfaceMegapixels) megapixels."
            return
        }
        do {
            // The ends as fractions of the box, so a scaled line still runs between the same two places.
            func unit(_ point: CGPoint) -> CGPoint {
                CGPoint(x: rect.width > 0 ? (point.x - rect.minX) / rect.width : 0.5,
                        y: rect.height > 0 ? (point.y - rect.minY) / rect.height : 0.5)
            }
            let start = ends.map { unit($0.start) }, finish = ends.map { unit($0.end) }
            let line = draft.kind == .line
            var style = LayerShapeStyle(kind: draft.kind, red: draft.fill.red, green: draft.fill.green,
                                        blue: draft.fill.blue, cornerRadius: draft.cornerRadius, smoothing: draft.smoothing ? true : nil,
                                        lineWidth: line ? thickness : nil, start: start, end: finish,
                                        lineStyle: line && draft.lineStyle != .solid ? draft.lineStyle : nil,
                                        lineCap: line && draft.lineCap != .round ? draft.lineCap : nil)
            if !line { style.setStroke(width: draft.strokeWidth, color: draft.strokeColor) }
            let image = try Self.shapeImage(style, size: rect.size)
            addPixelLayer(image, at: rect.origin, name: nextShapeName(draft.kind), editName: draft.kind.rawValue,
                          dropsSelection: false, shape: LayerShape(style: style, image: image))
        } catch { brushError = error.localizedDescription }
    }

    /// "Rectangle 1", "Ellipse 2", … skipping names already in the document.
    func nextShapeName(_ kind: ShapeKind) -> String {
        let names = Set(document?.layers.map(\.name) ?? [])
        var number = 1
        while names.contains("\(kind.rawValue) \(number)") { number += 1 }
        return "\(kind.rawValue) \(number)"
    }

    /// A shape layer scaled to a new size draws its shape again at that size, so a rounded corner keeps its radius
    /// instead of stretching. A line doesn't: it stretches as it looked while being scaled, thicker when made taller,
    /// and is plain pixels from then on. Part of the edit that changed the size.
    func redrawShape(at index: Int) {
        guard let layer = document?.layers[index], let shape = layer.liveShape, let asset = layer.asset else { return }
        let width = max(1, Int(layer.transform.size.width.rounded())), height = max(1, Int(layer.transform.size.height.rounded()))
        guard width != asset.image.width || height != asset.image.height else { return }
        if shape.style.kind == .line { document?.layers[index].shape = nil; return }
        guard width * height <= Self.maxShapePixels,
              let image = try? Self.shapeImage(shape.style, size: CGSize(width: width, height: height)),
              let thumbnail = try? PixelInvert.thumbnail(of: image) else { return }
        // A mask that follows the layer's pixel grid stays exactly where it is while that grid changes size.
        if let mask = layer.mask, mask.placement == nil { document?.layers[index].mask?.placement = layer.maskTransform }
        document?.layers[index].asset = ImportedImage(image: image, thumbnail: thumbnail, name: asset.name)
        document?.layers[index].shape = LayerShape(style: shape.style, image: image)
    }

    /// While a rounded or stroked shape is being scaled, the shape drawn at the size it's being dragged to, so its
    /// corners and its inside stroke keep their document-pixel size during the drag rather than only once it's applied.
    /// At most 2048 pixels across (the radius and stroke scale down with it); nil for any other layer, which just
    /// stretches until the redraw at commit.
    func shapeTransformPreview(for layer: ImageLayer, transform: LayerTransform) -> CGImage? {
        if transformEdit == nil {
            if !shapeTransformPreviewCache.isEmpty { shapeTransformPreviewCache = [:] }
            return nil
        }
        // A plain fill stretches the same as a redraw. A radius or an inside stroke does not: both stay in document
        // pixels, so the drag shows the shape drawn again rather than a stretched picture of it.
        guard let shape = layer.liveShape, shape.style.kind != .line,
              shape.style.cornerRadius > 0 || (shape.style.strokeWidth ?? 0) > 0 else { return nil }
        let size = transform.size
        guard size.width >= 1, size.height >= 1,
              abs(size.width - CGFloat(shape.image.width)) >= 0.5 || abs(size.height - CGFloat(shape.image.height)) >= 0.5 else { return nil }
        let factor = min(1, 2048 / max(size.width, size.height))
        let drawn = CGSize(width: max(1, (size.width * factor).rounded()), height: max(1, (size.height * factor).rounded()))
        if let cached = shapeTransformPreviewCache[layer.id], cached.size == drawn { return cached.image }
        var style = shape.style
        style.cornerRadius *= factor
        if let width = style.strokeWidth { style.strokeWidth = width * factor }
        guard let image = try? Self.shapeImage(style, size: drawn) else { return nil }
        shapeTransformPreviewCache[layer.id] = (drawn, image)
        return image
    }

    /// The shape filling its box, anti-aliased where it curves. A rectangle or ellipse's stroke is drawn inside that
    /// box: the path is filled, then stroked at twice the width and clipped to the path, so the outer edge stays put
    /// and the fill gives way. The width is capped at half the shorter side, so it meets in the middle and no further.
    nonisolated static func shapeImage(_ kind: ShapeKind, size: CGSize, color: PaletteColor, cornerRadius: CGFloat = 0, smoothing: Bool = false,
                           lineWidth: CGFloat = 0, start: CGPoint? = nil, end: CGPoint? = nil,
                           lineStyle: ShapeLineStyle = .solid, lineCap: ShapeLineCap = .round,
                           strokeWidth: CGFloat = 0, strokeColor: PaletteColor? = nil) throws -> CGImage {
        let context = try BrushRaster.context(width: Int(size.width), height: Int(size.height), mask: false)
        let bounds = CGRect(origin: .zero, size: size)
        if kind == .line {
            // Corner to corner, inset by half the thickness so the stroke stays inside the layer.
            let thickness = max(1, lineWidth)
            context.setStrokeColor(CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1))
            // The ends sit where they were dragged, as fractions of the box. Older lines (no ends stored) ran corner
            // to corner, inset by half their thickness.
            let inset = bounds.insetBy(dx: min(thickness, size.width) / 2, dy: min(thickness, size.height) / 2)
            let from = start.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) } ?? CGPoint(x: inset.minX, y: inset.minY)
            let to = end.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) } ?? CGPoint(x: inset.maxX, y: inset.maxY)
            context.strokeShapeLine(from: from, to: to, width: thickness, style: lineStyle, cap: lineCap)
            guard let image = context.makeImage() else { throw ExportError.render }
            return image
        }
        let path = kind.path(in: bounds, cornerRadius: cornerRadius, smoothing: smoothing)
        fillShape(path, color: CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1),
                  stroke: strokeColor.map { CGColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 1) },
                  strokeWidth: min(strokeWidth, min(size.width, size.height) / 2), in: context)
        guard let image = context.makeImage() else { throw ExportError.render }
        return image
    }

    /// Fills `path`, with an inside stroke `strokeWidth` wide when there is one: the whole shape in the stroke color,
    /// then what lies inside the stroke in the fill color. Each edge pixel is drawn once, so the anti-aliased rim is
    /// the stroke alone. Filling first and stroking over it, clipped to the shape, drew those pixels twice: a faint
    /// ring of the fill and a heavier edge.
    nonisolated static func fillShape(_ path: CGPath, color: CGColor, stroke: CGColor?, strokeWidth: CGFloat, in context: CGContext) {
        guard strokeWidth > 0, let stroke else {
            context.setFillColor(color)
            context.addPath(path)
            context.fillPath()
            return
        }
        context.setFillColor(stroke)
        context.addPath(path)
        context.fillPath()
        // Inside the stroke: the shape less a band twice the width centered on its edge, half of which falls outside.
        let band = path.copy(strokingWithWidth: strokeWidth * 2, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
        let inside = path.subtracting(band)
        guard !inside.isEmpty else { return }
        context.setFillColor(color)
        context.addPath(inside)
        context.fillPath()
    }

    /// `style` drawn into a box of `size`.
    nonisolated static func shapeImage(_ style: LayerShapeStyle, size: CGSize) throws -> CGImage {
        try shapeImage(style.kind, size: size, color: style.color, cornerRadius: style.cornerRadius,
                       smoothing: style.smoothing == true, lineWidth: style.lineWidth ?? 0,
                       start: style.start, end: style.end, lineStyle: style.lineStyle ?? .solid,
                       lineCap: style.lineCap ?? .round,
                       strokeWidth: style.kind == .line ? 0 : (style.strokeWidth ?? 0), strokeColor: style.strokeColor)
    }

    /// The rectangle or ellipse the Shape bar edits: the only selected layer, still the shape it was drawn as.
    var editingShapeLayer: ImageLayer? {
        guard tool == .shape, !isMaskSelected, selectedLayerIDs.count <= 1, let layer = activeLayer,
              let shape = layer.liveShape, shape.style.kind != .line else { return nil }
        return layer
    }

    /// The line the Shape bar edits. Its color, width, dashes and caps redraw that line.
    var editingLineLayer: ImageLayer? {
        guard tool == .shape, !isMaskSelected, selectedLayerIDs.count <= 1, let layer = activeLayer,
              let shape = layer.liveShape, shape.style.kind == .line else { return nil }
        return layer
    }

    /// The next shape's color: the fill last picked in the Shape bar until the foreground changes, otherwise the
    /// foreground.
    var nextShapeFill: PaletteColor {
        shapeFillChoice.flatMap { $0.foreground == foregroundColor ? $0.fill : nil } ?? foregroundColor
    }

    /// What the Fill swatch shows: the color the next shape will be, not the selected shape's, so a new foreground
    /// shows there at once. Picking from it recolors the selected shape too.
    var displayedShapeFill: PaletteColor {
        if let picker = colorPicker, case .shapeFill = picker.target { return picker.color }
        if let draft = shapeDraft, draft.kind == .line { return draft.fill }
        return nextShapeFill
    }

    /// What the Stroke swatch shows. A selected shape's stroke, or the color the next stroke will use.
    var displayedShapeStroke: PaletteColor {
        if let picker = colorPicker, case .shapeStroke = picker.target { return picker.color }
        return editingShapeLayer?.liveShape?.style.strokeColor ?? shapeStrokeColor
    }

    var displayedStrokeWidth: Double {
        if let width = editingShapeLayer?.liveShape?.style.strokeWidth { return Double(width) }
        return editingShapeLayer == nil ? shapeStrokeWidth : 0
    }

    var displayedCornerRadius: Double {
        if let shape = editingShapeLayer?.liveShape, shape.style.kind == .rectangle {
            return Double(shape.style.cornerRadius)
        }
        return shapeCornerRadius
    }

    var displayedLineWidth: Double {
        if let draft = shapeDraft, draft.kind == .line { return Double(draft.lineWidth) }
        if let width = editingLineLayer?.liveShape?.style.lineWidth { return Double(width) }
        return shapeLineWidth
    }
    var displayedLineStyle: ShapeLineStyle {
        editingLineLayer?.liveShape?.style.lineStyle ?? (editingLineLayer == nil ? shapeLineStyle : .solid)
    }
    var displayedLineCap: ShapeLineCap {
        editingLineLayer?.liveShape?.style.lineCap ?? (editingLineLayer == nil ? shapeLineCap : .round)
    }

    var displayedShapeSmoothing: Bool {
        if let shape = editingShapeLayer?.liveShape, shape.style.kind == .rectangle {
            return shape.style.smoothing == true
        }
        return shapeSmoothing
    }

    func beginShapeStyleEdit() {
        guard shapeStyleEditLayerID == nil, let layer = editingShapeLayer ?? editingLineLayer, canEditLayers else { return }
        if shapeColorPickerIsOpen { closeColorPicker(commit: true) }
        finishOpacityEdit()
        beginEdit("Shape Style")
        shapeStyleEditLayerID = layer.id
    }

    func finishShapeStyleEdit() {
        guard shapeStyleEditLayerID != nil else { return }
        shapeStyleEditLayerID = nil
        endEdit()
    }

    func setDisplayedStrokeWidth(_ width: Double) {
        let width = width.isFinite ? min(5000, max(0, width)) : 0
        guard editingShapeLayer != nil else { shapeStrokeWidth = width; return }
        changeLiveShape { style in
            style.setStroke(width: CGFloat(width), color: style.strokeColor ?? shapeStrokeColor)
        }
    }

    func setDisplayedCornerRadius(_ radius: Double) {
        let radius = radius.isFinite ? min(5000, max(0, radius)) : 0
        guard editingShapeLayer?.liveShape?.style.kind == .rectangle else { shapeCornerRadius = radius; return }
        changeLiveShape { $0.cornerRadius = CGFloat(radius) }
    }

    func setDisplayedLineWidth(_ width: Double) {
        let width = width.isFinite ? min(5000, max(1, width)) : 4
        if var draft = shapeDraft, draft.kind == .line {
            draft.lineWidth = CGFloat(width)
            shapeDraft = draft
            shapeLineWidth = width
            return
        }
        guard editingLineLayer != nil else { shapeLineWidth = width; return }
        changeLiveLine { style, transform in
            relayoutLine(&style, transform: &transform, width: CGFloat(width))
        }
    }

    func setDisplayedLineStyle(_ style: ShapeLineStyle) {
        guard editingLineLayer != nil else { shapeLineStyle = style; return }
        changeLiveLine { line, _ in
            line.lineStyle = style == .solid ? nil : style
        }
    }

    func setDisplayedLineCap(_ cap: ShapeLineCap) {
        guard editingLineLayer != nil else { shapeLineCap = cap; return }
        changeLiveLine { style, transform in
            style.lineCap = cap == .round ? nil : cap
            relayoutLine(&style, transform: &transform, width: style.lineWidth ?? CGFloat(shapeLineWidth))
        }
    }
    func setDisplayedShapeSmoothing(_ on: Bool) {
        guard editingShapeLayer?.liveShape?.style.kind == .rectangle else { shapeSmoothing = on; return }
        changeLiveShape { $0.smoothing = on ? true : nil }
    }

    func openShapeFillPicker() {
        guard canEditPalette, colorPicker == nil, tool == .shape else { return }
        // The line under the pointer is the one being created: its color is the foreground, not a shape already selected.
        if shapeDraft?.kind == .line {
            openColorPicker(background: false)
            return
        }
        if let layer = editingLineLayer, let shape = layer.liveShape {
            colorPicker = ColorPickerState(target: .shapeFill(layerID: layer.id), original: shape.style.color)
        } else if shapeKind != .line, let layer = editingShapeLayer, let shape = layer.liveShape {
            colorPicker = ColorPickerState(target: .shapeFill(layerID: layer.id), original: shape.style.color)
        } else if !isMaskSelected {
            // Nothing to recolor: it sets the foreground, starting from the color the swatch shows.
            colorPicker = ColorPickerState(background: false, original: nextShapeFill)
        }
    }

    func openShapeStrokePicker() {
        guard canEditPalette, colorPicker == nil, tool == .shape else { return }
        let style = editingShapeLayer?.liveShape?.style
        let bound = (style?.strokeWidth ?? 0) > 0
        colorPicker = ColorPickerState(target: .shapeStroke(layerID: bound ? editingShapeLayer?.id : nil),
                                       original: bound ? (style?.strokeColor ?? shapeStrokeColor) : shapeStrokeColor)
    }

    /// The canvas follows the picker's working color. The layer itself is unchanged until OK, so a save keeps the
    /// committed fill.
    func previewShapeColor() {
        guard let picker = colorPicker else { return }
        let layerID: UUID
        let fill: Bool
        switch picker.target {
        case .shapeFill(let id): layerID = id; fill = true
        case .shapeStroke(let id?): layerID = id; fill = false
        default: return
        }
        guard let layer = document?.layers.first(where: { $0.id == layerID }),
              let shape = layer.liveShape, let asset = layer.asset else { return }
        if !fill, shape.style.kind == .line { return }
        var style = shape.style
        if fill {
            style.red = picker.color.red
            style.green = picker.color.green
            style.blue = picker.color.blue
        } else if (style.strokeWidth ?? 0) > 0 {
            style.setStroke(width: style.strokeWidth ?? 0, color: picker.color)
        } else {
            shapeColorPreview = nil
            refreshCanvasPreview?()
            return
        }
        let size = CGSize(width: asset.image.width, height: asset.image.height)
        guard let image = try? Self.shapeImage(style, size: size) else { return }
        shapeColorPreview = (layerID, image)
        refreshCanvasPreview?()
    }

    /// OK records one edit from the shape as it was when the picker opened. Cancel drops the preview and records nothing.
    func finishShapeColorPick(commit: Bool) {
        let picker = colorPicker
        shapeColorPreview = nil
        guard commit, let picker else { refreshCanvasPreview?(); return }
        switch picker.target {
        case .shapeStroke(nil):
            shapeStrokeColor = picker.color
        case .shapeFill(let layerID):
            applyShapeColor(picker.color, fill: true, layerID: layerID)
            shapeFillChoice = (picker.color, foregroundColor)
        case .shapeStroke(let layerID?):
            applyShapeColor(picker.color, fill: false, layerID: layerID)
        default:
            break
        }
        refreshCanvasPreview?()
    }

    /// Drops the preview and closes the picker. The layer was never changed, so there is nothing to undo.
    func cancelShapeColorPreview() {
        guard shapeColorPreview != nil || shapeColorPickerIsOpen else { return }
        shapeColorPreview = nil
        if shapeColorPickerIsOpen { colorPicker = nil }
        refreshCanvasPreview?()
    }

    /// Paints a live shape's fill, keeping its stroke and the fact that it is still a shape. False when it isn't a
    /// live shape or it couldn't be redrawn, so the caller fills the pixels as usual.
    @discardableResult
    func recolorShape(_ id: UUID, to color: PaletteColor) -> Bool {
        if shapeColorPreview != nil { cancelShapeColorPreview() }
        guard canEditLayers, let index = document?.layers.firstIndex(where: { $0.id == id }),
              let layer = document?.layers[index], let shape = layer.liveShape, let asset = layer.asset else { return false }
        var style = shape.style
        guard style.red != color.red || style.green != color.green || style.blue != color.blue else { return true }
        style.red = color.red
        style.green = color.green
        style.blue = color.blue
        guard let image = try? Self.shapeImage(style, size: CGSize(width: asset.image.width, height: asset.image.height)),
              let thumbnail = try? PixelInvert.thumbnail(of: image) else { return false }
        finishShapeStyleEdit()
        finishOpacityEdit()
        beginEdit("Fill")
        document?.layers[index].asset = ImportedImage(image: image, thumbnail: thumbnail, name: asset.name)
        document?.layers[index].shape = LayerShape(style: style, image: image)
        endEdit()
        return true
    }

    private var shapeColorPickerIsOpen: Bool {
        switch colorPicker?.target {
        case .shapeFill, .shapeStroke: true
        default: false
        }
    }

    private func changeLiveShape(_ change: (inout LayerShapeStyle) -> Void) {
        if shapeStyleEditLayerID == nil, shapeColorPickerIsOpen { closeColorPicker(commit: true) }
        guard canEditLayers, let layer = editingShapeLayer, var style = layer.liveShape?.style,
              let index = document?.layers.firstIndex(where: { $0.id == layer.id }),
              let asset = layer.asset else { return }
        let before = style
        change(&style)
        guard style != before else { return }
        let open = shapeStyleEditLayerID != nil
        if !open { finishOpacityEdit(); beginEdit("Shape Style") }
        if !paintShape(at: index, style: style, asset: asset), !open {
            endEdit()
            return
        }
        if !open { endEdit() }
    }

    private func applyShapeColor(_ color: PaletteColor, fill: Bool, layerID: UUID) {
        guard let index = document?.layers.firstIndex(where: { $0.id == layerID }),
              let layer = document?.layers[index], let shape = layer.liveShape, let asset = layer.asset else { return }
        if !fill, shape.style.kind == .line { return }
        var style = shape.style
        if fill {
            guard style.red != color.red || style.green != color.green || style.blue != color.blue else { return }
            style.red = color.red
            style.green = color.green
            style.blue = color.blue
        } else {
            guard (style.strokeWidth ?? 0) > 0 else { return }
            let before = style.strokeColor
            style.setStroke(width: style.strokeWidth ?? 0, color: color)
            guard style.strokeColor != before else { return }
        }
        finishShapeStyleEdit()
        finishOpacityEdit()
        beginEdit("Shape Style")
        _ = paintShape(at: index, style: style, asset: asset)
        endEdit()
    }

    @discardableResult
    private func paintShape(at index: Int, style: LayerShapeStyle, asset: ImportedImage) -> Bool {
        let size = CGSize(width: asset.image.width, height: asset.image.height)
        guard let image = try? Self.shapeImage(style, size: size),
              let thumbnail = try? PixelInvert.thumbnail(of: image) else { return false }
        document?.layers[index].asset = ImportedImage(image: image, thumbnail: thumbnail, name: asset.name)
        document?.layers[index].shape = LayerShape(style: style, image: image)
        return true
    }

    /// Redraws the selected line. A new width or cap grows the layer around the same two points, so the stroke still fits.
    private func changeLiveLine(_ change: (inout LayerShapeStyle, inout LayerTransform) -> Void) {
        if shapeStyleEditLayerID == nil, shapeColorPickerIsOpen { closeColorPicker(commit: true) }
        guard canEditLayers, let layer = editingLineLayer, var style = layer.liveShape?.style,
              let index = document?.layers.firstIndex(where: { $0.id == layer.id }) else { return }
        var transform = layer.transform
        let beforeStyle = style, beforeTransform = transform
        change(&style, &transform)
        guard style != beforeStyle || transform != beforeTransform, transform.isValid,
              Int(transform.size.width) * Int(transform.size.height) <= Self.maxShapePixels else { return }
        let open = shapeStyleEditLayerID != nil
        if !open { finishOpacityEdit(); beginEdit("Shape Style") }
        guard let image = try? Self.shapeImage(style, size: transform.size),
              let thumbnail = try? PixelInvert.thumbnail(of: image) else {
            if !open { endEdit() }
            return
        }
        if layer.asset.map({ $0.image.width != image.width || $0.image.height != image.height }) == true,
           let mask = layer.mask, mask.placement == nil {
            document?.layers[index].mask?.placement = layer.maskTransform
        }
        document?.layers[index].transform = transform
        document?.layers[index].asset = ImportedImage(image: image, thumbnail: thumbnail, name: layer.asset?.name ?? layer.name)
        document?.layers[index].shape = LayerShape(style: style, image: image)
        if !open { endEdit() }
    }

    /// Puts `width` on the line and rebuilds its box around the same two points. Older lines, with no ends stored, ran
    /// corner to corner inset by half their thickness.
    private func relayoutLine(_ style: inout LayerShapeStyle, transform: inout LayerTransform, width: CGFloat) {
        let width = min(5000, max(1, width))
        let oldWidth = style.lineWidth ?? width
        let oldShift = Self.lineGridShift(width: oldWidth)
        let newShift = Self.lineGridShift(width: width)
        func placed(_ unit: CGPoint) -> CGPoint {
            CGPoint(x: transform.origin.x + unit.x * transform.size.width,
                    y: transform.origin.y + unit.y * transform.size.height)
        }
        let from: CGPoint
        let to: CGPoint
        if let start = style.start, let end = style.end {
            let nudge = newShift - oldShift
            from = CGPoint(x: placed(start).x + nudge, y: placed(start).y + nudge)
            to = CGPoint(x: placed(end).x + nudge, y: placed(end).y + nudge)
        } else {
            let reach = oldWidth / 2
            let box = CGRect(origin: transform.origin, size: transform.size).insetBy(dx: reach, dy: reach)
            from = CGPoint(x: box.minX + newShift, y: box.minY + newShift)
            to = CGPoint(x: box.maxX + newShift, y: box.maxY + newShift)
        }
        let cap = style.lineCap ?? .round
        let reach = cap.reach(from: from, to: to, width: width)
        var rect = CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
                          width: abs(to.x - from.x), height: abs(to.y - from.y)).insetBy(dx: -reach, dy: -reach)
        if rect.width < 1 { rect.size.width = 1 }
        if rect.height < 1 { rect.size.height = 1 }
        func unit(_ point: CGPoint) -> CGPoint {
            CGPoint(x: rect.width > 0 ? (point.x - rect.minX) / rect.width : 0.5,
                    y: rect.height > 0 ? (point.y - rect.minY) / rect.height : 0.5)
        }
        style.lineWidth = width
        style.start = unit(from)
        style.end = unit(to)
        transform.origin = rect.origin
        transform.size = rect.size
    }
}
