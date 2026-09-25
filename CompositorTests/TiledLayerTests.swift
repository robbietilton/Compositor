import AppKit
import Testing
@testable import Compositor

/// A painted layer (image plus replacement tiles) must look like the same pixels drawn as one image — while the
/// stroke is live and once it's committed — so nothing shifts when painting starts or ends.
@MainActor
struct TiledLayerTests {
    /// Detailed, deterministic pixels.
    private func noise(width: Int, height: Int, seed: UInt32, alpha: UInt8 = 255) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var state = seed
        for i in 0..<(width * height) {
            state = state &* 1_664_525 &+ 1_013_904_223
            for (c, shift) in [(0, 24), (1, 16), (2, 8)] {
                bytes[i * 4 + c] = UInt8(Int(UInt8(truncatingIfNeeded: state >> UInt32(shift))) * Int(alpha) / 255)
            }
            bytes[i * 4 + 3] = alpha
        }
        return try #require(context.makeImage())
    }
    private func composite(_ base: CGImage, _ patches: [BrushPatch]) throws -> CGImage {
        let context = try BrushRaster.context(width: base.width, height: base.height, mask: false)
        BrushRaster.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height), mask: false, context: context)
        for patch in patches { BrushRaster.draw(patch.image, in: patch.rect, mask: false, context: context) }
        return try #require(context.makeImage())
    }
    private func render(_ side: Int, _ draw: (CGContext) -> Void) throws -> [UInt8] {
        let context = try BrushRaster.context(width: side, height: side, mask: false)
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        draw(context)
        return Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self), count: side * side * 4))
    }
    private func grayNoise(width: Int, height: Int, seed: UInt32) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: true)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var state = seed
        for i in 0..<(width * height) {
            state = state &* 1_664_525 &+ 1_013_904_223
            bytes[i] = UInt8(truncatingIfNeeded: state >> 24)
        }
        return try #require(context.makeImage())
    }
    private func maskComposite(_ base: CGImage, _ patches: [BrushPatch]) throws -> CGImage {
        let context = try BrushRaster.context(width: base.width, height: base.height, mask: true)
        BrushRaster.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height), mask: true, context: context)
        for patch in patches { BrushRaster.draw(patch.image, in: patch.rect, mask: true, context: context) }
        return try #require(context.makeImage())
    }
    /// Largest channel difference over pixels fully inside the layer — judged from `reference` (default `expected`),
    /// since the layer's own outline may antialias a little differently.
    private func largestDifference(_ expected: [UInt8], _ actual: [UInt8], side: Int, inside reference: [UInt8]? = nil) -> Int {
        let outline = reference ?? expected
        var largest = 0
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                var inside = true
                for dy in -1...1 { for dx in -1...1 where outline[((y + dy) * side + x + dx) * 4 + 3] < 255 { inside = false } }
                guard inside else { continue }
                let i = (y * side + x) * 4
                for c in 0..<4 { largest = max(largest, abs(Int(expected[i + c]) - Int(actual[i + c]))) }
            }
        }
        return largest
    }

    @Test(arguments: [(0.2, 0.0), (0.7, 0.0), (0.3, 25.0)])
    func tiledLayersDrawLikeOneImage(scale: Double, rotation: Double) throws {
        let base = try noise(width: 1600, height: 1000, seed: 7)
        let committed = BrushPatch(rect: CGRect(x: 1100, y: 400, width: 256, height: 256), image: try noise(width: 256, height: 256, seed: 99))
        let raster = RasterSnapshot(width: 1600, height: 1000, base: base, baseRect: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                                    patches: [committed])
        var transform = LayerTransform(origin: .zero, size: CGSize(width: 1600, height: 1000))
        transform.sampling = .high
        transform.rotation = rotation
        let s = CGFloat(scale)
        // Rotated, Core Graphics's resample and hard clip edges aren't exactly crop-invariant: on this worst-case noise
        // pieces can land a few levels off (9 measured), well below anything visible.
        let tolerance = rotation == 0 ? 2 : 12
        let side = Int((1700 * s).rounded(.up))
        let center = CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2)

        let finished = try composite(base, [committed])
        let expected = try render(side) { LayerRenderer.draw(finished, transform: transform, center: center, scale: s, in: $0) }
        let drawn = try render(side) {
            TiledLayerRenderer.drawRaster(raster, transform: transform, center: center, scale: s, opacity: 1, blendMode: .normal, mask: nil, in: $0)
        }
        #expect(largestDifference(expected, drawn, side: side) <= tolerance, "a committed painted layer at \(scale)×, \(rotation)°")

        // A live stroke over the committed layer, crossing a piece boundary.
        let stroke = BrushPatch(rect: CGRect(x: 900, y: 500, width: 256, height: 256), image: try noise(width: 256, height: 256, seed: 5))
        let expectedLive = try render(side) {
            LayerRenderer.draw(try! composite(finished, [stroke]), transform: transform, center: center, scale: s, in: $0)
        }
        let live = try render(side) {
            TiledLayerRenderer.drawStroke(width: 1600, height: 1000, sourceRect: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                patches: [stroke], image: nil, raster: raster, transform: transform, center: center, scale: s, opacity: 1,
                blendMode: .normal, mask: nil, in: $0)
        }
        #expect(largestDifference(expectedLive, live, side: side) <= tolerance, "a live stroke on a painted layer at \(scale)×, \(rotation)°")

        // A first stroke on a plain image.
        let expectedFirst = try render(side) {
            LayerRenderer.draw(try! composite(base, [stroke]), transform: transform, center: center, scale: s, in: $0)
        }
        let first = try render(side) {
            TiledLayerRenderer.drawStroke(width: 1600, height: 1000, sourceRect: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                patches: [stroke], image: base, raster: nil, transform: transform, center: center, scale: s, opacity: 1,
                blendMode: .normal, mask: nil, in: $0)
        }
        #expect(largestDifference(expectedFirst, first, side: side) <= tolerance, "a first stroke on an image at \(scale)×, \(rotation)°")
    }

    @Test(arguments: [(0.2, 0.0), (0.7, 0.0), (0.3, 25.0)])
    func maskStrokesDrawLikeOneMask(scale: Double, rotation: Double) throws {
        let layer = try noise(width: 1600, height: 1000, seed: 11)
        let oldMask = try grayNoise(width: 1600, height: 1000, seed: 12)
        let tile = BrushPatch(rect: CGRect(x: 900, y: 500, width: 256, height: 256), image: try grayNoise(width: 256, height: 256, seed: 13))
        var transform = LayerTransform(origin: .zero, size: CGSize(width: 1600, height: 1000))
        transform.sampling = .high
        transform.rotation = rotation
        let s = CGFloat(scale)
        let tolerance = rotation == 0 ? 2 : 12
        let side = Int((1700 * s).rounded(.up))
        let center = CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
        let unmasked = try render(side) { LayerRenderer.draw(layer, transform: transform, center: center, scale: s, in: $0) }
        let expected = try render(side) {
            LayerRenderer.draw(layer, transform: transform, center: center, scale: s, mask: try! maskComposite(oldMask, [tile]), in: $0)
        }
        let live = try render(side) {
            TiledLayerRenderer.drawMaskStroke(width: 1600, height: 1000, sourceRect: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                patches: [tile], oldMask: ImportedImage(image: oldMask, thumbnail: oldMask, name: "Mask"), image: layer, raster: nil,
                transform: transform, center: center, scale: s, opacity: 1, blendMode: .normal, in: $0)
        }
        #expect(largestDifference(expected, live, side: side, inside: unmasked) <= tolerance, "a live mask stroke at \(scale)×, \(rotation)°")
    }

    /// Painting at the layer's own edge must not change it. A piece composes its square plus a margin, and at the
    /// edge that margin falls outside the layer; resampling it used to pull that emptiness into the border — worse
    /// the more the layer was magnified, and gone again on mouse-up. Each patch holds the pixels already beneath it,
    /// so a correct stroke changes nothing anywhere.
    @Test(arguments: [10.749, 1.0])
    func paintingAtTheLayersEdgeDoesNotChangeIt(zoom: Double) throws {
        let image = try noise(width: 3360, height: 1812, seed: 11)
        var transform = LayerTransform(origin: .zero, size: CGSize(width: 336, height: 181))
        transform.sampling = .high
        let s = CGFloat(zoom), d: CGFloat = 2
        let side = 600
        // The layer's top-left corner sits 50 points into the view.
        let center = CGPoint(x: 336 * s / 2 + 50, y: 181 * s / 2 + 50)
        let grid = CGRect(x: 0, y: 0, width: 3360, height: 1812)
        let pixels = Int((CGFloat(side) * d).rounded(.up))
        func renderRetina(_ draw: (CGContext) -> Void) throws -> [UInt8] {
            let context = try BrushRaster.context(width: pixels, height: pixels, mask: false)
            context.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
            context.scaleBy(x: d, y: d)
            draw(context)
            return Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self), count: pixels * pixels * 4))
        }
        func largest(_ a: [UInt8], _ b: [UInt8]) -> Int {
            var worst = 0
            for i in stride(from: 0, to: a.count, by: 1) { worst = max(worst, abs(Int(a[i]) - Int(b[i]))) }
            return worst
        }
        let plain = try renderRetina { LayerRenderer.draw(image, transform: transform, center: center, scale: s, in: $0) }
        let mask = try #require(LayerMask.solid(revealing: true)).asset
        let masked = try renderRetina { LayerRenderer.draw(image, transform: transform, center: center, scale: s, mask: mask.image, in: $0) }
        for origin in [CGPoint(x: 0, y: 0), CGPoint(x: 256, y: 256)] {
            let rect = CGRect(x: origin.x, y: origin.y, width: 256, height: 256)
            let same = try #require(image.cropping(to: rect))
            let painting = try renderRetina {
                TiledLayerRenderer.drawStroke(width: 3360, height: 1812, sourceRect: grid, patches: [BrushPatch(rect: rect, image: same)],
                    image: image, raster: nil, transform: transform, center: center, scale: s,
                    opacity: 1, blendMode: .normal, mask: nil, in: $0)
            }
            #expect(largest(plain, painting) <= 2, "painting at \(Int(origin.x)),\(Int(origin.y)) at \(zoom)× zoom")
            // The same for a mask stroke, which shows the layer through the mask it is painting.
            let white = try BrushRaster.context(width: 256, height: 256, mask: true)
            white.setFillColor(gray: 1, alpha: 1)
            white.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            let reveal = BrushPatch(rect: rect, image: try #require(white.makeImage()))
            let maskPainting = try renderRetina {
                TiledLayerRenderer.drawMaskStroke(width: 3360, height: 1812, sourceRect: grid, patches: [reveal], oldMask: mask,
                    image: image, raster: nil, transform: transform, center: center, scale: s, opacity: 1, blendMode: .normal, in: $0)
            }
            #expect(largest(masked, maskPainting) <= 2, "painting a mask at \(Int(origin.x)),\(Int(origin.y)) at \(zoom)× zoom")
        }
    }

    /// Where pieces meet, split pixels must be drawn once: translucent pixels show any double draw as a line.
    @Test(arguments: [(0.3, 0.0), (0.7, 25.0)])
    func translucentStrokesDrawLikeOneImage(scale: Double, rotation: Double) throws {
        let base = try noise(width: 1600, height: 1000, seed: 21, alpha: 128)
        let tile = BrushPatch(rect: CGRect(x: 900, y: 500, width: 256, height: 256), image: try noise(width: 256, height: 256, seed: 22, alpha: 128))
        var transform = LayerTransform(origin: .zero, size: CGSize(width: 1600, height: 1000))
        transform.sampling = .high
        transform.rotation = rotation
        let s = CGFloat(scale)
        let tolerance = rotation == 0 ? 2 : 12
        let side = Int((1700 * s).rounded(.up))
        let center = CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
        let silhouette = try noise(width: 1600, height: 1000, seed: 1)
        let inside = try render(side) { LayerRenderer.draw(silhouette, transform: transform, center: center, scale: s, in: $0) }
        let finished = try composite(base, [tile])
        let expected = try render(side) { LayerRenderer.draw(finished, transform: transform, center: center, scale: s, in: $0) }
        let live = try render(side) {
            TiledLayerRenderer.drawStroke(width: 1600, height: 1000, sourceRect: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                patches: [tile], image: base, raster: nil, transform: transform, center: center, scale: s,
                opacity: 1, blendMode: .normal, mask: nil, in: $0)
        }
        #expect(largestDifference(expected, live, side: side, inside: inside) <= tolerance, "a translucent live stroke at \(scale)×, \(rotation)°")
    }

    /// Paints on a big scaled-down photo shown on a real canvas — its pixels or, with `paintingMask`, its layer
    /// mask — and returns how far pixels away from the brush moved as the stroke started and as it finished.
    private func canvasShift(paintingMask: Bool, layerScale: CGFloat = 0.25) throws -> (start: Int, finish: Int, committed: Bool) {
        let session = EditorSession()
        session.createDocument(width: 800, height: 600)
        let photo = try noise(width: 2400, height: 1800, seed: 3)
        session.insert(ImportedImage(image: photo, thumbnail: photo, name: "Photo"))
        let index = try #require(session.document?.layers.firstIndex { $0.id == session.activeLayerID })
        var transform = LayerTransform(origin: CGPoint(x: 100, y: 75),
                                       size: CGSize(width: 2400 * layerScale, height: 1800 * layerScale))
        transform.sampling = .high
        session.document?.layers[index].transform = transform
        if paintingMask {
            session.addLayerMask()
            #expect(session.isMaskSelected)
        }
        let view = CanvasView(session: session)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        let size = CGSize(width: 800, height: 600)
        session.viewport.resize(to: view.bounds.size, backingScale: 1, documentSize: size)
        session.selectTool(.brush)
        session.brushSettings.diameter = 30

        struct Snapshot { let bytes: [UInt8]; let width: Int; let height: Int; let rowBytes: Int; let samples: Int }
        struct SnapshotUnavailable: Error {}
        func snapshot() throws -> Snapshot {
            view.synchronizeDisplay()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw SnapshotUnavailable() }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let data = rep.bitmapData else { throw SnapshotUnavailable() }
            return Snapshot(bytes: Array(UnsafeBufferPointer(start: data, count: rep.bytesPerRow * rep.pixelsHigh)),
                            width: rep.pixelsWide, height: rep.pixelsHigh, rowBytes: rep.bytesPerRow, samples: rep.bitsPerPixel / 8)
        }
        // The brushed area in snapshot pixels, grown generously.
        let brush = CGPoint(x: transform.center.x, y: transform.center.y)
        let topLeft = session.viewport.viewPoint(from: CGPoint(x: brush.x - 60, y: brush.y - 40), documentSize: size)
        let bottomRight = session.viewport.viewPoint(from: CGPoint(x: brush.x + 80, y: brush.y + 40), documentSize: size)
        func largestDifference(_ a: Snapshot, _ b: Snapshot) -> Int {
            let perPoint = CGFloat(a.width) / view.bounds.width
            let box = CGRect(x: topLeft.x * perPoint, y: topLeft.y * perPoint,
                             width: (bottomRight.x - topLeft.x) * perPoint, height: (bottomRight.y - topLeft.y) * perPoint)
            var largest = 0, at = (0, 0), count = 0
            _ = (at, count)
            for y in 0..<a.height {
                for x in 0..<a.width where !box.contains(CGPoint(x: x, y: y)) {
                    let i = y * a.rowBytes + x * a.samples
                    var d = 0
                    for c in 0..<a.samples { d = max(d, abs(Int(a.bytes[i + c]) - Int(b.bytes[i + c]))) }
                    if d > 2 { count += 1 }
                    if d > largest { largest = d; at = (x, y) }
                }
            }
            return largest
        }

        let before = try snapshot()
        session.beginBrush(at: brush)
        session.continueBrush(at: CGPoint(x: brush.x + 20, y: brush.y))
        let during = try snapshot()
        session.finishBrushImmediately()
        let after = try snapshot()
        let committed = paintingMask ? session.activeLayer?.mask?.asset.raster != nil : session.activeLayer?.asset?.raster != nil
        return (largestDifference(before, during), largestDifference(during, after), committed)
    }

    /// On the canvas: starting a stroke on a big scaled-down layer changes nothing away from the brush, and
    /// finishing it changes nothing there either.
    @Test func paintingAScaledDownLayerDoesNotShiftItsPixels() throws {
        let shift = try canvasShift(paintingMask: false)
        #expect(shift.committed, "the stroke was committed")
        #expect(shift.start <= 3, "starting to paint changed pixels away from the brush by \(shift.start)")
        #expect(shift.finish <= 3, "finishing the stroke changed pixels away from the brush by \(shift.finish)")
    }

    /// The same when painting the layer's mask.
    @Test func paintingAScaledDownLayersMaskDoesNotShiftItsPixels() throws {
        let shift = try canvasShift(paintingMask: true)
        #expect(shift.committed, "the mask stroke was committed")
        #expect(shift.start <= 3, "starting to paint the mask changed pixels away from the brush by \(shift.start)")
        #expect(shift.finish <= 3, "finishing the mask stroke changed pixels away from the brush by \(shift.finish)")
    }
}
