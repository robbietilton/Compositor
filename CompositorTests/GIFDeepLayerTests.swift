import AppKit
import ImageIO
import Testing
@testable import Compositor

/// The two project-format lineages and animations beside Compositor 1.5's high-precision still layers.
@MainActor
struct GIFDeepLayerTests {
    private func asset(hdr: Bool = false) throws -> ImportedImage {
        let context = try DeepLayer.context(width: 32, height: 24, hdr: hdr)
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt16.self)
        for y in 0..<24 {
            for x in 0..<32 {
                let i = y * context.bytesPerRow / 2 + x * 4
                pixels[i] = hdr ? Float16(2).bitPattern : UInt16(32768 + x)
                pixels[i + 1] = 0; pixels[i + 2] = 0
                pixels[i + 3] = hdr ? Float16(1).bitPattern : 65535
            }
        }
        return try DeepLayer.asset(#require(context.makeImage()), name: hdr ? "HDR" : "16-Bit")
    }

    private func package() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("GIFDeepLayers-\(UUID()).comp")
    }

    private func snapshot(_ session: EditorSession, version: Int) throws -> ProjectSnapshot {
        let source = try #require(session.projectSnapshot())
        var manifest = source.manifest
        manifest.version = version
        return ProjectSnapshot(manifest: manifest, images: source.images, masks: source.masks,
                               animations: source.animations, frameMasks: source.frameMasks)
    }

    @Test(arguments: [12, 13])
    func upstreamPrecisionVersionsStillOpen(version: Int) async throws {
        let session = EditorSession()
        session.createDocument(width: 32, height: 24)
        session.insert(try asset(hdr: version == 13))
        let snapshot = try snapshot(session, version: version)
        let url = package()
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(snapshot, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        let id = try #require(session.activeLayerID)
        let reopened = try #require(loaded.images[id])
        #expect(reopened.deep?.bitsPerComponent == 16)
        #expect(reopened.isHDR == (version == 13))
        #expect(loaded.animations.isEmpty)
        session.installProject(loaded, from: url)
        #expect(session.projectSnapshot()?.manifest.version == ProjectManifest.current)
    }

    @Test(arguments: [27, ProjectManifest.current])
    func foundationAndCurrentGIFVersionsStillOpen(version: Int) async throws {
        let file = try ImageImportTests().animatedGIFFixture()
        let url = package()
        defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([file])
        let id = try #require(session.activeLayerID)
        await session.selectGIFTimelineFrame(1)
        await session.invertPixels()
        if version == 27 { session.document?.layers[0].gifAnimation?.timing = GIFFrameTiming() }
        if version >= 28 { await session.duplicateGIFFrame(at: 1, for: id) }
        if version >= 28 { session.setGIFFrameTiming(GIFFrameTiming(frameDelays: [1: 0.2]), for: id) }
        let snapshot = try snapshot(session, version: version)
        try await ProjectStore.shared.save(snapshot, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.animations[id]?.frameReferences == snapshot.animations[id]?.frameReferences)
        #expect(loaded.animations[id]?.timing == snapshot.animations[id]?.timing)
        #expect(loaded.animations[id]?.framePixels.keys.sorted() == snapshot.animations[id]?.framePixels.keys.sorted())
    }

    @Test func mixedLayersKeepPixelsMasksTimingAndPrecisionThroughResizeAndReopen() async throws {
        let file = try ImageImportTests().animatedGIFFixture()
        let url = package()
        defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        session.createDocument(width: 32, height: 24)
        session.insert(try asset())
        let stillID = try #require(session.activeLayerID)
        session.insert(try asset(hdr: true))
        let hdrID = try #require(session.activeLayerID)
        await session.importImages([file])
        let gifID = try #require(session.activeLayerID)
        await session.selectGIFTimelineFrame(1)
        await session.invertPixels()
        session.setGIFFrameTiming(GIFFrameTiming(frameDelays: [1: 0.2]), for: gifID)
        let maskContext = try BrushRaster.context(width: 32, height: 24, mask: true)
        maskContext.setFillColor(gray: 1, alpha: 1)
        maskContext.fill(CGRect(x: 0, y: 0, width: 16, height: 24))
        session.document?.layers[2].gifFrameMasks[1] = LayerMask(asset: try LayerMask.asset(from: #require(maskContext.makeImage())))
        let snapshot = try #require(session.projectSnapshot())
        let resized = try await ImageResizer.shared.resize(snapshot,
            to: ImageSizeOptions(width: 64, height: 48, resolution: 72))
        #expect(resized.images[stillID]?.deep?.bitsPerComponent == 16)
        #expect(resized.images[hdrID]?.isHDR == true)
        #expect(resized.animations[gifID]?.framePixels[1]?.image.width == 64)
        try await ProjectStore.shared.save(resized, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.images[stillID]?.deep?.bitsPerComponent == 16)
        #expect(loaded.images[hdrID]?.isHDR == true)
        #expect(loaded.animations[gifID]?.timing.frameDelays == [1: 0.2])
        #expect(loaded.frameMasks[gifID]?[1]?.asset.image.width == 64)
        #expect(loaded.animations[gifID]?.framePixels[1]?.deep == nil)
        let encoded = try await GIFExporter.shared.encode(loaded, width: 64, height: 48, options: GIFExportOptions(layerID: gifID))
        #expect(encoded.durations == [0.1, 0.2])
        #expect(CGImageSourceCreateWithData(encoded.data as CFData, nil).map(CGImageSourceGetCount) == 2)
    }

    @Test func depthConversionLeavesGIFStateAloneAndDeepEditsUseTheFrameGrid() async throws {
        let file = try ImageImportTests().animatedGIFFixture()
        defer { try? FileManager.default.removeItem(at: file) }
        let session = EditorSession()
        await session.importImages([file])
        let id = try #require(session.activeLayerID)
        await session.selectGIFTimelineFrame(1)
        let before = try #require(session.projectSnapshot())
        #expect(!session.canConvertLayerDepth)
        session.convertLayerDepth()
        #expect(session.activeLayer?.asset?.deep == nil)
        #expect(session.activeLayer?.gifAnimation?.source === before.animations[id]?.source)
        let layer = try #require(session.activeLayer)
        let edited = try session.layerByEditingPixels(layer, asset: asset(), transform: layer.transform, mask: layer.mask)
        #expect(edited.gifAnimation?.framePixels[1]?.deep == nil)
        #expect(edited.gifAnimation?.framePixels[1]?.image.bitsPerComponent == 8)
        #expect(edited.gifAnimation?.framePixels[0] == nil)
    }
}
