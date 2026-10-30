import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import Compositor

@MainActor
struct GIFPreviewPlaybackTests {
    private enum Stop: Error, Equatable { case finished, excessiveSleeps }

    /// Clock reads and simulated decode work share locked time, including across suspension points.
    private nonisolated final class TestClock: Clock {
        struct Instant: InstantProtocol {
            var offset = Duration.zero
            func advanced(by duration: Duration) -> Self { Self(offset: offset + duration) }
            func duration(to other: Self) -> Duration { other.offset - offset }
            static func < (lhs: Self, rhs: Self) -> Bool { lhs.offset < rhs.offset }
        }
        private struct State {
            var now = Instant()
            var sleeps = 0
        }
        private let state = Mutex(State())
        var now: Instant { state.withLock { $0.now } }
        var minimumResolution: Duration { .nanoseconds(1) }
        var sleeps: Int { state.withLock { $0.sleeps } }
        var elapsed: Double { now.offset / .seconds(1) }

        func advance(by duration: Duration) { state.withLock { $0.now = $0.now.advanced(by: duration) } }
        func sleep(until deadline: Instant, tolerance: Duration?) async throws {
            try Task.checkCancellation()
            try state.withLock {
                $0.sleeps += 1
                guard $0.sleeps < 100 else { throw Stop.excessiveSleeps }
                if deadline > $0.now { $0.now = deadline }
            }
        }
    }

    @Test(arguments: [0.25, 1.0, 4.0])
    func decodingDoesNotAccumulateDelayAtAnyPlaybackSpeed(speed: Double) async throws {
        let clock = TestClock()
        var frames: [Int] = [], times: [Double] = []
        try await GIFPreviewPlayback.play(durations: [0.1, 0.2, 0.15].map { $0 / speed }, startingAt: 0,
                                           loops: false, clock: clock) { index in
            frames.append(index)
            times.append(clock.elapsed)
            clock.advance(by: .seconds(0.03 / speed))
        }
        #expect(frames == [1, 2])
        #expect(abs(times[0] - 0.1 / speed) < 1e-9)
        #expect(abs(times[1] - 0.3 / speed) < 1e-9)
        #expect(abs(clock.elapsed - 0.45 / speed) < 1e-9)
    }

    @Test(arguments: [0.25, 0.5])
    func slowDecodingSkipsExpiredIntervalsAndOnceEndsOnTheLastFrame(delay: Double) async throws {
        let clock = TestClock()
        var frames: [Int] = []
        try await GIFPreviewPlayback.play(durations: [0.1, 0.1, 0.1, 0.1], startingAt: 0,
                                           loops: false, clock: clock) { index in
            frames.append(index)
            clock.advance(by: .seconds(delay))
        }
        #expect(frames == [1, 3])
        #expect(clock.sleeps == (delay < 0.4 ? 3 : 2))
    }

    @Test func resumeAndLoopKeepMixedFrameDurations() async throws {
        let clock = TestClock()
        var frames: [Int] = [], times: [Double] = []
        await #expect(throws: Stop.finished) {
            try await GIFPreviewPlayback.play(durations: [0.1, 0.2, 0.3], startingAt: 1, clock: clock) { index in
                frames.append(index)
                times.append(clock.elapsed)
                clock.advance(by: .milliseconds(20))
                if frames.count == 3 { throw Stop.finished }
            }
        }
        #expect(frames == [2, 0, 1])
        for (time, expected) in zip(times, [0.2, 0.5, 0.6]) { #expect(abs(time - expected) < 1e-9) }
    }

