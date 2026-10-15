import Foundation
import CoreGraphics

enum GIFTimelineLayout {
    static let frameWidth: CGFloat = 88
    static let frameHeight: CGFloat = 74
    static let frameStride: CGFloat = 96
    static let padding: CGFloat = 12

    static func centeringInset(contentWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        max(0, (viewportWidth - contentWidth) / 2)
    }

    /// Insertion gaps and settling previews use viewport coordinates; drop thresholds use strip coordinates.
    static func frameCenterX(at position: Int, contentWidth: CGFloat, viewportWidth: CGFloat, scrollOffset: CGFloat) -> CGFloat {
        centeringInset(contentWidth: contentWidth, viewportWidth: viewportWidth)
            + padding + CGFloat(position) * frameStride + frameWidth / 2 - scrollOffset
    }

    /// Points use document-view coordinates, including the scroll offset and short-strip centering.
    /// Intersect the pointer segment so fast mouse or trackpad drags do not skip thumbnails.
    static func selectionPositions(from start: CGPoint, to end: CGPoint, count: Int,
                                   contentWidth: CGFloat, viewportSize: CGSize, scrollOffset: CGFloat = 0) -> Set<Int> {
        guard count > 0, viewportSize.width > 0, viewportSize.height > 0,
              [start.x, start.y, end.x, end.y, contentWidth, viewportSize.width, viewportSize.height, scrollOffset]
            .allSatisfy(\.isFinite) else { return [] }
        let inset = centeringInset(contentWidth: contentWidth, viewportWidth: viewportSize.width) + padding
        let first = Int(max(0, min(CGFloat(count - 1), ((min(start.x, end.x) - inset) / frameStride).rounded(.down))))
        let last = Int(max(0, min(CGFloat(count - 1), ((max(start.x, end.x) - inset) / frameStride).rounded(.down))))
        let y = (viewportSize.height - frameHeight) / 2
        let viewport = CGRect(x: scrollOffset, y: 0, width: viewportSize.width, height: viewportSize.height)
        return Set((first...last).filter { position in
            let rect = CGRect(x: inset + CGFloat(position) * frameStride, y: y, width: frameWidth, height: frameHeight)
                .intersection(viewport)
            guard !rect.isNull, !rect.isEmpty else { return false }
            var lower: CGFloat = 0, upper: CGFloat = 1
            for (origin, delta, minimum, maximum) in [
                (start.x, end.x - start.x, rect.minX, rect.maxX),
                (start.y, end.y - start.y, rect.minY, rect.maxY)
            ] {
                if delta == 0 {
                    if origin < minimum || origin > maximum { return false }
                } else {
                    let a = (minimum - origin) / delta, b = (maximum - origin) / delta
                    lower = max(lower, min(a, b))
                    upper = min(upper, max(a, b))
                    if lower > upper { return false }
                }
            }
            return true
        })
    }

    /// A small dead band keeps adjacent frames from oscillating under a stationary pointer.
    static func destination(for centerX: CGFloat, count: Int, current: Int) -> Int {
        guard count > 0, centerX.isFinite else { return current }
        let position = (centerX - padding - frameWidth / 2) / frameStride
        let threshold = 0.5 + 4 / frameStride
        guard abs(position - CGFloat(current)) > threshold else { return current }
        return Int(min(CGFloat(count - 1), max(0, position.rounded())))
    }
}
