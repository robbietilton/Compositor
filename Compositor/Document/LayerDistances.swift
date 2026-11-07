import CoreGraphics
import Foundation

/// A gap shown on the canvas: along x (`horizontal`) or y from `from` to `to`, at `across` on the other axis, in
/// document pixels.
nonisolated struct DistanceLine: Equatable {
    var horizontal: Bool
    var from: CGFloat
    var to: CGFloat
    var across: CGFloat
    var length: CGFloat { to - from }
}

/// The pixel gaps the Move tool shows: while a layer is dragged, and with Command held over another layer.
nonisolated enum LayerDistances {
    /// While `box` moves: from each of its sides to the nearest edge facing it, of a layer level with it or the canvas.
    static func moving(_ box: CGRect, among others: [CGRect], canvas: CGSize) -> [DistanceLine] {
        let page = CGRect(origin: .zero, size: canvas)
        var lines: [DistanceLine] = []
        for horizontal in [true, false] {
            let level = (others + [page]).filter { horizontal ? overlap($0.minY, $0.maxY, box.minY, box.maxY) : overlap($0.minX, $0.maxX, box.minX, box.maxX) }
            let low = horizontal ? box.minX : box.minY, high = horizontal ? box.maxX : box.maxY
            // Each side: the closest edge past it, and the middle of what the two have in common across.
            var before: (edge: CGFloat, rect: CGRect)?, after: (edge: CGFloat, rect: CGRect)?
            for rect in level {
                for edge in horizontal ? [rect.minX, rect.maxX] : [rect.minY, rect.maxY] {
                    if edge <= low, edge > (before?.edge ?? -.infinity) { before = (edge, rect) }
                    if edge >= high, edge < (after?.edge ?? .infinity) { after = (edge, rect) }
                }
            }
            if let before, low - before.edge >= 0.5 {
                lines.append(DistanceLine(horizontal: horizontal, from: before.edge, to: low, across: middle(box, before.rect, horizontal: horizontal)))
            }
            if let after, after.edge - high >= 0.5 {
                lines.append(DistanceLine(horizontal: horizontal, from: high, to: after.edge, across: middle(box, after.rect, horizontal: horizontal)))
            }
        }
        return lines
    }

    /// Between the selected `box` and `other`: the gap across each axis they're apart on; where they overlap, from
    /// each side of one to the same side of the other.
    static func between(_ box: CGRect, _ other: CGRect) -> [DistanceLine] {
        var gaps: [DistanceLine] = [], insets: [DistanceLine] = []
        for horizontal in [true, false] {
            let (low, high) = horizontal ? (box.minX, box.maxX) : (box.minY, box.maxY)
            let (otherLow, otherHigh) = horizontal ? (other.minX, other.maxX) : (other.minY, other.maxY)
            let across = middle(box, other, horizontal: horizontal)
            if otherLow >= high {
                gaps.append(DistanceLine(horizontal: horizontal, from: high, to: otherLow, across: across))
            } else if otherHigh <= low {
                gaps.append(DistanceLine(horizontal: horizontal, from: otherHigh, to: low, across: across))
            } else {
                for (a, b) in [(low, otherLow), (high, otherHigh)] where abs(a - b) >= 0.5 {
                    insets.append(DistanceLine(horizontal: horizontal, from: min(a, b), to: max(a, b), across: across))
                }
            }
        }
        // Side by side, only the gap between them; the sides' insets count only when one overlaps the other.
        return gaps.isEmpty ? insets : gaps
    }

    private static func overlap(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> Bool { a0 < b1 && a1 > b0 }

    /// Where a line between `box` and `other` runs across: the middle of the span they share, or of `box` if none.
    private static func middle(_ box: CGRect, _ other: CGRect, horizontal: Bool) -> CGFloat {
        let low = horizontal ? max(box.minY, other.minY) : max(box.minX, other.minX)
        let high = horizontal ? min(box.maxY, other.maxY) : min(box.maxX, other.maxX)
        return high > low ? (low + high) / 2 : horizontal ? box.midY : box.midX
    }
}

extension EditorSession {
    private static func box(of transform: LayerTransform) -> CGRect {
        let corners = DistortWarp.corners(of: transform)
        let xs = corners.map(\.x), ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func layerBoxes(excluding ids: Set<UUID>) -> [(id: UUID, box: CGRect)] {
        guard let document else { return [] }
        return document.renderLayers.filter { $0.asset != nil && !ids.contains($0.id) }
            .map { ($0.id, Self.box(of: displayedTransform(for: $0))) }
    }

    /// The gaps around `draft` as it's dragged, to the layers not `moving` and the canvas.
    func movingDistances(_ draft: LayerTransform, moving: Set<UUID>) -> [DistanceLine] {
        guard let document else { return [] }
        return LayerDistances.moving(Self.box(of: draft), among: layerBoxes(excluding: moving).map(\.box), canvas: document.size)
    }

    /// With Command held at `pixel`: the gaps from the selected layers to the top layer there, or to the canvas.
    func hoverDistances(at pixel: CGPoint) -> [DistanceLine] {
        guard let document, let active = activeLayer, active.asset != nil || transformsAsGroup else { return [] }
        let selected = selectedLayerIDs.union(groupTransformMembers.map(\.id)).union([active.id])
        let box = Self.box(of: editedTransform(for: active))
        let under = layerBoxes(excluding: selected).last { $0.box.contains(pixel) }?.box
        return LayerDistances.between(box, under ?? CGRect(origin: .zero, size: document.size))
    }
}
