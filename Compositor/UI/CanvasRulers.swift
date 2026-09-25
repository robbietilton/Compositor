import AppKit
import SwiftUI

enum CanvasRuler {
    static let thickness: CGFloat = 18
}

struct CanvasRulerCorner: View {
    var body: some View {
        Rectangle()
            .fill(Color(white: 0.2))
            .overlay(alignment: .bottomTrailing) {
                Path { path in
                    path.move(to: CGPoint(x: 5, y: CanvasRuler.thickness - 4))
                    path.addLine(to: CGPoint(x: CanvasRuler.thickness - 4, y: 5))
                }
                .stroke(Color.white.opacity(0.28), lineWidth: 1)
            }
            .frame(width: CanvasRuler.thickness, height: CanvasRuler.thickness)
    }
}

struct CanvasRulerView: NSViewRepresentable {
    let session: EditorSession
    let axis: CanvasGuide.Axis

    func makeNSView(context: Context) -> CanvasRulerNSView {
        CanvasRulerNSView(session: session, axis: axis)
    }

    func updateNSView(_ view: CanvasRulerNSView, context: Context) {
        view.session = session
        view.axis = axis
        _ = session.viewport
        _ = session.document?.id
        _ = session.document?.size
        view.needsDisplay = true
    }
}

final class CanvasRulerNSView: NSView {
    var session: EditorSession
    var axis: CanvasGuide.Axis

    init(session: EditorSession, axis: CanvasGuide.Axis) {
        self.session = session
        self.axis = axis
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.unknown)
        setAccessibilityLabel(axis == .horizontal ? "Horizontal ruler" : "Vertical ruler")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.2, alpha: 1).setFill()
        bounds.fill()
        guard let document = session.document else { return }
        let size = document.size
        let scale = session.viewport.pointsPerPixel
        let step = Self.majorStep(pointsPerPixel: scale)
        let minor = step / 10
        let hairline = 1 / max(window?.backingScaleFactor ?? 1, 1)
        let tick = NSColor(white: 0.62, alpha: 1)
        let labels = NSColor(white: 0.78, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular),
            .foregroundColor: labels
        ]

        let start: CGFloat
        let end: CGFloat
        if axis == .horizontal {
            start = session.viewport.documentPoint(from: CGPoint(x: 0, y: 0), documentSize: size).x
            end = session.viewport.documentPoint(from: CGPoint(x: bounds.width, y: 0), documentSize: size).x
        } else {
            start = session.viewport.documentPoint(from: CGPoint(x: 0, y: 0), documentSize: size).y
            end = session.viewport.documentPoint(from: CGPoint(x: 0, y: bounds.height), documentSize: size).y
        }
        let first = floor(min(start, end) / minor) * minor
        let last = ceil(max(start, end) / minor) * minor
        guard minor > 0, last.isFinite, first.isFinite else { return }

        var value = first
        while value <= last + 0.001 {
            let view: CGFloat
            if axis == .horizontal {
                view = session.viewport.viewPoint(from: CGPoint(x: value, y: 0), documentSize: size).x
            } else {
                view = session.viewport.viewPoint(from: CGPoint(x: 0, y: value), documentSize: size).y
            }
            let remainder = abs(value.remainder(dividingBy: step))
            let isMajor = remainder < 0.001 || abs(remainder - step) < 0.001
            let isMid = !isMajor && (abs(value.remainder(dividingBy: step / 2)) < 0.001)
            let length: CGFloat = isMajor ? 8 : isMid ? 5 : 3
            tick.setFill()
            if axis == .horizontal {
                NSRect(x: view - hairline / 2, y: bounds.height - length, width: hairline, height: length).fill()
            } else {
                NSRect(x: bounds.width - length, y: view - hairline / 2, width: length, height: hairline).fill()
            }
            if isMajor {
                let text = Self.label(value)
                let drawn = text.size(withAttributes: attributes)
                if axis == .horizontal {
                    text.draw(at: CGPoint(x: view + 2, y: 0), withAttributes: attributes)
                } else {
                    // Vertical labels sit along the tick, rotated so they read downward.
                    let point = CGPoint(x: 1, y: view + 2)
                    NSGraphicsContext.current?.saveGraphicsState()
                    let transform = NSAffineTransform()
                    transform.translateX(by: point.x, yBy: point.y)
                    transform.rotate(byDegrees: -90)
                    transform.concat()
                    text.draw(at: CGPoint(x: -drawn.width, y: 0), withAttributes: attributes)
                    NSGraphicsContext.current?.restoreGraphicsState()
                }
            }
            value += minor
        }
        NSColor(white: 0.08, alpha: 1).setFill()
        if axis == .horizontal {
            NSRect(x: 0, y: bounds.height - hairline, width: bounds.width, height: hairline).fill()
        } else {
            NSRect(x: bounds.width - hairline, y: 0, width: hairline, height: bounds.height).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(canvasView())
        guard session.canEditGuides, let position = documentPosition(for: event) else { return }
        session.beginGuideCreation(axis: axis, at: position)
        (axis == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard session.guideDrag != nil, let position = documentPosition(for: event) else { return }
        session.moveGuideDrag(to: position)
        (axis == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
    }

    override func mouseUp(with event: NSEvent) {
        guard session.guideDrag != nil else { return }
        session.finishGuideDrag(delete: isOverRuler(event))
        NSCursor.arrow.set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: axis == .vertical ? .resizeLeftRight : .resizeUpDown)
    }

    private func canvasView() -> CanvasView? {
        func find(_ view: NSView) -> CanvasView? {
            if let canvas = view as? CanvasView { return canvas }
            return view.subviews.compactMap(find).first
        }
        return window?.contentView.flatMap(find)
    }

    private func documentPosition(for event: NSEvent) -> Double? {
        guard let canvas = canvasView() else { return nil }
        let point = canvas.convert(event.locationInWindow, from: nil)
        return canvas.documentPosition(axis: axis, at: point)
    }

    private func isOverRuler(_ event: NSEvent) -> Bool {
        guard let canvas = canvasView() else { return true }
        return canvas.isOverRuler(canvas.convert(event.locationInWindow, from: nil))
    }

    /// Numbered ticks about 70 points apart, using 1-2-5 steps in document pixels.
    static func majorStep(pointsPerPixel: CGFloat) -> CGFloat {
        let target = 70 / max(pointsPerPixel, 0.0001)
        let nice: [CGFloat] = [1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1_000, 2_000, 2_500, 5_000, 10_000, 20_000, 25_000]
        return nice.first { $0 >= target } ?? 50_000
    }

    static func label(_ value: CGFloat) -> NSString {
        let rounded = value.rounded()
        return (rounded == 0 ? "0" : String(Int(rounded))) as NSString
    }
}