    @Test func cancelingDuringDecodeDoesNotRequestAnotherFrame() async throws {
        let clock = TestClock()
        var frames: [Int] = []
        let task = Task {
            do {
                try await GIFPreviewPlayback.play(durations: [0.1, 0.2, 0.3], startingAt: 0, clock: clock) { index in
                    frames.append(index)
                    clock.advance(by: .milliseconds(30))
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                return false
            } catch is CancellationError { return true }
            catch { Issue.record(error); return false }
        }
        #expect(await task.value)
        #expect(frames == [1])
    }

    @Test func emptySingleFrameAndInvalidTimingDoNotStartPlayback() async throws {
        for durations in [[], [0.1], [0.1, 0], [0.1, -.infinity], [0.1, .nan]] as [[Double]] {
            let clock = TestClock()
            try await GIFPreviewPlayback.play(durations: durations, startingAt: 0, clock: clock) { _ in
                Issue.record("Invalid or still timing must not request a frame")
            }
            #expect(clock.sleeps == 0)
        }
        let clock = TestClock()
        try await GIFPreviewPlayback.play(durations: [0.1, 0.2], startingAt: 2, clock: clock) { _ in
            Issue.record("An invalid starting frame must not play")
        }
        #expect(clock.sleeps == 0)
    }

    @Test func canceledNavigationDoesNotAdvanceTheDisplayedFrame() async throws {
        let url = try GIFLayerTests().fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let request = Task { await session.selectGIFTimelineFrame(1) }
        request.cancel()
        await request.value
        #expect(session.gifTimelineSelectedFrameIndex == 0)
        #expect(!session.gifTimelineIsLoadingFrame && session.importError == nil)
    }

    private func timeline(indices: [Int], durations: [Double], startingAt initial: Int = 0,
                          timing: GIFFrameTiming = GIFFrameTiming(), isPlaying: Bool = true,
                          showFrame: @escaping (Int) async -> Void) throws -> GIFTimeline {
        let thumbnail = try #require(BrushRaster.context(width: 1, height: 1, mask: false).makeImage())
        let frames = zip(indices, durations).map { GIFTimelineFrame(index: $0, thumbnail: thumbnail, duration: $1) }
        return GIFTimeline(frames: frames, selectedFrameIndex: initial, isPlaying: isPlaying, canPlay: true,
                           timing: timing, canEditFrames: true, canEditTiming: true, onSelectFrame: showFrame,
                           onTogglePlayback: {}, onStopPlayback: {}, onChangeTiming: { _ in },
                           onDuplicateFrame: { _ in }, onDeleteFrame: { _ in })
    }

    @Test(arguments: [GIFDelayMode.perFrame, .uniform])
    func timelineKeepsSavedTimingAndStableFrameIdentities(mode: GIFDelayMode) async throws {
        let clock = TestClock()
        var frames: [Int] = [], times: [Double] = []
        var timing = GIFFrameTiming()
        timing.mode = mode
        timing.uniformDelay = 0.1
        let view = try timeline(indices: [0, 4, 2, 3], durations: [0.04, 0.16, 0.08, 0.24],
                                startingAt: 4, timing: timing) { index in
            frames.append(index)
            times.append(clock.elapsed)
            clock.advance(by: .milliseconds(30))
            if frames.count == 3 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        await Task { await view.play(clock: clock) }.value
        #expect(frames == [2, 3, 0])
        let expected = mode == .uniform ? [0.1, 0.2, 0.3] : [0.16, 0.24, 0.48]
        for (time, deadline) in zip(times, expected) { #expect(abs(time - deadline) < 1e-9) }
    }

    @Test func timelineSkipsExpiredFramesAfterSlowDecode() async throws {
        let clock = TestClock()
        var frames: [Int] = [], times: [Double] = []
        let view = try timeline(indices: [0, 4, 2, 3], durations: [0.1, 0.1, 0.1, 0.1]) { index in
            frames.append(index)
            times.append(clock.elapsed)
            clock.advance(by: .milliseconds(250))
            if frames.count == 2 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        await Task { await view.play(clock: clock) }.value
        #expect(frames == [4, 3])
        for (time, deadline) in zip(times, [0.1, 0.35]) { #expect(abs(time - deadline) < 1e-9) }
    }

    @Test func pausedTimelineDoesNotDecodeFrames() async throws {
        let clock = TestClock()
        let view = try timeline(indices: [0, 1], durations: [0.1, 0.1], isPlaying: false) { _ in
            Issue.record("A paused timeline must not request a frame")
        }
        await view.play(clock: clock)
        #expect(clock.sleeps == 0)
    }
}
