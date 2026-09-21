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
        guard #available(macOS 15.0, *) else { return .crosshair }
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

    override func draw(_ dirtyRect: NSRect) {
        drawLayoutGrid()
        drawGuides()
        if session.tool == .crop { drawCrop() }
        else if let line = gradientLine { drawGradientLine(line) }
        else { drawTransformHandles() }
        drawSelection()
        drawLassoDraft()
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
              let path = selection.path.copy(using: &transform), let context = NSGraphicsContext.current?.cgContext else { return }
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
}
