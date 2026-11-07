import AppKit

extension TransformOverlayGeometry {
    func resizeCursor(for index: Int) -> NSCursor {
        let angle = atan2(handles[2].y - handles[0].y, handles[2].x - handles[0].x)
        let offsets: [CGFloat] = [.pi / 4, .pi / 2, 3 * .pi / 4, 0, .pi / 4, .pi / 2, 3 * .pi / 4, 0]
        let direction = (Int(((angle + offsets[index]) / (.pi / 4)).rounded()) % 4 + 4) % 4
        let positions: [NSCursor.FrameResizePosition] = [.right, .bottomRight, .bottom, .topRight]
        return .frameResize(position: positions[direction], directions: [.inward, .outward])
    }
}

/// Separate overlay so selecting a layer does not redraw image pixels. What it draws is `CanvasOverlay`'s, which the
/// iPad's canvas draws too.
final class TransformOverlay: NSView {
    let session: EditorSession
    private let overlay: CanvasOverlay
    init(session: EditorSession) {
        self.session = session
        overlay = CanvasOverlay(session: session)
        super.init(frame: .zero)
        setAccessibilityElement(false)
        overlay.needsDisplay = { [weak self] in self?.needsDisplay = true }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var geometry: TransformOverlayGeometry? { overlay.geometry }
    /// Pending gradient endpoints in view coordinates.
    var gradientLine: (start: CGPoint, end: CGPoint)? { overlay.gradientLine }
    /// Progressive Blur's line in view coordinates while its panel is open, and whether it's radial.
    var progressiveLine: (start: CGPoint, end: CGPoint, radial: Bool)? { overlay.progressiveLine }
    var antsPhase: CGFloat {
        get { overlay.antsPhase }
        set { overlay.antsPhase = newValue }
    }
    var cropViewRect: CGRect? { overlay.cropViewRect }
    var cropHandles: [CGPoint] { overlay.cropHandles }
    var cropResizeRegions: [(index: Int, rect: CGRect)] { overlay.cropResizeRegions }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        overlay.draw(in: context, bounds: bounds, deviceScale: window?.backingScaleFactor ?? 2)
        drawDistances()
        drawDragOutSize()
    }

    /// A Marquee's or shape's size, a line's length, or a resized layer's size, as it's dragged: in a dark label just
    /// above and right of the point being dragged, the other side of it near the view's edge.
    private func drawDragOutSize() {
        guard let size = session.dragOutSize, let transform = documentToView else { return }
        let corner = size.corner.applying(transform)
        let text = NSAttributedString(string: size.text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white,
        ])
        let textSize = text.size()
        var label = CGRect(x: corner.x + 14, y: corner.y - 14 - (textSize.height + 6), width: textSize.width + 12, height: textSize.height + 6)
        if label.maxX > bounds.maxX - 4 { label.origin.x = corner.x - 14 - label.width }
        if label.minY < bounds.minY + 4 { label.origin.y = corner.y + 14 }
        NSColor(white: 0.12, alpha: 0.9).setFill()
        NSBezierPath(roundedRect: label, xRadius: 4, yRadius: 4).fill()
        text.draw(at: CGPoint(x: label.minX + 6, y: label.minY + 3))
    }

    /// The Move tool's pixel gaps: a line with an end bar at each side, and its length in a label on it, the same
    /// size at any zoom.
    private func drawDistances() {
        let lines = session.distanceLines
        guard !lines.isEmpty, let transform = documentToView, let context = NSGraphicsContext.current?.cgContext else { return }
        let color = NSColor.systemPink
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(1)
        for line in lines {
            let start = (line.horizontal ? CGPoint(x: line.from, y: line.across) : CGPoint(x: line.across, y: line.from)).applying(transform)
            let end = (line.horizontal ? CGPoint(x: line.to, y: line.across) : CGPoint(x: line.across, y: line.to)).applying(transform)
            context.move(to: start)
            context.addLine(to: end)
            for point in [start, end] {
                context.move(to: line.horizontal ? CGPoint(x: point.x, y: point.y - 4) : CGPoint(x: point.x - 4, y: point.y))
                context.addLine(to: line.horizontal ? CGPoint(x: point.x, y: point.y + 4) : CGPoint(x: point.x + 4, y: point.y))
            }
        }
        context.strokePath()
        context.restoreGState()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white,
        ]
        for line in lines {
            let start = (line.horizontal ? CGPoint(x: line.from, y: line.across) : CGPoint(x: line.across, y: line.from)).applying(transform)
            let end = (line.horizontal ? CGPoint(x: line.to, y: line.across) : CGPoint(x: line.across, y: line.to)).applying(transform)
            let text = NSAttributedString(string: "\(Int(line.length.rounded())) px", attributes: attributes)
            let size = text.size()
            let label = CGRect(x: (start.x + end.x) / 2 - size.width / 2 - 5, y: (start.y + end.y) / 2 - size.height / 2 - 2,
                               width: size.width + 10, height: size.height + 4)
            color.setFill()
            NSBezierPath(roundedRect: label, xRadius: 4, yRadius: 4).fill()
            text.draw(at: CGPoint(x: label.minX + 5, y: label.minY + 2))
        }
    }

    private var documentToView: CGAffineTransform? {
        guard let document = session.document else { return nil }
        let origin = session.viewport.documentRect(document.size).origin
        let scale = session.viewport.pointsPerPixel
        return CGAffineTransform(translationX: origin.x, y: origin.y).scaledBy(x: scale, y: scale)
    }
}
