import CoreGraphics
import Testing
@testable import Compositor

@Suite struct ColorOverlayTests {
    private func square(_ color: CGColor, size: Int = 20) throws -> CGImage {
        let context = try BrushRaster.context(width: size, height: size, mask: false)
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return try #require(context.makeImage())
    }

    /// The premultiplied RGBA bytes at the middle of `image`.
    private func middle(of image: CGImage) throws -> [Int] {
        let context = try BrushRaster.copy(image)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = (image.height / 2) * context.bytesPerRow + (image.width / 2) * 4
        return (0..<4).map { Int(bytes[offset + $0]) }
    }

    @Test func overlayRecolorsTranslucentPixelsAndKeepsTheirAlpha() throws {
        // Half-transparent black under a white overlay: it should turn half-transparent white, which covers a white
        // background completely, not half-transparent grey that leaves a grey band.
        var effects = LayerEffects()
        effects.colorOverlay = ColorOverlayEffect(red: 1, green: 1, blue: 1, opacity: 1)
        let source = try square(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.5))
        let pixel = try middle(of: LayerEffectsRenderer.render(source, mask: nil, effects: effects).image)
        #expect(abs(pixel[3] - 128) <= 1)
        for channel in 0..<3 { #expect(abs(pixel[channel] - pixel[3]) <= 1) }
    }

    @Test func overlayOpacityMixesWithTheLayersOwnColor() throws {
        var effects = LayerEffects()
        effects.colorOverlay = ColorOverlayEffect(red: 0, green: 0, blue: 1, opacity: 0.5)
        let source = try square(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        let pixel = try middle(of: LayerEffectsRenderer.render(source, mask: nil, effects: effects).image)
        #expect(abs(pixel[0] - 128) <= 2 && pixel[1] <= 2 && abs(pixel[2] - 128) <= 2 && pixel[3] == 255)
    }

    @Test func overlayLeavesTheShadowBeneathTranslucentPixels() throws {
        // A red shadow straight under half-transparent black: the overlay recolors the layer, not the shadow, so the
        // result is half-transparent white over the shadow, itself half-transparent red as it follows the layer.
        var effects = LayerEffects()
        effects.colorOverlay = ColorOverlayEffect(red: 1, green: 1, blue: 1, opacity: 1)
        effects.shadow = ShadowEffect(angle: 90, distance: 0, blur: 0, red: 1, green: 0, blue: 0, opacity: 1)
        let source = try square(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.5))
        let pixel = try middle(of: LayerEffectsRenderer.render(source, mask: nil, effects: effects).image)
        #expect(abs(pixel[0] - 192) <= 2 && abs(pixel[1] - 128) <= 2 && abs(pixel[2] - 128) <= 2 && abs(pixel[3] - 192) <= 2)
    }
}
