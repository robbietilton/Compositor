import AppKit
import Testing
@testable import Compositor

@MainActor
struct OuterGlowTests {
    // MARK: - 1. Model & Codable Tests

    @Test func outerGlowDefaultsAndValidation() {
        let glow = OuterGlowEffect()
        #expect(glow.isEnabled == true)
        #expect(glow.size == 20)
        #expect(glow.opacity == 0.75)
        #expect(glow.isValid == true)

        var invalidSize = glow
        invalidSize.size = -1
        #expect(!invalidSize.isValid)

        var invalidOpacity = glow
        invalidOpacity.opacity = 1.5
        #expect(!invalidOpacity.isValid)

        var invalidColor = glow
        invalidColor.red = 2.0
        #expect(!invalidColor.isValid)
    }

    @Test func outerGlowCodableRoundTrip() throws {
        let original = OuterGlowEffect(enabled: true, size: 35, red: 0.2, green: 0.8, blue: 1.0, opacity: 0.6)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OuterGlowEffect.self, from: data)

        #expect(decoded == original)
        #expect(decoded.size == 35)
        #expect(decoded.red == 0.2)
        #expect(decoded.green == 0.8)
        #expect(decoded.blue == 1.0)
        #expect(decoded.opacity == 0.6)
        #expect(decoded.isEnabled == true)
    }

    @Test func layerEffectsIntegration() {
        var effects = LayerEffects()
        #expect(effects.isEmpty)
        #expect(!effects.contains(.outerGlow))

        effects.outerGlow = OuterGlowEffect(size: 25, red: 1, green: 0, blue: 0, opacity: 0.8)
        #expect(!effects.isEmpty)
        #expect(effects.contains(.outerGlow))
        #expect(effects.isEnabled(.outerGlow))
        #expect(effects.color(.outerGlow) == PaletteColor(red: 1, green: 0, blue: 0))

        effects.setColor(PaletteColor(red: 0, green: 1, blue: 0), for: .outerGlow)
        #expect(effects.outerGlow?.green == 1)
        #expect(effects.outerGlow?.red == 0)

        effects.setEnabled(false, for: .outerGlow)
        #expect(!effects.isEnabled(.outerGlow))
        #expect(effects.visible.outerGlow == nil)

        effects.remove(.outerGlow)
        #expect(effects.outerGlow == nil)
        #expect(effects.isEmpty)
    }

    @Test func layerEffectsCodableBackwardCompatibility() throws {
        // Decode older JSON without outerGlow
        let olderJSON = """
        {
            "stroke": { "size": 3, "red": 0, "green": 0, "blue": 0, "opacity": 1, "inside": false }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(LayerEffects.self, from: olderJSON)
        #expect(decoded.stroke?.size == 3)
        #expect(decoded.outerGlow == nil)
        #expect(decoded.isValid)

        // Encode with outerGlow and decode back
        var withGlow = decoded
        withGlow.outerGlow = OuterGlowEffect(size: 15, red: 1, green: 0.5, blue: 0, opacity: 0.9)
        let encoded = try JSONEncoder().encode(withGlow)
        let roundTrip = try JSONDecoder().decode(LayerEffects.self, from: encoded)
        #expect(roundTrip.outerGlow?.size == 15)
        #expect(roundTrip.outerGlow?.opacity == 0.9)
    }

    // MARK: - 2. Rendering & Omnidirectional Tests

    private func createSquareImage(size: Int = 40, innerSize: Int = 20, color: NSColor = .white) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                             bytesPerRow: size * 4, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: size, height: size))
        let origin = (size - innerSize) / 2
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: origin, y: origin, width: innerSize, height: innerSize))
        return try #require(context.makeImage())
    }

    @Test func outerGlowRendersOmnidirectionally() throws {
        // 40x40 image with 20x20 solid white square in the center (origin 10,10 to 30,30)
        let image = try createSquareImage(size: 40, innerSize: 20, color: .white)
        let effects = LayerEffects(outerGlow: OuterGlowEffect(enabled: true, size: 10, red: 0, green: 1, blue: 0, opacity: 1.0))

        let (rendered, inset) = try LayerEffectsRenderer.render(image, mask: nil, effects: effects)
        #expect(inset > 0)
        let bitmap = NSBitmapImageRep(cgImage: rendered)

        // Center of square in rendered coordinates
        let centerX = Int(inset) + 20
        let centerY = Int(inset) + 20

        // 1. Source interior remains intact and sharp white
        let centerPixel = try #require(bitmap.colorAt(x: centerX, y: centerY))
        #expect(centerPixel.alphaComponent > 0.95)
        #expect(centerPixel.redComponent > 0.95)
        #expect(centerPixel.greenComponent > 0.95)
        #expect(centerPixel.blueComponent > 0.95)

        // 2. Pixels outside the square have the green glow
        let leftGlow = try #require(bitmap.colorAt(x: Int(inset) + 5, y: centerY))
        let rightGlow = try #require(bitmap.colorAt(x: Int(inset) + 35, y: centerY))
        let topGlow = try #require(bitmap.colorAt(x: centerX, y: Int(inset) + 5))
        let bottomGlow = try #require(bitmap.colorAt(x: centerX, y: Int(inset) + 35))

        // All 4 cardinal directions must have non-zero alpha and green glow color
        #expect(leftGlow.alphaComponent > 0.1)
        #expect(rightGlow.alphaComponent > 0.1)
        #expect(topGlow.alphaComponent > 0.1)
        #expect(bottomGlow.alphaComponent > 0.1)

        #expect(leftGlow.greenComponent > 0.8)
        #expect(rightGlow.greenComponent > 0.8)
        #expect(topGlow.greenComponent > 0.8)
        #expect(bottomGlow.greenComponent > 0.8)

        // Omnidirectional symmetry: distances are identical so alpha values are symmetric within tolerance
        #expect(abs(leftGlow.alphaComponent - rightGlow.alphaComponent) < 0.05)
        #expect(abs(topGlow.alphaComponent - bottomGlow.alphaComponent) < 0.05)
        #expect(abs(leftGlow.alphaComponent - topGlow.alphaComponent) < 0.05)
    }

    @Test func outerGlowSizeAndOpacityVariations() throws {
        let image = try createSquareImage(size: 40, innerSize: 20, color: .white)

        // Small glow vs Large glow
        let smallGlowEffects = LayerEffects(outerGlow: OuterGlowEffect(enabled: true, size: 4, red: 1, green: 0, blue: 0, opacity: 1.0))
        let largeGlowEffects = LayerEffects(outerGlow: OuterGlowEffect(enabled: true, size: 20, red: 1, green: 0, blue: 0, opacity: 1.0))

        let (smallRendered, smallInset) = try LayerEffectsRenderer.render(image, mask: nil, effects: smallGlowEffects)
        let (largeRendered, largeInset) = try LayerEffectsRenderer.render(image, mask: nil, effects: largeGlowEffects)

        #expect(largeInset > smallInset)

        // Sample point 8px outside square (square starts at inset + 10)
        let smallBitmap = NSBitmapImageRep(cgImage: smallRendered)
        let largeBitmap = NSBitmapImageRep(cgImage: largeRendered)

        let smallFar = try #require(smallBitmap.colorAt(x: Int(smallInset) + 2, y: Int(smallInset) + 20))
        let largeFar = try #require(largeBitmap.colorAt(x: Int(largeInset) + 2, y: Int(largeInset) + 20))

        // Larger glow reaches further out
        #expect(largeFar.alphaComponent > smallFar.alphaComponent)

        // Low opacity vs High opacity
        let lowOpacity = LayerEffects(outerGlow: OuterGlowEffect(enabled: true, size: 10, red: 0, green: 0, blue: 1, opacity: 0.2))
        let highOpacity = LayerEffects(outerGlow: OuterGlowEffect(enabled: true, size: 10, red: 0, green: 0, blue: 1, opacity: 1.0))

        let (lowRendered, lowInset) = try LayerEffectsRenderer.render(image, mask: nil, effects: lowOpacity)
        let (highRendered, highInset) = try LayerEffectsRenderer.render(image, mask: nil, effects: highOpacity)

        let lowBitmap = NSBitmapImageRep(cgImage: lowRendered)
        let highBitmap = NSBitmapImageRep(cgImage: highRendered)

        let lowSample = try #require(lowBitmap.colorAt(x: Int(lowInset) + 5, y: Int(lowInset) + 20))
        let highSample = try #require(highBitmap.colorAt(x: Int(highInset) + 5, y: Int(highInset) + 20))

        #expect(highSample.alphaComponent > lowSample.alphaComponent)
    }

    // MARK: - 3. Text / Glyph Rendering Test

    @Test func outerGlowRendersAroundTextGlyphs() throws {
        // Create an image containing a T-shaped glyph silhouette with transparent background
        let size = CGSize(width: 60, height: 60)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                             bytesPerRow: Int(size.width) * 4, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(origin: .zero, size: size))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        // T-glyph silhouette: top bar (x: 15..45, y: 15..23) and stem (x: 26..34, y: 23..45)
        context.fill([
            CGRect(x: 15, y: 15, width: 30, height: 8),
            CGRect(x: 26, y: 23, width: 8, height: 22)
        ])
        let glyphImage = try #require(context.makeImage())

        // Apply Cyan Outer Glow
        let glowEffect = OuterGlowEffect(enabled: true, size: 8, red: 0, green: 1, blue: 1, opacity: 1.0)
        let effects = LayerEffects(outerGlow: glowEffect)

        let (rendered, inset) = try LayerEffectsRenderer.render(glyphImage, mask: nil, effects: effects)
        let bitmap = NSBitmapImageRep(cgImage: rendered)

        // Point inside the glyph stem should be white
        let glyphStemX = Int(inset) + 30
        let glyphStemY = Int(inset) + 30
        let stemColor = try #require(bitmap.colorAt(x: glyphStemX, y: glyphStemY))
        #expect(stemColor.alphaComponent > 0.9)
        #expect(stemColor.redComponent > 0.9)
        #expect(stemColor.greenComponent > 0.9)
        #expect(stemColor.blueComponent > 0.9)

        // Point 3px above the top bar of "T" (outside the glyph silhouette)
        let glowTopX = Int(inset) + 30
        let glowTopY = Int(inset) + 12
        let topGlowColor = try #require(bitmap.colorAt(x: glowTopX, y: glowTopY))
        #expect(topGlowColor.alphaComponent > 0.05)
        #expect(topGlowColor.greenComponent > 0.5)
        #expect(topGlowColor.blueComponent > 0.5)

        // Point in the concave notch under the left arm (outside the glyph silhouette)
        let notchX = Int(inset) + 20
        let notchY = Int(inset) + 27
        let notchGlowColor = try #require(bitmap.colorAt(x: notchX, y: notchY))
        #expect(notchGlowColor.alphaComponent > 0.05)
        #expect(notchGlowColor.greenComponent > 0.5)
        #expect(notchGlowColor.blueComponent > 0.5)
    }

    // MARK: - 4. Effect Combination Tests

    @Test func outerGlowCombinedWithStrokeAndDropShadow() throws {
        let image = try createSquareImage(size: 50, innerSize: 20, color: .white)
        var effects = LayerEffects()
        // Black outside stroke of 3px
        effects.stroke = StrokeEffect(size: 3, red: 0, green: 0, blue: 0, opacity: 1.0, inside: false)
        // Red outer glow of 10px
        effects.outerGlow = OuterGlowEffect(enabled: true, size: 10, red: 1, green: 0, blue: 0, opacity: 1.0)
        // Blue drop shadow cast to the right (angle 180 casts shadow at dx = +25, dy = 0)
        effects.shadow = ShadowEffect(enabled: true, angle: 180, distance: 25, blur: 4, red: 0, green: 0, blue: 1, opacity: 1.0)

        let (rendered, inset) = try LayerEffectsRenderer.render(image, mask: nil, effects: effects)
        let bitmap = NSBitmapImageRep(cgImage: rendered)

        let centerX = Int(inset) + 25
        let centerY = Int(inset) + 25

        // Center source is still white
        let center = try #require(bitmap.colorAt(x: centerX, y: centerY))
        #expect(center.redComponent > 0.9 && center.greenComponent > 0.9 && center.blueComponent > 0.9)

        // Stroke at 2px outside the 20x20 square border
        let strokePixel = try #require(bitmap.colorAt(x: Int(inset) + 13, y: centerY))
        #expect(strokePixel.alphaComponent > 0.9)
        #expect(strokePixel.redComponent < 0.2 && strokePixel.greenComponent < 0.2 && strokePixel.blueComponent < 0.2)

        // Glow to the left of the square (away from shadow)
        let glowPixel = try #require(bitmap.colorAt(x: Int(inset) + 10, y: centerY))
        #expect(glowPixel.alphaComponent > 0.05)
        #expect(glowPixel.redComponent > 0.6)

        // Drop shadow to the right of the square
        let shadowPixel = try #require(bitmap.colorAt(x: centerX + 25, y: centerY))
        #expect(shadowPixel.alphaComponent > 0.1)
        #expect(shadowPixel.blueComponent > 0.6)
    }

    // MARK: - 5. Export Test

    @Test func outerGlowPreservedInExport() async throws {
        let image = try createSquareImage(size: 30, innerSize: 10, color: .white)
        let id = UUID()
        let transform = LayerTransform(origin: CGPoint(x: 20, y: 20), size: CGSize(width: 30, height: 30))
        let effects = LayerEffects(outerGlow: OuterGlowEffect(enabled: true, size: 15, red: 1, green: 0.5, blue: 0, opacity: 1.0))

        let record = ProjectLayerRecord(id: id, name: "GlowLayer", isVisible: true, transform: transform,
                                        imageFile: "\(id).png", effects: effects)
        let manifest = ProjectManifest(documentID: UUID(), width: 100, height: 100, activeLayerID: id, layers: [record])
        let snapshot = ProjectSnapshot(manifest: manifest, images: [id: ImportedImage(image: image, thumbnail: image, name: "GlowLayer")])

        let pngData = try await ImageExporter.shared.pngData(snapshot)
        let rep = try #require(NSBitmapImageRep(data: pngData))

        // Center pixel (35, 35) must be white
        let centerPixel = try #require(rep.colorAt(x: 35, y: 35))
        #expect(centerPixel.alphaComponent > 0.9)

        // Glow pixel 3px outside the 10x10 square (e.g. at 27, 35)
        let glowPixel = try #require(rep.colorAt(x: 27, y: 35))
        #expect(glowPixel.alphaComponent > 0.1)
        #expect(glowPixel.redComponent > 0.6)
    }

    // MARK: - 6. CPU & Metal Parity Test

    @Test func outerGlowCPUAndMetalParity() throws {
        let image = try createSquareImage(size: 40, innerSize: 20, color: .white)
        let glow = OuterGlowEffect(enabled: true, size: 10, red: 0, green: 0.8, blue: 1.0, opacity: 1.0)
        let effects = LayerEffects(outerGlow: glow)

        // 1. Metal rendering (via LayerEffectsRenderer.render)
        let (metalResult, inset) = try LayerEffectsRenderer.render(image, mask: nil, effects: effects)
        let metalBitmap = NSBitmapImageRep(cgImage: metalResult)

        // 2. CPU fallback rendering (direct execution of CPU coverage and compositing)
        let width = image.width + Int(inset) * 2, height = image.height + Int(inset) * 2
        let placed = CGRect(x: inset, y: inset, width: CGFloat(image.width), height: CGFloat(image.height))
        let full = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        let cpuCoverage = try LayerEffectsRenderer.outerGlowCoverage(image, placed: placed, size: CGSize(width: width, height: height), glow: glow)
        BrushRaster.fill(CGColor(srgbRed: glow.red, green: glow.green, blue: glow.blue, alpha: 1),
                         coverage: cpuCoverage, in: full, alpha: CGFloat(glow.opacity), context: context)
        context.saveGState()
        context.translateBy(x: placed.minX, y: placed.maxY)
        context.scaleBy(x: 1, y: -1)
        context.setBlendMode(.normal)
        context.draw(image, in: CGRect(origin: .zero, size: placed.size))
        context.restoreGState()
        let cpuResult = try #require(context.makeImage())
        let cpuBitmap = NSBitmapImageRep(cgImage: cpuResult)

        // Compare sample points outside the square (e.g. at x = Int(inset) + 5, y = Int(inset) + 20)
        let sampleX = Int(inset) + 5
        let sampleY = Int(inset) + 20
        let metalColor = try #require(metalBitmap.colorAt(x: sampleX, y: sampleY))
        let cpuColor = try #require(cpuBitmap.colorAt(x: sampleX, y: sampleY))

        // Both must have non-zero alpha and matching cyan tint
        #expect(metalColor.alphaComponent > 0.1)
        #expect(cpuColor.alphaComponent > 0.1)
        #expect(abs(metalColor.alphaComponent - cpuColor.alphaComponent) < 0.15)
        #expect(abs(metalColor.greenComponent - cpuColor.greenComponent) < 0.1)
        #expect(abs(metalColor.blueComponent - cpuColor.blueComponent) < 0.1)

        // Both keep the source interior solid white
        let centerMetal = try #require(metalBitmap.colorAt(x: Int(inset) + 20, y: Int(inset) + 20))
        let centerCPU = try #require(cpuBitmap.colorAt(x: Int(inset) + 20, y: Int(inset) + 20))
        #expect(centerMetal.redComponent > 0.95 && centerCPU.redComponent > 0.95)
    }
}
