import AppKit
import ImageIO

/// Bounded derived mask; original image/container bytes stay in the existing source store.
nonisolated struct BrushShapeTip: Codable, Equatable, Hashable, Sendable {
    var side: Int
    var luminance: Data
    var alpha: Data
    var originalDigest: String? = nil
    var name: String = "Embedded image"
    var isValid: Bool {
        (1...256).contains(side) && luminance.count == side * side && alpha.count == side * side
            && name.utf8.count <= 4096
            && (originalDigest.map { $0.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } } ?? true)
    }
    static func decode(_ data: Data, name: String) throws -> BrushShapeTip {
        guard !data.isEmpty, data.count <= 64 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.int64Value > 0, height.int64Value > 0, width.int64Value <= 32768, height.int64Value <= 32768,
              width.int64Value * height.int64Value <= 64 * 1024 * 1024,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 256, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
            throw BrushImportError.invalid("Shape image is invalid, animated, or oversized: " + name)
        }
        let side = min(256, max(image.width, image.height))
        let context = try BrushRaster.context(width: side, height: side, mask: false)
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        let scale = CGFloat(side) / CGFloat(max(image.width, image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        BrushRaster.draw(image, in: CGRect(x: (CGFloat(side) - size.width) / 2, y: (CGFloat(side) - size.height) / 2,
            width: size.width, height: size.height), mask: false, context: context)
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { throw ExportError.render }
        var luminance = Data(count: side * side), alpha = Data(count: side * side)
        for y in 0..<side { for x in 0..<side {
            let i = y * context.bytesPerRow + x * 4, p = y * side + x
            luminance[p] = UInt8((54 * Int(bytes[i]) + 183 * Int(bytes[i + 1]) + 19 * Int(bytes[i + 2]) + 128) >> 8)
            alpha[p] = bytes[i + 3]
        } }
        return BrushShapeTip(side: side, luminance: luminance, alpha: alpha, name: name)
    }
    func mask(_ mode: ShapeBrushSettings.Mask) -> Data {
        switch mode {
        case .luminance: luminance
        case .alpha: alpha
        case .inverted: Data(zip(alpha, luminance).map { $0 >= $1 ? $0 - $1 : 0 })
        }
    }
    func preview(_ mode: ShapeBrushSettings.Mask) -> CGImage? {
        guard isValid, let provider = CGDataProvider(data: mask(mode) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

nonisolated struct ShapeBrushSettings: Codable, Equatable, Hashable, Sendable {
    enum Source: String, Codable, CaseIterable, Sendable { case procedural = "Procedural", generated = "Generated Substitute", embedded = "Original Embedded Image", custom = "Custom Image" }
    enum InputStyle: String, Codable, CaseIterable, Sendable { case touch = "Touch / Mouse", azimuth = "Pen Azimuth", barrel = "Azimuth + Barrel Rotation" }
    enum Filtering: String, Codable, CaseIterable, Sendable { case none = "None", classic = "Classic", improved = "Improved" }
    enum Mask: String, Codable, CaseIterable, Sendable { case luminance = "White paints", inverted = "Black paints", alpha = "Alpha" }
    var source: Source = .procedural
    var customTip: BrushShapeTip? = nil
    var generator: GeneratedBrushTip? = nil
    var generatedKind: GeneratedBrushTip { generator ?? .ink }
    var mask: Mask = .luminance
    var inputStyle: InputStyle = .touch
    var relativeBarrel = false
    var relativeToStroke: Bool? = nil
    var rotationResponse: CGFloat = 0
    var countJitter: CGFloat = 0
    var randomized = false
    var flipX = false
    var flipY = false
    var horizontalJitter: CGFloat = 0
    var verticalJitter: CGFloat = 0
    var horizontalInput: StrokePathSettings.Input = .none
    var verticalInput: StrokePathSettings.Input = .none
    var pressureRoundness: CGFloat = 0
    var tiltRoundness: CGFloat = 0
    var filtering: Filtering = .classic
    var isActive: Bool {
        relativeToStroke == true || source != .procedural || inputStyle != .touch || rotationResponse != 0 || countJitter > 0
            || randomized || flipX || flipY || horizontalJitter > 0 || verticalJitter > 0
            || pressureRoundness > 0 || tiltRoundness > 0 || filtering != .classic
    }
    var isValid: Bool {
        [countJitter, horizontalJitter, verticalJitter, pressureRoundness, tiltRoundness].allSatisfy { $0.isFinite && (0...1).contains($0) }
            && rotationResponse.isFinite && (-1...1).contains(rotationResponse)
            && [horizontalInput, verticalInput].allSatisfy { $0 == .none || $0 == .pressure }
            && (customTip?.isValid ?? true) && (source != .custom || customTip != nil)
    }
}
