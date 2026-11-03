import CoreImage

/// Reduce Noise layers on the GPU canvas: the filter's own work (`PixelFilter.reduceNoise`, its brightness smoothed on
/// the GPU by `MetalNonlocalMeans`), over each region Core Image asks for and the reach of its search around it, so the
/// canvas shows what the export makes.
nonisolated enum GPUReduceNoise {
    static func apply(to image: CIImage, _ settings: ReduceNoiseLayerSettings, scale: CGFloat) -> CIImage? {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty else { return nil }
        guard settings.strength > 0 || settings.color > 0 else { return image }
        return try? ReduceNoiseKernel.apply(withExtent: extent.integral, inputs: [image],
                                            arguments: ["strength": settings.strength, "details": settings.details,
                                                        "color": settings.color, "scale": scale])
    }
}

/// Works on the CPU's copy of its region, as the C code it runs needs.
final class ReduceNoiseKernel: CIImageProcessorKernel {
    /// How far the search, its patches and the color smoothing reach, in the canvas's pixels.
    static let margin: CGFloat = 24

    override class var outputFormat: CIFormat { .RGBA8 }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBA8 }
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        outputRect.insetBy(dx: -margin, dy: -margin)
    }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?,
                                output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first, let scale = arguments?["scale"] as? CGFloat else { throw ExportError.render }
        let width = Int(input.region.width), height = Int(input.region.height), bytesPerRow = width * 4
        guard width > 0, height > 0 else { return }
        var settings = FilterSettings()
        settings.reduceNoiseLuminance = arguments?["strength"] as? Double ?? 50
        settings.reduceNoiseDetail = arguments?["details"] as? Double ?? 50
        settings.reduceNoiseColor = arguments?["color"] as? Double ?? 50
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let source = input.baseAddress.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            pixels.withUnsafeMutableBufferPointer {
                ($0.baseAddress! + row * bytesPerRow).update(from: source + row * input.bytesPerRow, count: bytesPerRow)
            }
        }
        pixels.withUnsafeMutableBufferPointer {
            PixelFilter.reduceNoise($0.baseAddress!, width: width, height: height, bytesPerRow: bytesPerRow, settings: settings, scale: scale)
        }
        // Both regions' rows run top-down: the output's first row is as far into the input as its top is below the input's.
        let rows = Int(output.region.height), columns = Int(output.region.width)
        let top = Int(input.region.maxY - output.region.maxY), left = Int(output.region.minX - input.region.minX)
        let target = output.baseAddress.assumingMemoryBound(to: UInt8.self)
        pixels.withUnsafeBufferPointer { pixels in
            for row in 0..<rows {
                (target + row * output.bytesPerRow).update(from: pixels.baseAddress! + (top + row) * bytesPerRow + left * 4, count: columns * 4)
            }
        }
    }
}
