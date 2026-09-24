import AppKit

struct TransformOverlayGeometry: Equatable {
    let handles: [CGPoint]
    let rotationHandle: CGPoint
    /// A distortion has no single rotation, so its rotation handle is hidden.
    let showsRotation: Bool

    init(transform: LayerTransform, viewport: CanvasViewport, documentSize: CGSize) {
        handles = LayerTransform.handles.map { viewport.viewPoint(from: transform.point($0), documentSize: documentSize) }
        rotationHandle = CGPoint(x: handles[1].x + sin(transform.radians) * 28,
                                 y: handles[1].y - cos(transform.radians) * 28)
        showsRotation = true
    }

    /// Handles for a distortion: its four corners (document pixels) and the midpoints of its edges.
    init(corners: [CGPoint], viewport: CanvasViewport, documentSize: CGSize) {
        let view = corners.map { viewport.viewPoint(from: $0, documentSize: documentSize) }
        func middle(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        handles = [view[0], middle(view[0], view[1]), view[1], middle(view[1], view[2]),
                   view[2], middle(view[2], view[3]), view[3], middle(view[3], view[0])]
        rotationHandle = handles[1]
        showsRotation = false
    }

    func hit(_ point: CGPoint) -> TransformDrag.Mode? {
        func near(_ other: CGPoint) -> Bool { hypot(point.x - other.x, point.y - other.y) <= 10 }
        if showsRotation, near(rotationHandle) { return .rotate }
        if let index = handles.firstIndex(where: near) { return .resize(index) }
        for (start, end, handle) in [(0, 2, 1), (2, 4, 3), (4, 6, 5), (6, 0, 7)] {
            let a = handles[start], b = handles[end]
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            guard lengthSquared > 0 else { continue }
            let t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared
            if (0...1).contains(t), hypot(point.x - a.x - t * dx, point.y - a.y - t * dy) <= 10 {
                return .resize(handle)
            }
        }
        return nil
    }

    func resizeCursor(for index: Int) -> NSCursor {
        let angle = atan2(handles[2].y - handles[0].y, handles[2].x - handles[0].x)
        let offsets: [CGFloat] = [.pi / 4, .pi / 2, 3 * .pi / 4, 0, .pi / 4, .pi / 2, 3 * .pi / 4, 0]
        let direction = (Int(((angle + offsets[index]) / (.pi / 4)).rounded()) % 4 + 4) % 4
        let positions: [NSCursor.FrameResizePosition] = [.right, .bottomRight, .bottom, .topRight]
        return .frameResize(position: positions[direction], directions: [.inward, .outward])
    }
}

/// Separate overlay so selecting a layer does not redraw image pixels.
final class TransformOverlay: NSView {
    let session: EditorSession
    init(session: EditorSession) {
        self.session = session
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var geometry: TransformOverlayGeometry? {
        guard session.tool == .move, session.showsTransformControls || session.transformEdit?.persistent == true,
              let document = session.document else { return nil }
        // Several layers selected, or a folder: one box around them all.
        if session.transformEdit?.group != nil || (session.transformEdit == nil && session.transformsAsGroup) {
            if let corners = session.transformEdit?.corners {
                return TransformOverlayGeometry(corners: corners, viewport: session.viewport, documentSize: document.size)
            }
            guard let box = session.transformEdit?.draft ?? session.groupTransformBox else { return nil }
            return TransformOverlayGeometry(transform: box, viewport: session.viewport, documentSize: document.size)
        }
        guard let layer = session.activeLayer, layer.asset != nil, !layer.isGroup, document.effectiveVisibleIDs.contains(layer.id) else { return nil }
        if let edit = session.transformEdit, edit.layerID == layer.id, let corners = edit.corners {
            return TransformOverlayGeometry(corners: corners, viewport: session.viewport, documentSize: document.size)
        }
        return TransformOverlayGeometry(transform: session.editedTransform(for: layer),
                                        viewport: session.viewport, documentSize: document.size)
    }

    /// Pending gradient endpoints in view coordinates.
    var gradientLine: (start: CGPoint, end: CGPoint)? {
        guard let edit = session.gradientEdit, edit.hasLine, let document = session.document else { return nil }
        return (session.viewport.viewPoint(from: edit.start, documentSize: document.size),
                session.viewport.viewPoint(from: edit.end, documentSize: document.size))
    }

    var antsPhase: CGFloat = 0

    // MARK: Marching ants level of detail
    //
    // A Magic Wand outline on detailed artwork can have hundreds of thousands of edges, one per pixel step. Stroked in
    // full every tick, zoomed out they pile into a few screen pixels and one redraw can take seconds, which froze the
    // app. Below 1:1 a complex outline is drawn from one traced at screen resolution instead: built in the background,
    // cached per power-of-two zoom step, so it never has more edges than the screen has pixels to show.

    /// Outlines at or under this many path elements are always drawn in full; marquees and lassos stay exact.
    private static let fullDetailLimit = 20_000
    private var antsSource: CGPath?
    private var antsSourceIsComplex = false
    /// The screen-resolution outline in document coordinates, and the zoom step it was traced for.
    private var antsLevel: (path: CGPath, step: CGFloat)?
    private var antsPendingStep: CGFloat?
    private var antsTask: Task<Void, Never>?

    /// What the ants stroke: the selection itself, or when zoomed out on a complex one, its screen-resolution outline.
    /// Nil while the first simplified outline is still being traced.
    private func antsOutline(for path: CGPath) -> CGPath? {
        if antsSource !== path {
            antsSource = path
            antsTask?.cancel()
            antsTask = nil
            antsLevel = nil
            antsPendingStep = nil
            var elements = 0
            path.applyWithBlock { _ in elements += 1 }
            antsSourceIsComplex = elements > Self.fullDetailLimit
        }
        let scale = session.viewport.pointsPerPixel * (window?.backingScaleFactor ?? 2)
        guard antsSourceIsComplex, scale < 1, let document = session.document else { return path }
        // Screen pixels per document pixel, rounded up to a power of two so zooming doesn't retrace on every frame.
        let step = min(1, pow(2, ceil(log2(max(scale, 1 / 4096)))))
        if antsLevel?.step != step, antsPendingStep != step {
            antsPendingStep = step
            antsTask?.cancel()
            let canvas = CGRect(origin: .zero, size: document.size)
            antsTask = Task { [weak self] in
                let traced = await Task.detached(priority: .userInitiated) { Self.traceOutline(path, canvas: canvas, step: step) }.value
                guard let self, !Task.isCancelled, self.antsSource === path, self.antsPendingStep == step else { return }
                self.antsPendingStep = nil
                if let traced { self.antsLevel = (traced, step) }
                self.needsDisplay = true
            }
        }
        // Until the new step is traced, the last one stands in: a little coarse or fine for a moment, never slow.
        return antsLevel?.path
    }

    /// `path` filled into a mask fine enough to fill quickly, averaged down to `step` screen pixels per document pixel,
    /// and traced along those pixels' edges. Any coverage counts, so thin parts stay outlined rather than vanishing.
    private nonisolated static func traceOutline(_ path: CGPath, canvas: CGRect, step: CGFloat) -> CGPath? {
        let region = path.boundingBoxOfPath.intersection(canvas).integral
        guard !region.isNull, region.width >= 1, region.height >= 1 else { return nil }
        // Filling costs about as much as the edges each output pixel has to sort through, so the mask is filled at no
        // less than half resolution and at most about 40 megapixels.
        let fill = min(1, max(step, (40_000_000 / (region.width * region.height)).squareRoot()))
        func mask(_ width: Int, _ height: Int) -> CGContext? {
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        }
        let fillWidth = max(1, Int((region.width * fill).rounded(.up))), fillHeight = max(1, Int((region.height * fill).rounded(.up)))
        guard let filled = mask(fillWidth, fillHeight) else { return nil }
        // Top-left origin, so a mask row is a document row, as the tracer expects.
        filled.translateBy(x: 0, y: CGFloat(fillHeight))
        filled.scaleBy(x: fill, y: -fill)
        filled.translateBy(x: -region.minX, y: -region.minY)
        filled.addPath(path)
        filled.setFillColor(gray: 1, alpha: 1)
        filled.fillPath(using: .winding)
        guard let image = filled.makeImage() else { return nil }
        let width = max(1, Int((region.width * step).rounded(.up))), height = max(1, Int((region.height * step).rounded(.up)))
        guard let small = mask(width, height) else { return nil }
        small.interpolationQuality = .medium
        small.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = small.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var pixels = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            let line = bytes + row * small.bytesPerRow
            for column in 0..<width where line[column] > 0 { pixels[row * width + column] = 255 }
        }
        guard let traced = try? MagicWand.outline(of: pixels, width: width, height: height) else { return nil }
        var toDocument = CGAffineTransform(translationX: region.minX, y: region.minY).scaledBy(x: 1 / step, y: 1 / step)
        return traced.copy(using: &toDocument)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawLayoutGrid()
        drawGuides()
        if session.tool == .crop { drawCrop() }
        else if let line = gradientLine { drawGradientLine(line) }
        else if session.tool == .directSelection { drawDirectSelection() }
        else if session.tool == .pen { /* pen draft/interaction drawn below */ }
        else { drawTransformHandles() }
        drawPenPathOutline()
        drawSelection()
        drawLassoDraft()
        drawPenDraft()
        drawPenPathInteraction()
        drawSnapGuides()
    }

