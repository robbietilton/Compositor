import AppKit
import Testing
@testable import Compositor

@MainActor
struct GIFFrameDuplicationTests {
    private func displayed(_ session: EditorSession) throws -> CGImage {
        try #require(session.activeLayer.flatMap { session.displayedAsset(for: $0)?.image })
    }

    private func pixel(_ image: CGImage, x: Int = 8) throws -> [UInt8] {
        try ImageImportTests().rgba(image, x: x, y: 12)
    }

    private func paint(_ session: EditorSession) throws {
        session.isMaskSelected = false
        session.selectTool(.brush)
        session.brushSettings = BrushSettings(diameter: 6, hardness: 1, red: 0, green: 0, blue: 0)
        session.beginBrush(at: CGPoint(x: 8, y: 12))
        #expect(session.finishBrushImmediately())
        #expect(session.brushError == nil)
    }

    @Test(arguments: [0, 1, 3])
    func duplicateInsertsOnTheRightAndCopiesTimingPixelsAndMask(index: Int) async throws {
        let url = try GIFFrameDeletionTests().fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        await session.selectGIFTimelineFrame(index)
        try paint(session)
        await session.addGIFFrameMask(at: index, for: id)
        session.toggleGIFFrameMaskEnabled(at: index, for: id)
        let mask = try #require(session.activeLayer?.gifFrameMasks[index])
        let image = try displayed(session)
        let source = try #require(session.activeLayer?.gifAnimation?.source)
        let before = session.document
        let count = session.history.undoCount
        session.setGIFPlaybackSpeed(GIFPlaybackSpeed(position: 1), for: id)
        session.toggleGIFPlayback(for: id)
        await session.duplicateGIFFrame(at: index, for: id)

        var indices = Array(0..<4)
        indices.insert(4, at: index + 1)
        var delays = source.frames.map(\.duration)
        delays.insert(delays[index], at: index + 1)
        #expect(session.gifTimelineFrames.map(\.index) == indices)
        #expect(session.gifTimelineFrames.map(\.duration) == delays)
        #expect(abs(session.gifTimelineFrames.reduce(0) { $0 + $1.duration }
            - source.frames.reduce(0) { $0 + $1.duration } - source.frames[index].duration) < 0.000001)
        #expect(session.activeLayer?.gifAnimation?.source === source)
        #expect(session.activeLayer?.gifAnimation?.sourceFrameIndex(for: 4) == index)
        #expect(session.activeLayer?.gifAnimation?.framePixels[4]?.image === image)
        #expect(session.activeLayer?.gifFrameMasks[4] == mask)
        #expect(session.gifTimelineSelectedFrameIndex == 4 && session.isGIFFrameMaskSelected)
        #expect(try displayed(session) === image)
        #expect(session.activeLayerID == id && session.selectedLayerIDs == [id])
        #expect(!session.gifTimelineIsPlaying && session.gifTimelinePlaybackSpeed.multiplier == 2)
        #expect(session.history.undoCount == count + 1 && session.history.undoName == "Duplicate GIF Frame")
        let after = session.document
        session.undo()
        #expect(session.document == before && session.gifTimelineFrames.count == 4)
        session.redo()
        #expect(session.document == after && session.gifTimelineFrames.map(\.index) == indices)
    }

    @Test func copiedMasksAndPixelsCanBeEditedIndependently() async throws {
        let url = try GIFFrameDeletionTests().fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        await session.addGIFFrameMask(at: 0, for: id)
        let originalMask = try #require(session.activeLayer?.gifFrameMasks[0]?.asset.image)
        await session.duplicateGIFFrame(at: 0, for: id)
        session.document?.selection = DocumentSelection(path: CGPath(rect: CGRect(x: 0, y: 0, width: 16, height: 24), transform: nil), antialiased: false)
        await session.clearSelectedPixels()
        #expect(session.brushError == nil)
        let copiedMask = try #require(session.activeLayer?.gifFrameMasks[4]?.asset.image)
        #expect(copiedMask !== originalMask)
        #expect(session.activeLayer?.gifFrameMasks[0]?.asset.image === originalMask)
        session.document?.selection = nil
        try paint(session)
        let edited = try displayed(session)
        #expect(try pixel(edited) == [0, 0, 0, 255])
        #expect(session.activeLayer?.gifAnimation?.framePixels[0] == nil)
        await session.selectGIFTimelineFrame(0)
        #expect(try pixel(try displayed(session))[0] > 240)
        await session.selectGIFTimelineFrame(4)
        #expect(try displayed(session) === edited)
        #expect(session.activeLayer?.gifFrameMasks[4]?.asset.image === copiedMask)
    }

    @Test func duplicateOfADuplicateSurvivesSourceFrameDeletionReopenAndResize() async throws {
        let url = try GIFFrameDeletionTests().fixture()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CompositorGIFDuplicate-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        await session.selectGIFTimelineFrame(1)
        try paint(session)
        await session.addGIFFrameMask(at: 1, for: id)
        session.toggleGIFFrameMaskEnabled(at: 1, for: id)
        await session.duplicateGIFFrame(at: 1, for: id)
        await session.deleteGIFFrame(at: 1, for: id)
        await session.duplicateGIFFrame(at: 4, for: id)
        let expected = [0, 4, 5, 2, 3]
        #expect(session.gifTimelineFrames.map(\.index) == expected)
        #expect(session.activeLayer?.gifAnimation?.sourceFrameIndex(for: 5) == 1)
        let snapshot = try #require(session.projectSnapshot())
        #expect(snapshot.manifest.version == ProjectManifest.current)
        let package = folder.appendingPathComponent("Edited.comp")
        try await ProjectStore.shared.save(snapshot, to: package)
        try FileManager.default.removeItem(at: url)
        let reopened = EditorSession()
        reopened.installProject(try await ProjectStore.shared.load(from: package), from: package)
        #expect(reopened.gifTimelineFrames.map(\.index) == expected)
        #expect(reopened.gifTimelineFrames.map(\.duration) == session.gifTimelineFrames.map(\.duration))
        #expect(reopened.gifTimelineSelectedFrameIndex == 5 && !reopened.gifTimelineIsPlaying)
        #expect(reopened.activeLayer?.gifFrameMasks[5]?.isEnabled == false)
        #expect(reopened.activeLayer?.gifFrameMasks[1] == nil)
        #expect(try pixel(try displayed(reopened)) == [0, 0, 0, 255])
        #expect(try pixel(try displayed(reopened), x: 24)[2] > 240)
        var unedited = try #require(reopened.activeLayer?.gifAnimation)
        unedited.framePixels = [:]
        let raw = try await ImageImporter.shared.decodeGIFFrame(unedited, index: 5, name: "Duplicate")
        #expect(try pixel(raw.image)[2] > 240)
        await reopened.selectGIFTimelineFrame(2)
        #expect(try pixel(try displayed(reopened))[1] > 240)

        let resized = try await ImageResizer.shared.resize(snapshot,
            to: ImageSizeOptions(width: 64, height: 48, resolution: 72, sampling: .nearest))
        let resizedPackage = folder.appendingPathComponent("Resized.comp")
        try await ProjectStore.shared.save(resized, to: resizedPackage)
        let loaded = try await ProjectStore.shared.load(from: resizedPackage)
        #expect(loaded.animations[id]?.frameOrder == snapshot.animations[id]?.frameOrder)
        #expect(loaded.animations[id]?.framePixels[5]?.image.width == 64)
        #expect(loaded.frameMasks[id]?[5]?.asset.image.height == 48)
    }

    @Test func undoDoesNotReuseTheWrongPreviewWhenAnInsertedIdentityIsReused() async throws {
        let url = try GIFFrameDeletionTests().fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        await session.duplicateGIFFrame(at: 1, for: id)
        #expect(try pixel(try displayed(session))[2] > 240)
        await session.deleteGIFFrame(at: 4, for: id)
        await session.duplicateGIFFrame(at: 2, for: id)
        #expect(session.gifTimelineSelectedFrameIndex == 4)
        #expect(try pixel(try displayed(session))[1] > 240)
        session.undo()
        session.undo()
        #expect(session.gifTimelineSelectedFrameIndex == 4)
        #expect(try pixel(try displayed(session))[2] > 240)
        session.redo()
        session.redo()
        #expect(try pixel(try displayed(session))[1] > 240)
    }

    @Test func aSingleRemainingFrameCanBeDuplicatedAndInsertedCopiesCanBeDeleted() async throws {
        let url = try GIFFrameDeletionTests().fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        for index in [0, 1, 2] { await session.deleteGIFFrame(at: index, for: id) }
        await session.duplicateGIFFrame(at: 3, for: id)
        #expect(session.gifTimelineFrames.map(\.index) == [3, 4])
        #expect(session.gifTimelineFrames.map(\.duration) == [0.24, 0.24])
        session.toggleGIFPlayback(for: id)
        #expect(session.gifTimelineIsPlaying)
        await session.deleteGIFFrame(at: 3, for: id)
        #expect(session.gifTimelineFrames.map(\.index) == [4])
        #expect(!session.gifTimelineIsPlaying)
        await session.duplicateGIFFrame(at: 4, for: id)
        #expect(session.gifTimelineFrames.map(\.index) == [4, 5])
        await session.deleteGIFFrame(at: 5, for: id)
        #expect(session.activeLayer?.gifAnimation?.deletedFrameIndices == [0, 1, 2, 3])
        #expect(session.gifTimelineFrames.map(\.index) == [4])
        let before = session.document
        await session.deleteGIFFrame(at: 4, for: id)
        #expect(session.document == before)
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: package) }
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: package)
        #expect(try await ProjectStore.shared.load(from: package).animations[id]?.frames.count == 1)
    }

    @Test func invalidOrdersAreRejectedWithoutReplacingTheSavedProject() async throws {
        let url = try GIFFrameDeletionTests().fixture()
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: package) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        await session.duplicateGIFFrame(at: 1, for: id)
        let snapshot = try #require(session.projectSnapshot())
        let order = try #require(snapshot.animations[id]?.frameOrder)
        try await ProjectStore.shared.save(snapshot, to: package)
        let metadataFile = package.appendingPathComponent("manifest.json")
        let savedMetadata = try Data(contentsOf: metadataFile)
        let invalidOrders: [[GIFFrameReference]] = [[], order + [order[0]], Array(order.dropFirst()),
            order.map { $0.index == 4 ? GIFFrameReference(index: 4, sourceIndex: 4) : $0 },
            order.map { $0.index == 0 ? GIFFrameReference(index: 0, sourceIndex: 1) : $0 },
            order.map { $0.index == 4 ? GIFFrameReference(index: GIFTimelineLimits.frameIdentityLimit, sourceIndex: 1) : $0 }]
        for invalidOrder in invalidOrders {
            var manifest = snapshot.manifest
            manifest.layers[0].gif?.frameOrder = invalidOrder
            var animations = snapshot.animations
            animations[id]?.frameOrder = invalidOrder
            let invalid = ProjectSnapshot(manifest: manifest, images: snapshot.images,
                masks: snapshot.masks, animations: animations, frameMasks: snapshot.frameMasks)
            await #expect(throws: (any Error).self) { try await ProjectStore.shared.save(invalid, to: package) }
            #expect(try Data(contentsOf: metadataFile) == savedMetadata)
            try JSONEncoder().encode(manifest).write(to: metadataFile, options: .atomic)
            await #expect(throws: (any Error).self) { try await ProjectStore.shared.load(from: package) }
            try savedMetadata.write(to: metadataFile, options: .atomic)
        }
        var oldManifest = snapshot.manifest
        oldManifest.version = 27
        try JSONEncoder().encode(oldManifest).write(to: metadataFile, options: .atomic)
        await #expect(throws: (any Error).self) { try await ProjectStore.shared.load(from: package) }
        // A current deletion-only package can use its implicit source order.
        await session.deleteGIFFrame(at: 4, for: id)
        await session.deleteGIFFrame(at: 1, for: id)
        let legacy = try #require(session.projectSnapshot())
        oldManifest = legacy.manifest
        oldManifest.version = ProjectManifest.current
        oldManifest.layers[0].gif?.frameOrder = nil
        oldManifest.layers[0].gif?.timing = nil
        var legacyAnimations = legacy.animations
        legacyAnimations[id]?.frameOrder = nil
        legacyAnimations[id]?.timing = GIFFrameTiming()
        try await ProjectStore.shared.save(ProjectSnapshot(manifest: oldManifest, images: legacy.images,
            masks: legacy.masks, animations: legacyAnimations, frameMasks: legacy.frameMasks), to: package)
        #expect(try await ProjectStore.shared.load(from: package).animations[id]?.frames.map(\.index) == [0, 2, 3])
    }

    @Test func duplicationRespectsFramePixelAndMaskLimits() async throws {
        let url = try GIFFrameDeletionTests().fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        let original = try #require(session.document)
        let source = try #require(session.activeLayer?.gifAnimation?.source)
        let frames = (0..<GIFTimelineLimits.maxFrames).map {
            GIFTimelineFrame(index: $0, thumbnail: source.frames[0].thumbnail, duration: 0.1)
        }
        session.document?.layers[0].gifAnimation = GIFAnimation(source: GIFSource(data: source.data,
            frames: frames, width: source.width, height: source.height))
        session.history.reset()
        let full = session.document
        await session.duplicateGIFFrame(at: 0, for: id)
        #expect(session.document == full && !session.canUndo)

        // Count shared immutable grids as their separate saved copies, without allocating the entire budget.
        let side = 512, area = side * side
        let context = try BrushRaster.context(width: side, height: side, mask: false)
        let image = try #require(context.makeImage())
        let asset = ImportedImage(image: image, thumbnail: source.frames[0].thumbnail, name: "Budget")
        session.document = original
        session.document?.layers[0].asset = asset
        session.document?.layers[0].gifAnimation?.geometry = GIFFrameGeometry(width: side, height: side, unitTransform: .identity)
        session.document?.layers[0].gifAnimation?.framePixels[0] = asset
        for _ in 0..<(DocumentLimits.documentPixelBudget / area - 2) {
            session.document?.layers.append(ImageLayer(asset: asset, origin: .zero))
        }
        session.history.reset()
        let pixelsFull = session.document
        await session.duplicateGIFFrame(at: 0, for: id)
        #expect(session.document == pixelsFull && !session.canUndo)
        #expect(session.brushError == ProjectError.tooLarge.localizedDescription)

        session.document = original
        session.brushError = nil
        let maskContext = try BrushRaster.context(width: side, height: side, mask: true)
        let mask = LayerMask(asset: try LayerMask.asset(from: try #require(maskContext.makeImage())))
        session.document?.layers[0].gifFrameMasks[0] = mask
        for _ in 0..<(DocumentLimits.documentPixelBudget / area - 1) {
            var layer = ImageLayer(name: "Budget", blankSize: CGSize(width: side, height: side))
            layer.mask = mask
            session.document?.layers.append(layer)
        }
        session.history.reset()
        let masksFull = session.document
        await session.duplicateGIFFrame(at: 0, for: id)
        #expect(session.document == masksFull && !session.canUndo)
        #expect(session.brushError == ProjectError.tooLarge.localizedDescription)
    }
}
