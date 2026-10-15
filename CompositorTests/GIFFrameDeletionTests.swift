import AppKit
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import Compositor

@MainActor
struct GIFFrameDeletionTests {
    func fixture(delays: [TimeInterval] = [0.04, 0.16, 0.08, 0.24]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).gif")
        let colors: [CGColor] = [.init(red: 1, green: 0, blue: 0, alpha: 1),
            .init(red: 0, green: 0, blue: 1, alpha: 1), .init(red: 0, green: 1, blue: 0, alpha: 1),
            .init(red: 1, green: 1, blue: 0, alpha: 1)]
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, colors.count, nil))
        for (index, color) in colors.enumerated() {
            let context = try BrushRaster.context(width: 32, height: 24, mask: false)
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
            let image = try #require(context.makeImage())
            CGImageDestinationAddImage(destination, image,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delays[index]]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test(arguments: [0, 1, 3])
    func deletingFirstMiddleOrLastFrameKeepsSurvivingTimingAndAssets(index: Int) async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        let source = try #require(session.activeLayer?.gifAnimation?.source)
        let otherIndex = (index + 1) % 4
        await session.addGIFFrameMask(at: index, for: id)
        await session.addGIFFrameMask(at: otherIndex, for: id)
        session.toggleGIFFrameMaskEnabled(at: otherIndex, for: id)
        session.isMaskSelected = false
        let edited = try await ImageImporter.shared.decodeGIFFrame(try #require(session.activeLayer?.gifAnimation), index: index, name: "Edited")
        let other = try await ImageImporter.shared.decodeGIFFrame(try #require(session.activeLayer?.gifAnimation), index: otherIndex, name: "Other")
        session.document?.layers[0].gifAnimation?.framePixels[index] = edited
        session.document?.layers[0].gifAnimation?.framePixels[otherIndex] = other
        await session.selectGIFTimelineFrame(index)
        let before = session.document
        let count = session.history.undoCount
        session.setGIFPlaybackSpeed(GIFPlaybackSpeed(position: 1), for: id)
        session.toggleGIFPlayback(for: id)
        await session.deleteGIFFrame(at: index, for: id)

        let expected = source.frames.filter { $0.index != index }
        #expect(session.gifTimelineFrames.map(\.index) == expected.map(\.index))
        #expect(session.gifTimelineFrames.map(\.duration) == expected.map(\.duration))
        let total = session.gifTimelineFrames.reduce(0) { $0 + $1.duration }
        #expect(abs(total - (source.frames.reduce(0) { $0 + $1.duration } - source.frames[index].duration)) < 0.000001)
        #expect(session.activeLayer?.gifAnimation?.source === source)
        #expect(session.activeLayerID == id && session.selectedLayerIDs == [id])
        #expect(!session.gifTimelineIsPlaying && session.gifTimelinePlaybackSpeed.multiplier == 2)
        #expect(session.gifTimelineSelectedFrameIndex == expected[min(index, expected.count - 1)].index)
        #expect(session.activeLayer?.gifFrameMasks[index] == nil)
        #expect(session.activeLayer?.gifAnimation?.framePixels[index] == nil)
        #expect(session.activeLayer?.gifFrameMasks[otherIndex]?.isEnabled == false)
        #expect(session.activeLayer?.gifAnimation?.framePixels[otherIndex]?.image === other.image)
        #expect(session.history.undoCount == count + 1 && session.history.undoName == "Delete GIF Frame")
        let after = session.document
        session.undo()
        #expect(session.document == before)
        #expect(session.gifTimelineFrames.count == 4)
        session.redo()
        #expect(session.document == after)
        #expect(session.gifTimelineFrames.map(\.index) == expected.map(\.index))
        let selected = session.gifTimelineSelectedFrameIndex
        await session.selectGIFTimelineFrame(index)
        #expect(session.gifTimelineSelectedFrameIndex == selected && session.importError == nil)
    }

    @Test func deletingAnUnselectedFrameKeepsTheCanvasAndTheLastFrameCannotBeDeleted() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        await session.selectGIFTimelineFrame(3)
        let displayed = try #require(session.activeLayer.flatMap { session.displayedAsset(for: $0)?.image })
        for index in [0, 1, 2] { await session.deleteGIFFrame(at: index, for: id) }
        #expect(session.gifTimelineFrames.map(\.index) == [3])
        #expect(session.gifTimelineSelectedFrameIndex == 3)
        #expect(session.activeLayer.flatMap { session.displayedAsset(for: $0)?.image } === displayed)
        session.toggleGIFPlayback(for: id)
        #expect(!session.gifTimelineIsPlaying)
        let before = session.document
        let count = session.history.undoCount
        await session.deleteGIFFrame(at: 3, for: id)
        await session.deleteGIFFrame(at: 0, for: id)
        #expect(session.document == before && session.history.undoCount == count)
    }

    @Test func maskMenuActionsTargetTheClickedFrameAndUndo() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        await session.addGIFFrameMask(at: 2, for: id)
        #expect(session.gifTimelineSelectedFrameIndex == 2 && session.isGIFFrameMaskSelected)
        let mask = try #require(session.activeLayer?.gifFrameMasks[2])
        await session.selectGIFTimelineFrame(0)
        session.toggleGIFFrameMaskEnabled(at: 2, for: id)
        #expect(session.activeLayer?.gifFrameMasks[2]?.isEnabled == false)
        #expect(session.gifTimelineSelectedFrameIndex == 0 && !session.isMaskSelected)
        session.toggleGIFFrameMaskEnabled(at: 2, for: id)
        #expect(session.activeLayer?.gifFrameMasks[2] == mask)
        session.deleteGIFFrameMask(at: 2, for: id)
        #expect(session.activeLayer?.gifFrameMasks[2] == nil)
        #expect(session.gifTimelineSelectedFrameIndex == 0)
        session.undo()
        #expect(session.activeLayer?.gifFrameMasks[2] == mask)
        session.redo()
        #expect(session.activeLayer?.gifFrameMasks[2] == nil)
    }

    @Test func deletionRoundTripsWithoutTheSourceAndRejectsInvalidRecords() async throws {
        let url = try fixture()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CompositorGIFDeletion-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        await session.addGIFFrameMask(at: 3, for: id)
        await session.deleteGIFFrame(at: 1, for: id)
        let snapshot = try #require(session.projectSnapshot())
        #expect(snapshot.manifest.version == ProjectManifest.current)
        #expect(snapshot.manifest.layers[0].gif?.deletedFrameIndices == [1])
        let package = folder.appendingPathComponent("Edited.comp")
        try await ProjectStore.shared.save(snapshot, to: package)
        try FileManager.default.removeItem(at: url)
        let reopened = EditorSession()
        reopened.installProject(try await ProjectStore.shared.load(from: package), from: package)
        #expect(reopened.gifTimelineFrames.map(\.index) == [0, 2, 3])
        #expect(reopened.gifTimelineFrames.map(\.duration) == session.gifTimelineFrames.map(\.duration))
        #expect(reopened.activeLayer?.gifFrameMasks[3] != nil)
        await reopened.selectGIFTimelineFrame(2)
        let displayed = try #require(reopened.activeLayer.flatMap { reopened.displayedAsset(for: $0)?.image })
        #expect(try ImageImportTests().rgba(displayed, x: 8, y: 12)[1] > 240)

        for indices in [[-1], [4], [1, 1], [0, 1, 2, 3], [3]] {
            var manifest = snapshot.manifest
            manifest.layers[0].gif?.deletedFrameIndices = indices
            var animations = snapshot.animations
            animations[id]?.deletedFrameIndices = Set(indices)
            let invalid = ProjectSnapshot(manifest: manifest, images: snapshot.images,
                masks: snapshot.masks, animations: animations, frameMasks: snapshot.frameMasks)
            await #expect(throws: (any Error).self) { try await ProjectStore.shared.save(invalid, to: package) }
        }
        var oldManifest = snapshot.manifest
        oldManifest.version = 27
        oldManifest.layers[0].gif?.timing = nil
        var legacyAnimations = snapshot.animations
        legacyAnimations[id]?.timing = GIFFrameTiming()
        let oldVersion = ProjectSnapshot(manifest: oldManifest, images: snapshot.images,
            masks: snapshot.masks, animations: legacyAnimations, frameMasks: snapshot.frameMasks)
        await #expect(throws: (any Error).self) { try await ProjectStore.shared.save(oldVersion, to: package) }
        #expect(try await ProjectStore.shared.load(from: package).manifest.layers[0].gif?.deletedFrameIndices == [1])

        oldManifest.layers[0].gif?.deletedFrameIndices = []
        legacyAnimations[id]?.deletedFrameIndices = []
        let legacy = ProjectSnapshot(manifest: oldManifest, images: snapshot.images,
            masks: snapshot.masks, animations: legacyAnimations, frameMasks: snapshot.frameMasks)
        let legacyPackage = folder.appendingPathComponent("Legacy.comp")
        try await ProjectStore.shared.save(legacy, to: legacyPackage)
        let metadataFile = legacyPackage.appendingPathComponent("manifest.json")
        var metadata = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadataFile)) as? [String: Any])
        var layers = try #require(metadata["layers"] as? [[String: Any]])
        var gif = try #require(layers[0]["gif"] as? [String: Any])
        gif.removeValue(forKey: "deletedFrameIndices")
        layers[0]["gif"] = gif
        metadata["layers"] = layers
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataFile, options: .atomic)
        let loadedLegacy = try await ProjectStore.shared.load(from: legacyPackage)
        #expect(loadedLegacy.animations[id]?.frames.count == 4)

        metadata["version"] = ProjectManifest.current
        for indices in [[4], [1, 1], [3]] {
            gif["deletedFrameIndices"] = indices
            layers[0]["gif"] = gif
            metadata["layers"] = layers
            try JSONSerialization.data(withJSONObject: metadata).write(to: metadataFile, options: .atomic)
            await #expect(throws: (any Error).self) { try await ProjectStore.shared.load(from: legacyPackage) }
        }
    }
}
