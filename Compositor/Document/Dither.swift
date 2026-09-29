import AppKit
import CoreText

/// Filter › Dither's looks, grouped as the panel's menu lists them. The order matches `DitherPixels.h`.
nonisolated enum DitherStyle: String, CaseIterable, Sendable {
    case atkinson = "Atkinson (Classic Mac)"
    case floydSteinberg = "Floyd–Steinberg"
    case bayer2 = "Bayer 2 × 2"
    case bayer4 = "Bayer 4 × 4"
    case bayer8 = "Bayer 8 × 8"
    case dots = "Halftone Dots"
    case lines = "Halftone Lines"
    case diamonds = "Halftone Diamonds"
    case patterns = "Mac Patterns"
    case ascii = "ASCII"

    static let groups: [[DitherStyle]] = [
        [.atkinson, .floydSteinberg],
        [.bayer2, .bayer4, .bayer8],
        [.dots, .lines, .diamonds],
        [.patterns, .ascii],
    ]
    var code: Int32 { Int32(Self.allCases.firstIndex(of: self)!) }
    /// Error diffusion: each pixel's rounding error is passed to its neighbors.
    var diffuses: Bool { Self.groups[0].contains(self) }
    /// Diffusion and ordered styles quantize to a number of tones; the rest draw marks in two.
    var hasTones: Bool { Self.groups[0].contains(self) || Self.groups[1].contains(self) }
    var isHalftone: Bool { Self.groups[2].contains(self) }
    /// Halftone shapes, patterns and characters mark one tone on the other, so which one is the mark matters.
    var drawsMarks: Bool { !hasTones }
}

/// How a chunky pixel is drawn: a solid square, or a round dot with the dark color showing around it, like the lit
/// pixels of a dot-matrix or LED screen.
nonisolated enum DitherPixelShape: String, CaseIterable, Sendable {
    case square = "Square"
    case dot = "Dot"
}

nonisolated enum DitherColors: String, CaseIterable, Sendable {
    case blackWhite = "Black & White"
    case twoColors = "Two Colors"
    case original = "Original"
}

