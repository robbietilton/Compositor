import SwiftUI

/// A GIF layer's frames under the canvas: play and pause, one delay for every frame, and a strip of thumbnails. A click
/// shows a frame, which painting and filters then change; right-click duplicates or deletes it.
struct GIFTimeline: View {
    let frames: [GIFTimelineFrame]
    let selectedFrameIndex: Int
    let isPlaying: Bool
    let canPlay: Bool
    let timing: GIFFrameTiming
    let canEditFrames: Bool
    let canEditTiming: Bool
    let onSelectFrame: (Int) async -> Void
    let onTogglePlayback: () -> Void
    let onStopPlayback: () -> Void
    let onChangeTiming: (GIFFrameTiming) -> Void
    let onDuplicateFrame: (Int) async -> Void
    let onDeleteFrame: (Int) async -> Void

    /// The delay every frame shows for, in milliseconds: the one set here, or the GIF's own usual one.
    private var delay: Double {
        (timing.mode == .uniform ? timing.uniformDelay : GIFFrameTiming.defaultUniformDelay(for: frames)) * 1000
    }

    @State private var requestedFrame: Int?

    private var shownFrame: Int { requestedFrame ?? selectedFrameIndex }
    private var frameNumber: Int { (frames.firstIndex { $0.index == shownFrame } ?? 0) + 1 }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { scroller in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(Array(frames.enumerated()), id: \.element.id) { position, frame in
                            thumbnail(frame, number: position + 1)
                        }
                    }
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 6)
                }
                .frame(height: 88)
                .onChange(of: shownFrame, initial: true) { _, index in
                    scroller.scrollTo(index)
                }
            }
            Divider()
            playbackBar
        }
        // Decoding must not lengthen the layer's saved frame delays.
        .task(id: Playback(isPlaying: isPlaying, frames: frames.map(\.index), timing: timing)) { await play() }
        .task(id: requestedFrame != nil) {
            // Finish one decode at a time. A fast drag replaces any intermediate request with the latest frame.
            while let index = requestedFrame, !Task.isCancelled {
                await onSelectFrame(index)
                guard !Task.isCancelled else { return }
                if requestedFrame == index { requestedFrame = nil }
            }
        }
        .onChange(of: canPlay) { if !canPlay, isPlaying { onStopPlayback() } }
        .onDisappear { onStopPlayback() }
    }

    private var playbackBar: some View {
        HStack(spacing: 8) {
            Button(action: onTogglePlayback) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 20, height: 18)
            }
            .disabled(!canPlay || requestedFrame != nil)
            .help(isPlaying ? "Pause" : "Play")
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

            Menu { delayMenu } label: {
                Text(timing.mode == .uniform ? "\(Int(delay.rounded())) ms" : originalDelays())
                    .monospacedDigit()
            }
            .menuStyle(.button).buttonStyle(.bordered).menuIndicator(.hidden).fixedSize()
            .disabled(!canEditTiming)
            .help("How long each frame shows")
            .accessibilityLabel("Frame delay")
            .accessibilityValue(timing.mode == .uniform ? "\(Int(delay.rounded())) ms" : originalDelays())

            AppSlider(value: Binding(get: { Double(frameNumber) }, set: { value in
                let position = Int(value) - 1
                if frames.indices.contains(position) { requestFrame(frames[position].index) }
            }), in: 1...Double(max(1, frames.count)), step: 1)
            .disabled(frames.count < 2)
            .accessibilityLabel("GIF frame")

            Text(String(format: "%02d / %02d", frameNumber, frames.count))
                .monospacedDigit()
                .accessibilityLabel("Frame \(frameNumber) of \(frames.count)")
        }
        .padding(.horizontal, 10)
        .frame(height: LayersFooter.height)
    }

    private func requestFrame(_ index: Int) {
        if isPlaying { onStopPlayback() }
        guard index != shownFrame else { return }
        requestedFrame = index
    }

    private struct Playback: Equatable {
        let isPlaying: Bool
        let frames: [Int]
        let timing: GIFFrameTiming
    }

    func play<C: Clock>(clock: C = ContinuousClock()) async where C.Duration == Duration {
        guard isPlaying, frames.count > 1 else { return }
        let durations = frames.map { max(GIFTimelineLimits.minimumFrameDuration, timing.delay(for: $0)) }
        let initial = frames.firstIndex { $0.index == selectedFrameIndex } ?? 0
        do {
            try await GIFPreviewPlayback.play(durations: durations, startingAt: initial, clock: clock) { position in
                await onSelectFrame(frames[position].index)
            }
        } catch is CancellationError { }
        catch { onStopPlayback() }
    }

    private func thumbnail(_ frame: GIFTimelineFrame, number: Int) -> some View {
        let selected = frame.index == shownFrame
        let box = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return VStack(spacing: 4) {
            Image(decorative: frame.thumbnail, scale: 1)
                .resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                .frame(width: 56, height: 56)
                .background(Color.black.opacity(0.25), in: box)
                .overlay { box.strokeBorder(selected ? Color.accentColor : Color.white.opacity(0.12), lineWidth: selected ? 2 : 1) }
            Text("\(number)").font(.caption2.monospacedDigit()).foregroundStyle(selected ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { requestFrame(frame.index) }
        .contextMenu {
            Button("Duplicate Frame") { Task { await onDuplicateFrame(frame.index) } }.disabled(!canEditFrames)
            Button("Delete Frame") { Task { await onDeleteFrame(frame.index) } }.disabled(!canEditFrames || frames.count < 2)
        }
        .id(frame.index)
        .accessibilityLabel("Frame \(number)")
    }

    /// Every frame for the same time, from a fast 20 ms up to a second, or each for the GIF's own.
    @ViewBuilder private var delayMenu: some View {
        Toggle("\(originalDelays()) · Original", isOn: Binding(get: { timing.mode != .uniform }, set: { on in
            guard on else { return }
            var original = timing
            original.mode = .perFrame
            onChangeTiming(original)
        }))
        Divider()
        ForEach([20, 33, 40, 50, 67, 80, 100, 125, 150, 200, 250, 500, 1000], id: \.self) { milliseconds in
            Toggle("\(milliseconds) ms · \(fps(milliseconds)) fps", isOn: Binding(
                get: { timing.mode == .uniform && Int(delay.rounded()) == milliseconds },
                set: { if $0 { setDelay(Double(milliseconds)) } }))
        }
    }

    /// The GIF's own delays: one, or the shortest to the longest when its frames differ.
    private func originalDelays() -> String {
        let delays = frames.map { Int(((timing.frameDelays[$0.index] ?? $0.duration) * 1000).rounded()) }
        guard let shortest = delays.min(), let longest = delays.max() else { return "" }
        return (shortest == longest ? "\(shortest)" : "\(shortest)–\(longest)") + " ms"
    }

    private func fps(_ milliseconds: Int) -> String {
        (1000 / Double(milliseconds)).formatted(.number.precision(.fractionLength(0...1)))
    }

    /// One delay for every frame, kept within what GIF can store.
    private func setDelay(_ milliseconds: Double) {
        guard milliseconds.isFinite else { return }
        var timing = timing
        timing.mode = .uniform
        timing.uniformDelay = min(GIFFrameTiming.delayRange.upperBound, max(GIFFrameTiming.delayRange.lowerBound, milliseconds / 1000))
        onChangeTiming(timing)
    }
}
