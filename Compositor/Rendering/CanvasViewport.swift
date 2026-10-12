import Foundation
import CoreGraphics

/// Document: pixels with top-left origin. View: AppKit points. Zoom 1 means actual display pixels.
struct CanvasViewport: Equatable {
    var viewSize: CGSize = .zero
    /// The part of the view the glass header, rulers and side panels leave clear, in view coordinates.
    /// The document is fitted and centered within it; nil until the layout reports it.
    var safeArea: CGRect? = nil
    var backingScale: CGFloat = 1
    private(set) var zoom: CGFloat = 1
    var pan: CGSize = .zero
    private(set) var followsFit = true
    static let zoomRange: ClosedRange<CGFloat> = 0.001...32
    static let keyboardZoomLevels: [CGFloat] = [0.125, 1.0 / 6.0, 0.25, 1.0 / 3.0,
                                              0.5, 2.0 / 3.0, 1, 1.25, 1.5, 2,
                                              3, 4, 5, 6, 8, 12, 16]
    var pointsPerPixel: CGFloat { zoom / backingScale }
    var center: CGPoint { safeArea.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2) }

    func documentRect(_ size: CGSize) -> CGRect {
        let scaled = CGSize(width: size.width * pointsPerPixel, height: size.height * pointsPerPixel)
        return CGRect(x: center.x - scaled.width / 2 + pan.width,
                      y: center.y - scaled.height / 2 + pan.height,
                      width: scaled.width, height: scaled.height)
    }

    func documentPoint(from point: CGPoint, documentSize: CGSize) -> CGPoint {
        let origin = documentRect(documentSize).origin
        return CGPoint(x: (point.x - origin.x) / pointsPerPixel, y: (point.y - origin.y) / pointsPerPixel)
    }

    func viewPoint(from point: CGPoint, documentSize: CGSize) -> CGPoint {
        let origin = documentRect(documentSize).origin
        return CGPoint(x: origin.x + point.x * pointsPerPixel, y: origin.y + point.y * pointsPerPixel)
    }

    mutating func fit(documentSize: CGSize) {
        let area = safeArea ?? CGRect(origin: .zero, size: viewSize)
        guard area.width > 0, area.height > 0 else { followsFit = true; return }
        zoom = clamp(min(max(1, area.width - 96) / documentSize.width,
                         max(1, area.height - 96) / documentSize.height) * backingScale)
        pan = .zero
        followsFit = true
    }

    mutating func resize(to size: CGSize, backingScale newScale: CGFloat, documentSize: CGSize?, safeArea: CGRect? = nil) {
        // Preserve the center document point when moving between displays.
        let oldScale = pointsPerPixel
        viewSize = size
        self.safeArea = safeArea
        backingScale = max(1, newScale)
        if followsFit, let documentSize {
            fit(documentSize: documentSize)
        } else {
            let ratio = pointsPerPixel / oldScale
            pan = CGSize(width: pan.width * ratio, height: pan.height * ratio)
        }
    }

    /// Whether a point sits on the ruler strips at the top and left of the safe area, where a guide
    /// being dragged is let go to delete it. Before any safe area is reported, the whole view is clear.
    func isOverRuler(_ point: CGPoint) -> Bool {
        guard let safeArea else { return point.x < 0 || point.y < 0 }
        return point.x < safeArea.minX || point.y < safeArea.minY
    }

    mutating func setZoom(_ value: CGFloat, anchoredAt anchor: CGPoint, documentSize: CGSize) {
        guard value.isFinite else { return }
        let pixel = documentPoint(from: anchor, documentSize: documentSize)
        zoom = clamp(value)
        let moved = viewPoint(from: pixel, documentSize: documentSize)
        pan.width += anchor.x - moved.x
        pan.height += anchor.y - moved.y
        followsFit = false
    }

    func keyboardZoomTarget(by step: Int) -> CGFloat {
        guard step != 0 else { return zoom }
        let tolerance = max(0.000000001, abs(zoom) * 0.000000001)
        if step > 0 {
            return Self.keyboardZoomLevels.first { $0 > zoom + tolerance } ?? zoom
        }
        return Self.keyboardZoomLevels.last { $0 < zoom - tolerance } ?? zoom
    }

    mutating func translate(by delta: CGSize) {
        pan.width += delta.width
        pan.height += delta.height
        followsFit = false
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, value))
    }
}
