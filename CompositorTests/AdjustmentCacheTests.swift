import AppKit
import CoreImage
import Metal
import Testing
@testable import Compositor

/// The canvas keeps each adjustment layer's result while nothing it's made from changes: what it draws must be what it
/// draws working everything out again.
@MainActor
struct AdjustmentCacheTests {
    private func picture() throws -> CGImage {
        let context = try BrushRaster.context(width: 400, height: 260, mask: false)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let gradient = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 0.1, green: 0.1, blue: 0.3, alpha: 1),
                                                               CGColor(srgbRed: 0.8, green: 0.5, blue: 0.3, alpha: 1)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 400, y: 260), options: [])
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fillEllipse(in: CGRect(x: 280, y: 100, width: 14, height: 14))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.8, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 60, y: 60, width: 90, height: 120))
        return try #require(context.makeImage())
    }

    private struct Scene {
        let session: EditorSession
        let canvas: CanvasView
        let window: NSWindow
        let below: UUID
        let above: UUID
    }

    /// A picture, three adjustment layers over it (one of them Lens Effects), and a blank layer on top.
    private func scene() throws -> Scene {
        let session = EditorSession()
        session.createDocument(width: 400, height: 260)
        let image = try picture()
        session.insert(ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: "Picture"))
        let below = try #require(session.activeLayerID)
        var values: [LayerAdjustment] = []
        var curves = LayerAdjustment(kind: .curves)
        curves.curves.channels[0] = [CurvePoint(x: 0, y: 30), CurvePoint(x: 255, y: 230)]
        values.append(curves)
        var tonal = LayerAdjustment(kind: .tonalContrast)
        tonal.filterLayer.tonal = TonalLayerSettings()
        values.append(tonal)
        var lens = LayerAdjustment(kind: .lensEffects)
        lens.filterLayer.lens = LensEffectSettings()
        lens.filterLayer.lens?.effect = .anamorphicFlare
        values.append(lens)
        for value in values {
            session.addAdjustment(value.kind)
            session.adjustmentEditingID = nil
            session.updateAdjustment(try #require(session.activeLayerID), value: value)
        }
        session.addBlankLayer()
        let above = try #require(session.activeLayerID)
        let canvas = CanvasView(session: session)
        canvas.frame = CGRect(x: 0, y: 0, width: 500, height: 340)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = canvas
        session.viewport.resize(to: canvas.bounds.size, backingScale: 2, documentSize: session.document?.size)
        session.viewport.fit(documentSize: session.document!.size)
        canvas.synchronizeDisplay()
        return Scene(session: session, canvas: canvas, window: window, below: below, above: above)
    }

    /// The canvas's frame as 8-bit pixels.
    private func frame(_ canvas: CanvasView) throws -> [UInt8] {
        let renderer = try #require(GPUCanvasRenderer.shared)
        let image = try #require(canvas.gpuFrame(size: CGSize(width: 1000, height: 680)))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1000, height: 680, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        let texture = try #require(renderer.device.makeTexture(descriptor: descriptor))
        let command = try #require(renderer.queue.makeCommandBuffer())
        renderer.context.render(image, to: texture, commandBuffer: command, bounds: CGRect(x: 0, y: 0, width: 1000, height: 680),
                                colorSpace: renderer.space)
        command.commit()
        command.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: 1000 * 680 * 4)
        texture.getBytes(&bytes, bytesPerRow: 4000, from: MTLRegionMake2D(0, 0, 1000, 680), mipmapLevel: 0)
        return bytes
    }

    /// The largest difference between two frames, in 8-bit levels.
    private func difference(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
    }

    @Test func cachedFramesMatchWorkedOutOnes() throws {
        guard GPUCanvasRenderer.shared != nil else { return }
        let scene = try scene()
        scene.canvas.cachesAdjustments = false
        let worked = try frame(scene.canvas)
        scene.canvas.cachesAdjustments = true
        let first = try frame(scene.canvas), second = try frame(scene.canvas)
        #expect(difference(worked, first) <= 1, "as it's kept: \(difference(worked, first))")
        #expect(difference(worked, second) <= 1, "drawn from what was kept: \(difference(worked, second))")
    }

    @Test func aChangeUnderneathIsShownAndOneAboveKeepsTheCache() throws {
        guard GPUCanvasRenderer.shared != nil else { return }
        let scene = try scene()
        _ = try frame(scene.canvas)
        // Underneath: the picture fades. The cached adjustments must work it out again.
        let index = try #require(scene.session.document?.layers.firstIndex { $0.id == scene.below })
        scene.session.document?.layers[index].opacity = 0.5
        let cachedAfterChange = try frame(scene.canvas)
        scene.canvas.cachesAdjustments = false
        let worked = try frame(scene.canvas)
        #expect(difference(worked, cachedAfterChange) <= 1, "the change shows through: \(difference(worked, cachedAfterChange))")
        // Above: a stroke's worth of pixels on the top layer. Underneath stays as it was, so what's kept still matches.
        scene.canvas.cachesAdjustments = true
        _ = try frame(scene.canvas)
        let context = try BrushRaster.context(width: 400, height: 260, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 10, y: 10, width: 40, height: 40))
        let paint = try #require(context.makeImage())
        let top = try #require(scene.session.document?.layers.firstIndex { $0.id == scene.above })
        scene.session.document?.layers[top].asset = ImportedImage(image: paint, thumbnail: paint, name: "Paint")
        let cached = try frame(scene.canvas)
        scene.canvas.cachesAdjustments = false
        #expect(difference(try frame(scene.canvas), cached) <= 1)
    }
}
