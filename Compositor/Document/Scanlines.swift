import AppKit
import CoreImage

/// Filter › Scanlines: the picture as a CRT draws it, in lines of light on a dark screen. The lines can bead into dots,
/// waver, rise with the picture's brightness into its shapes, stop below a threshold, and split their red and blue.
nonisolated struct ScanlinesSettings: Equatable, Sendable {
    static let lineSpacingRange: ClosedRange<Double> = 2...32
    static let wobbleRange: ClosedRange<Double> = 0...64
    static let displaceRange: ClosedRange<Double> = 0...64
    static let splitRange: ClosedRange<Double> = 0...16
    /// How far apart the lines are, in layer pixels.
    var lineSpacing: Double = 4
    /// How much of the gap a full-bright line fills, 5–100%; dimmer parts draw it thinner.
    var thickness: Double = 70
    /// 0–100%: light blooming around the lines, and how far they break into round dots.
    var glow: Double = 35
    var dots: Double = 0
    /// Pixels the lines waver sideways, in a wave down the screen.
    var wobble: Double = 0
    /// Pixels a line rises where the picture under it is bright, so the lines ripple into the picture's shapes.
    var displace: Double = 0
    /// 0–100%: tones darker than this draw no line, leaving the screen dark.
    var threshold: Double = 0
    /// Pixels the red and blue are moved apart, for colored fringes.
    var split: Double = 0
    /// −100…100: darker or lighter, and flatter or punchier, before the lines are drawn.
    var density: Double = 0
    var contrast: Double = 0
    var colors: DitherColors = .blackWhite
    var dark = AdjustmentColor(red: 0, green: 0, blue: 0)
    var light = AdjustmentColor(red: 1, green: 1, blue: 1)

    var normalized: Self {
        var result = self
        result.lineSpacing = ImageAdjustmentPixels.clamp(lineSpacing, Self.lineSpacingRange, 4).rounded()
        result.thickness = ImageAdjustmentPixels.clamp(thickness, 5...100, 70)
        result.glow = ImageAdjustmentPixels.clamp(glow, 0...100, 35)
        result.dots = ImageAdjustmentPixels.clamp(dots, 0...100, 0)
        result.wobble = ImageAdjustmentPixels.clamp(wobble, Self.wobbleRange, 0)
        result.displace = ImageAdjustmentPixels.clamp(displace, Self.displaceRange, 0)
        result.threshold = ImageAdjustmentPixels.clamp(threshold, 0...100, 0)
        result.split = ImageAdjustmentPixels.clamp(split, Self.splitRange, 0).rounded()
        result.density = ImageAdjustmentPixels.clamp(density, -100...100, 0)
        result.contrast = ImageAdjustmentPixels.clamp(contrast, -100...100, 0)
        result.dark = dark.clamped
        result.light = light.clamped
        return result
    }

    func apply(_ image: CGImage) throws -> CGImage {
        let settings = normalized
        func bytes(_ color: AdjustmentColor) -> (UInt8, UInt8, UInt8) {
            (UInt8((color.red * 255).rounded()), UInt8((color.green * 255).rounded()), UInt8((color.blue * 255).rounded()))
        }
        let (dark, light) = settings.colors == .twoColors ? (bytes(settings.dark), bytes(settings.light)) : ((0, 0, 0), (255, 255, 255))
        var failed = false
        let drawn = try ImageAdjustmentPixels.run(image) { pixels, width, height, stride in
            var params = ScanlinesParams(spacing: Int32(settings.lineSpacing), thickness: Float(settings.thickness / 100),
                                         dots: Float(settings.dots / 100), wobble: Float(settings.wobble),
                                         displace: Float(settings.displace), threshold: Float(settings.threshold / 100),
                                         split: Float(settings.split), density: Float(settings.density / 100),
                                         contrast: Float(settings.contrast / 100), originalColors: settings.colors == .original ? 1 : 0,
                                         dark: dark, light: light)
            failed = scanlines_apply(pixels, width, height, stride, &params) == 0
        }
        if failed { throw ExportError.render }
        return settings.glow > 0 ? try settings.glowing(drawn) : drawn
    }

    /// The lines' light, blurred across a few line spacings and added back over them, as a CRT's phosphors bloom.
    private func glowing(_ image: CGImage) throws -> CGImage {
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        // The glow is wide and soft, so it's blurred at a fraction of the size and scaled back up: the same light for a
        // small part of the work.
        let sigma = lineSpacing * 3 + 3, shrink = max(1, (sigma / 4).rounded(.down))
        let blurred = CIImage(cgImage: image).clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: 1 / shrink, y: 1 / shrink))
            .applyingGaussianBlur(sigma: sigma / shrink)
            .transformed(by: CGAffineTransform(scaleX: shrink, y: shrink))
            .cropped(to: extent)
        let bloom = try BrushRaster.copy(try PixelAdjust.render(blurred, width: image.width, height: image.height, isMask: false))
        let result = try BrushRaster.copy(image)
        guard let pixels = result.data, let light = bloom.data, bloom.bytesPerRow == result.bytesPerRow else { throw ExportError.render }
        dither_glow(pixels.assumingMemoryBound(to: UInt8.self), light.assumingMemoryBound(to: UInt8.self), image.width, image.height,
                    result.bytesPerRow, Float(glow / 100 * 2.5))
        guard let glowing = result.makeImage() else { throw ExportError.render }
        return glowing
    }
}
