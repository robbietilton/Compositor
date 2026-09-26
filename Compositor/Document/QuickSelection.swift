import AppKit

/// Settings for the brush-driven Quick Selection tool.
nonisolated struct QuickSelectionSettings: Equatable, Sendable {
    var diameter: CGFloat = 40
    var tolerance: Int = 32
    /// A luminance edge above this value blocks flood-fill traversal.
    var edgeSensitivity: Int = 32

    init(diameter: CGFloat = 40, tolerance: Int = 32, edgeSensitivity: Int = 32) {
        self.diameter = diameter
        self.tolerance = tolerance
        self.edgeSensitivity = edgeSensitivity
    }
}

/// Deterministic, macOS 12-compatible image analysis for Quick Selection.
nonisolated enum QuickSelection {
    /// Returns a binary, document-sized mask for the connected colour regions
    /// touched by the brush points. Each dab is one seed; their regions are
    /// unioned so a single pointer stroke can grow an object progressively.
    static func mask(in image: CGImage, points: [CGPoint], settings: QuickSelectionSettings) -> [UInt8]? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, !points.isEmpty,
              let context = try? BrushRaster.context(width: width, height: height, mask: false) else { return nil }
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        guard let raw = context.data else { return nil }

        let validPoints = points.filter { point in
            point.x.isFinite && point.y.isFinite && point.x >= 0 && point.y >= 0 && point.x < CGFloat(width) && point.y < CGFloat(height)
        }
        guard !validPoints.isEmpty else { return nil }

        let diameter = min(500, max(1, settings.diameter.isFinite ? settings.diameter : 40))
        let tolerance = min(255, max(0, settings.tolerance))
        let edgeSensitivity = min(255, max(0, settings.edgeSensitivity))
        let radius = max(1, Int(ceil(diameter / 2)))
        let expansion = max(8, radius * 4)
        let bounds = boundingBox(of: validPoints, expansion: expansion, width: width, height: height)
        let pixelCount = width * height
        var result = [UInt8](repeating: 0, count: pixelCount)
        var visited = [UInt8](repeating: 0, count: pixelCount)
        let bytes = raw.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = context.bytesPerRow

        for point in validPoints {
            let seedX = min(width - 1, max(0, Int(point.x.rounded(.down))))
            let seedY = min(height - 1, max(0, Int(point.y.rounded(.down))))
            let seed = color(atX: seedX, y: seedY, bytes: bytes, bytesPerRow: bytesPerRow)
            var queue = [Int]()
            queue.reserveCapacity(256)
            queue.append(seedY * width + seedX)
            var head = 0

            while head < queue.count {
                let index = queue[head]
                head += 1
                guard visited[index] == 0 else { continue }
                visited[index] = 1
                let x = index % width
                let y = index / width
                guard bounds.contains(CGPoint(x: x, y: y)) else { continue }
                let pixel = color(atX: x, y: y, bytes: bytes, bytesPerRow: bytesPerRow)
                guard colorDistance(pixel, seed) <= tolerance else { continue }
                result[index] = 255

                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                    guard bounds.contains(CGPoint(x: nx, y: ny)), nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                    let neighborIndex = ny * width + nx
                    guard visited[neighborIndex] == 0 else { continue }
                    let neighbor = color(atX: nx, y: ny, bytes: bytes, bytesPerRow: bytesPerRow)
                    if edgeMagnitude(pixel, neighbor) <= edgeSensitivity || colorDistance(neighbor, seed) <= tolerance {
                        queue.append(neighborIndex)
                    }
                }
            }
        }

        return result.contains(255) ? result : nil
    }

    private struct Color {
        let red: Int
        let green: Int
        let blue: Int
    }

    private static func color(atX x: Int, y: Int, bytes: UnsafeMutablePointer<UInt8>, bytesPerRow: Int) -> Color {
        let offset = y * bytesPerRow + x * 4
        return Color(red: Int(bytes[offset]), green: Int(bytes[offset + 1]), blue: Int(bytes[offset + 2]))
    }

    private static func colorDistance(_ lhs: Color, _ rhs: Color) -> Int {
        max(abs(lhs.red - rhs.red), max(abs(lhs.green - rhs.green), abs(lhs.blue - rhs.blue)))
    }

    private static func luminance(_ color: Color) -> Int {
        (54 * color.red + 183 * color.green + 19 * color.blue) / 256
    }

    private static func edgeMagnitude(_ lhs: Color, _ rhs: Color) -> Int {
        abs(luminance(lhs) - luminance(rhs))
    }

    private static func boundingBox(of points: [CGPoint], expansion: Int, width: Int, height: Int) -> CGRect {
        let minX = max(0, Int(floor(points.map(\.x).min() ?? 0)) - expansion)
        let maxX = min(width - 1, Int(ceil(points.map(\.x).max() ?? 0)) + expansion)
        let minY = max(0, Int(floor(points.map(\.y).min() ?? 0)) - expansion)
        let maxY = min(height - 1, Int(ceil(points.map(\.y).max() ?? 0)) + expansion)
        return CGRect(x: minX, y: minY, width: max(1, maxX - minX + 1), height: max(1, maxY - minY + 1))
    }
}
