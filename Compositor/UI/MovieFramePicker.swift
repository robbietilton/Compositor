import AppKit
import SwiftUI
import CoreImage
import AVFoundation

nonisolated struct MovieLink: Codable, Equatable, Sendable {
    let bookmark: Data
    let duration: Double
    var seconds: Double
}

@MainActor
enum MovieFramePicker {
    static func open(_ url: URL, remainingPixels: Int) async throws -> (MovieLink, ImportedImage) {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard try await asset.load(.isPlayable),
              let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ImageImportError.unsupported
        }
        let size = try await track.load(.naturalSize)
        let range = try await track.load(.timeRange)
        guard size.width > 0, size.height > 0, max(size.width, size.height) <= CGFloat(DocumentLimits.maxSide),
              size.width * size.height <= CGFloat(remainingPixels) else { throw ImageImportError.tooLarge }
        guard range.duration.isNumeric, range.duration > .zero else { throw ImageImportError.unreadable }
        let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        let link = MovieLink(bookmark: bookmark, duration: range.duration.seconds, seconds: 0)
        let first = try await frame(in: asset, at: range.start, range: range, name: url.deletingPathExtension().lastPathComponent, remainingPixels: remainingPixels)
        return (link, first)
    }

    static func frame(in asset: AVAsset, at time: CMTime, range: CMTimeRange, name: String,
                      remainingPixels: Int) async throws -> ImportedImage {
        let generator = frameGenerator(for: asset)
        let image = try await generator.image(at: frameTime(time, in: range)).image
        guard max(image.width, image.height) <= DocumentLimits.maxSide,
              image.width * image.height <= remainingPixels else { throw ImageImportError.tooLarge }
        return ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: name)
    }

    static func frameGenerator(for asset: AVAsset) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return generator
    }

    static func frameTime(_ time: CMTime, in range: CMTimeRange) -> CMTime {
        // The end of the track is exclusive. Scrubbing all the way right selects its last frame.
        let last = range.end - CMTime(value: 1, timescale: max(range.end.timescale, 60000))
        return max(range.start, min(time.isNumeric ? time : range.start, last))
    }
}

struct MovieTimeline: View {
    let session: EditorSession
    let layer: ImageLayer
    let link: MovieLink
    @State private var job: Task<Void, Never>?
    @State private var requested: Double?
    @AppStorage("moviePlaybackMuted") private var muted = false
    @State private var dragging = false
    @State private var failure: String?
    @State private var reader: AVURLAsset?
    @State private var scopedURL: URL?

