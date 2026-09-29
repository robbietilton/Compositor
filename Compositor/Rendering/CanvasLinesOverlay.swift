import AppKit

/// The lines drawn over the canvas's pixels — the pixel grid when zoomed far in, and the box a new text frame is being
/// dragged out as — in a layer of their own above them, so they look the same whether the GPU or Core Graphics draws
/// the pixels underneath (see `drawOnGPU`).
final class CanvasLinesOverlay: NSView {
    var drawLines: ((NSRect) -> Void)?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { drawLines?(dirtyRect) }
}
