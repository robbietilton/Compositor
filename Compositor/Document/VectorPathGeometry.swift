import CoreGraphics
import Foundation

/// A stable hand-off from the Pen tool to a future text-on-path implementation. Text owns the content and
/// typography; this value only says which editable path it follows and how its baseline starts on that path.
nonisolated struct TextPathPlacement: Codable, Equatable, Sendable {
    enum Side: String, Codable, CaseIterable, Sendable {
        case left
        case right
    }

    let pathLayerID: UUID
    /// A fraction of the complete path length. Keeping this normalized makes the start survive path scaling.
    var startOffset: CGFloat = 0
    /// Distance from the path in document pixels. The side chooses the normal on which it is applied.
    var baselineOffset: CGFloat = 0
    var side: Side = .left
    var reversed = false

    var isValid: Bool {
        startOffset.isFinite && (0...1).contains(startOffset) &&
            baselineOffset.isFinite && abs(baselineOffset) <= DocumentLimits.maxSideExtent
    }
}

/// Position and orientation at one arc-length location. The unit tangent follows the path; the normal points to
/// its left. A text renderer can place a glyph at `position + normal * baselineOffset` and rotate it by `angle`.
nonisolated struct VectorPathSample: Equatable, Sendable {
    let position: CGPoint
    let tangent: CGVector
    let normal: CGVector
    let distance: CGFloat
    let fraction: CGFloat
    var angle: CGFloat { atan2(tangent.dy, tangent.dx) }
}

/// A document-space, arc-length view of an editable Pen path. It is deliberately independent of AppKit text so
/// the Type tool can consume it without taking ownership of Pen state or duplicating Bezier geometry.
nonisolated struct VectorPathGeometry: Sendable {
    let isClosed: Bool
    let length: CGFloat
    private let points: [CGPoint]
    private let lengths: [CGFloat]

    init?(nodes: [VectorPathNode], closed: Bool, flatness: CGFloat = 0.25) {
        guard nodes.count >= (closed ? 3 : 2), nodes.allSatisfy(\.isFinite),
              flatness.isFinite, flatness > 0 else { return nil }
        var flattened = [nodes[0].anchor]
        let segmentCount = closed ? nodes.count : nodes.count - 1
        for index in 0..<segmentCount {
            let first = nodes[index]
            let second = nodes[(index + 1) % nodes.count]
            let controlLength = distance(first.anchor, first.outHandle) +
                distance(first.outHandle, second.inHandle) + distance(second.inHandle, second.anchor)
            // Bounded sampling prevents a damaged or adversarial 10,000-node path from exploding in memory.
            let steps = min(64, max(4, Int(ceil(controlLength / max(flatness * 8, 1)))))
            for step in 1...steps {
                flattened.append(vectorCubicPoint(first.anchor, first.outHandle, second.inHandle, second.anchor,
                                                  t: CGFloat(step) / CGFloat(steps)))
            }
        }

        var cumulative = [CGFloat](repeating: 0, count: flattened.count)
        for index in 1..<flattened.count {
            cumulative[index] = cumulative[index - 1] + distance(flattened[index - 1], flattened[index])
        }
        guard let total = cumulative.last, total.isFinite, total > 0 else { return nil }
        self.isClosed = closed
        self.length = total
        self.points = flattened
        self.lengths = cumulative
    }

    func sample(atFraction fraction: CGFloat, reversed: Bool = false) -> VectorPathSample? {
        guard fraction.isFinite else { return nil }
        let fraction = min(max(fraction, 0), 1)
        let distance = (reversed ? 1 - fraction : fraction) * length
        return sample(atDistance: distance, reversed: reversed)
    }

    func sample(atDistance requested: CGFloat, reversed: Bool = false) -> VectorPathSample? {
        guard requested.isFinite, points.count >= 2 else { return nil }
        let distance: CGFloat
        if isClosed {
            let remainder = requested.truncatingRemainder(dividingBy: length)
            distance = remainder < 0 ? remainder + length : remainder
        } else {
            distance = min(max(requested, 0), length)
        }
        let upper = firstLengthIndex(atLeast: distance)
        let lower = max(0, upper - 1)
        let segmentLength = max(lengths[upper] - lengths[lower], .ulpOfOne)
        let amount = min(max((distance - lengths[lower]) / segmentLength, 0), 1)
        let start = points[lower]
        let end = points[upper]
        var dx = end.x - start.x
        var dy = end.y - start.y
        let magnitude = hypot(dx, dy)
        guard magnitude > 0 else { return nil }
        dx /= magnitude
        dy /= magnitude
        if reversed { dx = -dx; dy = -dy }
        return VectorPathSample(
            position: CGPoint(x: start.x + (end.x - start.x) * amount,
                              y: start.y + (end.y - start.y) * amount),
            tangent: CGVector(dx: dx, dy: dy),
            normal: CGVector(dx: -dy, dy: dx),
            distance: distance,
            fraction: distance / length
        )
    }

    /// The nearest arc-length fraction, used when the Type tool drags a text start/end marker along the path.
    func nearestFraction(to point: CGPoint) -> CGFloat? {
        guard point.x.isFinite, point.y.isFinite, points.count >= 2 else { return nil }
        var best: (distanceSquared: CGFloat, pathDistance: CGFloat)?
        for index in 1..<points.count {
            let start = points[index - 1]
            let end = points[index]
            let vx = end.x - start.x
            let vy = end.y - start.y
            let squared = vx * vx + vy * vy
            guard squared > 0 else { continue }
            let amount = min(max(((point.x - start.x) * vx + (point.y - start.y) * vy) / squared, 0), 1)
            let x = start.x + vx * amount
            let y = start.y + vy * amount
            let candidate = (point.x - x) * (point.x - x) + (point.y - y) * (point.y - y)
            if best == nil || candidate < best!.distanceSquared {
                best = (candidate, lengths[index - 1] + sqrt(squared) * amount)
            }
        }
        return best.map { $0.pathDistance / length }
    }

    /// Samples a future text placement after advancing by a glyph width in document pixels.
    func sample(for placement: TextPathPlacement, advance: CGFloat = 0) -> VectorPathSample? {
        guard placement.isValid, advance.isFinite else { return nil }
        let start = placement.startOffset * length
        let requested = start + (placement.reversed ? -advance : advance)
        guard var sample = sample(atDistance: requested, reversed: placement.reversed) else { return nil }
        let sign: CGFloat = placement.side == .left ? 1 : -1
        sample = VectorPathSample(
            position: CGPoint(x: sample.position.x + sample.normal.dx * placement.baselineOffset * sign,
                              y: sample.position.y + sample.normal.dy * placement.baselineOffset * sign),
            tangent: sample.tangent,
            normal: sample.normal,
            distance: sample.distance,
            fraction: sample.fraction
        )
        return sample
    }

    private func firstLengthIndex(atLeast distance: CGFloat) -> Int {
        var lower = 1
        var upper = lengths.count - 1
        while lower < upper {
            let middle = (lower + upper) / 2
            if lengths[middle] < distance { lower = middle + 1 }
            else { upper = middle }
        }
        return lower
    }
}

