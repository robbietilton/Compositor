import AppKit
import Testing
@testable import Compositor

/// Painting on a layer that has been scaled down lands in the layer's own pixels, at their
/// resolution, so scaling the layer back up shows a clean edge rather than a blocky one.
@MainActor
struct NativeResolutionPaintTests {
    private func alpha(_ image: CGImage) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<(image.width * image.height)).map { bytes[$0 * 4 + 3] }
    }
    /// Where each row first drops below half alpha, scanning in from the left, across the rows `range`.
    private func edge(_ values: [UInt8], width: Int, rows range: ClosedRange<Int>, from start: Int) -> [Int] {
        range.map { y in
            (start..<width).first { values[y * width + $0] < 128 } ?? width
        }
    }
    private func session(scaledTo scale: CGFloat, source: Int = 1000) throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 200, height: 200)
        let context = try BrushRaster.context(width: source, height: source, mask: false)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: source, height: source))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Photo"))
        let index = try #require(session.document?.layers.indices.last)
        let side = CGFloat(source) * scale
        session.document?.layers[index].transform = LayerTransform(origin: CGPoint(x: 100 - side / 2, y: 100 - side / 2),
            size: CGSize(width: side, height: side))
        session.selectTool(.brush)
        session.brushMode = .erase
        session.brushSettings = BrushSettings(diameter: 40, hardness: 1, red: 0, green: 0, blue: 0)
        return session
    }

    @Test func erasingAScaledDownImageKeepsItsResolution() async throws {
        let session = try session(scaledTo: 0.1)
        session.beginBrush(at: CGPoint(x: 100, y: 100))
        await session.finishBrush()
        #expect(session.brushError == nil)
        let image = try #require(session.activeLayer?.asset?.image)
        #expect(image.width == 1000 && image.height == 1000)
        // The hole is 40 document pixels wide at 10%, so 400 of the image's own pixels.
        let values = try alpha(image)
        #expect(values[500 * 1000 + 500] == 0)
        #expect(values[500 * 1000 + 250] == 255)
        // Its outline, one row at a time down the upper-left arc: a smooth circle moves a
        // pixel or so per row; one drawn on a 10× coarser grid moves in steps of ten.
        let outline = edge(values, width: 1000, rows: 330...470, from: 250)
        let steps = zip(outline, outline.dropFirst()).map { abs($0 - $1) }
        #expect(steps.max() ?? 0 <= 4, "outline moves in steps: \(steps)")
    }

    /// Without Metal, the tip is drawn on the CPU. A layer scaled by hand is never exactly as wide
    /// as it is tall, and that must not send the tip through a small document-sized stamp.
    @Test(arguments: [false, true])
    func erasingWithoutMetalKeepsItsResolution(rotated: Bool) throws {
        let session = try session(scaledTo: 0.1)
        let index = try #require(session.document?.layers.indices.last)
        session.document?.layers[index].transform.size.height += 0.013
        if rotated { session.document?.layers[index].transform.rotation = 30 }
        var settings = session.brushSettings
        settings.erasing = true
        let layer = try #require(session.activeLayer)
        let stroke = try BrushStroke(layer: layer, mask: false, settings: settings, canvas: session.document!.size, useGPU: false)
        try stroke.append(CGPoint(x: 100, y: 100))
        try stroke.flush()
        let image = try stroke.paintSnapshot().asset.image
        #expect(image.width == 1000)
        let values = try alpha(image)
        #expect(values[500 * 1000 + 500] == 0)
        let outline = edge(values, width: 1000, rows: 330...470, from: 250)
        let steps = zip(outline, outline.dropFirst()).map { abs($0 - $1) }
        #expect(steps.max() ?? 0 <= 4, "outline moves in steps: \(steps)")
    }

    /// The same on the canvas: erase while the layer is small and the canvas has cached it small,
    /// then scale it up, and the hole's outline is as smooth on screen as it is in the pixels.
    @Test func canvasShowsTheErasedEdgeSmoothlyAfterScalingBackUp() throws {
        let session = EditorSession()
        session.createDocument(width: 400, height: 400)
        let context = try BrushRaster.context(width: 1000, height: 1000, mask: false)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let photo = try #require(context.makeImage())
        session.insert(ImportedImage(image: photo, thumbnail: photo, name: "Photo"))
        let index = try #require(session.document?.layers.indices.last)
        var small = LayerTransform(origin: CGPoint(x: 180, y: 180), size: CGSize(width: 40, height: 40))
        small.sampling = .high
        session.document?.layers[index].transform = small
        let view = CanvasView(session: session)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        let size = CGSize(width: 400, height: 400)
        session.viewport.resize(to: view.bounds.size, backingScale: 1, documentSize: size)
        session.viewport.setZoom(1, anchoredAt: session.viewport.center, documentSize: size)
        func snapshot() throws -> NSBitmapImageRep {
            view.synchronizeDisplay()
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep
        }
        _ = try snapshot()
        session.selectTool(.brush)
        session.brushMode = .erase
        session.brushSettings = BrushSettings(diameter: 20, hardness: 1, red: 0, green: 0, blue: 0)
        session.beginBrush(at: CGPoint(x: 200, y: 200))
        #expect(session.finishBrushImmediately())
        _ = try snapshot()
        var large = small
        large.origin = .zero
        large.size = CGSize(width: 400, height: 400)
        session.document?.layers[index].transform = large
        let rep = try snapshot()
        // The hole is 500 image pixels wide: 200 document pixels at 40%, one view point each.
        let perPoint = CGFloat(rep.pixelsWide) / view.bounds.width
        let point = session.viewport.viewPoint(from: CGPoint(x: 200, y: 200), documentSize: size)
        let center = (x: Int(point.x * perPoint), y: Int(point.y * perPoint))
        func erased(_ x: Int, _ y: Int) -> Bool {
            guard let color = rep.colorAt(x: x, y: y) else { return false }
            return color.redComponent < 0.6 || color.greenComponent > 0.6
        }
        #expect(erased(center.x, center.y))
        #expect(!erased(center.x - Int(120 * perPoint), center.y))
        let outline = (center.y - Int(70 * perPoint)...center.y - Int(5 * perPoint)).map { y in
            (center.x - Int(120 * perPoint)..<center.x).first { erased($0, y) } ?? 0
        }
        let steps = zip(outline, outline.dropFirst()).map { abs($0 - $1) }
        #expect(steps.max() ?? 0 <= Int(3 * perPoint), "outline moves in steps on screen: \(steps)")
    }

    @Test func paintingABlankLayerThatWasScaledDownPaintsAtDocumentResolution() async throws {
        let session = EditorSession()
        session.createDocument(width: 200, height: 200)
        session.addBlankLayer()
        let index = try #require(session.document?.layers.indices.last)
        session.document?.layers[index].transform = LayerTransform(origin: CGPoint(x: 90, y: 90), size: CGSize(width: 20, height: 20))
        session.selectTool(.brush)
        session.brushSettings = BrushSettings(diameter: 40, hardness: 1, red: 1, green: 0, blue: 0)
        session.beginBrush(at: CGPoint(x: 100, y: 100))
        await session.finishBrush()
        let layer = try #require(session.activeLayer)
        let image = try #require(layer.asset?.image)
        // One layer pixel per document pixel, however small the empty layer had been made.
        #expect(abs(CGFloat(image.width) - layer.transform.size.width) <= 1)
        #expect(image.width >= 38)
    }

    /// A 1000×1000 image: a two-pixel black and white checker on the left half, red on the right, shown at 10%.
    private func checkerSession() throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 200, height: 200)
        let context = try BrushRaster.context(width: 1000, height: 1000, mask: false)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 500, y: 0, width: 500, height: 1000))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 500, height: 1000))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for y in stride(from: 0, to: 1000, by: 2) {
            for x in stride(from: (y / 2).isMultiple(of: 2) ? 0 : 2, to: 500, by: 4) { context.fill(CGRect(x: x, y: y, width: 2, height: 2)) }
        }
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Checker"))
        let index = try #require(session.document?.layers.indices.last)
        session.document?.layers[index].transform = LayerTransform(origin: CGPoint(x: 50, y: 50), size: CGSize(width: 100, height: 100))
        return session
    }
    private func green(_ image: CGImage) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<(image.width * image.height)).map { bytes[$0 * 4 + 1] }
    }

    /// Clone Stamp copies the layer's own pixels: the checker, far too fine to see at 10%, arrives intact
    /// rather than as the flat gray the canvas shows.
    @Test func cloneStampCopiesTheLayersOwnDetail() async throws {
        let session = try checkerSession()
        session.selectTool(.cloneStamp)
        session.setCloneSource(CGPoint(x: 70, y: 100))
        session.brushSettings = BrushSettings(diameter: 10, hardness: 1, red: 0, green: 0, blue: 0)
        session.beginBrush(at: CGPoint(x: 130, y: 100))
        await session.finishBrush()
        #expect(session.brushError == nil)
        let image = try #require(session.activeLayer?.asset?.image)
        #expect(image.width == 1000)
        let values = try green(image)
        let row = (790..<810).map { values[500 * 1000 + $0] }
        #expect(row.contains { $0 < 30 } && row.contains { $0 > 225 }, "copied row: \(row)")
    }

    /// Blur softens the layer's own pixels and leaves them at their own resolution.
    @Test func blurKeepsTheLayersResolution() async throws {
        let session = try checkerSession()
        session.blurMode = .blur
        session.selectTool(.blur)
        session.brushSettings = BrushSettings(diameter: 20, hardness: 1, red: 0, green: 0, blue: 0)
        session.beginBrush(at: CGPoint(x: 100, y: 100))
        #expect(session.brushStroke != nil)
        await session.finishBrush()
        #expect(session.brushError == nil)
        let image = try #require(session.activeLayer?.asset?.image)
        #expect(image.width == 1000)
        let values = try green(image)
        // The checker under the brush is smoothed toward gray, the checker far from it untouched.
        let blurred = (480..<490).map { values[500 * 1000 + $0] }
        #expect(blurred.allSatisfy { $0 > 40 && $0 < 215 }, "blurred: \(blurred)")
        let untouched = (100..<104).map { values[100 * 1000 + $0] }
        #expect(untouched.contains { $0 < 30 } && untouched.contains { $0 > 225 })
    }

    /// The Layers panel gives a scaled layer's size on the canvas and its scale, so a photo shrunk to 5% doesn't
    /// read as if it had been resampled to 100 pixels.
    @Test func layersPanelSaysHowFarALayerIsScaled() throws {
        let session = try session(scaledTo: 0.05)
        let layer = try #require(session.activeLayer)
        #expect(layer.sizeLabel == "50 × 50 px · 5%")
        var full = layer
        full.transform.size = CGSize(width: 1000, height: 1000)
        #expect(full.sizeLabel == "1000 × 1000 px")
        full.transform.size = CGSize(width: 25, height: 25)
        #expect(full.sizeLabel == "25 × 25 px · 2.5%")
    }
}
