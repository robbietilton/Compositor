import AppKit
import Testing
@testable import Compositor

@MainActor struct LiveMaskTests {
    @Test func clippingColorPreservesSoftBaseAlphaWithoutBlackFringe() async throws {
        let s = EditorSession(); s.createDocument(width: 2, height: 2)
        s.insert(try asset([255,128,32,0], color: 0))
        s.insert(try asset([255,255,255,255]))
        let id = try #require(s.activeLayerID)
        s.toggleClippingMask(id)
        for i in 0..<2 { s.document?.layers[i].transform.sampling = .nearest }
        let result = try await ImageExporter.shared.render(#require(s.projectSnapshot()))
        #expect(try alpha(result.image) == [255,128,32,0])
        let ctx = try BrushRaster.context(width: 2, height: 2, mask: false)
        BrushRaster.draw(result.image, in: CGRect(x: 0, y: 0, width: 2, height: 2), mask: false, context: ctx)
        let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for i in 0..<4 {
            #expect(bytes[i*4] == bytes[i*4+3])
            #expect(bytes[i*4+1] == 0 && bytes[i*4+2] == 0)
        }
        s.document?.layers[1].opacity = 0.5
        let translucent = try await ImageExporter.shared.render(#require(s.projectSnapshot()))
        #expect(try alpha(translucent.image) == [255,128,32,0])
        s.document?.layers[1].opacity = 1
        let white = try BrushRaster.context(width: 2, height: 2, mask: false)
        white.setFillColor(CGColor(gray: 1, alpha: 1))
        white.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        s.insert(ImportedImage(image: try #require(white.makeImage()), thumbnail: try #require(white.makeImage()), name: "White"))
        let background = try #require(s.activeLayerID)
        _ = s.placeLayer(background, in: nil, atBottom: true)
        let flattened = try await ImageExporter.shared.render(#require(s.projectSnapshot()))
        #expect(try alpha(flattened.image) == [255,255,255,255])
        BrushRaster.draw(flattened.image, in: CGRect(x: 0, y: 0, width: 2, height: 2), mask: false, context: ctx)
        for i in 0..<4 { #expect(bytes[i*4] == 255) }
    }

    func asset(_ alpha: [UInt8], color: UInt8 = 255) throws -> ImportedImage {
        let bytes = alpha.flatMap { a in [UInt8(Int(color)*Int(a)/255), UInt8(0), UInt8(0), a] }
        let image = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return ImportedImage(image: image, thumbnail: image, name: "Fixture")
    }
    func alpha(_ image: CGImage) throws -> [UInt8] {
        let ctx = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: ctx)
        let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (0..<image.width*image.height).map { bytes[$0*4+3] }
    }
    func fixture() throws -> EditorSession {
        let s = EditorSession(); s.createDocument(width: 2, height: 2)
        s.insert(try asset([255,255,255,255])); s.insert(try asset([255,0,128,255], color: 0))
        for i in 0..<2 { s.document?.layers[i].transform.sampling = .nearest }
        s.document?.layers[1].isVisible = false
        #expect(s.linkMask(source: s.document!.layers[1].id, target: s.document!.layers[0].id))
        return s
    }
    @Test func optionClickCreatesSharedStackAndDragOutReleases() throws {
        let s = EditorSession(); s.createDocument(width: 2, height: 2)
        for _ in 0..<3 { s.insert(try asset([255,255,255,255])) }
        let ids = s.document!.layers.map(\.id)
        #expect(!s.canToggleClippingMask(ids[0]) && s.canToggleClippingMask(ids[1]))
        s.toggleClippingMask(ids[0])
        #expect(s.document?.layers[0].maskSourceID == nil)
        s.toggleClippingMask(ids[1]); s.toggleClippingMask(ids[2])
        #expect(s.document?.layers[1].maskSourceID == ids[0])
        #expect(s.document?.layers[2].maskSourceID == ids[0])
        #expect(s.canToggleClippingMask(ids[2]))
        s.toggleClippingMask(ids[2])
        #expect(s.document?.layers[2].maskSourceID == nil)
        #expect(s.document?.layers[1].maskSourceID == ids[0])
        s.toggleClippingMask(ids[2]); s.toggleClippingMask(ids[1])
        #expect(s.document?.layers[1].maskSourceID == nil && s.document?.layers[2].maskSourceID == nil)
        s.undo(); #expect(s.document?.layers[2].maskSourceID == ids[0])
        #expect(s.placeLayer(ids[2], in: nil, atBottom: true))
        #expect(s.document?.layers.first?.id == ids[2] && s.document?.layers.first?.maskSourceID == nil)
        #expect(s.document?.layers.last?.maskSourceID == ids[0])
        s.undo()
        #expect(s.document?.layers.last?.id == ids[2] && s.document?.layers.last?.maskSourceID == ids[0])
    }
    @Test func hiddenBlackSourceSuppliesAlphaAndRasterMasksMultiply() async throws {
        let s = try fixture()
        var raster = try await ImageExporter.shared.render(#require(s.projectSnapshot()))
        #expect(try alpha(raster.image) == [255,0,128,255])
        s.document?.layers[1].opacity = 0.5
        raster = try await ImageExporter.shared.render(#require(s.projectSnapshot()))
        let a = try alpha(raster.image)
        #expect(abs(Int(a[0])-128) <= 1 && a[1] == 0 && abs(Int(a[2])-64) <= 1)
        let gray = try BrushRaster.context(width: 2, height: 2, mask: true)
        gray.setFillColor(gray: 0.5, alpha: 1); gray.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        s.document?.layers[0].mask = LayerMask(asset: try LayerMask.asset(from: #require(gray.makeImage())))
        raster = try await ImageExporter.shared.render(#require(s.projectSnapshot()))
        #expect(try alpha(raster.image)[0] < a[0])
    }
    @Test func cyclesUndoPersistenceBakeAndDelete() async throws {
        let s = try fixture(), target = s.document!.layers[0].id, source = s.document!.layers[1].id
        #expect(!s.linkMask(source: target, target: source))
        #expect(!s.linkMask(source: target, target: target))
        s.undo(); #expect(s.document?.layers[0].maskSourceID == nil)
        s.redo(); #expect(s.document?.layers[0].maskSourceID == source)
        let snapshot = try #require(s.projectSnapshot())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LiveMask-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(snapshot, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.layers[0].maskSourceID == source)
        let before = try await ImageExporter.shared.render(loaded)
        let baked = try #require(try LiveMaskBaker.bake(loaded, target: target))
        s.finishDeletingLayer(source, baked: [target:baked])
        let after = try await ImageExporter.shared.render(#require(s.projectSnapshot()))
        #expect(try alpha(before.image) == alpha(after.image))
        #expect(s.document?.layers[0].maskSourceID == nil)
        s.undo(); #expect(s.document?.layers.count == 2 && s.document?.layers[0].maskSourceID == source)
        var bad = snapshot.manifest.layers; bad[1].maskSourceID = target
        #expect(throws: (any Error).self) { try LiveMaskGraph.validate(bad) }
    }
    @Test func movingSourceChangesCoverageAndChainsMultiply() async throws {
        let s = try fixture()
        s.document?.layers[1].transform.origin.x += 1
        var raster = try await ImageExporter.shared.render(#require(s.projectSnapshot()))
        #expect(try alpha(raster.image) == [0,255,0,128])
        s.document?.layers[1].transform.origin.x -= 1
        s.insert(try asset([0,255,255,255]))
        s.document?.layers[2].isVisible = false
        #expect(s.linkMask(source: s.document!.layers[2].id, target: s.document!.layers[1].id))
        raster = try await ImageExporter.shared.render(#require(s.projectSnapshot()))
        #expect(try alpha(raster.image) == [0,0,128,255])
    }

    @Test(arguments: [false, true])
    func deletingGIFLiveMaskSourceRetainsTheChosenResult(bakes: Bool) async throws {
        let url = try ImageImportTests().animatedGIFFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        session.createDocument(width: 32, height: 24)
        session.insert(try asset([255, 0, 128, 255]))
        let source = try #require(session.activeLayerID)
        session.document?.layers[0].isVisible = false
        session.document?.layers[0].transform = LayerTransform(origin: .zero, size: CGSize(width: 32, height: 24), sampling: .nearest)
        await session.importImages([url])
        let target = try #require(session.activeLayerID)
        session.document?.layers[1].transform.sampling = .nearest
        await session.selectGIFTimelineFrame(1)
        let gray = try BrushRaster.context(width: 1, height: 1, mask: true)
        gray.setFillColor(gray: 0.5, alpha: 1)
        gray.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        session.document?.layers[1].mask = LayerMask(asset: try LayerMask.asset(from: #require(gray.makeImage())))
        session.applySelection(CGPath(rect: CGRect(x: 0, y: 0, width: 16, height: 24), transform: nil), mode: .replace, name: "Select")
        session.toggleGIFFrameMaskTarget()
        #expect(session.linkMask(source: source, target: target))
        let snapshot = try #require(session.projectSnapshot())
        let before = try await ImageExporter.shared.render(snapshot)
        let baked = bakes ? [target: try #require(try LiveMaskBaker.bake(snapshot, target: target))] : [:]
        session.finishDeletingLayers([source], baked: baked)
        let after = try await ImageExporter.shared.render(#require(session.projectSnapshot()))
        #expect(session.activeLayer?.maskSourceID == nil)
        if bakes {
            #expect(session.activeLayer?.gifAnimation == nil && session.activeLayer?.gifFrameMasks.isEmpty == true)
            #expect(session.gifTimelineFrames.isEmpty && !session.isGIFFrameMaskSelected)
            #expect(try alpha(after.image) == alpha(before.image))
            #expect(try ImageImportTests().rgba(after.image, x: 5, y: 5) == ImageImportTests().rgba(before.image, x: 5, y: 5))
        } else {
            #expect(session.activeLayer?.gifAnimation != nil && session.activeLayer?.gifFrameMasks[1] != nil)
            #expect(session.gifTimelineSelectedFrameIndex == 1)
            #expect(try alpha(after.image) != alpha(before.image))
        }
        session.undo()
        #expect(session.document?.layers.count == 2 && session.activeLayer?.maskSourceID == source)
        #expect(session.activeLayer?.gifAnimation != nil && session.activeLayer?.gifFrameMasks[1] != nil)
        let undone = try await ImageExporter.shared.render(#require(session.projectSnapshot()))
        #expect(try alpha(undone.image) == alpha(before.image))
        session.redo()
        #expect(session.activeLayer?.maskSourceID == nil)
        #expect((session.activeLayer?.gifAnimation == nil) == bakes)
    }
}
