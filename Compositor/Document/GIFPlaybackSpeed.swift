import Foundation

/// Preview timing only. The source GIF's frame delays remain unchanged.
nonisolated struct GIFPlaybackSpeed: Equatable, Sendable {
    static let sliderRange = -2.0...2.0
    let position: Double

    init(position: Double = 0) {
        self.position = position.isFinite
            ? min(Self.sliderRange.upperBound, max(Self.sliderRange.lowerBound, position)) : 0
    }

    // Equal travel halves or doubles the speed, putting 1.0× at the center.
    var multiplier: Double { pow(2, position) }

    func duration(for frame: GIFTimelineFrame) -> TimeInterval {
        frame.duration / multiplier
    }
}
