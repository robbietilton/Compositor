import AppKit
import Testing
@testable import Compositor

@MainActor
struct RasterSnapshotTests {
    private func session() -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 4000, height: 4000)
        session.addBlankLayer()
        session.selectTool(.brush)
        session.brushSettings = BrushSettings(diameter: 800, hardness: 0, red: 1, green: 1, blue: 1)
        return session
    }

    @Test func mouseUpAndNextStrokeNeverFlattenTheDocument() throws {
        let session = session()
        session.beginBrush(at: CGPoint(x: 800, y: 3200))
        session.continueBrush(at: CGPoint(x: 800, y: 800))
        session.continueBrush(at: CGPoint(x: 3200, y: 800))
        #expect(session.finishBrushImmediately())
        let first = try #require(session.activeLayer?.asset)
        let raster = try #require(first.raster)
        #expect(!raster.hasMaterializedPixels)
        #expect(session.canPaint && session.canEditLayers && !session.isProjectBusy)
        let count = session.history.undoCount
        session.beginBrush(at: CGPoint(x: 1600, y: 1600))
        session.continueBrush(at: CGPoint(x: 2200, y: 2200))
        #expect(session.finishBrushImmediately())
        let second = try #require(session.activeLayer?.asset)
        #expect(!raster.hasMaterializedPixels)
        #expect(second.raster?.hasMaterializedPixels == false)
        #expect(session.history.undoCount == count + 1)
        session.undo()
        #expect(session.activeLayer?.asset?.image === first.image)
        session.redo()
        #expect(session.activeLayer?.asset?.image === second.image)
        session.selectTool(.move)
        #expect(session.tool == .move && session.canTransform)
    }

    @Test func snapshotsStayImmutableAndDisplayMatchesExportAcrossSuccessiveStrokes() async throws {
        let session = session()
        session.brushSettings.opacity = 0.5
        for (index, point) in [CGPoint(x: 1400, y: 1600), CGPoint(x: 1200, y: 1600), CGPoint(x: 1800, y: 1700)].enumerated() {
            session.brushSettings.red = CGFloat(index % 2)
            session.beginBrush(at: point)
            session.continueBrush(at: CGPoint(x: point.x + 800, y: point.y + 200))
            #expect(session.finishBrushImmediately())
        }
        let layer = try #require(session.activeLayer)
        let asset = try #require(layer.asset)
        let raster = try #require(asset.raster)
        // Tile clips must apply layer opacity exactly once, even after crops shift the tile grid.
        let display = try BrushRaster.context(width: 4000, height: 4000, mask: false)
        LayerRenderer.drawBrushPreview(asset.image, transform: layer.transform, center: layer.transform.center,
            scale: 1, opacity: 0.5, blendMode: .normal, mask: nil, patches: [],
            pixelWidth: raster.width, pixelHeight: raster.height, paintingMask: false, raster: raster, in: display)
        #expect(!raster.hasMaterializedPixels)
        let reference = try BrushRaster.context(width: 4000, height: 4000, mask: false)
        LayerRenderer.draw(asset.image, transform: layer.transform, center: layer.transform.center, opacity: 0.5, in: reference)
        #expect(raster.hasMaterializedPixels)
        let a = try #require(display.data).assumingMemoryBound(to: UInt8.self)
        let b = try #require(reference.data).assumingMemoryBound(to: UInt8.self)
        #expect(memcmp(a, b, display.bytesPerRow * display.height) == 0)
        let frozen = Data(bytes: b, count: reference.bytesPerRow * reference.height)
        session.beginBrush(at: CGPoint(x: 1800, y: 1700))
        #expect(session.finishBrushImmediately())
        reference.clear(CGRect(x: 0, y: 0, width: 4000, height: 4000))
        LayerRenderer.draw(asset.image, transform: layer.transform, center: layer.transform.center, opacity: 0.5, in: reference)
        #expect(Data(bytes: b, count: reference.bytesPerRow * reference.height) == frozen)
        // Saving/reopening consumes the lazy CGImage through the normal project format.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SparseBrush-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        let reopened = try await ImageExporter.shared.render(loaded)
        #expect(reopened.image.width == 4000 && reopened.image.height == 4000)
    }

    @Test func maskMouseUpIsImmediateAndPreservesTheImage() throws {
        let session = session()
        session.beginBrush(at: CGPoint(x: 2000, y: 2000))
        #expect(session.finishBrushImmediately())
        let image = try #require(session.activeLayer?.asset?.image)
        session.addLayerMask()
        session.brushSettings.diameter = 300
        session.beginBrush(at: CGPoint(x: 2000, y: 2000))
        session.continueBrush(at: CGPoint(x: 2200, y: 2000))
        #expect(session.finishBrushImmediately())
        #expect(session.canPaint && !session.isProjectBusy)
        #expect(session.activeLayer?.asset?.image === image)
        let mask = try #require(session.activeLayer?.mask?.asset)
        #expect(LayerMask.isValid(mask.image))
        #expect(mask.raster?.hasMaterializedPixels == false)
        session.beginBrush(at: CGPoint(x: 2000, y: 2100))
        #expect(session.finishBrushImmediately())
        #expect(mask.raster?.hasMaterializedPixels == false)
    }

    @Test func softwareFallbackKeepsTheSoftStrokeContinuous() throws {
        let session = session()
        let layer = try #require(session.activeLayer)
        let stroke = try BrushStroke(layer: layer, mask: false,
            settings: BrushSettings(diameter: 120, hardness: 0, red: 1),
            canvas: CGSize(width: 4000, height: 4000), useGPU: false)
        try stroke.append(CGPoint(x: 500, y: 1000))
        try stroke.append(CGPoint(x: 1300, y: 1000))
        try stroke.flush()
        let result = try stroke.paintSnapshot()
        let context = try BrushRaster.context(width: 1400, height: 1100, mask: false)
        LayerRenderer.draw(result.asset.image, transform: result.transform, center: result.transform.center, in: context)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        for y in [1000, 1030, 1050] {
            let alpha = (700...1100).map { Int(bytes[y * context.bytesPerRow + $0 * 4 + 3]) }
            #expect(alpha.max()! - alpha.min()! <= 2)
        }
    }

    @Test func eightHundredPixelSoftStrokeHasNoPeriodicRidges() throws {
        #expect(MetalBrushCoverage.shared != nil)
        let session = session()
        session.beginBrush(at: CGPoint(x: 600, y: 1600))
        session.continueBrush(at: CGPoint(x: 3400, y: 1600))
        #expect(session.finishBrushImmediately())
        let layer = try #require(session.activeLayer)
        let context = try BrushRaster.context(width: 4000, height: 4000, mask: false)
        LayerRenderer.draw(try #require(layer.asset?.image), transform: layer.transform, center: layer.transform.center, in: context)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        // Stay outside both feathered end caps: a soft 800 px tip reaches up to 540 px.
        for y in [1600, 1700, 1800, 1900, 1980, 2070] {
            let alpha = (1200...2800).map { Int(bytes[y * context.bytesPerRow + $0 * 4 + 3]) }
            #expect(alpha.max()! - alpha.min()! <= 1)
        }
    }
}
