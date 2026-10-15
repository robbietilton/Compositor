import AppKit
import ImageIO
import Testing
@testable import Compositor

@MainActor
struct GIFFrameBatchTests {
    private func session() async throws -> EditorSession {
        let url = try GIFFrameDeletionTests().fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        return session
    }

    @Test func commandSelectionTracksIdentitiesAcrossNavigationReorderAndDeletion() {
        var selection = GIFFrameSelection()
        selection.reconcile(with: [0, 1, 2, 3, 4], displayedIndex: 1)
        selection.select(4, toggling: true, displayedIndex: 1)
        selection.followDisplayedFrame(2)
        #expect(selection.indices == [1, 4])
        selection.reconcile(with: [4, 3, 2, 1, 0], displayedIndex: 2)
        #expect(selection.indices == [1, 4])
        selection.select(1, toggling: true, displayedIndex: 2)
        #expect(selection.indices == [4])
        selection.select(4, toggling: true, displayedIndex: 2)
        #expect(selection.indices == [4])
        selection.reconcile(with: [0, 2, 3], displayedIndex: 2)
        #expect(selection.indices == [2])
        selection.select(3, toggling: true, displayedIndex: 2)
        selection.select(0, toggling: false, displayedIndex: 2)
        #expect(selection.indices == [0])
        selection.followDisplayedFrame(3)
        #expect(selection.indices == [3])
    }

