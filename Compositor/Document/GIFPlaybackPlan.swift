import Foundation

nonisolated enum GIFPlaybackScope: String, Sendable {
    case selected = "This GIF"
    case all = "All"
}

/// Preview frame times, without decoding images or constructing every combined output frame.
nonisolated struct GIFPlaybackPlan {
    struct Track {
        let layerID: UUID
        let name: String
        let animation: GIFAnimation
        let indices: [Int]
        let starts: [TimeInterval]
        let duration: TimeInterval

        func position(at time: TimeInterval) -> Int {
            var lower = 0, upper = starts.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if starts[middle] <= time { lower = middle + 1 }
                else { upper = middle }
            }
            return max(0, lower - 1)
        }
    }

    let tracks: [Track]
    let duration: TimeInterval

    init(layers: [ImageLayer]) {
        tracks = layers.compactMap { layer in
            guard let animation = layer.gifAnimation, !animation.frames.isEmpty else { return nil }
            var duration: TimeInterval = 0, starts: [TimeInterval] = []
            let frames = animation.frames
            for frame in frames {
                starts.append(duration)
                duration += frame.duration
            }
            return Track(layerID: layer.id, name: layer.name, animation: animation,
                         indices: frames.map(\.index), starts: starts, duration: duration)
        }
        duration = tracks.map(\.duration).max() ?? 0
    }

    func nextChange(after time: TimeInterval) -> TimeInterval {
        tracks.reduce(duration) { next, track in
            let position = track.position(at: time) + 1
            return position < track.starts.count ? min(next, track.starts[position]) : next
        }
    }
}
