import AppKit

final class BrushCursorOverlay: NSView {
    private var circle: CGRect?
    /// Clone Stamp's source crosshair, in view points.
    private var marker: CGPoint?
    /// Clone Stamp's preview of what a click would stamp, drawn inside the circle.
    private var preview: CGImage?
    private var previewOpacity: CGFloat = 1
    /// One click's coverage (white with alpha), which shapes the preview's edge to the brush hardness.
    private var tip: CGImage?
    /// While hardness is being dragged: the fraction of the radius painted at full strength, shown as an inner ring.
    private var hardness: CGFloat?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func update(point: CGPoint?, diameter: CGFloat, sample: CGPoint? = nil, preview: CGImage? = nil,
                previewOpacity: CGFloat = 1, tip: CGImage? = nil, hardness: CGFloat? = nil) {
        let next = point.map { CGRect(x: $0.x - diameter / 2, y: $0.y - diameter / 2, width: diameter, height: diameter) }
        if circle != next || self.preview !== preview || self.previewOpacity != previewOpacity || self.tip !== tip || self.hardness != hardness {
            if let circle { setNeedsDisplay(circle.insetBy(dx: -3, dy: -3)) }
            circle = next
            self.preview = preview
            self.previewOpacity = previewOpacity
            self.tip = tip
            self.hardness = hardness
            if let next { setNeedsDisplay(next.insetBy(dx: -3, dy: -3)) }
        }
        if marker != sample {
            let reach = BrushCursorDrawing.crosshairReach + 3
            if let marker { setNeedsDisplay(CGRect(x: marker.x - reach, y: marker.y - reach, width: reach * 2, height: reach * 2)) }
            marker = sample
            if let sample { setNeedsDisplay(CGRect(x: sample.x - reach, y: sample.y - reach, width: reach * 2, height: reach * 2)) }
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        BrushCursorDrawing.draw(circle: circle, preview: preview, previewOpacity: previewOpacity, tip: tip, hardness: hardness,
                                marker: marker, in: context)
    }
}