nonisolated struct DitherSettings: Equatable, Sendable {
    static let pixelSizeRange: ClosedRange<Double> = 1...32
    static let cellSizeRange: ClosedRange<Double> = 4...64
    static let textSizeRange: ClosedRange<Double> = 6...64
    static let levelsRange: ClosedRange<Double> = 2...8
    static let defaultCharacters = " .:-=+*#%@"
    var style: DitherStyle = .atkinson
    /// Each dithered pixel covers this many layer pixels on a side, for chunky old-screen pixels.
    var pixelSize: Double = 2
    var pixelShape: DitherPixelShape = .square
    /// Halftone screen and character cells, in dithered pixels.
    var cellSize: Double = 8
    /// ASCII's line height in layer pixels; the characters are about six tenths as wide.
    var textSize: Double = 14
    /// Halftone screen angle in degrees.
    var angle: Double = 45
    /// Tones per channel for diffusion and ordered styles; 2 is 1-bit.
    var levels: Double = 2
    /// How much of the error diffusion passes on, 0–100%. Less gives flatter, posterized areas.
    var diffusion: Double = 100
    /// −100…100: more ink (darker) or less, and flatter or punchier, before dithering.
    var density: Double = 0
    var contrast: Double = 0
    var colors: DitherColors = .blackWhite
    var dark = AdjustmentColor(red: 0, green: 0, blue: 0)
    var light = AdjustmentColor(red: 1, green: 1, blue: 1)
    /// Marks stand for the light tones, drawn in the light color on the dark: glowing dots on a black screen. On by
    /// default; it only affects halftone, patterns and ASCII.
    var lightOnDark = true
    /// ASCII's characters, any order: they're sorted by how much ink each one has.
    var characters = defaultCharacters

    var normalized: Self {
        var result = self
        result.pixelSize = ImageAdjustmentPixels.clamp(pixelSize, Self.pixelSizeRange, 2).rounded()
        result.cellSize = ImageAdjustmentPixels.clamp(cellSize, Self.cellSizeRange, 8).rounded()
        result.textSize = ImageAdjustmentPixels.clamp(textSize, Self.textSizeRange, 14).rounded()
        result.angle = ImageAdjustmentPixels.clamp(angle, -90...90, 45)
        result.levels = ImageAdjustmentPixels.clamp(levels, Self.levelsRange, 2).rounded()
        result.diffusion = ImageAdjustmentPixels.clamp(diffusion, 0...100, 100)
        result.density = ImageAdjustmentPixels.clamp(density, -100...100, 0)
        result.contrast = ImageAdjustmentPixels.clamp(contrast, -100...100, 0)
        result.dark = dark.clamped
        result.light = light.clamped
        result.characters = String(characters.filter { !$0.isNewline }.prefix(64))
        return result
    }

    func apply(_ image: CGImage) throws -> CGImage {
        let settings = normalized
        // ASCII draws its characters at full resolution: shrinking the image first would blur and break them up.
        let block = settings.style == .ascii ? 1 : Int(settings.pixelSize)
        // Chunky pixels: dither a copy averaged down by the pixel size, then blow it back up without smoothing.
        var working = image
        if block > 1 {
            let width = (image.width + block - 1) / block, height = (image.height + block - 1) / block
            let small = try BrushRaster.context(width: width, height: height, mask: false)
            small.saveGState()
            small.interpolationQuality = .high
            small.translateBy(x: 0, y: CGFloat(image.height) / CGFloat(block))
            small.scaleBy(x: 1, y: -1)
            small.setBlendMode(.copy)
            small.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width) / CGFloat(block), height: CGFloat(image.height) / CGFloat(block)))
            small.restoreGState()
            guard let averaged = small.makeImage() else { throw ExportError.render }
            working = averaged
        }
        let dithered = try settings.dither(working)
        guard block > 1 else { return dithered }
        let full = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(dithered, in: CGRect(x: 0, y: 0, width: dithered.width * block, height: dithered.height * block), mask: false, context: full)
        if settings.pixelShape == .dot {
            guard let data = full.data else { throw ExportError.render }
            // The gaps are the dark color: black, or the one picked.
            var gap: [UInt8] = settings.colors == .twoColors ? settings.darkBytes : [0, 0, 0]
            dither_dots(data.assumingMemoryBound(to: UInt8.self), image.width, image.height, full.bytesPerRow, Int32(block), &gap)
        }
        guard let result = full.makeImage() else { throw ExportError.render }
        return result
    }

    private var darkBytes: [UInt8] {
        [UInt8((dark.red * 255).rounded()), UInt8((dark.green * 255).rounded()), UInt8((dark.blue * 255).rounded())]
    }

    private func dither(_ image: CGImage) throws -> CGImage {
        let cell = Int(cellSize)
        let glyphs: (maps: [UInt8], coverage: [Float], width: Int, height: Int) = style == .ascii
            ? Self.glyphs(characters.isEmpty ? Self.defaultCharacters : characters, lineHeight: Int(textSize)) : ([], [], 1, 1)
        func bytes(_ color: AdjustmentColor) -> (UInt8, UInt8, UInt8) {
            (UInt8((color.red * 255).rounded()), UInt8((color.green * 255).rounded()), UInt8((color.blue * 255).rounded()))
        }
        let (darkColor, lightColor) = colors == .twoColors ? (bytes(dark), bytes(light)) : ((0, 0, 0), (255, 255, 255))
        var failed = false
        let result = try ImageAdjustmentPixels.run(image) { pixels, width, height, stride in
            glyphs.maps.withUnsafeBufferPointer { maps in
                glyphs.coverage.withUnsafeBufferPointer { coverage in
                    var params = DitherParams(style: style.code, levels: Int32(levels), diffusion: Float(diffusion / 100),
                                              density: Float(density / 100), contrast: Float(contrast / 100), cell: Int32(cell),
                                              angle: Float(angle * .pi / 180), lightOnDark: lightOnDark ? 1 : 0,
                                              originalColors: colors == .original ? 1 : 0, dark: darkColor, light: lightColor,
                                              glyphWidth: Int32(glyphs.width), glyphHeight: Int32(glyphs.height), glyphs: maps.baseAddress, glyphCoverage: coverage.baseAddress,
                                              glyphCount: Int32(coverage.count))
                    failed = dither_apply(pixels, width, height, stride, &params) == 0
                }
            }
        }
        if failed { throw ExportError.render }
        return result
    }

    /// Each distinct character drawn into a cell of monospaced text, `lineHeight` tall and one character wide, on a
    /// shared baseline as a terminal lays them out, sorted from least ink to most.
    private static func glyphs(_ characters: String, lineHeight: Int) -> (maps: [UInt8], coverage: [Float], width: Int, height: Int) {
        let font = NSFont.monospacedSystemFont(ofSize: CGFloat(lineHeight) / 1.2, weight: .bold)
        let height = lineHeight
        let width = max(1, Int(("M" as NSString).size(withAttributes: [.font: font]).width.rounded()))
        let baseline = ((CGFloat(height) - (font.ascender - font.descender)) / 2 - font.descender).rounded()
        var drawn: [(map: [UInt8], coverage: Float)] = []
        var seen = Set<Character>()
        for character in characters where seen.insert(character).inserted {
            var map = [UInt8](repeating: 0, count: width * height)
            map.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(character), attributes: [
                    .font: font, .foregroundColor: NSColor.white,
                ]))
                context.textPosition = CGPoint(x: ((CGFloat(width) - CTLineGetTypographicBounds(line, nil, nil, nil)) / 2).rounded(), y: baseline)
                CTLineDraw(line, context)
            }
            drawn.append((map, Float(map.reduce(0) { $0 + Int($1) }) / Float(255 * width * height)))
        }
        drawn.sort { $0.coverage < $1.coverage }
        return (drawn.flatMap(\.map), drawn.map(\.coverage), width, height)
    }
}
