import SwiftUI

/// Unscaled delays shared by the timeline and Export As. Original timing stays visible beside each field.
struct GIFFrameDelaysPopover: View {
    let frames: [GIFTimelineFrame]
    @Binding var timing: GIFFrameTiming
    @Binding var drafts: [Int: String]
    var scope = "Export only"
    @FocusState private var focusedFrame: Int?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Frame delays").font(.headline)
                Spacer()
                Button("Reset All") { drafts = [:]; timing.frameDelays = [:] }
                    .disabled(timing.frameDelays.isEmpty)
                    .help("Restore every frame's imported delay.")
            }
            Text("Delays before playback speed is applied.").foregroundStyle(.secondary)
            Divider()
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(frames.enumerated()), id: \.element.index) { position, frame in
                        HStack(spacing: 8) {
                            Text("Frame \(position + 1)").frame(width: 70, alignment: .leading)
                                .scrubbable(sensitivity: 10, value: milliseconds(for: frame), range: 20...655_350, step: 10)
                            GIFDelayField(milliseconds: milliseconds(for: frame), draft: Binding(
                                get: { drafts[frame.index] }, set: { drafts[frame.index] = $0 }),
                                focus: $focusedFrame, index: frame.index)
                                .frame(width: 80)
                                .accessibilityLabel("Frame \(position + 1) delay in milliseconds")
                                .accessibilityIdentifier("gifExportFrameDelay\(position + 1)")
                            Spacer(minLength: 0)
                            Text("Original \((frame.duration * 1000).formatted(.number.precision(.fractionLength(0...2)))) ms")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }.padding(.vertical, 2)
            }.frame(height: min(260, CGFloat(frames.count) * 38))
            Divider()
            HStack {
                Text(scope).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { finishEdits(); focusedFrame = nil; dismiss() }
            }
        }
        .padding(16).frame(width: 370).roundedControls()
    }

    private func finishEdits() {
        timing = Self.confirmedTiming(timing, drafts: drafts, frames: frames)
        drafts = [:]
    }

    /// The presenter also finishes pending text when macOS dismisses the popover directly.
    static func confirmedTiming(_ timing: GIFFrameTiming, drafts: [Int: String], frames: [GIFTimelineFrame]) -> GIFFrameTiming {
        var updated = timing
        for frame in frames where drafts[frame.index] != nil {
            let previous = (timing.frameDelays[frame.index] ?? frame.duration) * 1000
            let value = GIFDelayField.confirmedMilliseconds(drafts[frame.index], previous: previous)
            guard value != previous else { continue }
            let delay = value / 1000
            if delay == frame.duration { updated.frameDelays.removeValue(forKey: frame.index) }
            else { updated.frameDelays[frame.index] = delay }
        }
        return updated
    }

    private func milliseconds(for frame: GIFTimelineFrame) -> Binding<Double> {
        Binding(get: { (timing.frameDelays[frame.index] ?? frame.duration) * 1000 }, set: { value in
            let delay = value / 1000
            if delay == frame.duration { timing.frameDelays.removeValue(forKey: frame.index) }
            else { timing.frameDelays[frame.index] = delay }
        })
    }
}
