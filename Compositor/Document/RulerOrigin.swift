import CoreGraphics
import Foundation

/// Where the rulers count from, set by dragging out of the corner where they meet, as in Photoshop. Kept for the
/// session only, and only for the canvas it was set on: a different document, or the same one at a new size, counts
/// from its top-left corner again.
struct RulerOrigin: Equatable {
    let documentID: UUID
    let canvas: CGSize
    /// Document pixels.
    let point: CGPoint
}

extension EditorSession {
    /// The document pixel the rulers read 0, 0 at.
    var rulerZero: CGPoint {
        guard let origin = rulerOrigin, let document, origin.documentID == document.id, origin.canvas == document.size
        else { return .zero }
        return origin.point
    }

    var canMoveRulerOrigin: Bool { document != nil && !showsBusy }

    /// Pressing in the rulers' corner starts a drag; nothing changes until it is released over the canvas.
    func beginRulerOriginDrag(at point: CGPoint) {
        guard canMoveRulerOrigin else { return }
        rulerOriginDrag = snappedRulerOrigin(point)
        refreshCanvasPreview?()
    }

    func moveRulerOriginDrag(to point: CGPoint) {
        guard rulerOriginDrag != nil else { return }
        rulerOriginDrag = snappedRulerOrigin(point)
        refreshCanvasPreview?()
    }

    /// `cancel` is true when the drag ends back on the rulers (a plain click in the corner) or Escape is pressed.
    func finishRulerOriginDrag(cancel: Bool) {
        guard let point = rulerOriginDrag else { return }
        rulerOriginDrag = nil
        if !cancel { setRulerZero(point) }
        refreshCanvasPreview?()
    }

    /// Double-clicking the corner: the rulers count from the canvas's top-left corner again.
    func resetRulerOrigin() {
        rulerOriginDrag = nil
        rulerOrigin = nil
        refreshCanvasPreview?()
    }

    func setRulerZero(_ point: CGPoint) {
        guard let document, point.x.isFinite, point.y.isFinite else { return }
        rulerOrigin = point == .zero ? nil : RulerOrigin(documentID: document.id, canvas: document.size, point: point)
    }

    /// The pointer's spot in whole document pixels, pulled onto whatever View › Snap To lines up with, as a guide is.
    private func snappedRulerOrigin(_ point: CGPoint) -> CGPoint {
        CGPoint(x: CGFloat(snappedGuidePosition(Double(point.x), axis: .vertical, excluding: nil)).rounded(),
                y: CGFloat(snappedGuidePosition(Double(point.y), axis: .horizontal, excluding: nil)).rounded())
    }
}
