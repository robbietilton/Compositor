import Foundation

/// A shared export clock, in 10 ms GIF ticks. Shorter tracks hold their final frame.
nonisolated struct GIFExportSchedule {
    struct Track {
        let layer: ProjectLayerRecord
        let animation: GIFAnimation
        let frames: [GIFTimelineFrame]
        let starts: [Int]
        let end: Int
    }

    struct Frame {
        let start: Int
        /// Usually start; a lookahead near the end preserves final frames within the minimum delay.
        let sample: Int
        let ticks: Int
        let ticksPerSecond: Int
        var duration: TimeInterval { Double(ticks) / Double(ticksPerSecond) }
    }

    let tracks: [Track]
    let frames: [Frame]
    let usesMinimumDelay: Bool
    var durations: [TimeInterval] { frames.map(\.duration) }

    init(_ snapshot: ProjectSnapshot, options: GIFExportOptions) throws {
        let scale = 100
        let minimumTicks = Int((GIFTimelineLimits.minimumFrameDuration * Double(scale)).rounded())
        let layers = snapshot.gifExportLayers
        var tracks: [Track] = []
        var minimum = false
        for layer in layers {
            try Task.checkCancellation()
            guard let animation = snapshot.animations[layer.id], animation.hasValidFrameOrder,
                  !animation.frames.isEmpty else { throw GIFExportError.invalidTimeline }
            let sourceFrames = animation.sourceFrames
            guard sourceFrames.count <= GIFTimelineLimits.maxFrames else { throw GIFExportError.tooLarge }
            // Each frame for its layer's delay, which GIF stores in hundredths of a second.
            let durations = sourceFrames.map { frame -> TimeInterval in
                let delay = animation.timing.delay(for: frame)
                let kept = min(GIFFrameTiming.delayRange.upperBound, max(GIFFrameTiming.delayRange.lowerBound, delay.isFinite ? delay : 0.1))
                return (kept * 100).rounded() / 100
            }
            var end = 0, starts: [Int] = []
            for duration in durations {
                starts.append(end)
                end += Int((duration * Double(scale)).rounded())
            }
            tracks.append(Track(layer: layer, animation: animation, frames: sourceFrames, starts: starts, end: end))
        }
        self.tracks = tracks
        guard let end = tracks.map(\.end).max() else {
            let duration = GIFTimelineLimits.defaultFrameDuration
            frames = [Frame(start: 0, sample: 0, ticks: Int((duration * Double(scale)).rounded()), ticksPerSecond: scale)]
            usesMinimumDelay = false
            return
        }

        var frames: [Frame] = [], start = 0, sample = 0
        // Merge frame starts without constructing every possible pair or retaining an unbounded event list.
        var positions = Array(repeating: 1, count: tracks.count)
        func appendFrames(until boundary: Int) throws {
            while start < boundary {
                guard frames.count < GIFTimelineLimits.maxFrames else { throw GIFExportError.tooLarge }
                var ticks = min(65535, boundary - start)
                let remainder = boundary - start - ticks
                if remainder > 0, remainder < minimumTicks { ticks -= minimumTicks - remainder }
                // Respect GIF's frame-delay limit, splitting long holds when necessary.
                frames.append(Frame(start: start, sample: max(start, sample), ticks: ticks, ticksPerSecond: scale))
                start += ticks
                sample = start
            }
        }
        while true {
            try Task.checkCancellation()
            let next = tracks.indices.compactMap { index -> Int? in
                positions[index] < tracks[index].starts.count ? tracks[index].starts[positions[index]] : nil
            }.min() ?? end
            if next == end { break }
            for index in tracks.indices where positions[index] < tracks[index].starts.count
                && tracks[index].starts[positions[index]] == next {
                positions[index] += 1
            }
            if next <= start { continue }
            // Mismatched cadences can create a gap below the timeline's 20 ms floor. Move the boundary
            // without extending the export; at its end, look ahead to retain every final frame.
            if next - start >= minimumTicks { try appendFrames(until: next) }
            else {
                minimum = true
                if end - start >= minimumTicks * 2 { try appendFrames(until: start + minimumTicks) }
                else { sample = next }
            }
        }
        try appendFrames(until: end)
        self.frames = frames
        usesMinimumDelay = minimum
    }
}
