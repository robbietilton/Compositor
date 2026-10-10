import AppKit

/// Draws an image into an RGBA buffer (premultiplied, alpha last), lets a C kernel change it in place,
/// and returns the result.
nonisolated enum ImageAdjustmentPixels {
    /// The last result for one source image and key. Slider events repeat the same settings on the same image.
    final class Memo<Key: Equatable>: @unchecked Sendable {
        private let lock = NSLock()
        private var source: CGImage?
        private var key: Key?
        private var result: CGImage?
        func value(_ source: CGImage, key: Key, make: () throws -> CGImage) rethrows -> CGImage {
            if let cached = lock.withLock({ () -> CGImage? in
                self.source === source && self.key == key ? result : nil
            }) { return cached }
            let made = try make()
            lock.withLock { self.source = source; self.key = key; self.result = made }
            return made
        }
    }

    /// Full-size bitmaps kept between calls. `makeImage` copies, so the next caller can overwrite this memory.
    private final class RasterPool: @unchecked Sendable {
        fileprivate final class Buffer {
            var bytes: UnsafeMutableRawPointer?
            var capacity = 0
            func ensure(_ count: Int) -> UnsafeMutableRawPointer {
                if bytes == nil || capacity < count {
                    bytes?.deallocate()
                    bytes = .allocate(byteCount: count, alignment: 64)
                    capacity = count
                }
                return bytes!
            }
            deinit { bytes?.deallocate() }
        }
        private let lock = NSLock()
        private var spares: [Buffer] = []
        private let limit = 2
        fileprivate func checkout(byteCount: Int) -> Buffer {
            let buffer = lock.withLock { spares.popLast() ?? Buffer() }
            _ = buffer.ensure(byteCount)
            return buffer
        }
        fileprivate func checkin(_ buffer: Buffer) {
            lock.withLock {
                if spares.count < limit { spares.append(buffer); return }
                if let index = spares.indices.min(by: { spares[$0].capacity < spares[$1].capacity }),
                   spares[index].capacity < buffer.capacity {
                    spares[index] = buffer
                }
            }
        }
    }
    private static let pool = RasterPool()

    /// A context with the same layout as `BrushRaster.context`. `clear` zeroes it; a full-buffer copy can skip that.
    static func withContext<T>(width: Int, height: Int, clear: Bool, _ body: (CGContext) throws -> T) throws -> T {
        let row = width * 4
        guard width > 0, height > 0, row > 0, height <= Int.max / row else { throw ExportError.render }
        let count = row * height
        let buffer = pool.checkout(byteCount: count)
        defer { pool.checkin(buffer) }
        let bytes = buffer.ensure(count)
        if clear { memset(bytes, 0, count) }
        // The context is gone before the buffer goes back in the pool. `defer` runs after this closure returns.
        return try {
            guard let context = CGContext(data: bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: row,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { throw ExportError.render }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            return try body(context)
        }()
    }

    static func run(_ image: CGImage, _ body: (UnsafeMutablePointer<UInt8>, Int, Int, Int) -> Void) throws -> CGImage {
        try withContext(width: image.width, height: image.height, clear: true) { context in
            BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
            guard let data = context.data else { throw ExportError.render }
            body(data.assumingMemoryBound(to: UInt8.self), image.width, image.height, context.bytesPerRow)
            guard let result = context.makeImage() else { throw ExportError.render }
            return result
        }
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
    private static let memo = ImageAdjustmentPixels.Memo<ExposureSettings>()
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
        return try Self.memo.value(image, key: self) {
            let tables = Array([[Float]](repeating: table, count: 3).joined())
            return try ImageAdjustmentPixels.run(image) { pixels, width, height, _ in
                levels_apply(pixels, width * height, tables)
            }
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
    private static let memo = ImageAdjustmentPixels.Memo<GradientMapSettings>()
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
        return try Self.memo.value(image, key: self) {
            let (dark, light) = ends
            // Split into explicitly typed steps: as one expression the type checker times out (Xcode 26.1).
            func channel(_ from: Double, _ to: Double, _ t: Double) -> UInt8 {
                let value: Double = from + (to - from) * t
                let scaled: Double = (value * 255).rounded()
                return UInt8(min(255.0, max(0.0, scaled)))
            }
            var table = [UInt8]()
            table.reserveCapacity(256 * 3)
            for index in 0...255 {
                let t: Double = Double(index) / 255
                table.append(channel(dark.red, light.red, t))
                table.append(channel(dark.green, light.green, t))
                table.append(channel(dark.blue, light.blue, t))
            }
            return try ImageAdjustmentPixels.run(image) { pixels, width, height, stride in
                adjust_gradient_map(pixels, width, height, stride, table)
            }
        }
    }
}

/// Black & White, as Photoshop's is: not a desaturation, but a choice of how bright each family of
/// colors becomes in gray. Reds at 40% and yellows at 60% is why a default conversion keeps skin and
/// foliage apart where a plain luminance flattens them.
nonisolated struct BlackWhiteSettings: Codable, Equatable, Sendable {
    static let range: ClosedRange<Double> = -200...300
    /// Photoshop's defaults.
    var reds: Double = 40
    var yellows: Double = 60
    var greens: Double = 40
    var cyans: Double = 60
    var blues: Double = 20
    var magentas: Double = 80
    /// Color the result while keeping its tones, for a sepia or a cyanotype.
    var tint = false
    var tintHue: Double = 40
    var tintSaturation: Double = 20
    var isValid: Bool {
        [reds, yellows, greens, cyans, blues, magentas].allSatisfy { $0.isFinite && Self.range.contains($0) }
            && tintHue.isFinite && (0...360).contains(tintHue)
            && tintSaturation.isFinite && (0...100).contains(tintSaturation)
    }
    private static let memo = ImageAdjustmentPixels.Memo<BlackWhiteSettings>()
    func apply(_ image: CGImage) throws -> CGImage {
        guard isValid else { throw ProjectError.invalid }
        return try Self.memo.value(image, key: self) {
            // The C routine's order: red, yellow, green, cyan, blue, magenta.
            let weights = [reds, yellows, greens, cyans, blues, magentas].map { Float($0 / 100) }
            return try ImageAdjustmentPixels.run(image) { pixels, width, height, stride in
                adjust_black_white(pixels, width, height, stride, weights,
                                   tint ? 1 : 0, tintHue, tintSaturation / 100)
            }
        }
    }
}

/// Color Balance: shifts color towards one end of each opposing pair, separately for shadows,
/// midtones and highlights. Preserve Luminosity puts each pixel's brightness back afterwards, so a
/// warm cast doesn't also lighten the picture.
nonisolated struct ColorBalanceSettings: Codable, Equatable, Sendable {
    static let range: ClosedRange<Double> = -100...100
    var shadowCyanRed: Double = 0
    var shadowMagentaGreen: Double = 0
    var shadowYellowBlue: Double = 0
    var midCyanRed: Double = 0
    var midMagentaGreen: Double = 0
    var midYellowBlue: Double = 0
    var highlightCyanRed: Double = 0
    var highlightMagentaGreen: Double = 0
    var highlightYellowBlue: Double = 0
    var preserveLuminosity = true
    private var all: [Double] {
        [shadowCyanRed, shadowMagentaGreen, shadowYellowBlue,
         midCyanRed, midMagentaGreen, midYellowBlue,
         highlightCyanRed, highlightMagentaGreen, highlightYellowBlue]
    }
    var isValid: Bool { all.allSatisfy { $0.isFinite && Self.range.contains($0) } }
    var isIdentity: Bool { all.allSatisfy { $0 == 0 } }
    private static let memo = ImageAdjustmentPixels.Memo<ColorBalanceSettings>()
    func apply(_ image: CGImage) throws -> CGImage {
        guard isValid else { throw ProjectError.invalid }
        guard !isIdentity else { return image }
        return try Self.memo.value(image, key: self) {
            let shadows = [shadowCyanRed, shadowMagentaGreen, shadowYellowBlue].map { Float($0 / 100) }
            let midtones = [midCyanRed, midMagentaGreen, midYellowBlue].map { Float($0 / 100) }
            let highlights = [highlightCyanRed, highlightMagentaGreen, highlightYellowBlue].map { Float($0 / 100) }
            return try ImageAdjustmentPixels.run(image) { pixels, width, height, stride in
                adjust_color_balance(pixels, width, height, stride, shadows, midtones, highlights,
                                     preserveLuminosity ? 1 : 0)
            }
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
    /// 0–100: how much smaller, irregular detail roughens the main grain particles.
    var roughness: Double = 50
    var seed: UInt32 = 0
    var isValid: Bool { Self.amountRange.contains(amount) && Self.sizeRange.contains(size) && Self.roughnessRange.contains(roughness) }
    private struct ApplyKey: Equatable {
        var amount: Double
        var size: Double
        var roughness: Double
        var seed: UInt32
        var originX: Double
        var originY: Double
        var unitsPerPixel: Double
    }
    private static let memo = ImageAdjustmentPixels.Memo<ApplyKey>()
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
        let key = ApplyKey(amount: amount, size: size, roughness: roughness, seed: pattern,
                           originX: Double(origin.x), originY: Double(origin.y), unitsPerPixel: Double(unitsPerPixel))
        return try Self.memo.value(image, key: key) {
            try ImageAdjustmentPixels.run(image) { pixels, width, height, stride in
                adjust_grain(pixels, width, height, stride, amount, size, roughness, pattern,
                             Double(origin.x), Double(origin.y), Double(unitsPerPixel))
            }
        }
    }
}
