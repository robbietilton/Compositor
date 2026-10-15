import AppKit
import ImageIO
import Testing
@testable import Compositor

@MainActor
struct GIFExportTimingTests {
    private func delays(_ data: Data) throws -> [TimeInterval] {
        let reader = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try (0..<CGImageSourceGetCount(reader)).map { index in
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(reader, index, nil) as? [CFString: Any])
            let gif = try #require(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            return try #require(gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
                ?? gif[kCGImagePropertyGIFDelayTime] as? Double)
        }
    }

    @Test func originalMetadataCustomDelaysAndSpeedRoundTripWithoutChangingTheProject() async throws {
        let url = try GIFFrameDeletionTests().fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        let source = try #require(session.activeLayer?.gifAnimation?.source)
        #expect(source.frames.map(\.duration) == [0.04, 0.16, 0.08, 0.24])
        await session.duplicateGIFFrame(at: 1, for: id)
        session.moveGIFFrame(at: 4, to: 0, for: id)
        #expect(session.gifTimelineFrames.map(\.index) == [4, 0, 1, 2, 3])
        session.setGIFPlaybackSpeed(GIFPlaybackSpeed(position: -2), for: id)
        let snapshot = try #require(session.projectSnapshot())
        let before = session.document
        let history = session.history.undoCount
        var options = GIFExportOptions(layerID: id)

        let original = try await GIFExporter.shared.encode(snapshot, width: 32, height: 24, options: options)
        #expect(try delays(original.data) == [0.16, 0.04, 0.16, 0.08, 0.24])

        options.timing.delays = GIFFrameTiming(frameDelays: [4: 0.3, 1: 0.1])
        options.timing.speedMultiplier = 2
        let custom = try await GIFExporter.shared.encode(snapshot, width: 32, height: 24, options: options)
        #expect(custom.durations == [0.15, 0.02, 0.05, 0.04, 0.12])
        #expect(try delays(custom.data) == custom.durations)
        #expect(try GIFDecoder.source(custom.data, name: "Export").frames.map(\.duration) == custom.durations)
        #expect(source.frames.map(\.duration) == [0.04, 0.16, 0.08, 0.24])
        #expect(session.document == before && session.history.undoCount == history)
        #expect(session.gifTimelineSelectedFrameIndex == 4 && session.gifTimelinePlaybackSpeed.multiplier == 0.25)
    }

    @Test func uniformDelaysSpeedAndMinimumDelayAreWrittenToTheGIF() async throws {
        let url = try GIFFrameDeletionTests().fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        let snapshot = try #require(session.projectSnapshot())
        var options = GIFExportOptions(layerID: id)
        options.timing.delays = GIFFrameTiming(mode: .uniform, uniformDelay: 0.095)
        options.timing.speedMultiplier = 2
        // Uniform mode ignores individual overrides, and GIF rounds to 10 ms ticks.
        options.timing.delays?.frameDelays = [0: 0.5]
        let uniform = try await GIFExporter.shared.encode(snapshot, width: 32, height: 24, options: options)
        #expect(uniform.durations == Array(repeating: 0.05, count: 4))
        #expect(try delays(uniform.data) == uniform.durations)

        options.timing = GIFExportTiming(speedMultiplier: 4)
        let fast = try await GIFExporter.shared.encode(snapshot, width: 32, height: 24, options: options)
        #expect(fast.durations == [0.02, 0.04, 0.02, 0.06])
        #expect(try delays(fast.data) == fast.durations)
        #expect(options.timing.usesMinimumDelay(for: session.gifTimelineFrames))
        #expect(try GIFExportTiming().durations(for: []) == [0.1])
    }

    @Test func invalidDelayOrSpeedFailsBeforeEncoding() async throws {
        let url = try GIFFrameDeletionTests().fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        let snapshot = try #require(session.projectSnapshot())
        for delay in [0, 0.01, Double.nan, Double.infinity, 655.36] {
            var options = GIFExportOptions(layerID: id)
            options.timing.delays = GIFFrameTiming(frameDelays: [0: delay])
            await #expect(throws: GIFExportError.self) {
                try await GIFExporter.shared.encode(snapshot, width: 32, height: 24, options: options)
            }
            options.timing.delays?.mode = .uniform
            options.timing.delays?.uniformDelay = delay
            await #expect(throws: GIFExportError.self) {
                try await GIFExporter.shared.encode(snapshot, width: 32, height: 24, options: options)
            }
        }
        for speed in [0, 0.24, 4.01, Double.nan, Double.infinity] {
            #expect(throws: GIFExportError.self) {
                try GIFExportTiming(speedMultiplier: speed).durations(for: session.gifTimelineFrames)
            }
        }
        var timing = GIFExportTiming(delays: GIFFrameTiming(mode: .uniform, uniformDelay: 655.35))
        #expect(try timing.durations(for: session.gifTimelineFrames) == Array(repeating: 655.35, count: 4))
        timing.speedMultiplier = 0.25
        #expect(throws: GIFExportError.self) { try timing.durations(for: session.gifTimelineFrames) }
    }
}
