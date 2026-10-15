import Foundation

/// Preview presentation follows elapsed time; decoding never changes the saved frame delays.
nonisolated enum GIFPreviewPlayback {
    @MainActor
    static func play<C: Clock>(durations: [TimeInterval], startingAt initial: Int, loops: Bool = true,
                               clock: C = ContinuousClock(), showFrame: (Int) async throws -> Void) async throws
        where C.Duration == Duration {
        try Task.checkCancellation()
        guard durations.count > 1, durations.indices.contains(initial),
              durations.allSatisfy({ $0.isFinite && $0 > 0 }) else { return }
        let seconds = durations.reduce(0, +)
        guard seconds.isFinite, seconds < Double(Int64.max) else { return }
        let holds = durations.map { Duration.seconds($0) }
        guard holds.allSatisfy({ $0 > .zero }) else { return }
        var starts: [Duration] = [], total = Duration.zero
        for duration in holds {
            starts.append(total)
            total += duration
        }
        let started = clock.now, offset = starts[initial]
        var displayed = initial, next = holds[initial]
        while true {
            try await clock.sleep(until: started.advanced(by: next), tolerance: nil)
            try Task.checkCancellation()
            let elapsed = started.duration(to: clock.now)
            let position = offset + elapsed
            if !loops, position >= total {
                // Once always ends on the last frame, even if decoding missed its interval.
                if displayed != durations.count - 1 { try await showFrame(durations.count - 1) }
                try Task.checkCancellation()
                return
            }
            var time = position - total * floor(position / total)
            if time < .zero || time >= total { time = .zero }
            var lower = 0, upper = starts.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if starts[middle] <= time { lower = middle + 1 }
                else { upper = middle }
            }
            let index = max(0, lower - 1)
            let end = index + 1 < starts.count ? starts[index + 1] : total
            // Keep the boundary sampled before decoding. Late frames catch up on the next iteration.
            next = elapsed + end - time
            if index != displayed {
                try await showFrame(index)
                try Task.checkCancellation()
                displayed = index
            }
        }
    }
}
