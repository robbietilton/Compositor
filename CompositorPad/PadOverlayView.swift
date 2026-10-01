import Observation
import UIKit

/// What's drawn over the canvas: the transform box and its handles, guides, the crop frame, marching ants and the
/// lines a move snaps to, drawn by the editor's own `CanvasOverlay`, as the Mac's canvas draws them; a box being
/// dragged out for new text; and the brush cursor.
final class PadOverlayView: UIView {
    let overlay: CanvasOverlay
    /// A box being dragged out for new text, in document pixels.
    var textBox: CGRect? { didSet { if textBox != oldValue { setNeedsDisplay() } } }
    /// The brush cursor, in the view's points, as the Mac's canvas draws it: the brush's circle, `diameter` across, at
    /// `point`, with a crosshair in it where the Mac shows its crosshair pointer, or Clone Stamp's `preview` of what it
    /// would stamp, at `previewOpacity` and cut to one click's `tip`; and Clone Stamp's source crosshair at `sample`.
    struct BrushCursor {
        var point: CGPoint?
        var diameter: CGFloat
        var crosshair: Bool
        var sample: CGPoint?
        var preview: CGImage?
        var previewOpacity: CGFloat
        var tip: CGImage?

        var circle: CGRect? { point.map { CGRect(x: $0.x - diameter / 2, y: $0.y - diameter / 2, width: diameter, height: diameter) } }

        /// What it covers, to be drawn again when it moves or changes.
        var areas: [CGRect] {
            let reach = BrushCursorDrawing.crosshairReach + 3
            return [circle?.insetBy(dx: -3, dy: -3), point.map { CGRect(x: $0.x - reach, y: $0.y - reach, width: reach * 2, height: reach * 2) },
                    sample.map { CGRect(x: $0.x - reach, y: $0.y - reach, width: reach * 2, height: reach * 2) }].compactMap { $0 }
        }

        func same(as other: BrushCursor?) -> Bool {
            guard let other else { return false }
            return point == other.point && diameter == other.diameter && crosshair == other.crosshair && sample == other.sample
                && preview === other.preview && previewOpacity == other.previewOpacity && tip === other.tip
        }
    }
    /// Only the areas the cursor leaves and moves to are drawn again, as it follows the brush.
    var brushCursor: BrushCursor? {
        didSet {
            if let brushCursor, brushCursor.same(as: oldValue) { return }
            if brushCursor == nil, oldValue == nil { return }
            for area in (oldValue?.areas ?? []) + (brushCursor?.areas ?? []) { setNeedsDisplay(area) }
        }
    }

    init(session: EditorSession) {
        overlay = CanvasOverlay(session: session)
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
        overlay.needsDisplay = { [weak self] in self?.setNeedsDisplay() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Draws, and draws again when anything it read from the editor changes. The lines a move snaps to aren't
    /// observed; the canvas asks for those itself as it drags.
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let marching = withObservationTracking {
            overlay.draw(in: context, bounds: bounds, deviceScale: traitCollection.displayScale)
            drawTextBox(in: context)
            return overlay.session.displayedSelection?.isEmpty == false
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.setNeedsDisplay() }
        }
        march(marching && window != nil)
        if let cursor = brushCursor {
            BrushCursorDrawing.draw(circle: cursor.circle, preview: cursor.preview, previewOpacity: cursor.previewOpacity,
                                    tip: cursor.tip, hardness: nil, marker: cursor.sample, in: context)
            if cursor.crosshair, let point = cursor.point { BrushCursorDrawing.strokeCrosshair(at: point, in: context) }
        }
    }

    /// The box for new text, outlined in the accent color, as the Mac draws it.
    private func drawTextBox(in context: CGContext) {
        let session = overlay.session
        guard let rect = textBox, let document = session.document else { return }
        let origin = session.viewport.viewPoint(from: rect.origin, documentSize: document.size)
        let scale = session.viewport.pointsPerPixel
        context.setStrokeColor(Platform.accentColor.cgColor)
        context.setLineWidth(1)
        context.stroke(CGRect(origin: origin, size: CGSize(width: rect.width * scale, height: rect.height * scale)))
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { march(false) } else { setNeedsDisplay() }
    }

    private var antsTimer: Timer?

    /// The marching ants move a step every 0.12 seconds while there's a selection to show, as on the Mac.
    private func march(_ marching: Bool) {
        if marching, antsTimer == nil {
            let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.overlay.antsPhase = (self.overlay.antsPhase + 1).truncatingRemainder(dividingBy: 8)
                    self.setNeedsDisplay()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            antsTimer = timer
        } else if !marching, let timer = antsTimer {
            timer.invalidate()
            antsTimer = nil
        }
    }
}

extension TransformOverlayGeometry {
    /// What a touch at `point` grabs. A fingertip is broader than a pointer, so the nearest handle within `reach`
    /// counts, though less of it around a small box, which a finger should still move by pressing inside it; the edges
    /// count within a pointer's 10 points.
    func hit(touch point: CGPoint, reach: CGFloat = 22) -> TransformDrag.Mode? {
        let side = min(hypot(handles[2].x - handles[0].x, handles[2].y - handles[0].y),
                       hypot(handles[6].x - handles[0].x, handles[6].y - handles[0].y))
        let reach = min(reach, max(10, side / 3))
        var nearest: (mode: TransformDrag.Mode, distance: CGFloat)?
        func consider(_ mode: TransformDrag.Mode, at handle: CGPoint) {
            let distance = hypot(point.x - handle.x, point.y - handle.y)
            if distance <= reach, distance < nearest?.distance ?? .infinity { nearest = (mode, distance) }
        }
        if showsRotation { consider(.rotate, at: rotationHandle) }
        for (index, handle) in handles.enumerated() { consider(.resize(index), at: handle) }
        return nearest?.mode ?? hit(point)
    }
}
