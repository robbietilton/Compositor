import AppKit
import SwiftUI
import Testing
@testable import Compositor

@MainActor
struct GIFPixelEditingTests {
    private func displayed(_ session: EditorSession) throws -> CGImage {
        try #require(session.activeLayer.flatMap { session.displayedAsset(for: $0)?.image })
    }

    private func pixel(_ image: CGImage, x: Int = 8, y: Int = 12) throws -> [UInt8] {
        try ImageImportTests().rgba(image, x: x, y: y)
    }

    private func paint(_ session: EditorSession, at point: CGPoint = CGPoint(x: 8, y: 12)) throws {
        session.selectTool(.brush)
        session.brushSettings = BrushSettings(diameter: 6, hardness: 1, red: 0, green: 0, blue: 0)
        session.beginBrush(at: point)
        #expect(session.brushStroke != nil)
        #expect(session.finishBrushImmediately())
        #expect(session.brushError == nil)
    }

    @Test func paintIsVisibleImmediatelyInCanvasThumbnailPlaybackAndFollowingStroke() async throws {
        let url = try ImageImportTests().animatedGIFFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        let baseline = try #require(session.activeLayer?.asset?.image)
        await session.selectGIFTimelineFrame(1)
        let navigationDocument = session.document
        let count = session.history.undoCount
        session.toggleGIFPlayback(for: id)
        try paint(session)
        #expect(!session.gifTimelineIsPlaying)
        #expect(session.history.undoCount == count + 1)
        #expect(session.activeLayer?.asset?.image === baseline)
        let painted = try displayed(session)
        #expect(try pixel(painted) == [0, 0, 0, 255])
        #expect(try pixel(painted, x: 24)[2] > 240)
        #expect(try pixel(session.gifTimelineFrames[1].thumbnail) == [0, 0, 0, 255])
        let rendered = try await ImageExporter.shared.render(try #require(session.projectSnapshot()))
        #expect(try pixel(rendered.image) == [0, 0, 0, 255])
        #expect(session.displayedLayer(for: try #require(session.activeLayer)).asset?.image === painted)
        session.toggleGIFPlayback(for: id)
        await session.selectGIFTimelineFrame(0)
        #expect(try pixel(try displayed(session))[0] > 240)
        await session.selectGIFTimelineFrame(1)
        #expect(try displayed(session) === painted)
        #expect(session.gifTimelineIsPlaying)
        session.stopGIFPlayback(for: id)
        session.undo()
        #expect(session.document == navigationDocument)
        #expect(try pixel(try displayed(session))[2] > 240)
        session.redo()
        #expect(try displayed(session) === painted)
        session.beginBrush(at: CGPoint(x: 24, y: 12))
        #expect(session.brushStroke?.layer.asset?.image === painted)
        #expect(session.finishBrushImmediately())
        #expect(try pixel(try displayed(session)) == [0, 0, 0, 255])
        #expect(try pixel(try displayed(session), x: 24) == [0, 0, 0, 255])
    }

    @Test(arguments: [NavigationTool.spotHealing, .cloneStamp, .blur])
    func rasterToolsReadTheEditedSelectedFrame(tool: NavigationTool) async throws {
        let url = try ImageImportTests().animatedGIFFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        await session.selectGIFTimelineFrame(1)
        try paint(session)
        let painted = try displayed(session)
        session.selectTool(tool)
        session.brushSettings = BrushSettings(diameter: 6, hardness: 1, red: 0, green: 0, blue: 0)
        session.blurMode = .blur
        if tool == .cloneStamp { session.setCloneSource(CGPoint(x: 8, y: 12)) }
        session.beginBrush(at: CGPoint(x: 24, y: 12))
        let stroke = try #require(session.brushStroke)
        #expect(stroke.layer.asset?.image === painted)
        #expect(stroke.layer.gifAnimation?.selectedFrameIndex == 1)
        #expect(session.finishBrushImmediately())
        #expect(session.brushError == nil)
        #expect(try pixel(try displayed(session)) == [0, 0, 0, 255])
        if tool == .cloneStamp { #expect(try pixel(try displayed(session), x: 24) == [0, 0, 0, 255]) }
        await session.selectGIFTimelineFrame(0)
        #expect(try pixel(try displayed(session))[0] > 240)
    }

    @Test(arguments: [BlurToolMode.smudge, .liquify])
    func warpToolsReadAndCommitTheSelectedFrame(mode: BlurToolMode) async throws {
        let url = try ImageImportTests().animatedGIFFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        await session.selectGIFTimelineFrame(1)
        try paint(session)
        let painted = try displayed(session)
        session.selectTool(.blur)
        session.blurMode = mode
        session.beginBrush(at: CGPoint(x: 8, y: 12))
        #expect(session.warpStroke?.layer.asset?.image === painted)
        session.continueBrush(at: CGPoint(x: 13, y: 12))
        #expect(session.finishBrushImmediately())
        #expect(session.brushError == nil)
        let edited = try displayed(session)
        #expect(edited !== painted)
        #expect(try pixel(edited, x: 13)[2] < 240)
        await session.selectGIFTimelineFrame(0)
        #expect(try pixel(try displayed(session))[0] > 240)
        await session.selectGIFTimelineFrame(1)
        #expect(try displayed(session) === edited)
    }

    @Test func clearingAndInvertingStayInTheFrameGridAndPreserveMasks() async throws {
        let url = try ImageImportTests().animatedGIFFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        await session.selectGIFTimelineFrame(1)
        session.toggleGIFFrameMaskTarget()
        session.toggleGIFFrameMaskTarget()
        let mask = try #require(session.activeLayer?.gifFrameMasks[1]?.asset.image)
        let transform = try #require(session.activeLayer?.transform)
        session.document?.selection = DocumentSelection(path: CGPath(rect: CGRect(x: 0, y: 0, width: 16, height: 24), transform: nil), antialiased: false)
        await session.clearSelectedPixels()
        #expect(session.brushError == nil)
        var image = try displayed(session)
        #expect(image.width == 32 && image.height == 24)
        #expect(try pixel(image)[3] == 0)
        #expect(try pixel(image, x: 24)[2] > 240)
        #expect(session.activeLayer?.transform == transform)
        #expect(session.activeLayer?.gifFrameMasks[1]?.asset.image === mask)
        let beforeInvert = try pixel(image, x: 24)
        session.document?.selection = nil
        #expect(session.canInvert)
        await session.invertPixels()
        #expect(session.brushError == nil)
        image = try displayed(session)
        #expect(try pixel(image)[3] == 0)
        let inverted = try pixel(image, x: 24)
        #expect(inverted == beforeInvert.prefix(3).map { 255 - $0 } + [255])
        session.undo()
        #expect(try pixel(try displayed(session), x: 24)[2] > 240)
        session.undo()
        #expect(try pixel(try displayed(session))[3] == 255)
        await session.selectGIFTimelineFrame(0)
        #expect(try pixel(try displayed(session))[0] > 240)
    }

    @Test(arguments: [FilterKind.gaussianBlur, .cameraRaw])
    func adjustmentsUseSelectedFrameAndCommitOnlyToIt(filter: FilterKind) async throws {
        let url = try ImageImportTests().animatedGIFFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let sourcePixels = try pixel(try displayed(session))
        await session.selectGIFTimelineFrame(1)
        session.beginLevels()
        #expect(session.levels?.original.image === (try displayed(session)))
        var levels = LevelsSettings()
        levels.current = LevelRange(outputBlack: 255, outputWhite: 0)
        session.updateLevels(levels, preview: false)
        await session.commitLevels()
        #expect(try pixel(try displayed(session))[0] > 240)
        #expect(try pixel(try displayed(session))[2] < 15)
        session.beginHueSaturation()
        #expect(session.hueSaturation?.original.image === (try displayed(session)))
        session.cancelHueSaturation()
        session.beginFilter(filter)
        #expect(session.filterEdit?.original.image === (try displayed(session)))
        if filter == .cameraRaw {
            let edit = try #require(session.filterEdit)
            #expect(edit.previewSource === edit.original.image && edit.previewScale == 1)
            var settings = edit.settings
            settings.cameraRaw.exposure = -1
            session.updateFilter(settings, preview: true)
            while let task = edit.previewTask { await task.value }
            #expect(edit.preparedPreview?.width == 32 && edit.preparedPreview?.height == 24)
            #expect(session.activeLayer?.gifAnimation?.framePixels.count == 1)
        }
        await session.commitFilter()
        #expect(session.brushError == nil)
        #expect(session.activeLayer?.gifAnimation?.framePixels.count == 1)
        #expect(session.canEditLayers)
        await session.selectGIFTimelineFrame(0)
        #expect(session.gifTimelineSelectedFrameIndex == 0)
        let original = try pixel(try displayed(session))
        #expect(original == sourcePixels)
    }

    @Test func editedFramesRoundTripWithIndependentMasksAndImmutableSnapshots() async throws {
        let url = try ImageImportTests().animatedGIFFixture()
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("GIFPixels-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: project) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        try paint(session)
        let captured = try #require(session.projectSnapshot())
        await session.selectGIFTimelineFrame(1)
        try paint(session, at: CGPoint(x: 24, y: 12))
        session.toggleGIFFrameMaskTarget()
        session.toggleGIFFrameMaskTarget()
        #expect(captured.animations[id]?.framePixels.count == 1)
        let snapshot = try #require(session.projectSnapshot())
        #expect(snapshot.manifest.version == ProjectManifest.current)
        #expect(snapshot.manifest.layers[0].gif?.framePixels.map(\.index) == [0, 1])
        try FileManager.default.removeItem(at: url)
        try await ProjectStore.shared.save(snapshot, to: project)
        let loaded = try await ProjectStore.shared.load(from: project)
        let reopened = EditorSession()
        reopened.installProject(loaded, from: project)
        #expect(!reopened.isModified && !reopened.canUndo && !reopened.gifTimelineIsPlaying)
        #expect(reopened.activeLayer?.gifFrameMasks[1] != nil && !reopened.isMaskSelected)
        #expect(try pixel(try displayed(reopened), x: 24) == [0, 0, 0, 255])
        #expect(try pixel(try displayed(reopened))[2] > 240)
        await reopened.selectGIFTimelineFrame(0)
        #expect(try pixel(try displayed(reopened)) == [0, 0, 0, 255])
        #expect(try pixel(try displayed(reopened), x: 24)[0] > 240)
        let active = try #require(reopened.activeLayer)
        let copied = try #require(try reopened.renderSelectedPixels(from: active, mask: false))
        #expect(try pixel(copied.image) == [0, 0, 0, 255])
        reopened.duplicateActiveLayer()
        #expect(reopened.activeLayer?.gifAnimation?.framePixels.count == 2)
        let resized = try await ImageResizer.shared.resize(try #require(reopened.projectSnapshot()),
            to: ImageSizeOptions(width: 64, height: 48, resolution: 72, sampling: .nearest))
        let resizedID = try #require(reopened.activeLayerID)
        let pixels = try #require(resized.animations[resizedID]?.framePixels[0]?.image)
        #expect(pixels.width == 64 && pixels.height == 48)
        #expect(try pixel(pixels, x: 16, y: 24) == [0, 0, 0, 255])
        try await ProjectStore.shared.save(resized, to: project)
        #expect(try await ProjectStore.shared.load(from: project).animations[resizedID]?.framePixels.count == 2)
    }

    @Test func GIFWithoutOptionalPixelRecordsStillReopens() async throws {
        let url = try ImageImportTests().animatedGIFFixture()
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("GIFDefaults-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: project) }
        let session = EditorSession()
        await session.importImages([url])
        let snapshot = try #require(session.projectSnapshot())
        try await ProjectStore.shared.save(snapshot, to: project)
        let file = project.appendingPathComponent("manifest.json")
        var metadata = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var layers = try #require(metadata["layers"] as? [[String: Any]])
        var gif = try #require(layers[0]["gif"] as? [String: Any])
        gif.removeValue(forKey: "framePixels")
        layers[0]["gif"] = gif
        metadata["layers"] = layers
        try JSONSerialization.data(withJSONObject: metadata).write(to: file)
        let loaded = try await ProjectStore.shared.load(from: project)
        #expect(loaded.manifest.version == ProjectManifest.current)
        #expect(loaded.animations.values.first?.framePixels.isEmpty == true)
        let reopened = EditorSession()
        reopened.installProject(loaded, from: project)
        await reopened.selectGIFTimelineFrame(1)
        #expect(reopened.gifTimelineSelectedFrameIndex == 1)
        #expect(try pixel(try displayed(reopened))[2] > 240)
    }

    @Test func historyAccountsForReplacedFramePixels() async throws {
        let url = try ImageImportTests().animatedGIFFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        await session.selectGIFTimelineFrame(1)
        try paint(session)
        let first = try displayed(session)
        try paint(session, at: CGPoint(x: 24, y: 12))
        #expect(session.history.retainedBytes(current: session.document) >= first.bytesPerRow * first.height)
        session.undo()
        #expect(try displayed(session) === first)
        session.redo()
        #expect(try pixel(try displayed(session), x: 24) == [0, 0, 0, 255])
    }

    @Test func paintingAndClearingAtTheFrameEdgeKeepTheOtherFramesAndPlacement() async throws {
        let fixture = try ImageImportTests().asymmetricGIFFixture()
        defer { for url in [fixture.gif] + fixture.pngs { try? FileManager.default.removeItem(at: url) } }
        let session = EditorSession()
        await session.importImages([fixture.gif])
        let source = try displayed(session)
        await session.selectGIFTimelineFrame(1)
        let transform = try #require(session.activeLayer?.transform)
        try paint(session, at: CGPoint(x: 8, y: 6))
        let brushPixel = try pixel(try displayed(session), x: 8, y: 6)
        #expect(brushPixel == [0, 0, 0, 255])
        session.document?.selection = DocumentSelection(path: CGPath(rect: CGRect(x: 0, y: 0, width: 32, height: 12), transform: nil), antialiased: false)
        await session.clearSelectedPixels()
        #expect(session.brushError == nil)
        let cleared = try displayed(session)
        let clearTop = try pixel(cleared, x: 8, y: 6)
        let clearBottom = try pixel(cleared, x: 8, y: 18)
        #expect(clearTop[3] == 0)
        #expect(clearBottom[3] == 255)
        #expect(cleared.width == 32 && cleared.height == 24)
        #expect(session.activeLayer?.transform == transform)
        await session.selectGIFTimelineFrame(0)
        #expect(try pixel(try displayed(session), x: 8, y: 6) == pixel(source, x: 8, y: 6))
        await session.selectGIFTimelineFrame(1)
        #expect(try displayed(session) === cleared)
        session.undo()
        #expect(try pixel(try displayed(session), x: 8, y: 6) == [0, 0, 0, 255])
    }

    @Test func invalidPixelRecordsAndMissingAssetsCannotReplaceAProject() async throws {
        let url = try ImageImportTests().animatedGIFFixture()
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("GIFPixelValidation-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: project) }
        let session = EditorSession()
        await session.importImages([url])
        try paint(session)
        let snapshot = try #require(session.projectSnapshot())
        let id = try #require(session.activeLayerID)
        try await ProjectStore.shared.save(snapshot, to: project)
        let manifestFile = project.appendingPathComponent("manifest.json")
        let original = try Data(contentsOf: manifestFile)
        for records in [
            [ProjectGIFPixelsRecord(index: -1, imageFile: "\(id).frame--1.png")],
            [ProjectGIFPixelsRecord(index: 2, imageFile: "\(id).frame-2.png")],
            [ProjectGIFPixelsRecord(index: 0, imageFile: "../outside.png")],
            Array(repeating: ProjectGIFPixelsRecord(index: 0, imageFile: "\(id).frame-0.png"), count: 2)
        ] {
            var manifest = snapshot.manifest
            manifest.layers[0].gif?.framePixels = records
            let invalid = ProjectSnapshot(manifest: manifest, images: snapshot.images, masks: snapshot.masks,
                animations: snapshot.animations, frameMasks: snapshot.frameMasks)
            await #expect(throws: ProjectError.self) { try await ProjectStore.shared.save(invalid, to: project) }
            #expect(try Data(contentsOf: manifestFile) == original)
        }
        var oldManifest = snapshot.manifest
        oldManifest.version = 12
        let old = ProjectSnapshot(manifest: oldManifest, images: snapshot.images, masks: snapshot.masks,
            animations: snapshot.animations, frameMasks: snapshot.frameMasks)
        await #expect(throws: ProjectError.self) { try await ProjectStore.shared.save(old, to: project) }
        #expect(try Data(contentsOf: manifestFile) == original)
        var mismatched = snapshot
        mismatched.animations[id]?.framePixels[0] = ImportedImage(image: try #require(session.gifTimelineFrames[0].thumbnail.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1))), thumbnail: session.gifTimelineFrames[0].thumbnail, name: "Wrong size")
        await #expect(throws: ProjectError.self) { try await ProjectStore.shared.save(mismatched, to: project) }
        #expect(try Data(contentsOf: manifestFile) == original)
        try FileManager.default.removeItem(at: project.appendingPathComponent("images/\(id).frame-0.png"))
        await #expect(throws: (any Error).self) { try await ProjectStore.shared.load(from: project) }
    }
}
