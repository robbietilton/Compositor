import AppKit
import Testing
@testable import Compositor

@MainActor
struct FinishingFilterTests {
    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self),
                                         count: image.width * image.height * 4))
    }

    private func apply(_ kind: FilterKind, to source: CGImage, settings: FilterSettings) throws -> [UInt8] {
        let image = try PixelFilter.run(FilterJob(kind: kind, image: source, settings: settings,
                                                  scale: 1, selection: nil, mapping: .identity))
        return try pixels(image)
    }

    @Test func vignetteDarkensCornersWhileKeepingCenterAndAlpha() throws {
        let context = try BrushRaster.context(width: 41, height: 41, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.8, green: 0.8, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 41, height: 41))
        let source = try #require(context.makeImage())
        var settings = FilterSettings()
        settings.vignetteAmount = 80
        let result = try apply(.vignette, to: source, settings: settings)
        let corner = 0, center = (20 * 41 + 20) * 4
        #expect(Int(result[center]) > Int(result[corner]) + 50)
        #expect(abs(Int(result[center]) - 204) <= 2)
        #expect(stride(from: 3, to: result.count, by: 4).allSatisfy { result[$0] == 255 })
    }

    @Test func vignetteBlendsSelectedColorOnlyAtEdges() throws {
        let context = try BrushRaster.context(width: 41, height: 41, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 41, height: 41))
        let source = try #require(context.makeImage())
        var settings = FilterSettings()
        settings.vignetteAmount = 100
        settings.vignetteHighlights = 0
        settings.vignetteColor = AdjustmentColor(red: 1, green: 0, blue: 0)
        let result = try apply(.vignette, to: source, settings: settings)
        let corner = 0, center = (20 * 41 + 20) * 4
        #expect(Int(result[corner]) > Int(result[corner + 1]) + 80)
        #expect(abs(Int(result[center]) - Int(result[center + 1])) <= 2)
        #expect(abs(Int(result[center]) - 128) <= 2)
        #expect(stride(from: 3, to: result.count, by: 4).allSatisfy { result[$0] == 255 })
    }

    @Test func bloomSpreadsLightFromBrightPixels() throws {
        let context = try BrushRaster.context(width: 65, height: 65, mask: false)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 65, height: 65))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 30, y: 30, width: 5, height: 5))
        let source = try #require(context.makeImage())
        var settings = FilterSettings()
        settings.bloomAmount = 100
        settings.bloomRadius = 12
        let result = try apply(.bloomGlow, to: source, settings: settings)
        let nearLight = (32 * 65 + 40) * 4
        let corner = (2 * 65 + 2) * 4
        #expect(result[nearLight] > result[corner])
        #expect(result[nearLight] > 0)
        #expect(stride(from: 3, to: result.count, by: 4).allSatisfy { result[$0] == 255 })

        let transparent = try BrushRaster.context(width: 65, height: 65, mask: false)
        transparent.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        transparent.fill(CGRect(x: 30, y: 30, width: 5, height: 5))
        let isolatedLight = try #require(transparent.makeImage())
        let spread = try apply(.bloomGlow, to: isolatedLight, settings: settings)
        #expect(spread[nearLight + 3] > 0, "bloom must remain visible beyond a transparent layer's bright pixels")
    }

    @Test func tonalContrastIncreasesMidtoneDetailWithoutChangingAlpha() throws {
        let context = try BrushRaster.context(width: 64, height: 16, mask: false)
        for stripe in 0..<8 {
            let gray: CGFloat = stripe.isMultiple(of: 2) ? 0.4 : 0.6
            context.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
            context.fill(CGRect(x: stripe * 8, y: 0, width: 8, height: 16))
        }
        let source = try #require(context.makeImage())
        let original = try pixels(source)
        var settings = FilterSettings()
        settings.tonalAmount = 100
        settings.tonalShadows = 0
        settings.tonalMidtones = 100
        settings.tonalHighlights = 0
        settings.tonalRadius = 6
        let result = try apply(.tonalContrast, to: source, settings: settings)
        let dark = (8 * 64 + 5) * 4, light = (8 * 64 + 13) * 4
        #expect(result[dark] < original[dark])
        #expect(result[light] > original[light])
        #expect(stride(from: 3, to: result.count, by: 4).allSatisfy { result[$0] == 255 })
    }

    @Test func eachFilterCommitsAsOneUndoStepAndKeepsLayerEffects() async throws {
        for kind in [FilterKind.vignette, .bloomGlow, .tonalContrast] {
            let session = EditorSession()
            session.createDocument(width: 48, height: 48)
            let context = try BrushRaster.context(width: 24, height: 24, mask: false)
            context.setFillColor(CGColor(srgbRed: 0.7, green: 0.7, blue: 0.7, alpha: 1))
            context.fill(CGRect(x: 3, y: 3, width: 18, height: 18))
            let image = try #require(context.makeImage())
            session.insert(ImportedImage(image: image, thumbnail: image, name: "Sample"))
            let effects = LayerEffects(stroke: StrokeEffect(size: 3))
            let index = try #require(session.document?.layers.firstIndex(where: { $0.id == session.activeLayerID }))
            session.document?.layers[index].effects = effects
            session.beginFilter(kind)
            #expect(session.filterEdit?.kind == kind)
            let undoCount = session.history.undoCount
            await session.commitFilter()
            #expect(session.filterEdit == nil)
            #expect(session.history.undoCount == undoCount + 1)
            #expect(session.activeLayer?.effects == effects)
        }
    }
}
