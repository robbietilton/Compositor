import AppKit
import Testing
@testable import Compositor

/// Effects on the canvas around a layer too large for the canvas to make them at its own size.
@MainActor struct LargeLayerEffectsTests {
    enum Effect: String, CaseIterable { case outerGlow, innerGlow, innerShadow }

    /// The canvas makes a large layer's effects from a smaller copy of it, and makes the effects smaller with it, so a
    /// glow or an inner shadow reaches as far on the canvas as in the exported image.
    @Test(arguments: Effect.allCases)
    func effectsOfALargeLayerReachAsFarAsWhenExported(effect: Effect) async throws {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 640, height: 100), backingScale: 1, documentSize: nil)
        session.createDocument(width: 2400, height: 400)
        func solid(red: CGFloat, height: Int) throws -> CGImage {
            let context = try BrushRaster.context(width: 2400, height: height, mask: false)
            context.setFillColor(CGColor(srgbRed: red, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 2400, height: height))
            return try #require(context.makeImage())
        }
        // A red layer 2400 pixels wide, past the size the canvas makes effects at, over black.
        for (image, name) in [(try solid(red: 0, height: 400), "Black"), (try solid(red: 1, height: 200), "Wide")] {
            session.insert(ImportedImage(image: image, thumbnail: image, name: name))
        }
        let id = try #require(session.activeLayerID)
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document?.layers[index].transform = LayerTransform(origin: CGPoint(x: 0, y: 100), size: CGSize(width: 2400, height: 200))
        // In green, which neither the layer nor the black behind it has.
        switch effect {
        case .outerGlow:
            session.document?.layers[index].effects = LayerEffects(outerGlow: OuterGlowEffect(size: 40, red: 0, green: 1, blue: 0, opacity: 1))
        case .innerGlow:
            session.document?.layers[index].effects = LayerEffects(innerGlow: InnerGlowEffect(size: 40, red: 0, green: 1, blue: 0, opacity: 1))
        case .innerShadow:
            // 40 pixels down from the layer's top edge, softened.
            session.document?.layers[index].effects = LayerEffects(innerShadow: InnerShadowEffect(distance: 40, blur: 20, green: 1, opacity: 1))
        }
        session.zoom(to: 0.25)
        let canvas = CanvasView(session: session)
        canvas.frame = CGRect(x: 0, y: 0, width: 640, height: 100)
        canvas.allowsGPU = false
        // The green the canvas draws at a point on the document, down the middle of the layer.
        func drawn() throws -> (CGFloat) -> Double {
            let cpu = try #require(CGContext(data: nil, width: 640, height: 100, bitsPerComponent: 8, bytesPerRow: 640 * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            cpu.translateBy(x: 0, y: 100); cpu.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cpu, flipped: true)
            canvas.draw(canvas.bounds)
            NSGraphicsContext.restoreGraphicsState()
            let bytes = Array(UnsafeBufferPointer(start: try #require(cpu.data).assumingMemoryBound(to: UInt8.self), count: 640 * 100 * 4))
            return { y in
                let at = session.viewport.viewPoint(from: CGPoint(x: 1200, y: y), documentSize: CGSize(width: 2400, height: 400))
                return Double(bytes[(Int(at.y) * 640 + Int(at.x)) * 4 + 1]) / 255
            }
        }
        // The effects are made on a worker: wait for them, as the canvas does.
        _ = try drawn()
        for _ in 0..<100 where session.effectsPreviews.rendered(id) == nil { try await Task.sleep(for: .milliseconds(20)) }
        let green = try drawn()
        let image = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        func exported(_ y: CGFloat) -> Double { Double(bytes[(Int(y) * image.width + 1200) * 4 + 1]) / 255 }
        // Above and below the layer, where an outer glow fades out, and inside its top and bottom edges, where an inner
        // glow fades out and the inner shadow ends; away from the edges, where a pixel either way changes little.
        for y: CGFloat in [60, 75, 125, 155, 245, 260, 275, 325, 340] {
            #expect(abs(green(y) - exported(y)) < 0.05, "\(effect.rawValue) at \(y): canvas \(green(y)), exported \(exported(y))")
        }
    }
}
