import AppKit
import Testing
@testable import Compositor

/// A stroke that can't go on as it started carries on another way, rather than failing: past a scaled-down layer it
/// is painted again on the layer at its displayed size, and when the GPU fails it is painted again on the CPU.
@MainActor struct BrushRecoveryTests {
    /// A 3000 × 3000 canvas with a gray layer of 1371 × 835 pixels shown at 27.8%, as in the report.
    private func scaledDown() throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 3000, height: 3000)
        let context = try BrushRaster.context(width: 1371, height: 835, mask: false)
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1371, height: 835))
        // A white band along one edge, so the layer reads differently upside down.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1371, height: 100))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Painted"))
        let index = try #require(session.document?.layers.indices.last)
        session.document?.layers[index].transform = LayerTransform(origin: CGPoint(x: 1300, y: 1400), size: CGSize(width: 381, height: 232))
        session.selectTool(.brush)
        session.brushSettings = BrushSettings(diameter: 258, hardness: 0.59, red: 0, green: 0, blue: 0)
        return session
    }

    /// The layer's color at a document point: its red channel and alpha.
    private func sample(_ layer: ImageLayer, at point: CGPoint) throws -> (red: UInt8, alpha: UInt8) {
        let image = try #require(layer.asset?.image)
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let frame = layer.transform
        let x = Int((point.x - frame.origin.x) / frame.size.width * CGFloat(image.width))
        let y = Int((point.y - frame.origin.y) / frame.size.height * CGFloat(image.height))
        let at = (y * image.width + x) * 4
        return (bytes[at], bytes[at + 3])
    }

    @Test func paintingFarPastAScaledDownLayerPaintsItAtItsDisplayedSize() async throws {
        let session = try scaledDown()
        // Two points well clear of the stroke, near the layer's top and bottom edges.
        let edges = [CGPoint(x: 1320, y: 1410), CGPoint(x: 1320, y: 1625)]
        let before = try edges.map { try sample(#require(session.activeLayer), at: $0).red }
        #expect(before[0] != before[1], "the band should make the edges differ")
        session.beginBrush(at: CGPoint(x: 400, y: 400))
        for step in 1...60 { session.continueBrush(at: CGPoint(x: 400 + Double(step) * 40, y: 400 + Double(step) * 35)) }
        await session.finishBrush()
        #expect(session.brushError == nil)
        let layer = try #require(session.activeLayer)
        let image = try #require(layer.asset?.image)
        // One pixel a document pixel, not the 81 megapixels it grew to at 27.8%.
        #expect(abs(CGFloat(image.width) - layer.transform.size.width) <= 2, "\(image.width) wide for \(layer.transform.size.width)")
        // The paint where the stroke began, and the layer's gray where it was, the right way up.
        #expect(try sample(layer, at: CGPoint(x: 400, y: 400)).alpha > 200)
        let after = try edges.map { try sample(layer, at: $0).red }
        #expect(zip(before, after).allSatisfy { abs(Int($0) - Int($1)) < 12 }, "the layer's own pixels moved: \(before) → \(after)")
        // One undo brings back the layer as it was, scaled down at its own resolution.
        session.undo()
        #expect(session.activeLayer?.asset?.image.width == 1371)
        #expect(session.activeLayer?.transform.size.width == 381)
    }

    /// Begun inside the layer, the stroke only outgrows it partway: it's painted again from its start, all of it.
    @Test func aStrokeThatLeavesAScaledDownLayerPartwayIsPaintedWhole() async throws {
        let session = try scaledDown()
        let start = CGPoint(x: 1490, y: 1516), end = CGPoint(x: 400, y: 400)
        session.beginBrush(at: start)
        for step in 1...120 {
            let t = CGFloat(step) / 120
            session.continueBrush(at: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
        }
        await session.finishBrush()
        #expect(session.brushError == nil)
        let layer = try #require(session.activeLayer)
        let image = try #require(layer.asset?.image)
        #expect(abs(CGFloat(image.width) - layer.transform.size.width) <= 2, "\(image.width) wide for \(layer.transform.size.width)")
        for t in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            #expect(try sample(layer, at: point).alpha > 200, "no paint at \(point)")
        }
    }

    @Test func paintingWithinAScaledDownLayerKeepsItsResolution() async throws {
        let session = try scaledDown()
        session.brushSettings.diameter = 20
        session.beginBrush(at: CGPoint(x: 1450, y: 1500))
        session.continueBrush(at: CGPoint(x: 1550, y: 1510))
        await session.finishBrush()
        #expect(session.brushError == nil)
        #expect(session.activeLayer?.asset?.image.width == 1371)
    }

    @Test func aStrokeTheGPUFailsIsPaintedOnTheCPU() async throws {
        guard let gpu = MetalBrushCoverage.shared else { return }
        let session = EditorSession()
        session.createDocument(width: 400, height: 400)
        session.addBlankLayer()
        session.selectTool(.brush)
        session.brushSettings = BrushSettings(diameter: 40, hardness: 0.5, red: 1, green: 0, blue: 0)
        gpu.failuresForTesting = 1
        defer { gpu.failuresForTesting = 0 }
        session.beginBrush(at: CGPoint(x: 100, y: 100))
        session.continueBrush(at: CGPoint(x: 300, y: 300))
        await session.finishBrush()
        #expect(gpu.failuresForTesting == 0, "the GPU was never asked to paint")
        #expect(session.brushError == nil)
        let layer = try #require(session.activeLayer)
        #expect(try sample(layer, at: CGPoint(x: 200, y: 200)).alpha > 200, "the stroke is missing")
    }
}
