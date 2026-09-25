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

/// Brush-seeded, adaptive colour selection. The pixel frontier runs in C so a full-size
/// document can be analysed for each visible preview without blocking the editor.
nonisolated enum QuickSelection {
    struct PreparedImage: Sendable {
        let width: Int
        let height: Int
        let rgba: [UInt8]
    }

    static func prepare(_ image: CGImage) -> PreparedImage? {
        guard image.width > 0, image.height > 0,
              let rgba = try? ForegroundMaskUtilities.rgbaBytes(from: image, width: image.width, height: image.height)
        else { return nil }
        return PreparedImage(width: image.width, height: image.height, rgba: rgba)
    }

    static func mask(in image: CGImage, points: [CGPoint], settings: QuickSelectionSettings,
                     previousMask: [UInt8]? = nil) -> [UInt8]? {
        guard let prepared = prepare(image) else { return nil }
        return mask(in: prepared, points: points, settings: settings, previousMask: previousMask)
    }

    static func mask(in prepared: PreparedImage, points: [CGPoint], settings: QuickSelectionSettings,
                     previousMask: [UInt8]? = nil) -> [UInt8]? {
        let width = prepared.width, height = prepared.height
        guard !points.isEmpty else { return nil }
        let coordinates = points.flatMap { point -> [Int32] in
            guard point.x.isFinite, point.y.isFinite,
                  point.x >= 0, point.y >= 0, point.x < CGFloat(width), point.y < CGFloat(height) else { return [] }
            return [Int32(point.x.rounded(.down)), Int32(point.y.rounded(.down))]
        }
        guard !coordinates.isEmpty else { return nil }

        let diameter = Int32(min(500, max(1, settings.diameter.isFinite ? settings.diameter : 40)))
        let tolerance = Int32(min(255, max(0, settings.tolerance)))
        let edgeSensitivity = Int32(min(255, max(0, settings.edgeSensitivity)))
        let prior = previousMask.flatMap { $0.count == width * height ? $0 : nil } ?? []
        var result = [UInt8](repeating: 0, count: width * height)
        let selected = prepared.rgba.withUnsafeBufferPointer { pixels in
            coordinates.withUnsafeBufferPointer { samples in
                prior.withUnsafeBufferPointer { previous in
                    result.withUnsafeMutableBufferPointer { output in
                        quick_selection_mask(pixels.baseAddress, width, height, samples.baseAddress,
                                             samples.count / 2, diameter, tolerance, edgeSensitivity,
                                             previous.isEmpty ? nil : previous.baseAddress, output.baseAddress)
                    }
                }
            }
        }
        return selected > 0 ? result : nil
    }
}
