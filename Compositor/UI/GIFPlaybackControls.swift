import SwiftUI

struct GIFPlaybackControls: View {
    let layerName: String
    let isPlaying: Bool
    let playbackScope: GIFPlaybackScope
    let canPlay: Bool
    let headerViewportWidth: CGFloat
    let onTogglePlayback: () -> Void
    let onChangePlaybackScope: (GIFPlaybackScope) -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onTogglePlayback) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(canPlay || isPlaying ? Color.green : Color.secondary)
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canPlay && !isPlaying)
            .help(playbackButtonHelp)
            .accessibilityLabel(isPlaying ? "Pause animation playback" : (playbackScope == .all ? "Play all visible animations" : "Play \(layerName) in a loop"))
            .accessibilityValue(isPlaying ? "Playing" : "Paused")
            .accessibilityIdentifier("gifTimelinePlayback")
            Button { onChangePlaybackScope(playbackScope == .all ? .selected : .all) } label: {
                Text(playbackScopeLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(playbackScope == .all ? Color.accentColor : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Reserve Play's 24-point hit area and the 2-point gap in narrow headers.
                    .frame(maxWidth: max(0, min(140, headerViewportWidth - 26)), alignment: .leading)
                    .frame(height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(playbackScope == .all ? "Play all visible animations together. Click to play “\(layerName)” only." : "Play “\(layerName)” only. Click to play all visible animations together.")
            .accessibilityLabel("Animation playback scope")
            .accessibilityValue(playbackScope == .all ? "All" : layerName)
            .accessibilityIdentifier("gifPlaybackScope")
        }
    }

    private var playbackScopeLabel: String {
        if playbackScope == .all { return "All" }
        return layerName.count > 13 ? String(layerName.prefix(13)) + "…" : layerName
    }

    private var playbackButtonHelp: String {
        if isPlaying { return "Pause animation playback." }
        return playbackScope == .all ? "Play visible animations together; shorter animations hold their last frame until the longest ends." : "Play the animation in a continuous loop."
    }
}

struct GIFPlaybackSpeedControl: View {
    let playbackSpeed: GIFPlaybackSpeed
    let canPlay: Bool
    let onChangePlaybackSpeed: (GIFPlaybackSpeed) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Slider(value: Binding(get: { playbackSpeed.position }, set: { position in
                onChangePlaybackSpeed(GIFPlaybackSpeed(position: abs(position) < 0.05 ? 0 : position))
            }), in: GIFPlaybackSpeed.sliderRange)
                .controlSize(.mini)
                .tint(Color(white: 0.76))
                .frame(minWidth: 60, idealWidth: 100, maxWidth: 100)
                .disabled(!canPlay)
                .help("Drag to change playback speed.")
                .accessibilityLabel("Animation playback speed")
                .accessibilityValue("\(playbackSpeed.multiplier.formatted(.number.precision(.fractionLength(1...2)))) times")
                .accessibilityIdentifier("gifPlaybackSpeed")
            Button { onChangePlaybackSpeed(GIFPlaybackSpeed()) } label: {
                Text("\(playbackSpeed.multiplier.formatted(.number.precision(.fractionLength(1...2))))×")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 22, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canPlay)
            .help("Reset playback speed to 1.0×.")
            .accessibilityLabel("Reset animation playback speed")
            .accessibilityValue("\(playbackSpeed.multiplier.formatted(.number.precision(.fractionLength(1...2)))) times")
            .accessibilityIdentifier("gifPlaybackSpeedValue")
        }
        .accessibilityElement(children: .contain)
    }
}
