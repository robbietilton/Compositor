import Foundation
import Testing
@testable import Compositor

@MainActor
struct GIFCombinedPlaybackTests {
    private func session() async throws -> EditorSession {
        let background = try GIFFrameDeletionTests().fixture(delays: Array(repeating: 0.1, count: 4))
        let foreground = try GIFFrameDeletionTests().fixture(delays: Array(repeating: 0.06, count: 4))
        defer {
            try? FileManager.default.removeItem(at: background)
            try? FileManager.default.removeItem(at: foreground)
        }
        let session = EditorSession()
        await session.importImages([background, foreground])
        return session
    }

    @Test func sharedClockAdvancesBothLayersHoldsTheShorterAndRestartsTogether() async throws {
        let session = try await session()
        let layers = try #require(session.document?.renderLayers)
        let foreground = try #require(session.activeLayerID)
        await session.addGIFFrameMask(at: 2, for: foreground)
        let before = session.document, history = session.history.undoCount
        let selection = session.selectedLayerIDs, maskTarget = session.isGIFFrameMaskSelected
        let plan = GIFPlaybackPlan(layers: try #require(session.document?.renderLayers))
        #expect(abs(plan.duration - 0.4) < 1e-9)
        #expect(abs(plan.nextChange(after: 0.13) - 0.18) < 1e-9)
        session.setGIFPlaybackScope(.all, for: foreground)
        session.toggleGIFPlayback(for: foreground)
        #expect(await session.showAllGIFFrames(plan, at: 0.13, for: foreground))
        #expect(session.selectedGIFFrameIndex(for: layers[0].id) == 1)
        #expect(session.selectedGIFFrameIndex(for: foreground) == 2)
        let active = try #require(session.activeLayer)
        #expect(session.displayedLayer(for: active).mask?.isEnabled == true)
        #expect(session.isGIFFrameMaskSelected == maskTarget)
        #expect(await session.showAllGIFFrames(plan, at: 0.25, for: foreground))
        #expect(session.selectedGIFFrameIndex(for: layers[0].id) == 2 && session.gifTimelineSelectedFrameIndex == 3)
        #expect(await session.showAllGIFFrames(plan, at: 0.35, for: foreground))
        #expect(session.selectedGIFFrameIndex(for: layers[0].id) == 3 && session.gifTimelineSelectedFrameIndex == 3)
        #expect(await session.showAllGIFFrames(plan, at: 0, for: foreground))
        #expect(session.selectedGIFFrameIndex(for: layers[0].id) == 0 && session.gifTimelineSelectedFrameIndex == 0)
        #expect(session.document == before && session.history.undoCount == history)
        #expect(session.activeLayerID == foreground && session.selectedLayerIDs == selection)
        session.stopGIFPlayback(for: foreground)
        #expect(!session.gifTimelineIsPlaying && !session.gifTimelineIsLoadingFrame)
    }

    @Test func scopesKeepIndependentSpeedsAndOnlyTheActiveControlCanChangeThem() async throws {
        let session = try await session(), foreground = try #require(session.activeLayerID)
        let background = try #require(session.document?.layers.first?.id)
        let before = session.document, history = session.history.undoCount
        #expect(session.gifPlaybackScope == .selected)
        session.setGIFPlaybackSpeed(GIFPlaybackSpeed(position: 1), for: foreground)
        session.toggleGIFPlayback(for: foreground)
        session.setGIFPlaybackScope(.all, for: foreground)
        #expect(session.gifTimelineIsPlaying && session.gifTimelinePlaybackSpeed.multiplier == 1)
        session.setGIFPlaybackSpeed(GIFPlaybackSpeed(position: -1), for: foreground)
        session.setGIFPlaybackScope(.selected, for: background)
        session.setGIFPlaybackSpeed(GIFPlaybackSpeed(), for: background)
        #expect(session.gifPlaybackScope == .all && session.gifTimelinePlaybackSpeed.multiplier == 0.5)
        session.setGIFPlaybackScope(.selected, for: foreground)
        #expect(session.gifTimelineIsPlaying && session.gifTimelinePlaybackSpeed.multiplier == 2)
        session.setGIFPlaybackScope(.all, for: foreground)
        #expect(session.gifTimelinePlaybackSpeed.multiplier == 0.5)
        session.stopGIFPlayback(for: foreground)
        let snapshot = try #require(session.projectSnapshot())
        let reopened = EditorSession()
        reopened.installProject(snapshot, from: URL(fileURLWithPath: "/tmp/Playback.comp"))
        #expect(reopened.gifPlaybackScope == .selected && reopened.gifTimelinePlaybackSpeed.multiplier == 1)
        #expect(!reopened.gifTimelineIsPlaying && !reopened.isModified)
        #expect(session.document == before && session.history.undoCount == history)
    }

    @Test func frameClicksEditingAndCanceledOrStaleUpdatesStopCombinedPlayback() async throws {
        let session = try await session(), foreground = try #require(session.activeLayerID)
        let background = try #require(session.document?.layers.first?.id)
        let plan = GIFPlaybackPlan(layers: try #require(session.document?.renderLayers))
        session.setGIFPlaybackScope(.all, for: foreground)
        session.toggleGIFPlayback(for: foreground)
        await session.selectGIFTimelineFrame(2)
        #expect(!session.gifTimelineIsPlaying && session.gifTimelineSelectedFrameIndex == 2)
        session.toggleGIFPlayback(for: foreground)
        let canceled = Task { await session.showAllGIFFrames(plan, at: 0.35, for: foreground) }
        canceled.cancel()
        #expect(await canceled.value == false)
        #expect(session.gifTimelineSelectedFrameIndex == 2 && session.selectedGIFFrameIndex(for: background) == 0)
        session.pauseGIFForEditing(for: foreground)
        #expect(await session.showAllGIFFrames(plan, at: 0.35, for: foreground) == false)
        #expect(!session.gifTimelineIsLoadingFrame && session.importError == nil)
        session.toggleGIFPlayback(for: foreground)
        session.selectLayer(background)
        #expect(await session.showAllGIFFrames(plan, at: 0.35, for: foreground) == false)
        #expect(session.activeLayerID == background && session.gifTimelineSelectedFrameIndex == 0)
        session.stopGIFPlayback(for: foreground)
    }

    @Test func hiddenLayersAreExcludedAndSingleFrameSelectionCanPlayOtherGIFs() async throws {
        let session = try await session()
        let foreground = try #require(session.activeLayerID)
        session.document?.layers[1].gifAnimation?.deletedFrameIndices = [1, 2, 3]
        #expect(!session.gifTimelineCanPlay)
        session.setGIFPlaybackScope(.all, for: foreground)
        #expect(session.gifTimelineCanPlay)
        let plan = GIFPlaybackPlan(layers: try #require(session.document?.renderLayers))
        session.toggleGIFPlayback(for: foreground)
        #expect(await session.showAllGIFFrames(plan, at: 0.35, for: foreground))
        #expect(session.gifTimelineSelectedFrameIndex == 0)
        session.document?.layers[0].isVisible = false
        #expect(!session.gifTimelineCanPlay)
        #expect(await session.showAllGIFFrames(plan, at: 0.35, for: foreground) == false)
        let visible = GIFPlaybackPlan(layers: try #require(session.document?.renderLayers))
        #expect(visible.tracks.map(\.layerID) == [foreground] && visible.duration == 0.06)
        // Pause stays available even when hiding a layer removes the only moving timeline.
        session.toggleGIFPlayback(for: foreground)
        #expect(!session.gifTimelineIsPlaying)
    }
}
