import AppKit
import ImageIO
import Testing
@testable import Compositor

@MainActor
struct GIFFrameMaskCopyTests {
    private func halfMask(side: Int = 32) throws -> LayerMask {
        let context = try BrushRaster.context(width: side, height: side, mask: true)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side / 2, height: side))
        return LayerMask(asset: try LayerMask.asset(from: #require(context.makeImage())))
    }

    @Test(arguments: [true, false])
    func batchReplacesMasksInOneEditWithoutChangingSelection(enabled: Bool) async throws {
        let url = try GIFFrameDeletionTests().fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        var mask = try halfMask()
        mask.isEnabled = enabled
        mask.isLinked = false
        mask.placement = LayerTransform(origin: CGPoint(x: 2, y: 3), size: CGSize(width: 32, height: 24))
        session.document?.layers[0].gifFrameMasks[0] = mask
        let oldMask = try #require(LayerMask.solid(revealing: false))
        session.document?.layers[0].gifFrameMasks[1] = oldMask
        await session.selectGIFTimelineFrame(2)
        let selection = DocumentSelection(path: CGPath(rect: CGRect(x: 1, y: 1, width: 8, height: 8), transform: nil), antialiased: false)
        session.document?.selection = selection
        let before = session.document
        let count = session.history.undoCount
        session.toggleGIFPlayback(for: id)
        let request = try #require(session.prepareGIFFrameMaskCopy(at: 0, for: id))
        #expect(!session.gifTimelineIsPlaying && session.gifTimelineSelectedFrameIndex == 2)
        #expect(session.document == before && session.history.undoCount == count)
        var refreshed = false
        session.refreshCanvasPreview = { refreshed = true }
        let revision = session.brushRevision
        #expect(session.copyGIFFrameMask(request, to: [0, 1, 2]))
        #expect(session.activeLayer?.gifFrameMasks == [0: mask, 1: mask, 2: mask])
        #expect(session.gifTimelineSelectedFrameIndex == 2 && !session.isGIFFrameMaskSelected)
        #expect(session.activeLayerID == id && session.selectedLayerIDs == [id])
        #expect(session.document?.selection == selection)
        #expect(session.activeLayer?.gifAnimation == before?.layers[0].gifAnimation)
        #expect(session.activeLayer?.mask == before?.layers[0].mask)
        #expect(session.brushRevision > revision && refreshed)
        #expect(session.history.undoCount == count + 1 && session.history.undoName == "Copy Frame Mask")
        let after = session.document
        session.undo()
        #expect(session.document == before)
        session.redo()
        #expect(session.document == after)
    }

    @Test func editingAndDisablingACopyDoesNotChangeOtherMasks() async throws {
        let url = try GIFFrameDeletionTests().fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        await session.addGIFFrameMask(at: 0, for: id)
        let original = try #require(session.activeLayer?.gifFrameMasks[0])
        #expect(session.copyGIFFrameMask(try #require(session.prepareGIFFrameMaskCopy(at: 0, for: id)), to: [1, 2]))
        await session.selectGIFTimelineFrame(1)
        #expect(session.isGIFFrameMaskSelected)
        session.document?.selection = DocumentSelection(path: CGPath(rect: CGRect(x: 0, y: 0, width: 16, height: 24), transform: nil), antialiased: false)
        await session.clearSelectedPixels()
        let edited = try #require(session.activeLayer?.gifFrameMasks[1])
        #expect(edited.asset.image !== original.asset.image)
        #expect(session.activeLayer?.gifFrameMasks[0] == original && session.activeLayer?.gifFrameMasks[2] == original)
        session.toggleGIFFrameMaskEnabled(at: 2, for: id)
        #expect(session.activeLayer?.gifFrameMasks[2]?.isEnabled == false)
        #expect(session.activeLayer?.gifFrameMasks[0]?.isEnabled == true && session.activeLayer?.gifFrameMasks[1]?.isEnabled == true)
        session.undo()
        session.undo()
        #expect(session.activeLayer?.gifFrameMasks[1] == original && session.activeLayer?.gifFrameMasks[2] == original)
        session.redo()
        session.redo()
        #expect(session.activeLayer?.gifFrameMasks[1] == edited && session.activeLayer?.gifFrameMasks[2]?.isEnabled == false)
    }

    @Test func copiesFollowStableFrameIdentitiesAndSurviveReopenAndExport() async throws {
        let url = try GIFFrameDeletionTests().fixture()
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("GIFMaskCopy-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: package) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        await session.duplicateGIFFrame(at: 1, for: id)
        let mask = try halfMask()
        session.document?.layers[0].gifFrameMasks[0] = mask
        let request = try #require(session.prepareGIFFrameMaskCopy(at: 0, for: id))
        session.moveGIFFrame(at: 4, to: 0, for: id)
        #expect(session.copyGIFFrameMask(request, to: [2, 4]))
        await session.deleteGIFFrame(at: 0, for: id)
        #expect(session.gifTimelineFrames.map(\.index) == [4, 1, 2, 3])
        #expect(session.activeLayer?.gifFrameMasks == [2: mask, 4: mask])
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: package)
        try FileManager.default.removeItem(at: url)
        let reopened = EditorSession()
        reopened.installProject(try await ProjectStore.shared.load(from: package), from: package)
        #expect(reopened.activeLayer?.gifFrameMasks.keys.sorted() == [2, 4])
        for index in [2, 4] {
            let saved = try #require(reopened.activeLayer?.gifFrameMasks[index])
            #expect(saved.isEnabled && saved.isLinked && saved.placement == nil)
            #expect(try ImageImportTests().rgba(saved.asset.image, x: 8, y: 12)[0] == 255)
            #expect(try ImageImportTests().rgba(saved.asset.image, x: 24, y: 12)[0] == 0)
        }
        let snapshot = try #require(reopened.projectSnapshot())
        let result = try await GIFExporter.shared.encode(snapshot, width: 32, height: 24, options: GIFExportOptions(layerID: id))
        let source = try #require(CGImageSourceCreateWithData(result.data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 4 && result.durations == [0.16, 0.16, 0.08, 0.24])
        for position in [0, 2] {
            let image = try #require(CGImageSourceCreateImageAtIndex(source, position, nil))
            #expect(try ImageImportTests().rgba(image, x: 8, y: 12)[3] == 255)
            #expect(try ImageImportTests().rgba(image, x: 24, y: 12)[3] == 0)
        }
    }

    @Test func staleOrInvalidRequestsCannotPartiallyApply() async throws {
        let url = try GIFFrameDeletionTests().fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        #expect(session.prepareGIFFrameMaskCopy(at: 0, for: id) == nil)
        await session.addGIFFrameMask(at: 0, for: id)
        let request = try #require(session.prepareGIFFrameMaskCopy(at: 0, for: id))
        #expect(!session.copyGIFFrameMask(request, to: []))
        #expect(!session.copyGIFFrameMask(request, to: [0]))
        await session.deleteGIFFrame(at: 1, for: id)
        let before = session.document, count = session.history.undoCount
        #expect(!session.copyGIFFrameMask(request, to: [1, 2]))
        #expect(session.document == before && session.history.undoCount == count)
        session.toggleGIFFrameMaskEnabled(at: 0, for: id)
        let changed = session.document, changedCount = session.history.undoCount
        #expect(!session.copyGIFFrameMask(request, to: [2]))
        #expect(session.document == changed && session.history.undoCount == changedCount)
        let fresh = try #require(session.prepareGIFFrameMaskCopy(at: 0, for: id))
        session.showsImporter = true
        #expect(!session.copyGIFFrameMask(fresh, to: [2]))
        session.showsImporter = false
        #expect(session.copyGIFFrameMask(fresh, to: [2]))
        let copied = session.document, copiedCount = session.history.undoCount
        #expect(session.copyGIFFrameMask(fresh, to: [2]))
        #expect(session.document == copied && session.history.undoCount == copiedCount)
        session.addBlankLayer()
        let inactive = session.document, inactiveCount = session.history.undoCount
        #expect(!session.copyGIFFrameMask(fresh, to: [3]))
        #expect(session.document == inactive && session.history.undoCount == inactiveCount)
    }

    @Test func budgetFailureIsAtomicAndReplacementReusesTheOldBudget() async throws {
        let url = try GIFFrameDeletionTests().fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        let side = 4096, area = side * side
        let mask = try halfMask(side: side)
        var replacement = mask
        replacement.isEnabled = false
        session.document?.layers[0].gifFrameMasks = [0: mask, 1: replacement]
        // Sharing an immutable grid keeps the fixture small while accounting for each saved mask.
        for _ in 0..<(DocumentLimits.documentPixelBudget / area - 2) {
            var layer = ImageLayer(name: "Budget", blankSize: CGSize(width: 32, height: 24))
            layer.mask = mask
            session.document?.layers.append(layer)
        }
        session.history.reset()
        let request = try #require(session.prepareGIFFrameMaskCopy(at: 0, for: id))
        let before = session.document
        #expect(!session.copyGIFFrameMask(request, to: [1, 2]))
        #expect(session.document == before && !session.canUndo)
        #expect(session.brushError == ProjectError.tooLarge.localizedDescription)
        session.brushError = nil
        #expect(session.copyGIFFrameMask(request, to: [1]))
        #expect(session.activeLayer?.gifFrameMasks[1] == mask && session.activeLayer?.gifFrameMasks[2] == nil)
        #expect(session.brushError == nil && session.history.undoCount == 1)
    }
}
