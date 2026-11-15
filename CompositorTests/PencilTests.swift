import AppKit
import Testing
@testable import Compositor

/// The Brush with Anti-alias off is a pencil: every pixel it paints is fully painted, with no soft edge, on the GPU and
/// in the CPU fallback alike, whatever Hardness was left at.
@MainActor struct PencilTests {
    private func alphas(_ image: CGImage) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<(image.width * image.height)).map { bytes[$0 * 4 + 3] }
    }

    private func paint(antialiased: Bool) async throws -> [UInt8] {
        let session = EditorSession()
        session.createDocument(width: 120, height: 120)
        session.addBlankLayer()
        session.selectTool(.brush)
        session.brushSettings = BrushSettings(diameter: 17, hardness: 0.3, red: 1, green: 0, blue: 0)
        session.brushSettings.antialiased = antialiased
        session.beginBrush(at: CGPoint(x: 20, y: 25))
        session.continueBrush(at: CGPoint(x: 95, y: 70))
        await session.finishBrush()
        #expect(session.brushError == nil)
        return try alphas(#require(session.activeLayer?.asset?.image))
    }

    @Test func aPencilStrokeHasNoSoftPixels() async throws {
        let pencil = try await paint(antialiased: false)
        #expect(pencil.contains(255), "the pencil painted nothing")
        #expect(pencil.allSatisfy { $0 == 0 || $0 == 255 }, "soft pixels: \(Set(pencil).sorted().prefix(12))")
        // The brush as it was still has its soft edge.
        let brush = try await paint(antialiased: true)
        #expect(brush.contains { $0 > 0 && $0 < 255 })
    }

    @Test func theCPUFallbackPencilIsHardToo() throws {
        let session = EditorSession()
        session.createDocument(width: 120, height: 120)
        session.addBlankLayer()
        var settings = BrushSettings(diameter: 17, hardness: 1, red: 1, green: 0, blue: 0)
        settings.antialiased = false
        let stroke = try BrushStroke(layer: #require(session.activeLayer), mask: false, settings: settings,
                                     canvas: CGSize(width: 120, height: 120), useGPU: false)
        try stroke.append(CGPoint(x: 20, y: 25))
        try stroke.append(CGPoint(x: 95, y: 70))
        try stroke.flush()
        let values = try alphas(stroke.paintSnapshot().asset.image)
        #expect(values.contains(255))
        #expect(values.allSatisfy { $0 == 0 || $0 == 255 }, "soft pixels: \(Set(values).sorted().prefix(12))")
    }
}
