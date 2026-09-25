import AppKit

/// Settings for the brush-driven Quick Selection tool.
nonisolated struct QuickSelectionSettings: Equatable, Sendable {
    var diameter: CGFloat = 40
    var tolerance: Int = 32
    /// A luminance edge above this value becomes increasingly expensive to cross.
    var edgeSensitivity: Int = 32

    init(diameter: CGFloat = 40, tolerance: Int = 32, edgeSensitivity: Int = 32) {
        self.diameter = diameter
        self.tolerance = tolerance
        self.edgeSensitivity = edgeSensitivity
    }
}

/// Deterministic, macOS 12-compatible image analysis for Quick Selection.
///
/// The selector deliberately stays independent from Vision/Core ML. It combines a circular
/// brush footprint, an adaptive colour model, local colour continuity, and luminance edge cost.
/// That gives the editor Photoshop-like brush behaviour while preserving a small, deterministic
/// implementation that can run on both Intel and Apple Silicon Macs.
nonisolated enum QuickSelection {
    /// Returns a binary, document-sized mask for the connected colour regions touched by the
    /// brush points. `previousMask` is retained and used as additional seeds when a later dab
    /// continues the same gesture or selection.
    static func mask(in image: CGImage, points: [CGPoint], settings: QuickSelectionSettings,
                     previousMask: [UInt8]? = nil) -> [UInt8]? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, !points.isEmpty,
              let rgba = try? ForegroundMaskUtilities.rgbaBytes(from: image, width: width, height: height) else { return nil }

        let validPoints = points.filter { point in
            point.x.isFinite && point.y.isFinite && point.x >= 0 && point.y >= 0 &&
                point.x < CGFloat(width) && point.y < CGFloat(height)
        }
        guard !validPoints.isEmpty else { return nil }

        let diameter = min(500, max(1, settings.diameter.isFinite ? settings.diameter : 40))
        let tolerance = min(255, max(0, settings.tolerance))
        let edgeSensitivity = min(255, max(0, settings.edgeSensitivity))
        let radius = max(0.5, diameter / 2)
        let expansion = max(24, Int(ceil(radius * 8)))
        let bounds = analysisBounds(of: validPoints, previousMask: previousMask,
                                    expansion: expansion, width: width, height: height)
        let pixelCount = width * height
        var result = [UInt8](repeating: 0, count: pixelCount)
        var visited = [UInt8](repeating: 0, count: pixelCount)
        // Keep at most the best frontier entry for each pixel. Without this guard a broad
        // selection adds the same neighbours once for every adjacent selected pixel, making
        // the heap grow quadratically on larger photographs.
        var queuedScore = [Int](repeating: Int.max, count: pixelCount)
        var model = AdaptiveColourModel()
        var frontier = MinHeap()

        if let previousMask, previousMask.count == pixelCount {
            for index in previousMask.indices where previousMask[index] != 0 {
                let x = index % width
                let y = index / width
                guard bounds.contains(x: x, y: y) else { continue }
                result[index] = 255
                visited[index] = 1
                queuedScore[index] = 0
                model.add(pixel(at: index, in: rgba))
            }
        }

        for point in validPoints {
            let centerX = min(width - 1, max(0, Int(point.x.rounded(.down))))
            let centerY = min(height - 1, max(0, Int(point.y.rounded(.down))))
            let minX = max(bounds.minX, Int(floor(CGFloat(centerX) - radius)))
            let maxX = min(bounds.maxX, Int(ceil(CGFloat(centerX) + radius)))
            let minY = max(bounds.minY, Int(floor(CGFloat(centerY) - radius)))
            let maxY = min(bounds.maxY, Int(ceil(CGFloat(centerY) + radius)))
            let radiusSquared = radius * radius
            guard minX <= maxX, minY <= maxY else { continue }
            for y in minY...maxY {
                for x in minX...maxX where squaredDistance(x: x, y: y, centerX: centerX, centerY: centerY) <= radiusSquared {
                    let index = y * width + x
                    result[index] = 255
                    queuedScore[index] = 0
                    if visited[index] == 0 {
                        visited[index] = 1
                        model.add(pixel(at: index, in: rgba))
                    }
                }
            }
        }

        guard model.count > 0 else { return nil }

        for y in bounds.minY...bounds.maxY {
            for x in bounds.minX...bounds.maxX {
                let index = y * width + x
                guard result[index] != 0 else { continue }
                enqueueNeighbours(of: index, x: x, y: y, width: width, height: height,
                                  bounds: bounds, rgba: rgba, model: model,
                                  queuedScore: &queuedScore, heap: &frontier)
            }
        }

        while let candidate = frontier.pop() {
            guard visited[candidate.index] == 0 else { continue }
            let parent = pixel(at: candidate.parent, in: rgba)
            let current = pixel(at: candidate.index, in: rgba)
            guard accepted(current, nextTo: parent, model: model,
                           tolerance: tolerance, edgeSensitivity: edgeSensitivity) else { continue }

            visited[candidate.index] = 1
            result[candidate.index] = 255
            model.add(current)
            let x = candidate.index % width
            let y = candidate.index / width
            enqueueNeighbours(of: candidate.index, x: x, y: y, width: width, height: height,
                              bounds: bounds, rgba: rgba, model: model,
                              queuedScore: &queuedScore, heap: &frontier)
        }

        return result.contains(255) ? result : nil
    }

    private struct Pixel {
        let red: Int
        let green: Int
        let blue: Int
        var luminance: Int { (54 * red + 183 * green + 19 * blue) / 256 }
    }

    private struct AdaptiveColourModel {
        private(set) var count = 0
        private var minRed = 255, minGreen = 255, minBlue = 255
        private var maxRed = 0, maxGreen = 0, maxBlue = 0
        private var meanRed = 0.0, meanGreen = 0.0, meanBlue = 0.0

        mutating func add(_ pixel: Pixel) {
            count += 1
            minRed = min(minRed, pixel.red); minGreen = min(minGreen, pixel.green); minBlue = min(minBlue, pixel.blue)
            maxRed = max(maxRed, pixel.red); maxGreen = max(maxGreen, pixel.green); maxBlue = max(maxBlue, pixel.blue)
            let weight = 1.0 / Double(count)
            meanRed += (Double(pixel.red) - meanRed) * weight
            meanGreen += (Double(pixel.green) - meanGreen) * weight
            meanBlue += (Double(pixel.blue) - meanBlue) * weight
        }

        func distance(to pixel: Pixel) -> Int {
            let red = pixel.red < minRed ? minRed - pixel.red : pixel.red > maxRed ? pixel.red - maxRed : 0
            let green = pixel.green < minGreen ? minGreen - pixel.green : pixel.green > maxGreen ? pixel.green - maxGreen : 0
            let blue = pixel.blue < minBlue ? minBlue - pixel.blue : pixel.blue > maxBlue ? pixel.blue - maxBlue : 0
            let rangeDistance = max(red, max(green, blue))
            let meanDistance = max(abs(pixel.red - Int(meanRed.rounded())),
                                   max(abs(pixel.green - Int(meanGreen.rounded())), abs(pixel.blue - Int(meanBlue.rounded()))))
            return max(rangeDistance, meanDistance / 2)
        }
    }

    private struct Candidate {
        let score: Int
        let index: Int
        let parent: Int
    }

    private struct MinHeap {
        private var values: [Candidate] = []

        mutating func push(_ value: Candidate) {
            values.append(value)
            var index = values.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                guard ordered(values[index], before: values[parent]) else { break }
                values.swapAt(index, parent)
                index = parent
            }
        }

        mutating func pop() -> Candidate? {
            guard !values.isEmpty else { return nil }
            if values.count == 1 { return values.removeLast() }
            let first = values[0]
            values[0] = values.removeLast()
            var index = 0
            while true {
                let left = index * 2 + 1
                let right = left + 1
                var smallest = index
                if left < values.count && ordered(values[left], before: values[smallest]) { smallest = left }
                if right < values.count && ordered(values[right], before: values[smallest]) { smallest = right }
                guard smallest != index else { break }
                values.swapAt(index, smallest)
                index = smallest
            }
            return first
        }

        private func ordered(_ lhs: Candidate, before rhs: Candidate) -> Bool {
            lhs.score == rhs.score ? lhs.index < rhs.index : lhs.score < rhs.score
        }
    }

    private struct Bounds {
        let minX: Int
        let minY: Int
        let maxX: Int
        let maxY: Int

        func contains(x: Int, y: Int) -> Bool { x >= minX && x <= maxX && y >= minY && y <= maxY }
    }

    private static func pixel(at index: Int, in rgba: [UInt8]) -> Pixel {
        let offset = index * 4
        return Pixel(red: Int(rgba[offset]), green: Int(rgba[offset + 1]), blue: Int(rgba[offset + 2]))
    }

    private static func squaredDistance(x: Int, y: Int, centerX: Int, centerY: Int) -> CGFloat {
        let dx = CGFloat(x - centerX), dy = CGFloat(y - centerY)
        return dx * dx + dy * dy
    }

    private static func analysisBounds(of points: [CGPoint], previousMask: [UInt8]?, expansion: Int,
                                       width: Int, height: Int) -> Bounds {
        var minX = width - 1, minY = height - 1, maxX = 0, maxY = 0
        for point in points {
            minX = min(minX, Int(floor(point.x))); maxX = max(maxX, Int(ceil(point.x)))
            minY = min(minY, Int(floor(point.y))); maxY = max(maxY, Int(ceil(point.y)))
        }
        if let previousMask, previousMask.count == width * height {
            for index in previousMask.indices where previousMask[index] != 0 {
                let x = index % width, y = index / width
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return Bounds(minX: max(0, minX - expansion), minY: max(0, minY - expansion),
                      maxX: min(width - 1, maxX + expansion), maxY: min(height - 1, maxY + expansion))
    }

    private static func enqueueNeighbours(of index: Int, x: Int, y: Int, width: Int, height: Int,
                                          bounds: Bounds, rgba: [UInt8], model: AdaptiveColourModel,
                                          queuedScore: inout [Int], heap: inout MinHeap) {
        let parent = pixel(at: index, in: rgba)
        for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
            guard nx >= 0, ny >= 0, nx < width, ny < height, bounds.contains(x: nx, y: ny) else { continue }
            let neighborIndex = ny * width + nx
            let neighbor = pixel(at: neighborIndex, in: rgba)
            let local = colourDistance(parent, neighbor)
            let modelDistance = model.distance(to: neighbor)
            let edge = abs(parent.luminance - neighbor.luminance)
            let score = local * 3 + modelDistance * 2 + edge * 4
            guard score < queuedScore[neighborIndex] else { continue }
            queuedScore[neighborIndex] = score
            heap.push(Candidate(score: score, index: neighborIndex, parent: index))
        }
    }

    private static func accepted(_ pixel: Pixel, nextTo parent: Pixel, model: AdaptiveColourModel,
                                 tolerance: Int, edgeSensitivity: Int) -> Bool {
        let local = colourDistance(pixel, parent)
        let modelDistance = model.distance(to: pixel)
        let edge = abs(pixel.luminance - parent.luminance)
        let localLimit = max(8, Int(Double(tolerance) * 1.5))
        // A shaded object may drift several tolerance units away from its first dab while
        // each neighbouring pixel remains close. The local and edge checks still reject a
        // hard contour, so the wider model envelope does not turn a boundary into a bridge.
        let modelLimit = max(12, tolerance * 6)
        guard local <= localLimit, modelDistance <= modelLimit else { return false }
        // A strong luminance edge is allowed only when the candidate is still close to the
        // model; this prevents a gradual colour change from tunnelling through a contour.
        return edge <= edgeSensitivity || (edge <= edgeSensitivity * 2 && modelDistance <= tolerance)
    }

    private static func colourDistance(_ lhs: Pixel, _ rhs: Pixel) -> Int {
        max(abs(lhs.red - rhs.red), max(abs(lhs.green - rhs.green), abs(lhs.blue - rhs.blue)))
    }
}