    /// Non-printing layout grid over the document: solid majors every 64 px, dotted 8 px subdivisions.
    private func drawLayoutGrid() {
        guard session.showsGrid, let document = session.document, let transform = documentToView,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let size = document.size
        let scale = session.viewport.pointsPerPixel
        let hairline = 1 / max(session.viewport.backingScale, 1)
        let subdivisionGap = LayoutGrid.step * scale
        context.saveGState()
        context.concatenate(transform)
        context.setLineWidth(hairline / max(scale, 0.0001))
        context.setStrokeColor(NSColor(white: 0.55, alpha: 0.28).cgColor)
        if subdivisionGap >= 4 {
            context.setLineDash(phase: 0, lengths: [1 / max(scale, 0.0001), 2 / max(scale, 0.0001)])
            let path = CGMutablePath()
            for x in LayoutGrid.lines(along: size.width) where !LayoutGrid.isMajor(x) {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in LayoutGrid.lines(along: size.height) where !LayoutGrid.isMajor(y) {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.addPath(path)
            context.strokePath()
        }
        context.setLineDash(phase: 0, lengths: [])
        context.setStrokeColor(NSColor(white: 0.7, alpha: 0.45).cgColor)
        let majors = CGMutablePath()
        for x in LayoutGrid.lines(along: size.width) where LayoutGrid.isMajor(x) {
            majors.move(to: CGPoint(x: x, y: 0))
            majors.addLine(to: CGPoint(x: x, y: size.height))
        }
        for y in LayoutGrid.lines(along: size.height) where LayoutGrid.isMajor(y) {
            majors.move(to: CGPoint(x: 0, y: y))
            majors.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.addPath(majors)
        context.strokePath()
        context.restoreGState()
    }

    /// User guides span the whole view, including the pasteboard.
    private func drawGuides() {
        guard session.showsGuides, let document = session.document,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let guides = session.displayedGuides
        guard !guides.isEmpty else { return }
        context.saveGState()
        context.setStrokeColor(EditorSession.guideColor)
        context.setLineWidth(1 / max(session.viewport.backingScale, 1))
        for guide in guides {
            if guide.axis == .vertical {
                let x = session.viewport.viewPoint(from: CGPoint(x: guide.position, y: 0), documentSize: document.size).x
                context.move(to: CGPoint(x: x, y: 0))
                context.addLine(to: CGPoint(x: x, y: bounds.height))
            } else {
                let y = session.viewport.viewPoint(from: CGPoint(x: 0, y: guide.position), documentSize: document.size).y
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: bounds.width, y: y))
            }
        }
        context.strokePath()
        context.restoreGState()
    }

    /// While a move is snapped, a line along what it lined up with, across the whole canvas.
    private func drawSnapGuides() {
        let guides = session.snapGuides
        guard !guides.xs.isEmpty || !guides.ys.isEmpty, let document = session.document,
              let transform = documentToView, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1)
        for x in guides.xs {
            context.move(to: CGPoint(x: x, y: 0).applying(transform))
            context.addLine(to: CGPoint(x: x, y: document.size.height).applying(transform))
        }
        for y in guides.ys {
            context.move(to: CGPoint(x: 0, y: y).applying(transform))
            context.addLine(to: CGPoint(x: document.size.width, y: y).applying(transform))
        }
        context.strokePath()
        context.restoreGState()
    }

