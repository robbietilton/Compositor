import CoreGraphics
import Foundation

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
    var color: PaletteColor { PaletteColor(red: red, green: green, blue: blue) }
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
}

extension EditorSession {
    /// Pixels one shape layer may hold, the same budget as an import.
    nonisolated static let maxShapePixels = DocumentLimits.maxSurfacePixels

    func beginShape(at point: CGPoint) {
        guard tool == .shape, canEditLayers, point.x.isFinite, point.y.isFinite else { return }
        let anchor = CGPoint(x: point.x.rounded(), y: point.y.rounded())
        shapeDraft = ShapeDraft(kind: shapeKind, anchor: anchor, rect: CGRect(origin: anchor, size: .zero),
                                cornerRadius: shapeKind == .rectangle ? CGFloat(shapeCornerRadius) : 0,
                                smoothing: shapeKind == .rectangle && shapeSmoothing,
                                lineStyle: shapeLineStyle, lineCap: shapeLineCap)
    }

    /// The line being dragged, from where it began to where the pointer is, in document pixels.
    var shapeLineEnds: (start: CGPoint, end: CGPoint)? {
        guard let draft = shapeDraft, draft.kind == .line, let end = draft.end else { return nil }
        let shift = Self.lineGridShift(width: CGFloat(shapeLineWidth))
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

    func cancelShape() {
        if shapeDraft != nil { shapeDraft = nil }
    }

    /// Shift-U (and Tab): the Shape tool steps through Rectangle, Ellipse and Line.
    func toggleShapeKind() {
        cancelShape()
        let kinds = ShapeKind.allCases
        shapeKind = kinds[((kinds.firstIndex(of: shapeKind) ?? 0) + 1) % kinds.count]
    }

    /// Fills the dragged shape with the foreground color on a new layer above the active one,
    /// in one undo step. A click without a drag makes nothing; the selection is left alone.
    func finishShape() {
        guard let draft = shapeDraft else { return }
        shapeDraft = nil
        var rect = draft.rect
        let thickness = CGFloat(shapeLineWidth)
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
            let image = try Self.shapeImage(draft.kind, size: rect.size, color: foregroundColor, cornerRadius: draft.cornerRadius, smoothing: draft.smoothing,
                                            lineWidth: thickness, start: start, end: finish,
                                            lineStyle: draft.lineStyle, lineCap: draft.lineCap)
            let line = draft.kind == .line
            let style = LayerShapeStyle(kind: draft.kind, red: foregroundColor.red, green: foregroundColor.green,
                                        blue: foregroundColor.blue, cornerRadius: draft.cornerRadius, smoothing: draft.smoothing ? true : nil,
                                        lineWidth: line ? thickness : nil, start: start, end: finish,
                                        lineStyle: line && draft.lineStyle != .solid ? draft.lineStyle : nil,
                                        lineCap: line && draft.lineCap != .round ? draft.lineCap : nil)
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
              let image = try? Self.shapeImage(shape.style.kind, size: CGSize(width: width, height: height),
                                               color: shape.style.color, cornerRadius: shape.style.cornerRadius, smoothing: shape.style.smoothing == true,
                                               lineWidth: shape.style.lineWidth ?? 0,
                                               start: shape.style.start, end: shape.style.end,
                                               lineStyle: shape.style.lineStyle ?? .solid, lineCap: shape.style.lineCap ?? .round),
              let thumbnail = try? PixelInvert.thumbnail(of: image) else { return }
        // A mask that follows the layer's pixel grid stays exactly where it is while that grid changes size.
        if let mask = layer.mask, mask.placement == nil { document?.layers[index].mask?.placement = layer.maskTransform }
        document?.layers[index].asset = ImportedImage(image: image, thumbnail: thumbnail, name: asset.name)
        document?.layers[index].shape = LayerShape(style: shape.style, image: image)
    }

    /// While a rounded rectangle is being scaled, the shape drawn at the size it's being dragged to, so its corners
    /// keep their radius during the drag rather than only once it's applied. At most 2048 pixels across (the radius
    /// scales down with it); nil for any other layer, which just stretches until the redraw at commit.
    func shapeTransformPreview(for layer: ImageLayer, transform: LayerTransform) -> CGImage? {
        guard transformEdit != nil, let shape = layer.liveShape, shape.style.kind == .rectangle, shape.style.cornerRadius > 0 else {
            if !shapeTransformPreviewCache.isEmpty, transformEdit == nil { shapeTransformPreviewCache = [:] }
            return nil
        }
        let size = transform.size
        guard size.width >= 1, size.height >= 1,
              abs(size.width - CGFloat(shape.image.width)) >= 0.5 || abs(size.height - CGFloat(shape.image.height)) >= 0.5 else { return nil }
        let factor = min(1, 2048 / max(size.width, size.height))
        let drawn = CGSize(width: max(1, (size.width * factor).rounded()), height: max(1, (size.height * factor).rounded()))
        if let cached = shapeTransformPreviewCache[layer.id], cached.size == drawn { return cached.image }
        guard let image = try? Self.shapeImage(.rectangle, size: drawn, color: shape.style.color,
                                               cornerRadius: shape.style.cornerRadius * factor, smoothing: shape.style.smoothing == true) else { return nil }
        shapeTransformPreviewCache[layer.id] = (drawn, image)
        return image
    }

    /// The shape filling its box, anti-aliased where it curves.
    nonisolated static func shapeImage(_ kind: ShapeKind, size: CGSize, color: PaletteColor, cornerRadius: CGFloat = 0, smoothing: Bool = false,
                           lineWidth: CGFloat = 0, start: CGPoint? = nil, end: CGPoint? = nil,
                           lineStyle: ShapeLineStyle = .solid, lineCap: ShapeLineCap = .round) throws -> CGImage {
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
        context.setFillColor(CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1))
        context.addPath(kind.path(in: bounds, cornerRadius: cornerRadius, smoothing: smoothing))
        context.fillPath()
        guard let image = context.makeImage() else { throw ExportError.render }
        return image
    }
}