    @Test(arguments: [([0, 1], 0, 2), ([1, 2], 1, 3), ([2, 3], 3, 1), ([0, 2], 3, 3)])
    func batchDeletionKeepsSurvivorsAndReplacesOnlyADeletedPreview(change: ([Int], Int, Int)) async throws {
        let session = try await session(), id = try #require(session.activeLayerID)
        #expect(await session.addGIFFrameMasks(at: [0, 1, 2, 3], for: id))
        session.toggleGIFFrameMaskEnabled(at: 2, for: id)
        session.document?.layers[0].gifAnimation?.timing.frameDelays = [0: 0.12, 2: 0.28]
        for index in 0..<4 {
            let asset = try await ImageImporter.shared.decodeGIFFrame(
                try #require(session.activeLayer?.gifAnimation), index: index, name: "Edited")
            session.document?.layers[0].gifAnimation?.framePixels[index] = asset
        }
        await session.selectGIFTimelineFrame(change.1)
        let before = try #require(session.document), animation = try #require(session.activeLayer?.gifAnimation)
        let displayed = try #require(session.activeLayer.flatMap { session.displayedAsset(for: $0)?.image })
        let count = session.history.undoCount, removed = Set(change.0)
        let survivors = animation.frames.filter { !removed.contains($0.index) }
        session.toggleGIFPlayback(for: id)
        await session.deleteGIFFrames(at: removed, for: id)
        #expect(!session.gifTimelineIsPlaying && session.gifTimelineSelectedFrameIndex == change.2)
        #expect(session.gifTimelineFrames.map(\.index) == survivors.map(\.index))
        #expect(session.gifTimelineFrames.map(\.duration) == survivors.map(\.duration))
        let edited = try #require(session.activeLayer?.gifAnimation)
        #expect(edited.source === animation.source && edited.deletedFrameIndices == removed)
        #expect(session.activeLayer?.gifFrameMasks.keys.sorted() == survivors.map(\.index).sorted())
        for frame in survivors {
            #expect(edited.framePixels[frame.index]?.image === animation.framePixels[frame.index]?.image)
            #expect(session.activeLayer?.gifFrameMasks[frame.index] == before.layers[0].gifFrameMasks[frame.index])
        }
        if !removed.contains(change.1) {
            #expect(session.activeLayer.flatMap { session.displayedAsset(for: $0)?.image } === displayed)
        }
        #expect(session.activeLayerID == id && session.selectedLayerIDs == [id])
        #expect(session.history.undoCount == count + 1 && session.history.undoName == "Delete GIF Frames")
        let after = session.document
        session.undo()
        #expect(session.document == before)
        session.redo()
        #expect(session.document == after)
    }

    @Test func maskBatchPreservesExistingMasksAndMapsSelectionThroughLayerPlacement() async throws {
        let session = try await session(), id = try #require(session.activeLayerID)
        var existing = try #require(LayerMask.solid(revealing: false))
        existing.isEnabled = false
        existing.isLinked = false
        session.document?.layers[0].gifFrameMasks[2] = existing
        let shared = try #require(LayerMask.solid(revealing: true))
        session.document?.layers[0].mask = shared
        session.document?.layers[0].transform.rotation = 180
        await session.selectGIFTimelineFrame(3)
        session.document?.selection = DocumentSelection(path: CGPath(rect: CGRect(x: 0, y: 0, width: 16, height: 24),
                                                                    transform: nil), antialiased: false)
        let before = session.document, count = session.history.undoCount
        let displayed = session.activeLayer.flatMap { session.displayedAsset(for: $0)?.image }
        session.toggleGIFPlayback(for: id)
        #expect(await session.addGIFFrameMasks(at: [0, 1, 2], for: id))
        #expect(!session.gifTimelineIsPlaying && session.gifTimelineSelectedFrameIndex == 3 && !session.isGIFFrameMaskSelected)
        #expect(session.activeLayer.flatMap { session.displayedAsset(for: $0)?.image } === displayed)
        #expect(session.activeLayer?.gifFrameMasks[2] == existing && session.activeLayer?.gifFrameMasks[3] == nil)
        #expect(session.activeLayer?.gifAnimation == before?.layers[0].gifAnimation)
        #expect(session.activeLayer?.mask == before?.layers[0].mask && session.document?.selection == nil)
        let first = try #require(session.activeLayer?.gifFrameMasks[0]), rotated = try #require(session.activeLayer?.gifFrameMasks[1])
        #expect(try ImageImportTests().rgba(first.asset.image, x: 8, y: 12)[0] == 0)
        #expect(try ImageImportTests().rgba(first.asset.image, x: 24, y: 12)[0] == 255)
        #expect(try ImageImportTests().rgba(rotated.asset.image, x: 8, y: 12)[0] == 0)
        #expect(try ImageImportTests().rgba(rotated.asset.image, x: 24, y: 12)[0] == 255)
        #expect(session.history.undoCount == count + 1 && session.history.undoName == "Add Frame Masks")
        let after = session.document
        session.undo()
        #expect(session.document == before)
        session.redo()
        #expect(session.document == after)
    }

    @Test func revealAllMasksShareImmutablePixelsUntilOneIsEdited() async throws {
        let session = try await session(), id = try #require(session.activeLayerID)
        #expect(await session.addGIFFrameMasks(at: [0, 1], for: id))
        #expect(session.isGIFFrameMaskSelected && session.gifTimelineSelectedFrameIndex == 0)
        let first = try #require(session.activeLayer?.gifFrameMasks[0]), other = try #require(session.activeLayer?.gifFrameMasks[1])
        #expect(first.asset.image === other.asset.image)
        session.document?.selection = DocumentSelection(path: CGPath(rect: CGRect(x: 0, y: 0, width: 16, height: 24),
                                                                    transform: nil), antialiased: false)
        await session.invertPixels()
        let painted = try #require(session.activeLayer?.gifFrameMasks[0])
        #expect(painted.asset.image !== other.asset.image)
        #expect(try ImageImportTests().rgba(painted.asset.image, x: 8, y: 12)[0] == 0)
        #expect(try ImageImportTests().rgba(other.asset.image, x: 8, y: 12)[0] == 255)
        #expect(session.activeLayer?.gifFrameMasks[1] == other)
    }

    @Test func deletingMixedFrameMasksPreservesAnimationAndSavesAsOneUndoableEdit() async throws {
        let session = try await session(), id = try #require(session.activeLayerID)
        #expect(await session.addGIFFrameMasks(at: [0, 1, 2], for: id))
        session.toggleGIFFrameMaskEnabled(at: 1, for: id)
        let sharedMask = try #require(LayerMask.solid(revealing: true))
        session.document?.layers[0].mask = sharedMask
        session.document?.layers[0].gifAnimation?.timing.frameDelays[1] = 0.28
        let asset = try await ImageImporter.shared.decodeGIFFrame(
            try #require(session.activeLayer?.gifAnimation), index: 0, name: "Edited")
        session.document?.layers[0].gifAnimation?.framePixels[0] = asset
        let staleCopy = try #require(session.prepareGIFFrameMaskCopy(at: 0, for: id))
        session.document?.selection = DocumentSelection(path: CGPath(rect: CGRect(x: 1, y: 1, width: 8, height: 8),
                                                                    transform: nil), antialiased: false)
        let before = try #require(session.document), count = session.history.undoCount, revision = session.brushRevision
        let survivingMask = try #require(before.layers[0].gifFrameMasks[2])
        let displayed = session.activeLayer.flatMap { session.displayedAsset(for: $0)?.image }
        var refreshed = false
        session.refreshCanvasPreview = { refreshed = true }
        session.toggleGIFPlayback(for: id)
        #expect(session.deleteGIFFrameMasks(at: [0, 1, 3], for: id))
        #expect(!session.gifTimelineIsPlaying && session.gifTimelineSelectedFrameIndex == 0)
        #expect(!session.isMaskSelected && !session.isGIFFrameMaskSelected)
        #expect(session.activeLayer?.gifFrameMasks == [2: survivingMask])
        #expect(session.activeLayer?.gifAnimation == before.layers[0].gifAnimation)
        #expect(session.activeLayer?.mask == before.layers[0].mask && session.selection == before.selection)
        #expect(session.activeLayer.flatMap { session.displayedAsset(for: $0)?.image } === displayed)
        #expect(session.activeLayerID == id && session.selectedLayerIDs == [id])
        #expect(session.brushRevision > revision && refreshed)
        #expect(session.history.undoCount == count + 1 && session.history.undoName == "Delete Frame Masks")
        #expect(session.copyGIFFrameMask(staleCopy, to: [3]) == false)
        let after = session.document
        session.undo()
        #expect(session.document == before)
        session.redo()
        #expect(session.document == after)
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("GIFDeleteMasks-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: package) }
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: package)
        let reopened = EditorSession()
        reopened.installProject(try await ProjectStore.shared.load(from: package), from: package)
        #expect(reopened.activeLayer?.gifFrameMasks.keys.sorted() == [2])
        let reopenedMask = try #require(reopened.activeLayer?.gifFrameMasks[2])
        #expect(reopenedMask.isEnabled == survivingMask.isEnabled && reopenedMask.isLinked == survivingMask.isLinked)
        #expect(try ImageImportTests().rgba(reopenedMask.asset.image, x: 8, y: 12)
            == ImageImportTests().rgba(survivingMask.asset.image, x: 8, y: 12))
        #expect(reopened.activeLayer?.gifAnimation?.timing == session.activeLayer?.gifAnimation?.timing)
        #expect(reopened.activeLayer?.gifAnimation?.framePixels.keys.sorted() == [0])
    }

    @Test func deletingOtherFrameMasksKeepsTheDisplayedOrSharedMaskTarget() async throws {
        let session = try await session(), id = try #require(session.activeLayerID)
        #expect(await session.addGIFFrameMasks(at: [0, 1, 2], for: id))
        await session.selectGIFTimelineFrame(2)
        #expect(session.isGIFFrameMaskSelected)
        #expect(session.deleteGIFFrameMasks(at: [0, 1], for: id))
        #expect(session.isMaskSelected && session.isGIFFrameMaskSelected && session.gifTimelineSelectedFrameIndex == 2)
        let sharedMask = try #require(LayerMask.solid(revealing: true))
        session.document?.layers[0].mask = sharedMask
        session.selectLayerTarget(id, mask: true)
        session.viewsMaskAlone = true
        session.deleteGIFFrameMask(at: 2, for: id)
        #expect(session.isMaskSelected && !session.isGIFFrameMaskSelected && session.viewsMaskAlone)
        #expect(session.activeLayer?.gifFrameMasks.isEmpty == true && session.activeLayer?.mask != nil)
        #expect(session.history.undoName == "Delete Frame Mask")
    }

    @Test func invalidBlockedAndUnmaskedDeleteBatchesDoNotEditOrPausePlayback() async throws {
        let session = try await session(), id = try #require(session.activeLayerID)
        #expect(await session.addGIFFrameMasks(at: [0, 1], for: id))
        let before = session.document, count = session.history.undoCount, revision = session.brushRevision
        session.toggleGIFPlayback(for: id)
        for indices: Set<Int> in [[], [0, 99], [-1, 1]] {
            #expect(session.deleteGIFFrameMasks(at: indices, for: id) == false)
        }
        #expect(session.deleteGIFFrameMasks(at: [0, 1], for: UUID()) == false)
        #expect(session.deleteGIFFrameMasks(at: [2, 3], for: id))
        session.showsImporter = true
        #expect(session.deleteGIFFrameMasks(at: [0, 1], for: id) == false)
        session.showsImporter = false
        session.isProjectBusy = true
        #expect(session.deleteGIFFrameMasks(at: [0, 1], for: id) == false)
        session.isProjectBusy = false
        #expect(session.document == before && session.history.undoCount == count && session.brushRevision == revision)
        #expect(session.gifTimelineIsPlaying)
    }

    @Test func invalidBlockedCanceledAndNoOpBatchesDoNotPartiallyEdit() async throws {
        let session = try await session(), id = try #require(session.activeLayerID)
        session.toggleGIFPlayback(for: id)
        let before = session.document, count = session.history.undoCount
        let invalidTargets: [Set<Int>] = [[], [0, 99], [-1, 1]]
        for indices in invalidTargets {
            #expect(await session.addGIFFrameMasks(at: indices, for: id) == false)
            await session.deleteGIFFrames(at: indices, for: id)
        }
        await session.deleteGIFFrames(at: [0, 1, 2, 3], for: id)
        #expect(session.gifTimelineIsPlaying && session.document == before && session.history.undoCount == count)
        session.showsImporter = true
        #expect(await session.addGIFFrameMasks(at: [0, 1], for: id) == false)
        await session.deleteGIFFrames(at: [0, 1], for: id)
        session.showsImporter = false
        let canceled = Task { await session.addGIFFrameMasks(at: [0, 1], for: id) }
        canceled.cancel()
        #expect(await canceled.value == false)
        let deletion = Task { await session.deleteGIFFrames(at: [0, 1], for: id) }
        deletion.cancel()
        await deletion.value
        #expect(session.document == before && session.history.undoCount == count && !session.isProjectBusy)
        #expect(await session.addGIFFrameMasks(at: [0, 1], for: id))
        let masked = session.document, maskedCount = session.history.undoCount
        #expect(await session.addGIFFrameMasks(at: [0, 1], for: id))
        #expect(session.document == masked && session.history.undoCount == maskedCount)
        #expect(await session.addGIFFrameMasks(at: [2, 3], for: UUID()) == false)
        await session.deleteGIFFrames(at: [2, 3], for: UUID())
        #expect(session.document == masked && session.history.undoCount == maskedCount)
    }

    @Test func maskBudgetChecksTheWholeBatchBeforeCreatingAnything() async throws {
        let session = try await session(), id = try #require(session.activeLayerID)
        let side = 4096, area = side * side
        let mask = try LayerMask.revealing(nil, over: LayerTransform(origin: .zero, size: CGSize(width: side, height: side)),
                                         width: side, height: side)
        session.document?.layers[0].gifAnimation?.geometry = GIFFrameGeometry(width: side, height: side, unitTransform: .identity)
        for _ in 0..<(DocumentLimits.documentPixelBudget / area - 1) {
            var layer = ImageLayer(name: "Budget", blankSize: CGSize(width: 32, height: 24))
            layer.mask = mask
            session.document?.layers.append(layer)
        }
        session.history.reset()
        let before = session.document
        #expect(await session.addGIFFrameMasks(at: [0, 1], for: id) == false)
        #expect(session.document == before && !session.canUndo && !session.isProjectBusy)
        #expect(session.brushError == ProjectError.tooLarge.localizedDescription)
        session.brushError = nil
        #expect(await session.addGIFFrameMasks(at: [0], for: id))
        #expect(session.activeLayer?.gifFrameMasks.keys.sorted() == [0] && session.history.undoCount == 1)
    }

    @Test func anExplicitEmptyCanvasSelectionCreatesHiddenMasksForTheWholeBatch() async throws {
        let session = try await session(), id = try #require(session.activeLayerID)
        session.document?.selection = DocumentSelection(path: CGMutablePath())
        #expect(await session.addGIFFrameMasks(at: [0, 2], for: id))
        for index in [0, 2] {
            let mask = try #require(session.activeLayer?.gifFrameMasks[index])
            #expect(try ImageImportTests().rgba(mask.asset.image, x: 8, y: 12)[0] == 0)
            #expect(try ImageImportTests().rgba(mask.asset.image, x: 24, y: 12)[0] == 0)
        }
        #expect(session.document?.selection == nil && session.history.undoName == "Add Frame Masks")
    }



    @Test func batchesOnReorderedCopiesRoundTripAndExportWithoutOriginalFile() async throws {
        let url = try GIFFrameDeletionTests().fixture()
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("GIFFrameBatch-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: package) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        await session.duplicateGIFFrame(at: 1, for: id)
        session.moveGIFFrame(at: 4, to: 0, for: id)
        session.document?.selection = DocumentSelection(path: CGPath(rect: CGRect(x: 0, y: 0, width: 16, height: 24),
                                                                    transform: nil), antialiased: false)
        #expect(await session.addGIFFrameMasks(at: [4, 2], for: id))
        await session.deleteGIFFrames(at: [0, 1], for: id)
        #expect(session.gifTimelineFrames.map(\.index) == [4, 2, 3] && session.gifTimelineSelectedFrameIndex == 4)
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: package)
        try FileManager.default.removeItem(at: url)
        let reopened = EditorSession()
        reopened.installProject(try await ProjectStore.shared.load(from: package), from: package)
        #expect(reopened.gifTimelineFrames.map(\.index) == [4, 2, 3])
        #expect(reopened.activeLayer?.gifFrameMasks.keys.sorted() == [2, 4])
        #expect(reopened.activeLayer?.gifAnimation?.deletedFrameIndices == [0, 1])
        let result = try await GIFExporter.shared.encode(try #require(reopened.projectSnapshot()), width: 32, height: 24,
                                                      options: GIFExportOptions(layerID: id))
        #expect(result.durations == [0.16, 0.08, 0.24])
        let source = try #require(CGImageSourceCreateWithData(result.data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 3)
        for index in [0, 1] {
            let image = try #require(CGImageSourceCreateImageAtIndex(source, index, nil))
            #expect(try ImageImportTests().rgba(image, x: 8, y: 12)[3] == 255)
            #expect(try ImageImportTests().rgba(image, x: 24, y: 12)[3] == 0)
        }
    }
}
