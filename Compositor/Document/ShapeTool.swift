import AppKit

nonisolated enum ShapeKind: String, CaseIterable, Codable, Sendable {
    case rectangle = "Rectangle"
    case ellipse = "Ellipse"
    case star = "Star"
    case polygon = "Polygon"
    case line = "Line"

    /// A star's points, from a triangle-like three to a near-circle of twenty.
    static let starPoints = 3...20
    /// A polygon's sides, from a triangle up.
    static let polygonSides = 3...20

    /// How far a star's inner corners sit from its center, as a fraction of its points' reach. Each inner corner
    /// lies on the straight line joining the two points either side of its neighbors, as in a drawn pentagram, so
    /// the edges line up across the star. With three or four points that line passes through the center or beyond
    /// it, so those keep the five-point star's depth instead.
    static func starIndent(points: Int) -> CGFloat {
        guard points >= 5 else { return starIndent(points: 5) }
        let step = CGFloat.pi / CGFloat(points)
        return cos(2 * step) / cos(step)
    }
    /// How far a star's inner corners may be pulled in toward its center, as a fraction of its points' reach.
    static let starInsets: ClosedRange<CGFloat> = 0.01...0.99
    /// The inset that keeps a star's sides even (see `starIndent`), which a new star uses until one is chosen.
    static func evenInset(points: Int) -> CGFloat { 1 - starIndent(points: points) }

    /// The shape filling `rect`. A rectangle's corners round by `cornerRadius`, at most half its shorter
    /// side (so a large radius makes a pill); ellipses ignore it. A star has `points` points and a polygon
    /// `points` sides, pointing straight up and stretched to touch every edge of `rect`; a star's inner corners are
    /// pulled in by `inset`, or by its even inset when that is nil. A line runs corner to corner and is stroked, not
    /// filled (see `shapeImage`).
    func path(in rect: CGRect, cornerRadius: CGFloat = 0, points: Int = 5, inset: CGFloat? = nil) -> CGPath {
        switch self {
        case .ellipse: return CGPath(ellipseIn: rect, transform: nil)
        case .star, .polygon: return Self.regularPath(in: rect, star: self == .star, count: points, inset: inset)
        case .rectangle, .line: break
        }
        let radius = min(max(0, cornerRadius), rect.width / 2, rect.height / 2)
        guard radius > 0 else { return CGPath(rect: rect, transform: nil) }
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// A regular polygon, or a star alternating between its points and its inner corners, with the first point at
    /// the top (y grows downward here, as it does in a layer's pixels and on the canvas). The corners are laid out
    /// on a unit circle, then their own bounding box is fitted to `rect`, so a pentagon's flat base sits on the
    /// bottom edge instead of floating above it.
    private static func regularPath(in rect: CGRect, star: Bool, count: Int, inset: CGFloat?) -> CGPath {
        let count = max(3, min(20, count))
        let corners = star ? count * 2 : count
        let indent = 1 - min(starInsets.upperBound, max(starInsets.lowerBound, inset ?? evenInset(points: count)))
        let unit = (0..<corners).map { index -> CGPoint in
            let angle = -CGFloat.pi / 2 + CGFloat(index) * 2 * .pi / CGFloat(corners)
            let reach = star && index % 2 == 1 ? indent : 1
            return CGPoint(x: cos(angle) * reach, y: sin(angle) * reach)
        }
        let minX = unit.map(\.x).min() ?? -1, maxX = unit.map(\.x).max() ?? 1
        let minY = unit.map(\.y).min() ?? -1, maxY = unit.map(\.y).max() ?? 1
        let path = CGMutablePath()
        path.addLines(between: unit.map { point in
            CGPoint(x: rect.minX + (point.x - minX) / (maxX - minX) * rect.width,
                    y: rect.minY + (point.y - minY) / (maxY - minY) * rect.height)
        })
        path.closeSubpath()
        return path
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
    /// A line's thickness, and its two ends as fractions of the layer's box (0–1), so the line lands on exactly the
    /// points it was dragged between and still redraws correctly at another size. Nil on other shapes.
    var lineWidth: CGFloat? = nil
    var start: CGPoint? = nil
    var end: CGPoint? = nil
    /// A star's points or a polygon's sides. Nil on other shapes.
    var points: Int? = nil
    /// How far a star's inner corners are pulled in, as a fraction of its points' reach. Nil keeps its sides even.
    var inset: CGFloat? = nil
    var color: PaletteColor { PaletteColor(red: red, green: green, blue: blue) }
    /// Stars and polygons arrived in format version 10 and must say how many corners they have.
    func isValid(version: Int) -> Bool {
        switch kind {
        case .star:
            return version >= 10 && points.map { (3...20).contains($0) } == true
                && inset.map { $0.isFinite && ShapeKind.starInsets.contains($0) } != false
        case .polygon: return version >= 10 && points.map { (3...20).contains($0) } == true && inset == nil
        case .rectangle, .ellipse, .line: return points == nil && inset == nil
        }
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
    /// A star's points or a polygon's sides, fixed when the drag starts.
    var points: Int = 5
    /// A star's chosen inset, fixed when the drag starts; nil keeps its sides even.
    var inset: CGFloat? = nil
}

extension EditorSession {
    /// Pixels one shape layer may hold, the same budget as an import.
    nonisolated static let maxShapePixels = DocumentLimits.maxSurfacePixels

    func beginShape(at point: CGPoint) {
        guard tool == .shape, canEditLayers, point.x.isFinite, point.y.isFinite else { return }
        let anchor = CGPoint(x: point.x.rounded(), y: point.y.rounded())
        shapeDraft = ShapeDraft(kind: shapeKind, anchor: anchor, rect: CGRect(origin: anchor, size: .zero),
                                cornerRadius: shapeKind == .rectangle ? CGFloat(shapeCornerRadius) : 0,
                                points: shapeKind == .star ? shapeStarPoints : shapePolygonSides,
                                inset: shapeKind == .star ? shapeStarInset.map { CGFloat($0) } : nil)
    }

    /// The line being dragged, from where it began to where the pointer is, in document pixels.
    var shapeLineEnds: (start: CGPoint, end: CGPoint)? {
        guard let draft = shapeDraft, draft.kind == .line, let end = draft.end else { return nil }
        return (draft.anchor, end)
    }

    /// Shift makes a square or circle; Option grows the shape from its center, as in Photoshop.
    func dragShape(to point: CGPoint, square: Bool, fromCenter: Bool) {
        guard var draft = shapeDraft, point.x.isFinite, point.y.isFinite else { return }
        // Shift on a line snaps its angle to eighths of a turn — flat, upright, or 45° — rather than squaring a box.
        if draft.kind == .line, square {
            let dx = point.x - draft.anchor.x, dy = point.y - draft.anchor.y
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let length = hypot(dx, dy)
            let snapped = CGPoint(x: draft.anchor.x + cos(angle) * length, y: draft.anchor.y + sin(angle) * length)
            draft.end = snapped
            draft.rect = DragBox.rect(from: draft.anchor, to: snapped, square: false, fromCenter: fromCenter)
            shapeDraft = draft
            return
        }
        if draft.kind == .line { draft.end = point }
        draft.rect = DragBox.rect(from: draft.anchor, to: point, square: square, fromCenter: fromCenter)
        shapeDraft = draft
    }

    func cancelShape() {
        if shapeDraft != nil { shapeDraft = nil }
    }

    /// Shift-U (and Tab): the Shape tool steps through Rectangle, Ellipse, Star, Polygon and Line.
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
        // thickness (and its round ends) around them.
        var ends: (start: CGPoint, end: CGPoint)?
        if draft.kind == .line {
            let from = draft.anchor, to = draft.end ?? draft.anchor
            rect = CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
                          width: abs(to.x - from.x), height: abs(to.y - from.y)).insetBy(dx: -thickness / 2, dy: -thickness / 2)
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
            let image = try Self.shapeImage(draft.kind, size: rect.size, color: foregroundColor, cornerRadius: draft.cornerRadius,
                                            lineWidth: thickness, start: start, end: finish, points: draft.points,
                                            inset: draft.inset)
            let style = LayerShapeStyle(kind: draft.kind, red: foregroundColor.red, green: foregroundColor.green,
                                        blue: foregroundColor.blue, cornerRadius: draft.cornerRadius,
                                        lineWidth: draft.kind == .line ? thickness : nil, start: start, end: finish,
                                        points: draft.kind == .star || draft.kind == .polygon ? draft.points : nil,
                                        inset: draft.kind == .star ? draft.inset : nil)
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
    /// instead of stretching. Part of the edit that changed the size.
    func redrawShape(at index: Int) {
        guard let layer = document?.layers[index], let shape = layer.liveShape, let asset = layer.asset else { return }
        let width = max(1, Int(layer.transform.size.width.rounded())), height = max(1, Int(layer.transform.size.height.rounded()))
        guard width != asset.image.width || height != asset.image.height, width * height <= Self.maxShapePixels,
              let image = try? Self.shapeImage(shape.style.kind, size: CGSize(width: width, height: height),
                                               color: shape.style.color, cornerRadius: shape.style.cornerRadius,
                                               lineWidth: shape.style.lineWidth ?? 0,
                                               start: shape.style.start, end: shape.style.end,
                                               points: shape.style.points ?? 5, inset: shape.style.inset),
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
                                               cornerRadius: shape.style.cornerRadius * factor) else { return nil }
        shapeTransformPreviewCache[layer.id] = (drawn, image)
        return image
    }

    /// The shape filling its box, anti-aliased where it curves.
    nonisolated static func shapeImage(_ kind: ShapeKind, size: CGSize, color: PaletteColor, cornerRadius: CGFloat = 0,
                           lineWidth: CGFloat = 0, start: CGPoint? = nil, end: CGPoint? = nil, points: Int = 5,
                           inset: CGFloat? = nil) throws -> CGImage {
        let context = try BrushRaster.context(width: Int(size.width), height: Int(size.height), mask: false)
        let bounds = CGRect(origin: .zero, size: size)
        if kind == .line {
            // Corner to corner, inset by half the thickness so the stroke stays inside the layer.
            let thickness = max(1, lineWidth)
            context.setStrokeColor(CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1))
            context.setLineWidth(thickness)
            context.setLineCap(.round)
            // The ends sit where they were dragged, as fractions of the box. Older lines (no ends stored) ran corner
            // to corner, inset by half their thickness.
            let inset = bounds.insetBy(dx: min(thickness, size.width) / 2, dy: min(thickness, size.height) / 2)
            let from = start.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) } ?? CGPoint(x: inset.minX, y: inset.minY)
            let to = end.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) } ?? CGPoint(x: inset.maxX, y: inset.maxY)
            context.move(to: from)
            context.addLine(to: to)
            context.strokePath()
            guard let image = context.makeImage() else { throw ExportError.render }
            return image
        }
        context.setFillColor(CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1))
        context.addPath(kind.path(in: bounds, cornerRadius: cornerRadius, points: points, inset: inset))
        context.fillPath()
        guard let image = context.makeImage() else { throw ExportError.render }
        return image
    }
}
