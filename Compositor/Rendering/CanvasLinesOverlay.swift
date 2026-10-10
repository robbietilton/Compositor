import AppKit

/// The lines drawn over the canvas's pixels — the pixel grid when zoomed far in, and the box a new text frame is being
/// dragged out as — in a layer of their own above them, so they look the same whether the GPU or Core Graphics draws
/// the pixels underneath (see `drawOnGPU`).
final class CanvasLinesOverlay: NSView {
    var drawLines: ((NSRect) -> Void)?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The canvas sets `needsDisplay` on every draw, so a small stroke would repaint this whole layer.
    /// While that draw is in progress, keep only the rect it is painting. `drawLines` already limits the
    /// grid to the rect it is given.
    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            guard newValue else { super.needsDisplay = false; return }
            guard let superview else { super.needsDisplay = true; return }
            var rects: UnsafePointer<NSRect>?
            var count = 0
            superview.getRectsBeingDrawn(&rects, count: &count)
            guard count > 0, let rects else { super.needsDisplay = true; return }
            var partial: [NSRect] = []
            for index in 0..<count {
                let region = convert(rects[index], from: superview).intersection(bounds)
                if region.isNull || region.isEmpty { continue }
                if region.contains(bounds) { super.needsDisplay = true; return }
                partial.append(region)
            }
            guard !partial.isEmpty else { return }
            for region in partial { setNeedsDisplay(region) }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.clip(to: dirtyRect)
        drawLines?(dirtyRect)
    }
}
