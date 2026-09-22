import Foundation
import CoreGraphics

public enum TrimBasedOn: String, CaseIterable, Identifiable, Sendable {
    case transparentPixels = "Transparent Pixels"
    case topLeftPixelColor = "Top Left Pixel Color"
    case bottomRightPixelColor = "Bottom Right Pixel Color"

    public var id: String { rawValue }
}

nonisolated public struct TrimOptions: Sendable, Equatable {
    public var basedOn: TrimBasedOn
    public var top: Bool
    public var bottom: Bool
    public var left: Bool
    public var right: Bool
    public var tolerance: UInt8

    public init(
        basedOn: TrimBasedOn = .transparentPixels,
        top: Bool = true,
        bottom: Bool = true,
        left: Bool = true,
        right: Bool = true,
        tolerance: UInt8 = 0
    ) {
        self.basedOn = basedOn
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
        self.tolerance = tolerance
    }

    public var trimsAny: Bool {
        top || bottom || left || right
    }
}

public enum TrimError: LocalizedError, Sendable {
    case noContentToTrim
    case invalidDimensions

    public var errorDescription: String? {
        switch self {
        case .noContentToTrim:
            return "No content remained after trimming."
        case .invalidDimensions:
            return "The trimmed image dimensions are invalid."
        }
    }
}

nonisolated public enum ImageTrim {
    /// Calculates the crop rectangle in document/image coordinates to trim according to the specified options.
    /// Returns nil if no non-trimmed content remains (e.g. fully transparent or single solid color).
    public static func calculateTrimRect(in image: CGImage, options: TrimOptions) -> CGRect? {
        guard options.trimsAny, image.width > 0, image.height > 0 else { return nil }
        let width = image.width
        let height = image.height

        guard let context = try? BrushRaster.context(width: width, height: height, mask: false) else {
            return nil
        }
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        guard let data = context.data else { return nil }
        let raw = data.assumingMemoryBound(to: UInt8.self)
        let stride = context.bytesPerRow

        switch options.basedOn {
        case .transparentPixels:
            var edges = [Int](repeating: 0, count: 4)
            brush_alpha_bounds(raw, width, height, stride, &edges)
            // If edges[2] == 0 (right == 0), the entire image has alpha == 0
            guard edges[2] > 0 else { return nil }
            let left = edges[0]
            let top = edges[1]
            let right = edges[2]
            let bottom = edges[3]

            let minX = options.left ? left : 0
            let minY = options.top ? top : 0
            let maxX = options.right ? right : width
            let maxY = options.bottom ? bottom : height

            guard maxX > minX, maxY > minY else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        case .topLeftPixelColor:
            return calculateColorTrimRect(
                raw: raw,
                width: width,
                height: height,
                stride: stride,
                samplePoint: (0, 0),
                options: options
            )

        case .bottomRightPixelColor:
            return calculateColorTrimRect(
                raw: raw,
                width: width,
                height: height,
                stride: stride,
                samplePoint: (width - 1, height - 1),
                options: options
            )
        }
    }

    private static func calculateColorTrimRect(
        raw: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        stride: Int,
        samplePoint: (x: Int, y: Int),
        options: TrimOptions
    ) -> CGRect? {
        let sampleOffset = samplePoint.y * stride + samplePoint.x * 4
        let targetR = Int(raw[sampleOffset + 0])
        let targetG = Int(raw[sampleOffset + 1])
        let targetB = Int(raw[sampleOffset + 2])
        let targetA = Int(raw[sampleOffset + 3])
        let tol = Int(options.tolerance)

        @inline(__always)
        func pixelMatches(x: Int, y: Int) -> Bool {
            let offset = y * stride + x * 4
            let r = Int(raw[offset + 0])
            let g = Int(raw[offset + 1])
            let b = Int(raw[offset + 2])
            let a = Int(raw[offset + 3])
            return abs(r - targetR) <= tol &&
                   abs(g - targetG) <= tol &&
                   abs(b - targetB) <= tol &&
                   abs(a - targetA) <= tol
        }

        var left = width, right = 0, top = height, bottom = 0
        for y in 0..<height {
            var first = 0
            while first < width && pixelMatches(x: first, y: y) {
                first += 1
            }
            if first == width { continue }

            var last = width
            while last > first && pixelMatches(x: last - 1, y: y) {
                last -= 1
            }
            if first < left { left = first }
            if last > right { right = last }
            if y < top { top = y }
            bottom = y + 1
        }

        // If right == 0, every pixel matched the sample color
        guard right > 0 else { return nil }

        let minX = options.left ? left : 0
        let minY = options.top ? top : 0
        let maxX = options.right ? right : width
        let maxY = options.bottom ? bottom : height

        guard maxX > minX, maxY > minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Crops a CGImage directly using the calculated trim rectangle.
    public static func trimImage(_ image: CGImage, options: TrimOptions) -> CGImage? {
        guard let rect = calculateTrimRect(in: image, options: options) else { return nil }
        return image.cropping(to: rect)
    }

    /// Trims a ProjectSnapshot using the rendered canvas raster and CanvasResizer.
    /// Returns the trimmed snapshot, or nil if no content remained to trim.
    static func trim(_ snapshot: ProjectSnapshot, options: TrimOptions) async throws -> ProjectSnapshot? {
        let raster = try await ImageExporter.shared.render(snapshot)
        guard let rect = calculateTrimRect(in: raster.image, options: options) else {
            return nil
        }
        let fullWidth = snapshot.manifest.width
        let fullHeight = snapshot.manifest.height
        if Int(rect.width) == fullWidth && Int(rect.height) == fullHeight && rect.minX == 0 && rect.minY == 0 {
            return snapshot
        }
        let canvasOptions = CanvasSizeOptions(
            width: Int(rect.width),
            height: Int(rect.height),
            contentOffset: CGPoint(x: -rect.minX, y: -rect.minY)
        )
        return try await CanvasResizer.shared.resize(snapshot, to: canvasOptions)
    }
}

@MainActor
extension EditorSession {
    @discardableResult
    func trim(options: TrimOptions = TrimOptions()) async throws -> Bool {
        guard canStartProjectOperation, let snapshot = projectSnapshot() else { return false }
        isProjectBusy = true
        defer { isProjectBusy = false }
        guard let trimmedSnapshot = try await ImageTrim.trim(snapshot, options: options) else {
            return false
        }
        try Task.checkCancellation()
        applyDocumentSize(trimmedSnapshot, actionName: "Trim")
        return true
    }
}
