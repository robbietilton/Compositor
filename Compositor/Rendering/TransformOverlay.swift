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
    }
}
