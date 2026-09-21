import AppKit

/// Draws an image into an RGBA buffer (premultiplied, alpha last), lets a C kernel change it in place,
/// and returns the result.
nonisolated enum ImageAdjustmentPixels {
    static func run(_ image: CGImage, _ body: (UnsafeMutablePointer<UInt8>, Int, Int, Int) -> Void) throws -> CGImage {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        guard let data = context.data else { throw ExportError.render }
        body(data.assumingMemoryBound(to: UInt8.self), image.width, image.height, context.bytesPerRow)
        guard let result = context.makeImage() else { throw ExportError.render }
        return result
    }
    static func clamp(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}

/// A straight sRGB color stored with an adjustment, 0–1 per channel.
nonisolated struct AdjustmentColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    init(red: Double, green: Double, blue: Double) {
        self.red = red; self.green = green; self.blue = blue
    }
    init(_ color: PaletteColor) { self.init(red: Double(color.red), green: Double(color.green), blue: Double(color.blue)) }
    var isValid: Bool { [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) } }
    var clamped: Self {
        Self(red: ImageAdjustmentPixels.clamp(red, 0...1, 0), green: ImageAdjustmentPixels.clamp(green, 0...1, 0),
             blue: ImageAdjustmentPixels.clamp(blue, 0...1, 0))
    }
}

/// Photoshop's Exposure: `exposure` (stops) scales linear light and `offset` shifts it, then gamma
/// correction bends the result. The same curve runs on every channel; alpha is kept.
nonisolated struct ExposureSettings: Codable, Equatable, Sendable {
    static let exposureRange: ClosedRange<Double> = -20...20
    static let offsetRange: ClosedRange<Double> = -0.5...0.5
    static let gammaRange: ClosedRange<Double> = 0.01...9.99
    /// Stops of light, −20…20.
    var exposure: Double = 0
    /// Added in linear light, −0.5…0.5: negative deepens the shadows, positive lifts them.
    var offset: Double = 0
    /// Gamma correction, 0.01…9.99; above 1 brightens the midtones.
    var gamma: Double = 1
    var isValid: Bool { Self.exposureRange.contains(exposure) && Self.offsetRange.contains(offset) && Self.gammaRange.contains(gamma) }
    var normalized: Self {
        Self(exposure: ImageAdjustmentPixels.clamp(exposure, Self.exposureRange, 0),
             offset: ImageAdjustmentPixels.clamp(offset, Self.offsetRange, 0),
             gamma: ImageAdjustmentPixels.clamp(gamma, Self.gammaRange, 1))
    }
    /// Each channel's output (0–1) for each input byte, decoded to linear light and encoded back.
    var table: [Float] {
        let scale = pow(2, exposure)
        return (0...255).map { index in
            let encoded = Double(index) / 255
            var linear = encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
            linear = pow(max(0, linear * scale + offset), 1 / gamma)
            let output = linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
            return Float(min(1, max(0, output)))
        }
    }
    func apply(_ image: CGImage) throws -> CGImage {
        guard isValid else { throw ProjectError.invalid }
        let tables = Array([[Float]](repeating: table, count: 3).joined())
        return try ImageAdjustmentPixels.run(image) { pixels, width, height, _ in
            levels_apply(pixels, width * height, tables)
        }
    }
}

/// Gradient Map: each pixel's brightness picks a color between `shadows` and `highlights` (the other
/// way round when reversed); alpha is kept.
nonisolated struct GradientMapSettings: Codable, Equatable, Sendable {
    var shadows = AdjustmentColor(red: 0, green: 0, blue: 0)
    var highlights = AdjustmentColor(red: 1, green: 1, blue: 1)
    var reversed = false
    var isValid: Bool { shadows.isValid && highlights.isValid }
    var normalized: Self {
        var result = self
        result.shadows = shadows.clamped
        result.highlights = highlights.clamped
        return result
    }
    /// The colors for the darkest and lightest tones, in the order they apply.
    var ends: (dark: AdjustmentColor, light: AdjustmentColor) { reversed ? (highlights, shadows) : (shadows, highlights) }
    func apply(_ image: CGImage) throws -> CGImage {
        guard isValid else { throw ProjectError.invalid }
        let (dark, light) = ends
        let table: [UInt8] = (0...255).flatMap { index -> [UInt8] in
            let t = Double(index) / 255
            let red = UInt8(min(255, max(0, (dark.red + (light.red - dark.red) * t) * 255).rounded()))
            let green = UInt8(min(255, max(0, (dark.green + (light.green - dark.green) * t) * 255).rounded()))
            let blue = UInt8(min(255, max(0, (dark.blue + (light.blue - dark.blue) * t) * 255).rounded()))
            return [red, green, blue]
        }
        return try ImageAdjustmentPixels.run(image) { pixels, width, height, stride in
            adjust_gradient_map(pixels, width, height, stride, table)
        }
    }
}

/// Film grain: brightness noise, strongest in the midtones. Its pattern is fixed in document space by
/// `seed`, so it stays put as the canvas pans or redraws part of the image.
nonisolated struct GrainSettings: Codable, Equatable, Sendable {
    static let amountRange: ClosedRange<Double> = 0...100
    static let sizeRange: ClosedRange<Double> = 0.5...20
    static let roughnessRange: ClosedRange<Double> = 0...100
    /// Strength, 0–100.
    var amount: Double = 25
    /// Grain scale in document pixels, 0.5–20.
    var size: Double = 1.5
    /// 0–100: how much per-pixel noise roughens the smooth grain.
    var roughness: Double = 50
    var seed: UInt32 = 0
    var isValid: Bool { Self.amountRange.contains(amount) && Self.sizeRange.contains(size) && Self.roughnessRange.contains(roughness) }
    var normalized: Self {
        var result = self
        result.amount = ImageAdjustmentPixels.clamp(amount, Self.amountRange, 25)
        result.size = ImageAdjustmentPixels.clamp(size, Self.sizeRange, 1.5)
        result.roughness = ImageAdjustmentPixels.clamp(roughness, Self.roughnessRange, 50)
        return result
    }
    /// `origin` and `unitsPerPixel` place the image's pixels in document space (a whole layer at 1:1 is
    /// origin zero, one unit per pixel); `seed` replaces the stored pattern when given.
    func apply(_ image: CGImage, origin: CGPoint = .zero, unitsPerPixel: CGFloat = 1, seed: UInt32? = nil) throws -> CGImage {
        guard isValid, unitsPerPixel.isFinite, unitsPerPixel > 0 else { throw ProjectError.invalid }
        guard amount > 0 else { return image }
        let pattern = seed ?? self.seed
        return try ImageAdjustmentPixels.run(image) { pixels, width, height, stride in
            adjust_grain(pixels, width, height, stride, amount, size, roughness, pattern,
                         Double(origin.x), Double(origin.y), Double(unitsPerPixel))
        }
    }
}
