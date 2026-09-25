import AppKit

/// Settings for the edge-snapping Magnetic Lasso tool.
nonisolated struct MagneticLassoSettings: Equatable, Sendable {
    var searchRadius: Int = 12
    /// Minimum local luminance gradient (0–255) accepted as an edge.
    var edgeSensitivity: Int = 12

    init(searchRadius: Int = 12, edgeSensitivity: Int = 12) {
        self.searchRadius = searchRadius
        self.edgeSensitivity = edgeSensitivity
    }
}

/// Deterministic, macOS 12-compatible edge sampling for Magnetic Lasso.
nonisolated enum MagneticLasso {
    /// Finds the strongest edge in a corridor around the segment ending at `to`.
    static func snap(in image: CGImage, from: CGPoint, to: CGPoint, settings: MagneticLassoSettings) -> CGPoint? {
        guard image.width > 2, image.height > 2,
              from.x.isFinite, from.y.isFinite, to.x.isFinite, to.y.isFinite,
              from.x >= 0, from.y >= 0, to.x >= 0, to.y >= 0,
              from.x < CGFloat(image.width), from.y < CGFloat(image.height),
              to.x < CGFloat(image.width), to.y < CGFloat(image.height),
              let pixels = LuminanceBuffer(image: image) else { return nil }

        let radius = min(64, max(1, settings.searchRadius))
        let threshold = min(255, max(0, settings.edgeSensitivity))
        let minX = max(1, Int(floor(min(from.x, to.x))) - radius)
        let maxX = min(image.width - 2, Int(ceil(max(from.x, to.x))) + radius)
        let minY = max(1, Int(floor(min(from.y, to.y))) - radius)
        let maxY = min(image.height - 2, Int(ceil(max(from.y, to.y))) + radius)
        let dx = to.x - from.x
        let dy = to.y - from.y
        let lengthSquared = dx * dx + dy * dy
        var best: (point: CGPoint, score: Int, distance: CGFloat)?

        for y in minY...maxY {
            for x in minX...maxX {
                let candidate = CGPoint(x: x, y: y)
                let projection: CGFloat
                if lengthSquared > 0 {
                    projection = max(0, min(1, ((candidate.x - from.x) * dx + (candidate.y - from.y) * dy) / lengthSquared))
                } else {
                    projection = 1
                }
                let onSegment = CGPoint(x: from.x + dx * projection, y: from.y + dy * projection)
                let corridorDistance = hypot(candidate.x - onSegment.x, candidate.y - onSegment.y)
                guard corridorDistance <= CGFloat(radius) else { continue }

                let score = pixels.gradient(atX: x, y: y)
                guard score >= threshold else { continue }
                let distance = hypot(candidate.x - to.x, candidate.y - to.y)
                if best == nil || score > best!.score || (score == best!.score && distance < best!.distance) {
                    best = (candidate, score, distance)
                }
            }
        }
        return best?.point
    }

    /// Snaps each segment in an anchor list and closes the resulting outline.
    static func path(in image: CGImage, anchors: [CGPoint], settings: MagneticLassoSettings) -> CGPath? {
        guard anchors.count >= 3 else { return nil }
        var snapped = [anchors[0]]
        for index in 1..<anchors.count {
            snapped.append(snap(in: image, from: snapped[index - 1], to: anchors[index], settings: settings) ?? anchors[index])
        }
        guard snapped.count >= 3 else { return nil }
        let path = CGMutablePath()
        path.addLines(between: snapped)
        path.closeSubpath()
        return path
    }

    private struct LuminanceBuffer {
        let width: Int
        let height: Int
        let values: [UInt8]

        init?(image: CGImage) {
            guard let context = try? BrushRaster.context(width: image.width, height: image.height, mask: false) else { return nil }
            BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
            guard let raw = context.data else { return nil }
            let bytes = raw.assumingMemoryBound(to: UInt8.self)
            var values = [UInt8](repeating: 0, count: image.width * image.height)
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let offset = y * context.bytesPerRow + x * 4
                    values[y * image.width + x] = UInt8((54 * Int(bytes[offset]) + 183 * Int(bytes[offset + 1]) + 19 * Int(bytes[offset + 2])) / 256)
                }
            }
            width = image.width
            height = image.height
            self.values = values
        }

        func value(x: Int, y: Int) -> Int { Int(values[y * width + x]) }

        func gradient(atX x: Int, y: Int) -> Int {
            let horizontal = abs(value(x: x + 1, y: y) - value(x: x - 1, y: y))
            let vertical = abs(value(x: x, y: y + 1) - value(x: x, y: y - 1))
            return max(horizontal, vertical)
        }
    }
}
