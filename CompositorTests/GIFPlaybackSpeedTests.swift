import Foundation
import UniformTypeIdentifiers
import Testing
@testable import Compositor

@MainActor
struct GIFPlaybackSpeedTests {
    @Test func centerAndEndpointsScaleVariableFrameTiming() async throws {
        let url = try ImageImportTests().animatedGIFFixture(delays: [0.04, 0.16])
        defer { try? FileManager.default.removeItem(at: url) }
        let (_, animation) = try await ImageImporter.shared.importGIF(url)
        let frames = animation.frames
        let normal = GIFPlaybackSpeed()
        let slow = GIFPlaybackSpeed(position: GIFPlaybackSpeed.sliderRange.lowerBound)
        let fast = GIFPlaybackSpeed(position: GIFPlaybackSpeed.sliderRange.upperBound)
        #expect(normal.position == 0 && normal.multiplier == 1)
        #expect(slow.multiplier == 0.25 && fast.multiplier == 4)
        for frame in frames {
            #expect(normal.duration(for: frame) == frame.duration)
            #expect(slow.duration(for: frame) == frame.duration * 4)
            #expect(fast.duration(for: frame) == frame.duration / 4)
        }
        #expect(abs(fast.duration(for: frames[1]) / fast.duration(for: frames[0]) - 4) < 0.01)
    }

    @Test func speedStaysWithItsLayerWithoutChangingTheDocument() async throws {
        let url = try ImageImportTests().animatedGIFFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let firstID = try #require(session.activeLayerID)
        await session.importImages([url])
        let secondID = try #require(session.activeLayerID)
        let document = session.document
        let undoCount = session.history.undoCount
        session.selectLayer(firstID)
        session.toggleGIFPlayback(for: firstID)
        session.setGIFPlaybackSpeed(GIFPlaybackSpeed(position: 1), for: firstID)
        #expect(session.gifTimelinePlaybackSpeed.multiplier == 2)
        #expect(session.gifTimelineIsPlaying)
        session.stopGIFPlayback(for: firstID)
        await session.selectGIFTimelineFrame(1)
        #expect(session.gifTimelinePlaybackSpeed.multiplier == 2)
        session.selectLayer(secondID)
        #expect(session.gifTimelinePlaybackSpeed.multiplier == 1)
        session.setGIFPlaybackSpeed(GIFPlaybackSpeed(position: -1), for: secondID)
        // A stale control from another layer must not change its preview setting.
        session.setGIFPlaybackSpeed(GIFPlaybackSpeed(), for: firstID)
        session.selectLayer(firstID)
        #expect(session.gifTimelinePlaybackSpeed.multiplier == 2)
        session.selectLayer(secondID)
        #expect(session.gifTimelinePlaybackSpeed.multiplier == 0.5)
        #expect(session.document == document)
        #expect(session.history.undoCount == undoCount)

        let snapshot = try #require(session.projectSnapshot())
        let reopened = EditorSession()
        reopened.installProject(snapshot, from: url.deletingPathExtension().appendingPathExtension("comp"))
        #expect(reopened.gifTimelinePlaybackSpeed.multiplier == 1)
        #expect(!reopened.isModified && !reopened.canUndo && !reopened.gifTimelineIsPlaying)
        #expect(reopened.gifTimelineFrames.map(\.duration) == session.gifTimelineFrames.map(\.duration))
    }

    @Test func invalidPositionsAreBoundedAndSingleFramePlaybackStaysDisabled() async throws {
        #expect(GIFPlaybackSpeed(position: .nan).multiplier == 1)
        #expect(GIFPlaybackSpeed(position: .infinity).multiplier == 1)
        #expect(GIFPlaybackSpeed(position: -100).multiplier == 0.25)
        #expect(GIFPlaybackSpeed(position: 100).multiplier == 4)
        let url = try ImageImportTests().fixture(.gif)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        session.setGIFPlaybackSpeed(GIFPlaybackSpeed(position: 1), for: id)
        session.toggleGIFPlayback(for: id)
        #expect(session.gifTimelinePlaybackSpeed.multiplier == 1)
        #expect(!session.gifTimelineIsPlaying)
    }

    @Test func cancelledPlaybackRequestsDoNotAdvanceTheFrame() async throws {
        let url = try ImageImportTests().animatedGIFFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let request = Task { await session.selectGIFTimelineFrame(1) }
        request.cancel()
        await request.value
        #expect(session.gifTimelineSelectedFrameIndex == 0)
        #expect(!session.gifTimelineIsLoadingFrame)
        #expect(session.importError == nil)
    }
}
