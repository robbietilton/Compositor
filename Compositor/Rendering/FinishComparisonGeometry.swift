import Foundation
import CoreGraphics

nonisolated enum FinishComparisonMode: String, CaseIterable, Identifiable {
    case single = "Single", split = "Split", sideBySide = "Side by Side"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .single: "rectangle"
        case .split: "rectangle.lefthalf.filled"
        case .sideBySide: "rectangle.split.2x1"
        }
    }
}

/// Shared geometry for screen rendering, divider hit testing and synchronized zoom anchoring.
nonisolated enum FinishComparisonGeometry {
    static func panes(in bounds: CGRect) -> [CGRect] {
        let half = max(0, (bounds.width - 12) / 2)
        return [CGRect(x: bounds.minX, y: bounds.minY, width: half, height: bounds.height),
                CGRect(x: bounds.maxX - half, y: bounds.minY, width: half, height: bounds.height)]
    }

    static func zoom(document: CGSize, view: CGSize, backingScale: CGFloat,
                     sideBySide: Bool, fill: Bool) -> CGFloat {
        let width = sideBySide ? max(1, (view.width - 12) / 2) : view.width
        let padding: CGFloat = fill ? 0 : 48
        let x = max(1, width - padding) / max(1, document.width)
        let y = max(1, view.height - padding) / max(1, document.height)
        let value = (fill ? max(x, y) : min(x, y)) * backingScale
        return min(CanvasViewport.zoomRange.upperBound, max(CanvasViewport.zoomRange.lowerBound, value))
    }

    /// Both drawing and navigation use exactly this device-pixel-aligned translation.
    static func paneOffset(_ pane: CGRect, in bounds: CGRect, backingScale: CGFloat) -> CGFloat {
        let scale = max(1, backingScale)
        return ((pane.midX - bounds.midX) * scale).rounded() / scale
    }

    static func centeredAnchor(_ point: CGPoint, view: CGSize, backingScale: CGFloat = 1) -> CGPoint {
        let panes = panes(in: CGRect(origin: .zero, size: view))
        let pane = point.x < view.width / 2 ? panes[0] : panes[1]
        let offset = paneOffset(pane, in: CGRect(origin: .zero, size: view), backingScale: backingScale)
        return CGPoint(x: point.x - offset, y: point.y)
    }
}
