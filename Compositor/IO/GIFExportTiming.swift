import Foundation

/// Nil delays inherit the timeline's saved timing. Export overrides and speed never change the document.
nonisolated struct GIFExportTiming: Equatable, Sendable {
    static let delayRange = GIFFrameTiming.delayRange
    static let speedRange = 0.25...4.0
    var delays: GIFFrameTiming? = nil
    var speedMultiplier = 1.0

    func durations(for frames: [GIFTimelineFrame], inheriting timeline: GIFFrameTiming = GIFFrameTiming()) throws -> [TimeInterval] {
        guard speedMultiplier.isFinite, Self.speedRange.contains(speedMultiplier) else {
            throw GIFExportError.invalidTiming
        }
        let timing = delays ?? timeline
        let values = frames.isEmpty ? [timing.mode == .uniform ? timing.uniformDelay : GIFTimelineLimits.defaultFrameDuration]
            : frames.map { timing.delay(for: $0) }
        return try values.map { delay in
            guard delay.isFinite, Self.delayRange.contains(delay) else { throw GIFExportError.invalidTiming }
            let scaled = max(Self.delayRange.lowerBound, delay / speedMultiplier)
            guard scaled <= Self.delayRange.upperBound else { throw GIFExportError.invalidTiming }
            // GIF stores frame delays in hundredths of a second.
            return (scaled * 100).rounded() / 100
        }
    }

    func usesMinimumDelay(for frames: [GIFTimelineFrame], inheriting timeline: GIFFrameTiming = GIFFrameTiming()) -> Bool {
        let timing = delays ?? timeline
        return frames.contains { timing.delay(for: $0) / speedMultiplier < Self.delayRange.lowerBound }
    }
}