    private var documentToView: CGAffineTransform? {
        guard let document = session.document else { return nil }
        let origin = session.viewport.documentRect(document.size).origin
        let scale = session.viewport.pointsPerPixel
        return CGAffineTransform(translationX: origin.x, y: origin.y).scaledBy(x: scale, y: scale)
    }

    /// Marching ants: a white line under an animated black dash.
    private func drawSelection() {
        guard let selection = session.displayedSelection, !selection.isEmpty, var transform = documentToView,
              let outline = antsOutline(for: selection.path),
              let path = outline.copy(using: &transform), let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setLineWidth(1)
        context.addPath(path)
        context.setStrokeColor(NSColor.white.cgColor)
        context.strokePath()
        context.addPath(path)
        context.setLineDash(phase: antsPhase, lengths: [4, 4])
        context.setStrokeColor(NSColor.black.cgColor)
        context.strokePath()
        context.restoreGState()
    }


    private func drawLassoDraft() {
        guard let draft = session.lassoDraft, let transform = documentToView,
              let context = NSGraphicsContext.current?.cgContext else { return }
        var points = draft.points.map { $0.applying(transform) }
        if draft.kind == .polygonal, let cursor = draft.cursor { points.append(cursor.applying(transform)) }
        guard let first = points.first else { return }
        context.saveGState()
        let path = CGMutablePath()
        if draft.kind == .ellipse, points.count == 4 {
            let xs = points.map(\.x), ys = points.map(\.y)
            path.addEllipse(in: CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!))
        } else {
            path.addLines(between: points)
            if draft.kind == .rectangle { path.closeSubpath() }
        }
        context.addPath(path)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.8).cgColor)
        context.setLineWidth(2)
        context.strokePath()
        context.addPath(path)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1)
        context.strokePath()
        if draft.kind == .polygonal {
            // The first corner: click it to close the outline.
            let handle = CGRect(x: first.x - 4, y: first.y - 4, width: 8, height: 8)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(handle)
            context.setStrokeColor(NSColor.black.cgColor)
            context.stroke(handle)
        }
        context.restoreGState()
    }

    private func drawTransformHandles() {
        guard let geometry, let context = NSGraphicsContext.current?.cgContext else { return }
        let path = CGMutablePath()
        path.move(to: geometry.handles[0])
        for index in [2, 4, 6] { path.addLine(to: geometry.handles[index]) }
        path.closeSubpath()
        if geometry.showsRotation {
            path.move(to: geometry.handles[1])
            path.addLine(to: geometry.rotationHandle)
        }
        // Just the accent line: a dark line behind it read as a grey halo around the box.
        context.addPath(path)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1)
        context.strokePath()
        context.setFillColor(NSColor.white.cgColor)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        for point in geometry.handles {
            let rect = CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)
            context.fill(rect)
            context.stroke(rect)
        }
        guard geometry.showsRotation else { return }
        let point = geometry.rotationHandle
        let rect = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
        context.fillEllipse(in: rect)
        context.strokeEllipse(in: rect)
    }

    var cropViewRect: CGRect? {
        guard let rect = session.visibleCropRect, let document = session.document else { return nil }
        return CGRect(origin: session.viewport.viewPoint(from: rect.origin, documentSize: document.size),
                      size: CGSize(width: rect.width * session.viewport.pointsPerPixel,
                                   height: rect.height * session.viewport.pointsPerPixel))
    }
    var cropHandles: [CGPoint] {
        guard let rect = cropViewRect else { return [] }
        return LayerTransform.handles.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
    }
    var cropResizeRegions: [(index: Int, rect: CGRect)] {
        guard let rect = cropViewRect else { return [] }
        let handles = cropHandles
        let radius: CGFloat = 10
        var regions = [0, 2, 4, 6].map { index in
            (index: index, rect: CGRect(x: handles[index].x - radius, y: handles[index].y - radius,
                                        width: radius * 2, height: radius * 2))
        }
        // Entire edges are draggable, not just the small midpoint squares.
        for index in [1, 5] {
            regions.append((index, CGRect(x: rect.minX + radius, y: handles[index].y - radius,
                width: max(0, rect.width - radius * 2), height: radius * 2)))
        }
        for index in [3, 7] {
            regions.append((index, CGRect(x: handles[index].x - radius, y: rect.minY + radius,
                width: radius * 2, height: max(0, rect.height - radius * 2))))
        }
        return regions
    }
    private func drawGradientLine(_ line: (start: CGPoint, end: CGPoint)) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        if session.gradientSettings.shape == .radial {
            // Faint rim where the radial gradient reaches its end color.
            let radius = hypot(line.end.x - line.start.x, line.end.y - line.start.y)
            let rim = CGRect(x: line.start.x - radius, y: line.start.y - radius, width: radius * 2, height: radius * 2)
            context.setLineDash(phase: 0, lengths: [4, 4])
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            context.setLineWidth(2)
            context.strokeEllipse(in: rim)
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
            context.setLineWidth(1)
            context.strokeEllipse(in: rim)
            context.setLineDash(phase: 0, lengths: [])
        }
        context.move(to: line.start)
        context.addLine(to: line.end)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        context.setLineWidth(3)
        context.strokePath()
        context.move(to: line.start)
        context.addLine(to: line.end)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1)
        context.strokePath()
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(1)
        for (point, color) in [(line.start, session.gradientColors(mask: false).first), (line.end, session.gradientColors(mask: false).last)] {
            let rect = CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)
            context.setFillColor(NSColor.white.cgColor)
            context.fillEllipse(in: rect)
            context.strokeEllipse(in: rect)
            // Checkerboard shows through transparent ends.
            let inner = rect.insetBy(dx: 2.5, dy: 2.5)
            context.setFillColor(NSColor(white: 0.75, alpha: 1).cgColor)
            context.fillEllipse(in: inner)
            if let color { context.setFillColor(color); context.fillEllipse(in: inner) }
        }
        context.restoreGState()
    }

    private func drawCrop() {
        guard let rect = cropViewRect, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.addRect(bounds)
        context.addRect(rect)
        context.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        context.drawPath(using: .eoFill)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1)
        context.stroke(rect)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.4).cgColor)
        for index in 1...2 {
            let fraction = CGFloat(index) / 3
            context.move(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY))
            context.addLine(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY))
            context.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * fraction))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * fraction))
        }
        context.strokePath()
        context.setFillColor(NSColor.white.cgColor)
        context.setStrokeColor(NSColor.black.cgColor)
        for point in cropHandles {
            let handle = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
            context.fill(handle)
            context.stroke(handle)
        }
        context.restoreGState()
    }

    private func drawPenDraft() {
        guard session.tool == .pen,
              let draft = session.penDraft,
              session.document != nil,
              let transform = documentToView,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let points = draft.subpath.points
        guard !points.isEmpty else { return }

        context.saveGState()

        // 1. Draw existing committed segments of the draft
        if points.count >= 2 {
            let path = CGMutablePath()
            let firstView = points[0].anchor.applying(transform)
            path.move(to: firstView)

            for i in 0 ..< points.count - 1 {
                let a = points[i]
                let b = points[i + 1]
                let bView = b.anchor.applying(transform)
                if a.nextControl == nil && b.previousControl == nil {
                    path.addLine(to: bView)
                } else {
                    let c1 = (a.nextControl ?? a.anchor).applying(transform)
                    let c2 = (b.previousControl ?? b.anchor).applying(transform)
                    path.addCurve(to: bView, control1: c1, control2: c2)
                }
            }

            if draft.isClosingCandidate {
                let last = points[points.count - 1]
                let first = points[0]
                if last.nextControl == nil && first.previousControl == nil {
                    path.addLine(to: firstView)
                } else {
                    let c1 = (last.nextControl ?? last.anchor).applying(transform)
                    let c2 = (first.previousControl ?? first.anchor).applying(transform)
                    path.addCurve(to: firstView, control1: c1, control2: c2)
                }
            }

            // Dark shadow/outline for contrast
            context.addPath(path)
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor)
            context.setLineWidth(3)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()

            // Main stroke line
            context.addPath(path)
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(1.5)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
        }

        // 2. Draw live preview segment from last anchor to pointer
        if !draft.isDragging && !draft.isClosingCandidate, let pointer = draft.pointer, let last = points.last {
            let lastView = last.anchor.applying(transform)
            let pointerView = pointer.applying(transform)

            let previewPath = CGMutablePath()
            previewPath.move(to: lastView)
            if let nextC = last.nextControl {
                let c1 = nextC.applying(transform)
                previewPath.addCurve(to: pointerView, control1: c1, control2: pointerView)
            } else {
                previewPath.addLine(to: pointerView)
            }

            context.saveGState()
            context.setLineDash(phase: 0, lengths: [4, 4])
            context.addPath(previewPath)
            context.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor)
            context.setLineWidth(1.5)
            context.strokePath()
            context.restoreGState()
        }

        // 3. Draw Bézier handles if dragging the active anchor
        if draft.isDragging, let index = draft.activeAnchorIndex, points.indices.contains(index) {
            let activePoint = points[index]
            let anchorView = activePoint.anchor.applying(transform)

            if let prevC = activePoint.previousControl, let nextC = activePoint.nextControl {
                let prevView = prevC.applying(transform)
                let nextView = nextC.applying(transform)

                // Handle stalks
                let handleLines = CGMutablePath()
                handleLines.move(to: prevView)
                handleLines.addLine(to: anchorView)
                handleLines.addLine(to: nextView)

                context.saveGState()
                context.addPath(handleLines)
                context.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor)
                context.setLineWidth(1)
                context.strokePath()

                // Circular control endpoints
                for cp in [prevView, nextView] {
                    let handleRect = CGRect(x: cp.x - 3.5, y: cp.y - 3.5, width: 7, height: 7)
                    context.setFillColor(NSColor.white.cgColor)
                    context.fillEllipse(in: handleRect)
                    context.setStrokeColor(NSColor.controlAccentColor.cgColor)
                    context.setLineWidth(1.5)
                    context.strokeEllipse(in: handleRect)
                }
                context.restoreGState()
            }
        }

        // 4. Draw anchors
        // Check if pointer is hovering close to initial anchor for closing
        let firstView = points[0].anchor.applying(transform)
        var hoveringFirst = draft.isClosingCandidate
        if !hoveringFirst, points.count >= 2, let pointer = draft.pointer {
            let pointerView = pointer.applying(transform)
            hoveringFirst = hypot(firstView.x - pointerView.x, firstView.y - pointerView.y) <= 10.0
        }

        for (idx, pt) in points.enumerated() {
            let v = pt.anchor.applying(transform)
            let rect = CGRect(x: v.x - 3.5, y: v.y - 3.5, width: 7, height: 7)

            if idx == 0 {
                // First anchor
                if hoveringFirst {
                    // Close-path indicator: draw a circle ring around first anchor
                    let ring = CGRect(x: v.x - 7, y: v.y - 7, width: 14, height: 14)
                    context.setStrokeColor(NSColor.systemGreen.cgColor)
                    context.setLineWidth(2)
                    context.strokeEllipse(in: ring)
                }
                context.setFillColor(NSColor.white.cgColor)
                context.fill(rect)
                context.setStrokeColor(hoveringFirst ? NSColor.systemGreen.cgColor : NSColor.controlAccentColor.cgColor)
                context.setLineWidth(hoveringFirst ? 2 : 1.5)
                context.stroke(rect)
            } else {
                // Other anchors
                context.setFillColor(NSColor.white.cgColor)
                context.fill(rect)
                context.setStrokeColor(NSColor.controlAccentColor.cgColor)
                context.setLineWidth(1)
                context.stroke(rect)
            }
        }

        context.restoreGState()
    }

    private func drawPenPathOutline() {
        guard session.tool == .pen,
              session.penDraft == nil,
              let document = session.document,
              let docToView = documentToView,
              let context = NSGraphicsContext.current?.cgContext else { return }

        let activeVectorLayer = session.activeLayer.flatMap { layer in
            (layer.isVisible && layer.vector != nil && !(layer.vector?.subpaths.isEmpty ?? true)) ? layer : nil
        }

        if let activeLayer = activeVectorLayer, let vector = activeLayer.vector {
            let layerToDoc = activeLayer.transform.layerToDocument
            var layerToView = layerToDoc.concatenating(docToView)

            let basePath = VectorBridge.cgPath(from: vector)
            if let viewPath = basePath.copy(using: &layerToView) {
                context.saveGState()
                context.addPath(viewPath)
                context.setStrokeColor(NSColor.controlAccentColor.cgColor)
                context.setLineWidth(1)
                context.setLineDash(phase: 0, lengths: [4, 4])
                context.strokePath()
                context.restoreGState()
            }
        }
    }

    private func drawPenPathInteraction() {
        guard session.tool == .pen,
              session.penDraft == nil,
              let document = session.document,
              let docToView = documentToView,
              let context = NSGraphicsContext.current?.cgContext else { return }

        // 1. If an active layer has a VectorModel and is visible, draw all its anchor points
        let activeVectorLayer = session.activeLayer.flatMap { layer in
            (layer.isVisible && layer.vector != nil && !(layer.vector?.subpaths.isEmpty ?? true)) ? layer : nil
        }

        if let activeLayer = activeVectorLayer, let vector = activeLayer.vector {
            let layerToDoc = activeLayer.transform.layerToDocument
            let layerToView = layerToDoc.concatenating(docToView)

            context.saveGState()

            // 1b. Draw all anchor points on each subpath
            for (sIdx, subpath) in vector.subpaths.enumerated() {
                for (aIdx, pt) in subpath.points.enumerated() {
                    let anchorIdx = VectorAnchorIndex(subpathIndex: sIdx, anchorIndex: aIdx)
                    let anchorView = pt.anchor.applying(layerToView)

                    let isHovered = (session.penHoverAnchor?.layerID == activeLayer.id &&
                                     session.penHoverAnchor?.anchorIndex == anchorIdx)

                    context.saveGState()
                    if isHovered {
                        // Outer accent halo for hovered anchor
                        let haloRect = CGRect(x: anchorView.x - 6.5, y: anchorView.y - 6.5, width: 13, height: 13)
                        context.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor)
                        context.setLineWidth(2)
                        context.stroke(haloRect)
                    }

                    // Anchor square with dark contrast backing and white fill
                    let anchorRect = CGRect(x: anchorView.x - 3.5, y: anchorView.y - 3.5, width: 7, height: 7)
                    context.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor)
                    context.setLineWidth(2.5)
                    context.stroke(anchorRect)

                    context.setFillColor(NSColor.white.cgColor)
                    context.fill(anchorRect)
                    context.setStrokeColor(NSColor.controlAccentColor.cgColor)
                    context.setLineWidth(isHovered ? 1.5 : 1.0)
                    context.stroke(anchorRect)

                    context.restoreGState()
                }
            }

            context.restoreGState()
        }

        // 2. Open endpoint continuation indicator
        if let hover = session.penHoverEndpoint {
            let hoverView = hover.point.applying(docToView)
            context.saveGState()
            let ring = CGRect(x: hoverView.x - 7, y: hoverView.y - 7, width: 14, height: 14)
            context.setStrokeColor(NSColor.systemGreen.cgColor)
            context.setLineWidth(2)
            context.strokeEllipse(in: ring)

            let dot = CGRect(x: hoverView.x - 3.5, y: hoverView.y - 3.5, width: 7, height: 7)
            context.setFillColor(NSColor.white.cgColor)
            context.fillEllipse(in: dot)
            context.setStrokeColor(NSColor.systemGreen.cgColor)
            context.setLineWidth(1.5)
            context.strokeEllipse(in: dot)
            context.restoreGState()
        } else {
            // 3. If hovering a non-active vector layer, draw its dashed outline and hovered anchor
            let activeID = session.activeLayerID
            if let hoverLayerHit = session.penHoverVectorLayer,
               hoverLayerHit.layerID != activeID,
               let layer = document.layers.first(where: { $0.id == hoverLayerHit.layerID && $0.isVisible }),
               let vector = layer.vector {
                let layerToDoc = layer.transform.layerToDocument
                var layerToView = layerToDoc.concatenating(docToView)
                let localPath = VectorBridge.cgPath(from: vector)
                if let viewPath = localPath.copy(using: &layerToView) {
                    context.saveGState()
                    context.addPath(viewPath)
                    context.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor)
                    context.setLineWidth(1.5)
                    context.setLineDash(phase: 0, lengths: [4, 4])
                    context.strokePath()
                    context.restoreGState()
                }
            }

            if let anchorTarget = session.penHoverAnchor,
               anchorTarget.layerID != activeID,
               let layer = document.layers.first(where: { $0.id == anchorTarget.layerID && $0.isVisible }),
               let vector = layer.vector {
                let s = anchorTarget.anchorIndex.subpathIndex
                let a = anchorTarget.anchorIndex.anchorIndex
                if vector.subpaths.indices.contains(s),
                   vector.subpaths[s].points.indices.contains(a) {
                    let pt = vector.subpaths[s].points[a]
                    let layerToDoc = layer.transform.layerToDocument
                    let layerToView = layerToDoc.concatenating(docToView)
                    let anchorView = pt.anchor.applying(layerToView)

                    context.saveGState()
                    let haloRect = CGRect(x: anchorView.x - 6.5, y: anchorView.y - 6.5, width: 13, height: 13)
                    context.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor)
                    context.setLineWidth(2)
                    context.stroke(haloRect)

                    let anchorRect = CGRect(x: anchorView.x - 3.5, y: anchorView.y - 3.5, width: 7, height: 7)
                    context.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor)
                    context.setLineWidth(2.5)
                    context.stroke(anchorRect)

                    context.setFillColor(NSColor.white.cgColor)
                    context.fill(anchorRect)
                    context.setStrokeColor(NSColor.controlAccentColor.cgColor)
                    context.setLineWidth(1.5)
                    context.stroke(anchorRect)
                    context.restoreGState()
                }
            }
        }
    }

    private func drawDirectSelection() {
        guard session.tool == .directSelection,
              let document = session.document,
              let docToView = documentToView,
              let context = NSGraphicsContext.current?.cgContext else { return }

        // Find active vector layer or target layer
        let targetLayerID = session.vectorSelection?.layerID ?? session.activeLayerID
        guard let layer = document.layers.first(where: { $0.id == targetLayerID && $0.isVisible && $0.vector != nil }),
              let baseVector = layer.vector else { return }

        let vector = (session.directSelectionDrag?.layerID == layer.id)
            ? session.directSelectionDrag!.currentModel
            : baseVector

        let layerToDoc = layer.transform.layerToDocument
        var layerToView = layerToDoc.concatenating(docToView)

        context.saveGState()

        // 1. Draw path outline
        let basePath = VectorBridge.cgPath(from: vector)
        if let viewPath = basePath.copy(using: &layerToView) {
            context.saveGState()
            context.addPath(viewPath)
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.4).cgColor)
            context.setLineWidth(2.5)
            context.strokePath()

            context.addPath(viewPath)
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(1)
            context.strokePath()
            context.restoreGState()
        }

        // 2. Draw anchors and handles
        let selection = session.vectorSelection?.layerID == layer.id ? session.vectorSelection : nil

        for (sIdx, subpath) in vector.subpaths.enumerated() {
            for (aIdx, pt) in subpath.points.enumerated() {
                let anchorIdx = VectorAnchorIndex(subpathIndex: sIdx, anchorIndex: aIdx)
                let anchorView = pt.anchor.applying(layerToView)
                let isSelected = selection?.selectedAnchors.contains(anchorIdx) == true

                if isSelected {
                    // Draw Bézier handles if present
                    let stalkPath = CGMutablePath()
                    var handlesToDraw: [(point: CGPoint, side: DirectSelectionHandleSide)] = []

                    if let prev = pt.previousControl {
                        let prevView = prev.applying(layerToView)
                        stalkPath.move(to: anchorView)
                        stalkPath.addLine(to: prevView)
                        handlesToDraw.append((prevView, .previous))
                    }
                    if let next = pt.nextControl {
                        let nextView = next.applying(layerToView)
                        stalkPath.move(to: anchorView)
                        stalkPath.addLine(to: nextView)
                        handlesToDraw.append((nextView, .next))
                    }

                    if !handlesToDraw.isEmpty {
                        context.saveGState()
                        // Subordinate dark contrast line under handle stalk
                        context.addPath(stalkPath)
                        context.setStrokeColor(NSColor.black.withAlphaComponent(0.35).cgColor)
                        context.setLineWidth(2)
                        context.strokePath()

                        // Subordinate accent line for stalk
                        context.addPath(stalkPath)
                        context.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor)
                        context.setLineWidth(1)
                        context.strokePath()

                        for item in handlesToDraw {
                            let handle = SelectedHandle(anchorIndex: anchorIdx, side: item.side)
                            let vState = session.visualStateForHandle(handle, in: layer.id)
                            let handleRect = CGRect(x: item.point.x - 3.5, y: item.point.y - 3.5, width: 7, height: 7)

                            // Hover halo if hovered
                            if vState.isHovered {
                                let hoverRect = CGRect(x: item.point.x - 5.5, y: item.point.y - 5.5, width: 11, height: 11)
                                context.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor)
                                context.setLineWidth(2)
                                context.strokeEllipse(in: hoverRect)
                            }

                            // Dark contrast outline
                            context.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
                            context.setLineWidth(2.5)
                            context.strokeEllipse(in: handleRect)

                            if vState.isSelected {
                                // Selected handle: filled accent circle with white inner border
                                context.setFillColor(NSColor.controlAccentColor.cgColor)
                                context.fillEllipse(in: handleRect)
                                context.setStrokeColor(NSColor.white.cgColor)
                                context.setLineWidth(1.5)
                                context.strokeEllipse(in: handleRect)
                            } else {
                                // Unselected handle: white circle with accent border
                                context.setFillColor(NSColor.white.cgColor)
                                context.fillEllipse(in: handleRect)
                                context.setStrokeColor(NSColor.controlAccentColor.cgColor)
                                context.setLineWidth(1.5)
                                context.strokeEllipse(in: handleRect)
                            }
                        }
                        context.restoreGState()
                    }
                }

                // Draw Anchor Point
                let anchorVState = session.visualStateForAnchor(anchorIdx, in: layer.id)
                let rect = CGRect(x: anchorView.x - 3.5, y: anchorView.y - 3.5, width: 7, height: 7)

                // Hover halo if hovered
                if anchorVState.isHovered {
                    let hoverRect = CGRect(x: anchorView.x - 5.5, y: anchorView.y - 5.5, width: 11, height: 11)
                    context.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor)
                    context.setLineWidth(2)
                    context.stroke(hoverRect)
                }

                // Dark contrast backing
                context.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor)
                context.setLineWidth(2.5)
                context.stroke(rect)

                if anchorVState.isSelected {
                    // Selected anchor: solid accent fill with crisp white border
                    context.setFillColor(NSColor.controlAccentColor.cgColor)
                    context.fill(rect)
                    context.setStrokeColor(NSColor.white.cgColor)
                    context.setLineWidth(1.5)
                    context.stroke(rect)
                } else {
                    // Unselected anchor: visually neutral, hollow (document content shows through), crisp white inner border
                    context.setStrokeColor(NSColor.white.cgColor)
                    context.setLineWidth(1.5)
                    context.stroke(rect)
                }
            }
        }

        // Draw hover feedback for an anchor on a different visible vector layer if targeted
        if let hover = session.directSelectionHoverTarget,
           hover.layerID != layer.id,
           let hoverLayer = document.layers.first(where: { $0.id == hover.layerID && $0.isVisible && $0.vector != nil }),
           let hoverVector = hoverLayer.vector {
            let hLayerToDoc = hoverLayer.transform.layerToDocument
            var hLayerToView = hLayerToDoc.concatenating(docToView)
            let s = hover.anchorIndex.subpathIndex
            let a = hover.anchorIndex.anchorIndex
            if hoverVector.subpaths.indices.contains(s),
               hoverVector.subpaths[s].points.indices.contains(a) {
                let pt = hoverVector.subpaths[s].points[a]
                let ptDoc: CGPoint
                switch hover.kind {
                case .anchor:
                    ptDoc = pt.anchor
                case .handle(.previous):
                    ptDoc = pt.previousControl ?? pt.anchor
                case .handle(.next):
                    ptDoc = pt.nextControl ?? pt.anchor
                }
                let ptView = ptDoc.applying(hLayerToView)
                let hoverRect = CGRect(x: ptView.x - 5.5, y: ptView.y - 5.5, width: 11, height: 11)
                context.saveGState()
                context.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor)
                context.setLineWidth(2)
                if case .handle = hover.kind {
                    context.strokeEllipse(in: hoverRect)
                } else {
                    context.stroke(hoverRect)
                }
                context.restoreGState()
            }
        }

        context.restoreGState()
    }
}