    private static let frameContext = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull()])

    @State private var scrubPlayer: AVPlayer?
    @State private var scrubRange: CMTimeRange?
    @State private var scrubJob: Task<Void, Never>?

    var body: some View {
        HStack {
            Button { togglePlayback() } label: {
                controlIcon(observer == nil ? "play.fill" : "pause.fill")
            }
            .accessibilityLabel(observer == nil ? "Play" : "Pause")
            Button { muted.toggle() } label: {
                controlIcon(muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
                .accessibilityLabel(muted ? "Unmute movie" : "Mute movie")
                .help(muted ? "Unmute movie" : "Mute movie")
            AppSlider(value: Binding(get: { requested ?? link.seconds }, set: { if dragging { scrub($0) } else { seek($0) } }),
                      in: 0...link.duration, onEditingChanged: { editing in
                if editing { job?.cancel(); job = nil; stopPlayback() }
                dragging = editing
                if !editing { seek(requested ?? link.seconds) }
            })
            .accessibilityLabel("Movie playhead")
            Text(Duration.seconds(requested ?? link.seconds).formatted(.time(pattern: .minuteSecond(padMinuteToLength: 1, fractionalSecondsLength: 2))))
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .frame(height: LayersFooter.height)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Grab Frame") { grab() }.disabled(job != nil || observer != nil || !session.canEditLayers)
            Button("Relink…") { relink() }
        }
        .onChange(of: muted) { _, value in
            if let playback = session.moviePlayback, playback.id == layer.id { playback.player.isMuted = value }
        }
        .overlay(alignment: .topLeading) { if let failure { Text(failure).font(.caption).offset(y: -15) } }
        .task(id: session.moviePlayback.map { ObjectIdentifier($0.player) }) {
            guard let playback = session.moviePlayback, playback.id == layer.id else { return }
            await showFrames(from: playback.player)
        }
        .onDisappear { stopPlayback(); job?.cancel(); session.moviePreview = nil; releaseSource() }
    }

    private func showFrames(from player: AVPlayer) async {
        guard let item = player.currentItem, let poster = layer.asset,
              let tracks = try? await item.asset.loadTracks(withMediaType: .video),
              let track = tracks.first, let transform = try? await track.load(.preferredTransform),
              !Task.isCancelled else { return }
        if let hdrTracks = try? await item.asset.loadTracks(withMediaCharacteristic: .containsHDRVideo),
           hdrTracks.contains(where: { $0.trackID == track.trackID }),
           let range = try? await track.load(.timeRange) {
            await showHDRFrames(from: player, asset: item.asset, range: range, poster: poster)
            return
        }
        guard !Task.isCancelled else { return }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        defer { item.remove(output) }
        // Track transforms use a top-left origin. Core Image uses a bottom-left origin.
        let orientation = CGAffineTransform(a: transform.a, b: -transform.b, c: -transform.c, d: transform.d, tx: 0, ty: 0)
        while !Task.isCancelled, session.moviePlayback?.player === player {
            let time = player.rate == 0 ? player.currentTime() : output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: time),
               let pixels = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                let image = CIImage(cvPixelBuffer: pixels).transformed(by: orientation)
                // Keep the decoder's RGB values and profile together, as the still generator does.
                if let rendered = Self.frameContext.createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: nil) {
                    let frame = CVImageBufferGetColorSpace(pixels).flatMap { rendered.copy(colorSpace: $0.takeUnretainedValue()) } ?? rendered
                    session.moviePreview = (layer.id, ImportedImage(image: frame, thumbnail: poster.thumbnail, name: poster.name))
                }
            }
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
        }
    }

    private func showHDRFrames(from player: AVPlayer, asset: AVAsset, range: CMTimeRange, poster: ImportedImage) async {
        // Use the same native HDR conversion as a paused frame. A single reusable generator
        // decodes at preview size, and each request follows the player's current clock.
        let generator = MovieFramePicker.frameGenerator(for: asset)
        generator.maximumSize = CGSize(width: 960, height: 960)
        let clock = ContinuousClock()
        var previous = CMTime.invalid
        while !Task.isCancelled, session.moviePlayback?.player === player {
            let nextRefresh = clock.now + .milliseconds(33)
            let current = MovieFramePicker.frameTime(player.currentTime(), in: range)
            let time = player.rate == 0 ? current
                : range.start + CMTimeConvertScale(current - range.start, timescale: 30, method: .roundTowardZero)
            if !previous.isValid || time != previous {
                previous = time
                if let result = try? await generator.image(at: time),
                   !Task.isCancelled, session.moviePlayback?.player === player {
                    session.moviePreview = (layer.id, ImportedImage(image: result.image, thumbnail: poster.thumbnail, name: poster.name))
                }
            }
            do { try await clock.sleep(until: nextRefresh) } catch { return }
        }
    }

    private func controlIcon(_ name: String) -> some View {
        Image(systemName: name)
            .frame(width: 20, height: 18)
    }

    private func releaseSource() {
        cancelScrub()
        scrubPlayer = nil
        scrubRange = nil
        reader = nil
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    @State private var observer: Any?
    @State private var playbackStart = CMTime.zero
    private func source() throws -> AVURLAsset {
        if reader == nil {
            var stale = false
            let url = try URL(resolvingBookmarkData: link.bookmark, options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            if url.startAccessingSecurityScopedResource() { scopedURL = url }
            reader = AVURLAsset(url: url)
        }
        guard let reader else { throw ImageImportError.unreadable }
        return reader
    }

    private func stopPlayback(keepFrame: Bool = false) {
        guard let playback = session.moviePlayback, playback.id == layer.id else { return }
        playback.player.pause()
        if let observer { playback.player.removeTimeObserver(observer) }
        observer = nil
        if !keepFrame { session.moviePlayback = nil }
    }

    private func togglePlayback() {
        if observer != nil, let playback = session.moviePlayback, playback.id == layer.id {
            playback.player.pause()
            seek(max(0, (playback.player.currentTime() - playbackStart).seconds), keepFrame: true)
            return
        }
        job?.cancel()
        job = Task {
            do {
                let asset = try source()
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else { throw ImageImportError.unreadable }
                let range = try await track.load(.timeRange)
                let item = AVPlayerItem(asset: asset)
                item.forwardPlaybackEndTime = range.end
                let player = AVPlayer(playerItem: item)
                let seconds = requested ?? link.seconds
                let start = seconds >= link.duration ? 0 : seconds
                await player.seek(to: range.start + CMTime(seconds: start, preferredTimescale: 600000), toleranceBefore: .zero, toleranceAfter: .zero)
                try Task.checkCancellation()
                player.isMuted = muted
                playbackStart = range.start
                session.moviePlayback = (layer.id, player)
                observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 24), queue: .main) { time in
                    MainActor.assumeIsolated {
                        guard observer != nil, session.moviePlayback?.player === player else { return }
                        requested = min(link.duration, max(0, (time - range.start).seconds))
                        if time >= range.end { seek(link.duration, keepFrame: true) }
                        else if item.status == .failed { stopPlayback(); failure = item.error?.localizedDescription }
                    }
                }
                failure = nil
                player.play()
            } catch {
                guard !Task.isCancelled else { return }
                failure = "Movie unavailable. Right-click the timeline to relink and play."
            }
            job = nil
        }
    }

    private func cancelScrub() {
        scrubJob?.cancel()
        scrubJob = nil
        scrubPlayer?.currentItem?.cancelPendingSeeks()
    }

    // Keep one decoder warm while dragging. If the pointer moves during a seek, jump
    // straight to its newest position once that seek finishes.
    private func scrub(_ seconds: Double) {
        requested = seconds
        guard scrubJob == nil else { return }
        scrubJob = Task {
            do {
                if scrubPlayer == nil {
                    let asset = try source()
                    guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ImageImportError.unreadable }
                    let range = try await track.load(.timeRange)
                    try Task.checkCancellation()
                    let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                    player.isMuted = true
                    scrubRange = range
                    scrubPlayer = player
                }
                guard let player = scrubPlayer, let range = scrubRange else { return }
                if session.moviePlayback?.player !== player { session.moviePlayback = (layer.id, player) }
                while let target = requested {
                    try Task.checkCancellation()
                    let time = range.start + CMTime(seconds: target, preferredTimescale: 600000)
                    let tolerance = CMTime(value: 1, timescale: 12)
                    await player.seek(to: min(time, range.end - CMTime(value: 1, timescale: 600000)),
                                      toleranceBefore: tolerance, toleranceAfter: tolerance)
                    if requested == target { break }
                }
            } catch {
                if !Task.isCancelled { failure = "Movie unavailable. Right-click the timeline to relink and scrub." }
            }
            if !Task.isCancelled { scrubJob = nil }
        }
    }

    private func seek(_ seconds: Double, keepFrame: Bool = false) {
        cancelScrub()
        stopPlayback(keepFrame: keepFrame)
        job?.cancel()
        requested = seconds
        job = Task {
            do {
                let reader = try source()
                let tracks = try await reader.loadTracks(withMediaType: .video)
                guard let track = tracks.first else { throw ImageImportError.unreadable }
                let range = try await track.load(.timeRange)
                let time = range.start + CMTime(seconds: seconds, preferredTimescale: 600000)
                try Task.checkCancellation()
                let frame = try await MovieFramePicker.frame(in: reader, at: time, range: range, name: layer.name,
                                                             remainingPixels: DocumentLimits.documentPixelBudget)
                try Task.checkCancellation()
                guard session.activeLayerID == layer.id, let index = session.document?.layers.firstIndex(where: { $0.id == layer.id }) else { return }
                failure = nil
                session.beginEdit("Select Movie Frame")
                session.document?.layers[index].asset = frame
                session.document?.layers[index].movie?.seconds = min(link.duration, max(0, (time - range.start).seconds))
                session.endEdit()
                session.moviePreview = nil
                if keepFrame { stopPlayback() }
                requested = nil
            } catch {
                guard !Task.isCancelled else { return }
                if keepFrame { stopPlayback() }
                failure = "Movie unavailable. Right-click the timeline to relink and scrub."
                requested = nil
                session.moviePreview = nil
            }
            if !Task.isCancelled { job = nil }
        }
    }

    private func grab() {
        guard let index = session.document?.layers.firstIndex(where: { $0.id == layer.id }), let asset = layer.asset else { return }
        let layers = session.document?.layers ?? []
        let usedPixels = layers.reduce(0) { sum, layer in
            sum + (layer.asset.map { $0.image.width * $0.image.height } ?? 0)
                + (layer.gifAnimation?.framePixels.values.reduce(0) { $0 + $1.image.width * $1.image.height } ?? 0)
        }
        guard layers.count < 10000, asset.image.width * asset.image.height <= DocumentLimits.documentPixelBudget - usedPixels else {
            session.importError = ImageImportError.tooLarge.localizedDescription
            return
        }
        session.moviePreview = nil
        var still = ImageLayer(asset: asset, origin: layer.origin)
        still.name = "\(layer.name) · \(Duration.seconds(link.seconds).formatted(.time(pattern: .minuteSecond(padMinuteToLength: 1, fractionalSecondsLength: 2))))"
        still.transform = layer.transform
        still.parentID = layer.parentID
        session.beginEdit("Grab Movie Frame")
        session.document?.layers.insert(still, at: index + 1)
        session.endEdit()
    }

    private func relink() {
        stopPlayback()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        job?.cancel()
        job = Task {
            defer { if !Task.isCancelled { job = nil } }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let (replacement, frame) = try await MovieFramePicker.open(url, remainingPixels: DocumentLimits.documentPixelBudget)
                guard !Task.isCancelled, let index = session.document?.layers.firstIndex(where: { $0.id == layer.id }) else { return }
                releaseSource()
                session.beginEdit("Relink Movie")
                session.document?.layers[index].movie = replacement
                session.document?.layers[index].asset = frame
                session.endEdit()
                requested = nil
                failure = nil
            } catch { failure = error.localizedDescription }
        }
    }
}
