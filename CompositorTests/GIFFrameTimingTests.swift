import AppKit
import Observation
import Synchronization
import Testing
@testable import Compositor

@MainActor
struct GIFFrameTimingTests {
    @Test func importedUniformDelayUsesMetadataAndKeepsCustomValuesWhenSwitchingModes() async throws {
        #expect(GIFFrameTiming.defaultUniformDelay(for: []) == GIFTimelineLimits.defaultFrameDuration)
        let cases: [(delays: [TimeInterval], expected: TimeInterval)] = [
            ([0.08, 0.08, 0.08, 0.08], 0.08),
            ([0.04, 0.04, 0.04, 0.16], 0.04),
            ([0.04, 0.04, 0.16, 0.16], 0.1),
            ([0.04, 0.16, 0.08, 0.24], 0.13)
        ]
        for (delays, expected) in cases {
            let url = try GIFFrameDeletionTests().fixture(delays: delays)
            let package = FileManager.default.temporaryDirectory.appendingPathComponent("GIFDefaultTiming-\(UUID()).comp")
            defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: package) }
            let session = EditorSession()
            await session.importImages([url])
            let id = try #require(session.activeLayerID)
            #expect(session.gifTimelineTiming.mode == .perFrame)
            #expect(abs(session.gifTimelineTiming.uniformDelay - expected) < 0.000001)
            #expect(session.gifTimelineFrames.map(\.duration) == delays)
            let snapshot = try #require(session.projectSnapshot())
            try await ProjectStore.shared.save(snapshot, to: package)
            let loaded = try await ProjectStore.shared.load(from: package)
            #expect(loaded.animations[id]?.timing == session.gifTimelineTiming)
            var timing = session.gifTimelineTiming
            timing.mode = .uniform
            session.setGIFFrameTiming(timing, for: id)
            #expect(session.gifTimelineFrames.allSatisfy { abs($0.duration - expected) < 0.000001 })
            timing.uniformDelay = 0.075
            session.setGIFFrameTiming(timing, for: id)
            timing.mode = .perFrame
            session.setGIFFrameTiming(timing, for: id)
            timing.mode = .uniform
            session.setGIFFrameTiming(timing, for: id)
            #expect(session.gifTimelineFrames.allSatisfy { $0.duration == 0.075 })
        }
    }

    @Test func frameEditControlsRefreshWhenLoadingFinishesWithoutRefreshingSharedControls() async throws {
        let url = try GIFFrameDeletionTests().fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let timelineRefreshed = Mutex(false)
        let sharedControlsRefreshed = Mutex(false)
        let delayControlsRefreshed = Mutex(false)
        let maskControlsRefreshed = Mutex(false)
        var observedLoading = false
        session.refreshCanvasPreview = {
            observedLoading = session.gifTimelineIsLoadingFrame
            #expect(!session.gifTimelineCanEditFrames)
            #expect(session.gifTimelineCanEditTiming && session.canEditMask)
            // A view can read availability after the displayed frame changes, before decoding's defer runs.
            withObservationTracking { _ = session.gifTimelineCanEditFrames } onChange: {
                timelineRefreshed.withLock { $0 = true }
            }
            withObservationTracking { _ = session.canEditLayers } onChange: {
                sharedControlsRefreshed.withLock { $0 = true }
            }
            withObservationTracking { _ = session.gifTimelineCanEditTiming } onChange: {
                delayControlsRefreshed.withLock { $0 = true }
            }
            withObservationTracking { _ = session.canEditMask } onChange: {
                maskControlsRefreshed.withLock { $0 = true }
            }
        }
        await session.selectGIFTimelineFrame(1)
        #expect(observedLoading && session.gifTimelineCanEditFrames)
        #expect(timelineRefreshed.withLock { $0 })
        #expect(!sharedControlsRefreshed.withLock { $0 })
        #expect(!delayControlsRefreshed.withLock { $0 } && !maskControlsRefreshed.withLock { $0 })
    }

    @Test(arguments: GIFDelayMode.allCases)
    func timingEditsDuringFrameLoadingKeepTheSelectionRequest(mode: GIFDelayMode) async throws {
        let url = try GIFFrameDeletionTests().fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        let history = session.history.undoCount
        let timing = GIFFrameTiming(mode: mode, uniformDelay: 0.075, frameDelays: [1: 0.3])
        var editedDuringLoading = false
        session.refreshCanvasPreview = {
            #expect(session.gifTimelineIsLoadingFrame && session.gifTimelineCanEditTiming)
            session.setGIFFrameTiming(timing, for: id)
            #expect(session.gifTimelineTiming == timing)
            #expect(session.gifTimelineIsLoadingFrame)
            editedDuringLoading = true
        }
        await session.selectGIFTimelineFrame(1)
        #expect(editedDuringLoading && !session.gifTimelineIsLoadingFrame)
        #expect(session.gifTimelineSelectedFrameIndex == 1 && session.activeLayerID == id)
        #expect(session.selectedLayerIDs == [id])
        #expect(session.history.undoCount == history + 1 && session.history.undoName == "Change GIF Delays")
        #expect(session.gifTimelineTiming == timing)
        session.undo()
        #expect(session.gifTimelineTiming.mode == .perFrame && session.gifTimelineTiming.frameDelays.isEmpty)
    }

    @Test func invalidDelayFieldDraftsKeepPreviousTimingAndDoNotCreateAnEdit() async throws {
        let url = try GIFFrameDeletionTests().fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        let timing = GIFFrameTiming(uniformDelay: 0.123456789, frameDelays: [1: 0.123456789])
        session.setGIFFrameTiming(timing, for: id)
        session.toggleGIFPlayback(for: id)
        let before = session.document
        let history = session.history.undoCount
        for draft in ["", " ", "abc", "50abc", "NaN", "inf", "1e400", "-50", "0", "19.99", "655351"] {
            #expect(GIFDelayField.confirmedMilliseconds(draft, previous: timing.uniformDelay * 1000) == timing.uniformDelay * 1000)
            let confirmed = GIFFrameDelaysPopover.confirmedTiming(timing, drafts: [1: draft], frames: session.gifTimelineSourceFrames)
            #expect(confirmed == timing)
            session.setGIFFrameTiming(confirmed, for: id)
        }
        #expect(session.document == before && session.history.undoCount == history && session.gifTimelineIsPlaying)
        let confirmed = GIFFrameDelaysPopover.confirmedTiming(timing,
            drafts: [0: "20", 1: "655350", 2: " 125.5 ", 3: "50abc"], frames: session.gifTimelineSourceFrames)
        #expect(confirmed.frameDelays == [0: 0.02, 1: 655.35, 2: 0.1255])
        #expect(confirmed.uniformDelay == timing.uniformDelay)
        session.setGIFFrameTiming(confirmed, for: id)
        #expect(session.history.undoCount == history + 1 && !session.gifTimelineIsPlaying)
        session.undo()
        #expect(session.document == before)
    }

    @Test func uniformAndIndividualDelaysAreLayerEditsWithUndoAndUnchangedSource() async throws {
        let url = try GIFFrameDeletionTests().fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let first = try #require(session.activeLayerID)
        await session.selectGIFTimelineFrame(2)
        await session.addGIFFrameMask(at: 2, for: first)
        session.document?.selection = DocumentSelection(path: CGPath(rect: CGRect(x: 2, y: 2, width: 8, height: 8), transform: nil), antialiased: false)
        let source = try #require(session.activeLayer?.gifAnimation?.source)
        let before = session.document
        let history = session.history.undoCount
        session.setGIFPlaybackSpeed(GIFPlaybackSpeed(position: 1), for: first)
        session.toggleGIFPlayback(for: first)
        let uniform = GIFFrameTiming(mode: .uniform, uniformDelay: 0.05, frameDelays: [2: 0.3])
        session.setGIFFrameTiming(uniform, for: first)
        #expect(session.gifTimelineFrames.map(\.duration) == Array(repeating: 0.05, count: 4))
        #expect(!session.gifTimelineIsPlaying && session.gifTimelinePlaybackSpeed.multiplier == 2)
        #expect(session.gifTimelineSelectedFrameIndex == 2 && session.isGIFFrameMaskSelected)
        #expect(session.activeLayerID == first && session.selectedLayerIDs == [first])
        #expect(session.document?.selection == before?.selection)
        #expect(session.history.undoCount == history + 1 && session.history.undoName == "Change GIF Delays")
        #expect(session.activeLayer?.gifAnimation?.source === source)
        #expect(source.frames.map(\.duration) == [0.04, 0.16, 0.08, 0.24])
        let after = session.document
        session.undo()
        #expect(session.document == before)
        session.redo()
        #expect(session.document == after)
        var individual = uniform
        individual.mode = .perFrame
        session.setGIFFrameTiming(individual, for: first)
        #expect(session.gifTimelineFrames.map(\.duration) == [0.04, 0.16, 0.3, 0.24])
        #expect(session.gifTimelineSourceFrames.map(\.duration) == source.frames.map(\.duration))
        await session.importImages([url])
        #expect(abs(session.gifTimelineTiming.uniformDelay - 0.13) < 0.000001)
        #expect(session.gifTimelineTiming.mode == .perFrame && session.gifTimelineTiming.frameDelays.isEmpty)
        session.activeLayerID = first
        #expect(session.gifTimelineTiming == individual)
    }

    @Test func editedDelaysFollowCopiesOrderDeletionReopenResizeAndDefaultExport() async throws {
        let url = try GIFFrameDeletionTests().fixture()
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("GIFTiming-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: package) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        session.setGIFFrameTiming(GIFFrameTiming(frameDelays: [1: 0.3]), for: id)
        await session.duplicateGIFFrame(at: 1, for: id)
        #expect(session.gifTimelineFrames.map(\.duration) == [0.04, 0.3, 0.3, 0.08, 0.24])
        var timing = session.gifTimelineTiming
        timing.frameDelays[4] = 0.2
        session.setGIFFrameTiming(timing, for: id)
        session.moveGIFFrame(at: 4, to: 0, for: id)
        await session.deleteGIFFrame(at: 1, for: id)
        #expect(session.gifTimelineFrames.map(\.index) == [4, 0, 2, 3])
        #expect(session.gifTimelineTiming.frameDelays == [4: 0.2])
        session.setGIFPlaybackSpeed(GIFPlaybackSpeed(position: -2), for: id)
        let snapshot = try #require(session.projectSnapshot())
        #expect(snapshot.manifest.version == ProjectManifest.current)
        #expect(snapshot.manifest.layers[0].gif?.timing?.frameDelays.map(\.index) == [4])
        try await ProjectStore.shared.save(snapshot, to: package)
        try FileManager.default.removeItem(at: url)
        let loaded = try await ProjectStore.shared.load(from: package)
        let reopened = EditorSession()
        reopened.installProject(loaded, from: package)
        #expect(reopened.gifTimelineTiming == session.gifTimelineTiming)
        #expect(reopened.gifTimelineFrames.map(\.duration) == [0.2, 0.04, 0.08, 0.24])
        #expect(reopened.gifTimelineSelectedFrameIndex == 4 && !reopened.gifTimelineIsPlaying)
        #expect(reopened.gifTimelinePlaybackSpeed.multiplier == 1 && !reopened.isModified)
        let result = try await GIFExporter.shared.encode(loaded, width: 32, height: 24, options: GIFExportOptions(layerID: id))
        #expect(result.durations == reopened.gifTimelineFrames.map(\.duration))
        #expect(try GIFDecoder.source(result.data, name: "Export").frames.map(\.duration) == result.durations)
        var options = GIFExportOptions(layerID: id)
        options.timing.delays = GIFFrameTiming(mode: .uniform, uniformDelay: 0.05)
        let override = try await GIFExporter.shared.encode(loaded, width: 32, height: 24, options: options)
        #expect(override.durations == Array(repeating: 0.05, count: 4))
        #expect(reopened.gifTimelineTiming == session.gifTimelineTiming)
        let resized = try await ImageResizer.shared.resize(loaded,
            to: ImageSizeOptions(width: 64, height: 48, resolution: 72, sampling: .nearest))
        #expect(resized.animations[id]?.timing == loaded.animations[id]?.timing)
        try await ProjectStore.shared.save(resized, to: package)
        #expect(try await ProjectStore.shared.load(from: package).animations[id]?.timing == loaded.animations[id]?.timing)
    }

    @Test func invalidNoOpBusyAndWrongLayerTimingChangesAreIgnored() async throws {
        let url = try GIFFrameDeletionTests().fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        let before = session.document
        let history = session.history.undoCount
        for delay in [0, 0.01, 655.36, Double.nan, Double.infinity] {
            session.setGIFFrameTiming(GIFFrameTiming(uniformDelay: delay), for: id)
            session.setGIFFrameTiming(GIFFrameTiming(frameDelays: [0: delay]), for: id)
        }
        session.setGIFFrameTiming(GIFFrameTiming(frameDelays: [500: 0.2]), for: id)
        session.setGIFFrameTiming(session.gifTimelineTiming, for: id)
        session.setGIFFrameTiming(GIFFrameTiming(mode: .uniform), for: UUID())
        session.showsImporter = true
        session.setGIFFrameTiming(GIFFrameTiming(mode: .uniform), for: id)
        session.showsImporter = false
        #expect(session.document == before && session.history.undoCount == history)
    }

    @Test func malformedSavedTimingAndVersionMismatchAreRejected() async throws {
        let url = try GIFFrameDeletionTests().fixture()
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("GIFTimingInvalid-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: package) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        session.setGIFFrameTiming(GIFFrameTiming(frameDelays: [1: 0.2]), for: id)
        let snapshot = try #require(session.projectSnapshot())
        try await ProjectStore.shared.save(snapshot, to: package)
        let manifestURL = package.appendingPathComponent("manifest.json")
        let original = try Data(contentsOf: manifestURL)
        var invalidRecords: [ProjectGIFTimingRecord] = []
        for delay in [0, 0.01, 655.36, Double.nan] {
            invalidRecords.append(ProjectGIFTimingRecord(GIFFrameTiming(mode: .uniform, uniformDelay: delay)))
            invalidRecords.append(ProjectGIFTimingRecord(GIFFrameTiming(frameDelays: [1: delay])))
        }
        invalidRecords.append(ProjectGIFTimingRecord(GIFFrameTiming(frameDelays: [500: 0.2])))
        var duplicate = ProjectGIFTimingRecord(GIFFrameTiming(frameDelays: [1: 0.2]))
        duplicate.frameDelays.append(ProjectGIFDelayRecord(index: 1, duration: 0.3))
        invalidRecords.append(duplicate)
        for record in invalidRecords {
            var manifest = snapshot.manifest
            manifest.layers[0].gif?.timing = record
            var animations = snapshot.animations
            animations[id]?.timing = record.frameTiming
            let invalid = ProjectSnapshot(manifest: manifest, images: snapshot.images, animations: animations)
            await #expect(throws: ProjectError.self) { try await ProjectStore.shared.save(invalid, to: package) }
            #expect(try Data(contentsOf: manifestURL) == original)
            if record.frameTiming.uniformDelay.isFinite && record.frameDelays.allSatisfy({ $0.duration.isFinite }) {
                try JSONEncoder().encode(manifest).write(to: manifestURL)
                await #expect(throws: ProjectError.self) { try await ProjectStore.shared.load(from: package) }
                try original.write(to: manifestURL)
            }
        }
        var old = snapshot.manifest
        old.version = 27
        let mismatch = ProjectSnapshot(manifest: old, images: snapshot.images, animations: snapshot.animations)
        await #expect(throws: ProjectError.self) { try await ProjectStore.shared.save(mismatch, to: package) }
        try JSONEncoder().encode(old).write(to: manifestURL)
        await #expect(throws: ProjectError.self) { try await ProjectStore.shared.load(from: package) }
    }

    @Test(arguments: [27, ProjectManifest.current]) func missingTimingDefaultsToOriginalDelays(version: Int) async throws {
        let url = try GIFFrameDeletionTests().fixture()
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("GIFTimingLegacy-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: package) }
        let session = EditorSession()
        await session.importImages([url])
        let snapshot = try #require(session.projectSnapshot())
        var manifest = snapshot.manifest
        manifest.version = version
        manifest.layers[0].gif?.timing = nil
        var animations = snapshot.animations
        animations[manifest.layers[0].id]?.timing = GIFFrameTiming()
        let legacy = ProjectSnapshot(manifest: manifest, images: snapshot.images, animations: animations)
        try await ProjectStore.shared.save(legacy, to: package)
        let loaded = try await ProjectStore.shared.load(from: package)
        #expect(loaded.animations.values.first?.timing == GIFFrameTiming())
        #expect(loaded.animations.values.first?.frames.map(\.duration) == [0.04, 0.16, 0.08, 0.24])
    }
}
