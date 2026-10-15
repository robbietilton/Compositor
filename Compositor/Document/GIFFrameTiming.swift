import Foundation

nonisolated enum GIFDelayMode: String, CaseIterable, Codable, Sendable {
    case perFrame = "Frame delay"
    case uniform = "Same for all"
}

/// Delays belong to editable frame identities; the encoded source stays immutable.
nonisolated struct GIFFrameTiming: Equatable, Sendable {
    static let delayRange = GIFTimelineLimits.minimumFrameDuration...655.35
    var mode: GIFDelayMode = .perFrame
    var uniformDelay: TimeInterval = GIFTimelineLimits.defaultFrameDuration
    var frameDelays: [Int: TimeInterval] = [:]

    /// Prefer the source's usual cadence; tied frequencies use the mean to retain its total loop duration.
    static func defaultUniformDelay(for frames: [GIFTimelineFrame]) -> TimeInterval {
        guard !frames.isEmpty else { return GIFTimelineLimits.defaultFrameDuration }
        var counts: [TimeInterval: Int] = [:]
        for frame in frames { counts[frame.duration, default: 0] += 1 }
        let mostUsed = counts.values.max() ?? 0
        let winners = counts.filter { $0.value == mostUsed }.map(\.key)
        if winners.count == 1 { return winners[0] }
        return frames.reduce(0) { $0 + $1.duration } / Double(frames.count)
    }

    func delay(for frame: GIFTimelineFrame) -> TimeInterval {
        mode == .uniform ? uniformDelay : frameDelays[frame.index] ?? frame.duration
    }

    var isValid: Bool {
        uniformDelay.isFinite && Self.delayRange.contains(uniformDelay)
            && frameDelays.count <= GIFTimelineLimits.maxFrames
            && frameDelays.values.allSatisfy { $0.isFinite && Self.delayRange.contains($0) }
    }

    func isValid(for indices: Set<Int>) -> Bool {
        isValid && Set(frameDelays.keys).isSubset(of: indices)
    }
}
