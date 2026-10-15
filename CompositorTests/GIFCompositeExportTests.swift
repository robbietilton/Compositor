import AppKit
import ImageIO
import Testing
@testable import Compositor

@MainActor
struct GIFCompositeExportTests {
    private func snapshot(delays: [[TimeInterval]]) throws -> ProjectSnapshot {
        let mask = try #require(LayerMask.solid(revealing: true))
        var layers: [ProjectLayerRecord] = [], animations: [UUID: GIFAnimation] = [:]
        for values in delays {
            let id = UUID()
            let frames = values.enumerated().map {
                GIFTimelineFrame(index: $0.offset, thumbnail: mask.asset.image, duration: $0.element)
            }
            layers.append(ProjectLayerRecord(id: id, name: "Track", isVisible: true,
                transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)), imageFile: "frame.png"))
            animations[id] = GIFAnimation(source: GIFSource(data: Data([1]), frames: frames, width: 1, height: 1))
        }
        return ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: 1, height: 1,
            activeLayerID: layers.last?.id, layers: layers), images: [:], animations: animations)
    }

    @Test func sharedClockUsesSavedTimingAndLongestDuration() throws {
        var snapshot = try snapshot(delays: [[0.1, 0.1, 0.1, 0.1], [0.1, 0.1, 0.1, 0.1]])
        let short = snapshot.manifest.layers[1].id
        snapshot.animations[short]?.timing = GIFFrameTiming(mode: .uniform, uniformDelay: 0.06)
        let schedule = try GIFExportSchedule(snapshot, options: GIFExportOptions())
        #expect(schedule.frames.map(\.start) == [0, 6, 10, 12, 18, 20, 30])
        #expect(schedule.frames.map(\.ticks) == [6, 4, 2, 6, 2, 10, 10])
        #expect(schedule.frames.reduce(0) { $0 + $1.ticks } == 40)
        #expect(!schedule.usesMinimumDelay)
        let fast = try GIFExportSchedule(snapshot, options: GIFExportOptions(timing: GIFExportTiming(speedMultiplier: 2)))
        #expect(fast.frames.reduce(0) { $0 + $1.ticks } == 20)
        #expect(fast.frames.allSatisfy { $0.ticks >= 2 })
    }

    @Test func closelySpacedChangesKeepTheTotalDurationAndLegalDelays() throws {
        let snapshot = try snapshot(delays: [[0.02, 0.02, 0.02], [0.03, 0.03]])
        let schedule = try GIFExportSchedule(snapshot, options: GIFExportOptions())
        #expect(schedule.frames.map(\.start) == [0, 2, 4])
        #expect(schedule.frames.map(\.ticks) == [2, 2, 2])
        #expect(schedule.usesMinimumDelay)
        // Nearby changes still reach both final frames promptly, even before a very long hold.
        let long = try self.snapshot(delays: [[0.03, 655.35], [0.02, 655.35]])
        let held = try GIFExportSchedule(long, options: GIFExportOptions())
        #expect(held.frames.map(\.ticks) == [2, 2, 65_534])
        #expect(held.frames.map(\.sample) == [0, 2, 4])
        #expect(held.frames.reduce(0) { $0 + $1.ticks } == 65_538)
        let final = try self.snapshot(delays: [[0.02, 0.03], [0.03, 0.02]])
        let finalSchedule = try GIFExportSchedule(final, options: GIFExportOptions())
        #expect(finalSchedule.frames.map(\.ticks) == [2, 3])
        #expect(finalSchedule.frames.map(\.sample) == [0, 3])
    }

    @Test func reorderedTracksKeepTheirOwnFrameIdentitiesAndUnequalFrameCounts() throws {
        var snapshot = try snapshot(delays: [[0.1, 0.1, 0.1], [0.05, 0.15]])
        let id = snapshot.manifest.layers[1].id
        snapshot.animations[id]?.frameOrder = [GIFFrameReference(index: 1, sourceIndex: 1), GIFFrameReference(index: 0, sourceIndex: 0)]
        let schedule = try GIFExportSchedule(snapshot, options: GIFExportOptions())
        #expect(schedule.tracks[1].frames.map(\.index) == [1, 0])
        #expect(schedule.frames.map(\.start) == [0, 10, 15, 20])
        #expect(schedule.frames.map(\.ticks) == [10, 5, 5, 10])
    }

    @Test func hiddenTimelinesAreExcludedAndCombinedFrameCountIsBounded() throws {
        let original = try snapshot(delays: [[0.1, 0.1], [0.2, 0.2]])
        var manifest = original.manifest
        let folderID = UUID()
        manifest.layers[1].parentID = folderID
        manifest.layers.append(ProjectLayerRecord(id: folderID, name: "Hidden folder", isVisible: false,
            transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)), imageFile: nil, isGroup: true))
        let snapshot = ProjectSnapshot(manifest: manifest, images: original.images, animations: original.animations)
        let visible = try GIFExportSchedule(snapshot, options: GIFExportOptions())
        #expect(visible.tracks.count == 1 && visible.frames.map(\.ticks) == [10, 10])
        manifest.layers[0].isVisible = false
        let hidden = ProjectSnapshot(manifest: manifest, images: original.images, animations: original.animations)
        let still = try GIFExportSchedule(hidden, options: GIFExportOptions())
        #expect(still.tracks.isEmpty && still.durations == [0.1])

        let crowded = try self.snapshot(delays: [Array(repeating: 0.03, count: 4096), Array(repeating: 0.05, count: 4096)])
        #expect(throws: GIFExportError.tooLarge) { try GIFExportSchedule(crowded, options: GIFExportOptions()) }
        let selected = try GIFExportSchedule(crowded, options: GIFExportOptions(layerID: crowded.manifest.layers[0].id))
        #expect(selected.frames.count == 4096)
    }

    @Test func invalidParticipatingTimingFailsButHiddenTimingDoesNot() throws {
        var snapshot = try snapshot(delays: [[0.1, 0.1], [0.1, 0.1]])
        let id = snapshot.manifest.layers[1].id
        snapshot.animations[id]?.timing.frameDelays[0] = .nan
        #expect(throws: GIFExportError.self) { try GIFExportSchedule(snapshot, options: GIFExportOptions()) }
        var manifest = snapshot.manifest
        manifest.layers[1].isVisible = false
        let hidden = ProjectSnapshot(manifest: manifest, images: snapshot.images, animations: snapshot.animations)
        #expect(try GIFExportSchedule(hidden, options: GIFExportOptions()).tracks.count == 1)
        #expect(throws: GIFExportError.self) {
            try GIFExportSchedule(snapshot, options: GIFExportOptions(timing: GIFExportTiming(speedMultiplier: 0)))
        }
    }

    @Test(arguments: [true, false])
    func allExportsEditedMaskedFramesAndHoldsTheShorterGIFAfterReopening(forever: Bool) async throws {
        let backgroundURL = try GIFFrameDeletionTests().fixture(delays: Array(repeating: 0.1, count: 4))
        let foregroundURL = try GIFFrameDeletionTests().fixture(delays: Array(repeating: 0.06, count: 4))
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("GIFComposite-\(UUID()).comp")
        defer {
            try? FileManager.default.removeItem(at: backgroundURL)
            try? FileManager.default.removeItem(at: foregroundURL)
            try? FileManager.default.removeItem(at: package)
        }
        let session = EditorSession()
        await session.importImages([backgroundURL, foregroundURL])
        let foreground = try #require(session.activeLayerID)
        session.document?.layers[1].transform.size = CGSize(width: 16, height: 24)
        let context = try BrushRaster.context(width: 32, height: 24, mask: false)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let white = try #require(context.makeImage())
        session.document?.layers[1].gifAnimation?.framePixels[3] = ImportedImage(image: white, thumbnail: white, name: "Edited")
        let maskContext = try BrushRaster.context(width: 32, height: 24, mask: true)
        maskContext.setFillColor(gray: 1, alpha: 1)
        maskContext.fill(CGRect(x: 0, y: 0, width: 16, height: 24))
        session.document?.layers[1].gifFrameMasks[3] = LayerMask(asset: try LayerMask.asset(from: #require(maskContext.makeImage())))
        await session.selectGIFTimelineFrame(1)
        let original = try #require(session.projectSnapshot())
        try await ProjectStore.shared.save(original, to: package)
        try FileManager.default.removeItem(at: backgroundURL)
        try FileManager.default.removeItem(at: foregroundURL)
        let reopened = try await ProjectStore.shared.load(from: package)
        let before = session.document, history = session.history.undoCount
        await #expect(throws: GIFExportError.tooLarge) {
            try await GIFExporter.shared.encode(reopened, width: 6000, height: 6000, options: GIFExportOptions())
        }
        let result = try await GIFExporter.shared.encode(reopened, width: 32, height: 24,
            options: GIFExportOptions(loopsForever: forever))
        #expect(result.durations == [0.06, 0.04, 0.02, 0.06, 0.02, 0.1, 0.1])
        let reader = try #require(CGImageSourceCreateWithData(result.data as CFData, nil))
        func pixel(_ frame: Int, _ x: Int) throws -> [UInt8] {
            try ImageImportTests().rgba(#require(CGImageSourceCreateImageAtIndex(reader, frame, nil)), x: x, y: 12)
        }
        #expect(CGImageSourceGetCount(reader) == 7)
        #expect(try GIFDecoder.source(result.data, name: "Combined").frames.map(\.duration) == result.durations)
        let background = try #require(reopened.animations[reopened.manifest.layers[0].id])
        func sourceColor(_ index: Int) throws -> [UInt8] {
            let image = try GIFDecoder.frame(background, index: index, name: "Background").image
            return try ImageImportTests().rgba(image, x: 4, y: 12)
        }
        func matches(_ actual: [UInt8], _ expected: [UInt8]) -> Bool {
            zip(actual, expected).allSatisfy { abs(Int($0) - Int($1)) <= 3 }
        }
        let first = try pixel(0, 4), second = try pixel(1, 4)
        #expect(try matches(first, sourceColor(0)))
        #expect(try matches(second, sourceColor(1)))
        let foregroundFrame = try pixel(3, 4)
        for frame in 4..<7 { #expect(try pixel(frame, 4) == [255, 255, 255, 255]) }
        let blue = try pixel(4, 12), green = try pixel(5, 12), yellow = try pixel(6, 12)
        #expect(try matches(blue, sourceColor(1)))
        #expect(try matches(green, sourceColor(2)))
        #expect(try matches(yellow, sourceColor(3)))
        #expect(try matches(foregroundFrame, sourceColor(2)))
        #expect((result.data.range(of: Data("NETSCAPE2.0".utf8)) != nil) == forever)
        #expect(session.document == before && session.history.undoCount == history)
        #expect(session.activeLayerID == foreground && session.gifTimelineSelectedFrameIndex == 1)
    }
}
