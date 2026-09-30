import CoreGraphics

/// Where the whole document sits in the Navigator's box (fitted, centred, its proportions kept), and the
/// conversions between that picture and document pixels.
struct NavigatorGeometry: Equatable {
    let documentSize: CGSize
    let box: CGSize

    var imageRect: CGRect {
        guard documentSize.width > 0, documentSize.height > 0, box.width > 0, box.height > 0 else { return .zero }
        let scale = min(box.width / documentSize.width, box.height / documentSize.height)
        let size = CGSize(width: documentSize.width * scale, height: documentSize.height * scale)
        return CGRect(x: (box.width - size.width) / 2, y: (box.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// Box points per document pixel.
    private var scale: CGFloat { documentSize.width > 0 ? imageRect.width / documentSize.width : 0 }

    func thumbnailRect(for documentRect: CGRect) -> CGRect {
        let image = imageRect
        return CGRect(x: image.minX + documentRect.minX * scale, y: image.minY + documentRect.minY * scale,
                      width: documentRect.width * scale, height: documentRect.height * scale)
    }

    /// The document pixel under a point in the box, held to the document's edges.
    func documentPoint(for point: CGPoint) -> CGPoint {
        guard scale > 0 else { return .zero }
        let image = imageRect
        return CGPoint(x: min(max((point.x - image.minX) / scale, 0), documentSize.width),
                       y: min(max((point.y - image.minY) / scale, 0), documentSize.height))
    }
}

extension CanvasViewport {
    /// The part of the document the canvas shows, in document pixels. It reaches past the document's edges when the
    /// canvas shows more than the document.
    func visibleDocumentRect(documentSize: CGSize) -> CGRect {
        let topLeft = documentPoint(from: .zero, documentSize: documentSize)
        let bottomRight = documentPoint(from: CGPoint(x: viewSize.width, y: viewSize.height), documentSize: documentSize)
        return CGRect(x: min(topLeft.x, bottomRight.x), y: min(topLeft.y, bottomRight.y),
                      width: abs(bottomRight.x - topLeft.x), height: abs(bottomRight.y - topLeft.y))
    }

    /// Scrolls so `point` (document pixels) is in the middle of the canvas, at the same zoom. Goes through
    /// `translate(by:)` so the view stops following Fit, as any scroll the person makes does.
    mutating func centerView(on point: CGPoint, documentSize: CGSize) {
        let scale = pointsPerPixel
        let target = CGSize(width: documentSize.width * scale / 2 - point.x * scale,
                            height: documentSize.height * scale / 2 - point.y * scale)
        translate(by: CGSize(width: target.width - pan.width, height: target.height - pan.height))
    }
}
