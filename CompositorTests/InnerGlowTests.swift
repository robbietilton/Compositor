import AppKit
import Testing
@testable import Compositor

@Suite struct InnerGlowTests {
    private func solidSquare(size: Int = 40, color: PaletteColor = PaletteColor(red: 1, green: 1, blue: 1)) throws -> CGImage {
        let context = try BrushRaster.context(width: size, height: size, mask: false)
        context.setFillColor(CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return try #require(context.makeImage())
    }

    @Test func innerGlowDefaultsAndValidation() {
        let effect = InnerGlowEffect()
        #expect(effect.size == 10)
        #expect(effect.opacity == 0.75)
        #expect(effect.color == PaletteColor(red: 1, green: 1, blue: 1))
        #expect(effect.isEnabled == true)
        #expect(effect.isValid)

        var invalidSize = effect
        invalidSize.size = -1
        #expect(!invalidSize.isValid)

        var invalidOpacity = effect
        invalidOpacity.opacity = 1.5
        #expect(!invalidOpacity.isValid)

        var invalidColor = effect
        invalidColor.red = 2.0
        #expect(!invalidColor.isValid)
    }

    @Test func innerGlowCodableRoundTrip() throws {
        var effect = InnerGlowEffect()
        effect.size = 25
        effect.red = 1
        effect.green = 0.5
        effect.blue = 0.2
        effect.opacity = 0.85
        effect.enabled = true

        let data = try JSONEncoder().encode(effect)
        let decoded = try JSONDecoder().decode(InnerGlowEffect.self, from: data)

        #expect(decoded == effect)
        #expect(decoded.size == 25)
        #expect(decoded.opacity == 0.85)
        #expect(decoded.color == PaletteColor(red: 1, green: 0.5, blue: 0.2))
        #expect(decoded.isEnabled == true)
    }

    @Test func innerGlowBackwardCompatibility() throws {
        // Simulates an older project JSON without innerGlow
        let olderJSON = """
        {
            "shadow": {
                "angle": 90,
                "distance": 10,
                "blur": 15,
                "red": 0,
                "green": 0,
                "blue": 0,
                "opacity": 0.5
            }
        }
        """.data(using: .utf8)!

        let effects = try JSONDecoder().decode(LayerEffects.self, from: olderJSON)
        #expect(effects.shadow != nil)
        #expect(effects.innerGlow == nil)
        #expect(effects.isValid)
    }

    @Test func layerEffectsIntegration() {
        var effects = LayerEffects()
        #expect(!effects.contains(.innerGlow))
        #expect(effects.isEmpty)

        var glow = InnerGlowEffect()
        glow.size = 15
        effects.innerGlow = glow
        #expect(effects.contains(.innerGlow))
        #expect(effects.isEnabled(.innerGlow))
        #expect(!effects.isEmpty)
        #expect(effects.kinds.contains(.innerGlow))

        // Disabling
        effects.setEnabled(false, for: .innerGlow)
        #expect(!effects.isEnabled(.innerGlow))
        #expect(effects.visible.innerGlow == nil)

        // Color access
        effects.setColor(PaletteColor(red: 1, green: 0.8, blue: 0), for: .innerGlow)
        #expect(effects.color(.innerGlow) == PaletteColor(red: 1, green: 0.8, blue: 0))

        // Removal
        effects.remove(.innerGlow)
        #expect(!effects.contains(.innerGlow))
        #expect(effects.isEmpty)
    }

    @Test func innerGlowRendersInsideSourceWithoutBoundsExpansion() throws {
        let source = try solidSquare(size: 40, color: PaletteColor(red: 0, green: 0, blue: 0)) // Black square
        var glow = InnerGlowEffect()
        glow.red = 1; glow.green = 1; glow.blue = 0 // Yellow inner glow
        glow.size = 12
        glow.opacity = 1.0

        var effects = LayerEffects()
        effects.innerGlow = glow

        // Margin should not expand for inner glow (remains baseline 2)
        let margin = LayerEffectsRenderer.margin(for: effects)
        #expect(margin == 2)

        let rendered = try LayerEffectsRenderer.render(source, mask: nil, effects: effects)
        let image = rendered.image
        let inset = rendered.inset

        let bitmap = NSBitmapImageRep(cgImage: image)

        // The outer padding area (e.g. x = 0, y = 0) must remain completely transparent
        let outsideColor = try #require(bitmap.colorAt(x: 0, y: 0))
        #expect(outsideColor.alphaComponent == 0)

        // Near the edge inside the square (e.g. x = Int(inset) + 2, y = Int(inset) + 20), inner glow should tint the pixel yellow
        let edgeX = Int(inset) + 2
        let edgeY = Int(inset) + 20
        let edgeColor = try #require(bitmap.colorAt(x: edgeX, y: edgeY))
        #expect(edgeColor.alphaComponent > 0.9)
        #expect(edgeColor.redComponent > 0.3 && edgeColor.greenComponent > 0.3)

        // In the deep center (x = Int(inset) + 20, y = Int(inset) + 20), the black source dominates
        let centerX = Int(inset) + 20
        let centerY = Int(inset) + 20
        let centerColor = try #require(bitmap.colorAt(x: centerX, y: centerY))
        #expect(centerColor.redComponent < 0.2 && centerColor.greenComponent < 0.2)
    }

    @Test func innerGlowRendersAroundTextGlyphs() throws {
        var style = LayerTextStyle()
        style.content = "O"
        style.fontSize = 72
        style.red = 0; style.green = 0; style.blue = 0 // Black text

        let textImage = try EditorSession.textImage(style)
        var glow = InnerGlowEffect()
        glow.red = 1; glow.green = 0; glow.blue = 0 // Red inner glow
        glow.size = 8
        glow.opacity = 0.9

        var effects = LayerEffects()
        effects.innerGlow = glow

        let rendered = try LayerEffectsRenderer.render(textImage, mask: nil, effects: effects)
        #expect(rendered.image.width >= textImage.width)
        #expect(rendered.image.height >= textImage.height)

        let bitmap = NSBitmapImageRep(cgImage: rendered.image)
        let inset = Int(rendered.inset)

        // Outside glyph bounds must be transparent
        let outside = try #require(bitmap.colorAt(x: 0, y: 0))
        #expect(outside.alphaComponent == 0)

        // Search for a glyph pixel that has inner glow tinting
        var foundGlow = false
        for y in inset..<(rendered.image.height - inset) {
            for x in inset..<(rendered.image.width - inset) {
                if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.5, color.redComponent > 0.3 {
                    foundGlow = true
                    break
                }
            }
            if foundGlow { break }
        }
        #expect(foundGlow)
    }

    @Test func innerGlowCPUAndMetalParity() throws {
        guard let metal = MetalLayerEffects.shared else { return }

        let source = try solidSquare(size: 40, color: PaletteColor(red: 0.1, green: 0.1, blue: 0.1))
        var glow = InnerGlowEffect()
        glow.red = 0; glow.green = 1; glow.blue = 1 // Cyan inner glow
        glow.size = 10
        glow.opacity = 0.8

        var effects = LayerEffects()
        effects.innerGlow = glow

        let inset = LayerEffectsRenderer.margin(for: effects)
        let width = source.width + Int(inset) * 2
        let height = source.height + Int(inset) * 2
        let placed = CGRect(x: inset, y: inset, width: CGFloat(source.width), height: CGFloat(source.height))

        let padded = try BrushRaster.context(width: width, height: height, mask: false)
        BrushRaster.draw(source, in: placed, mask: false, context: padded)
        let room = try #require(padded.makeImage())

        let metalImage = try metal.render(room, effects: effects)
        let metalBitmap = NSBitmapImageRep(cgImage: metalImage)

        let rendered = try LayerEffectsRenderer.render(source, mask: nil, effects: effects)
        let cpuBitmap = NSBitmapImageRep(cgImage: rendered.image)

        // Compare an edge point inside the square where inner glow is active
        let edgeX = Int(inset) + 3
        let edgeY = Int(inset) + 20
        let metalColor = try #require(metalBitmap.colorAt(x: edgeX, y: edgeY))
        let cpuColor = try #require(cpuBitmap.colorAt(x: edgeX, y: edgeY))

        #expect(abs(metalColor.alphaComponent - cpuColor.alphaComponent) < 0.15)
        #expect(abs(metalColor.greenComponent - cpuColor.greenComponent) < 0.2)
        #expect(abs(metalColor.blueComponent - cpuColor.blueComponent) < 0.2)
    }

    @Test func innerGlowPreservedInExport() async throws {
        let image = try solidSquare(size: 30, color: PaletteColor(red: 0, green: 0, blue: 0))
        let id = UUID()
        let transform = LayerTransform(origin: CGPoint(x: 20, y: 20), size: CGSize(width: 30, height: 30))
        var glow = InnerGlowEffect()
        glow.red = 1; glow.green = 0; glow.blue = 1 // Magenta
        glow.size = 8
        glow.opacity = 0.9

        let effects = LayerEffects(innerGlow: glow)
        let record = ProjectLayerRecord(id: id, name: "InnerGlowLayer", isVisible: true, transform: transform,
                                        imageFile: "\(id).png", effects: effects)
        let manifest = ProjectManifest(documentID: UUID(), width: 100, height: 100, activeLayerID: id, layers: [record])
        let snapshot = ProjectSnapshot(manifest: manifest, images: [id: ImportedImage(image: image, thumbnail: image, name: "InnerGlowLayer")])

        let pngData = try await ImageExporter.shared.pngData(snapshot)
        let rep = try #require(NSBitmapImageRep(data: pngData))

        // Search for an edge pixel inside the 30x30 square placed at (20, 20) with inner glow
        var found = false
        for x in 21...28 {
            if let color = rep.colorAt(x: x, y: 35) {
                if color.alphaComponent > 0.8 && color.redComponent > 0.2 && color.blueComponent > 0.2 {
                    found = true
                    break
                }
            }
        }
        #expect(found)
    }
}