extension EditorSession {
    /// The only Pen-to-Type bridge the text implementation needs. Returned nodes already include the layer's
    /// scale, rotation and flips, so glyph layout always works in document coordinates.
    func textPathGeometry(for layerID: UUID) -> VectorPathGeometry? {
        guard let layer = document?.layers.first(where: { $0.id == layerID }),
              let vectorPath = layer.liveVectorPath,
              vectorPath.style.subpathStarts?.isEmpty != false else { return nil }
        let nodes = vectorPath.style.nodes.map { node in
            VectorPathNode(
                anchor: node.anchor.applying(layer.transform.unitToDocument),
                inHandle: node.inHandle.applying(layer.transform.unitToDocument),
                outHandle: node.outHandle.applying(layer.transform.unitToDocument)
            )
        }
        return VectorPathGeometry(nodes: nodes, closed: vectorPath.style.closed)
    }

    func textPathPlacement(for layerID: UUID, startOffset: CGFloat = 0,
                           baselineOffset: CGFloat = 0, side: TextPathPlacement.Side = .left,
                           reversed: Bool = false) -> TextPathPlacement? {
        let placement = TextPathPlacement(pathLayerID: layerID, startOffset: startOffset,
                                          baselineOffset: baselineOffset, side: side, reversed: reversed)
        guard placement.isValid, textPathGeometry(for: layerID) != nil else { return nil }
        return placement
    }
}

private nonisolated func vectorCubicPoint(
    _ p0: CGPoint,
    _ p1: CGPoint,
    _ p2: CGPoint,
    _ p3: CGPoint,
    t: CGFloat
) -> CGPoint {
    let oneMinusT = 1 - t
    let a = oneMinusT * oneMinusT * oneMinusT
    let b = 3 * oneMinusT * oneMinusT * t
    let c = 3 * oneMinusT * t * t
    let d = t * t * t
    return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                   y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
}

private nonisolated func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
    hypot(rhs.x - lhs.x, rhs.y - lhs.y)
}
