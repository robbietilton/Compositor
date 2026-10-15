import SwiftUI

/// Numeric drafts commit when the field is left; the shared frame editor commits as one undoable change.
struct GIFDelayControls: View {
    let frames: [GIFTimelineFrame]
    let timing: GIFFrameTiming
    let canEdit: Bool
    let onStopPlayback: () -> Void
    let onChange: (GIFFrameTiming) -> Void
    @State private var uniformDraft: String?
    @State private var frameDraft = GIFFrameTiming()
    @State private var frameDelayDrafts: [Int: String] = [:]
    @State private var showsFrameDelays = false
    @FocusState private var focusedDelay: Int?

    var body: some View {
        HStack(spacing: 8) {
            Picker("Delay", selection: Binding(get: { timing.mode }, set: { mode in
                var updated = timing
                let previous = timing.uniformDelay * 1000
                let value = GIFDelayField.confirmedMilliseconds(uniformDraft, previous: previous)
                if value != previous { updated.uniformDelay = value / 1000 }
                self.uniformDraft = nil
                focusedDelay = nil
                updated.mode = mode
                onChange(updated)
            })) {
                ForEach(GIFDelayMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 170)
            .help("Use each frame's delay or one delay for every frame.")
            .accessibilityIdentifier("gifTimelineDelayMode")
            if timing.mode == .uniform {
                GIFDelayField(milliseconds: Binding(get: { timing.uniformDelay * 1000 }, set: { value in
                    var updated = timing
                    updated.uniformDelay = value / 1000
                    onChange(updated)
                }), draft: $uniformDraft, focus: $focusedDelay, index: 0, step: 1, alignment: .leading, unitSpacing: 8)
                    .frame(width: 88)
                    .help("Delay for every frame in milliseconds, before preview speed is applied.")
                    .accessibilityLabel("Delay for every frame in milliseconds")
                    .accessibilityIdentifier("gifTimelineUniformDelay")
            } else {
                Button("Edit…") {
                    onStopPlayback()
                    frameDraft = timing
                    frameDelayDrafts = [:]
                    showsFrameDelays = true
                }
                .help("Edit individual frame delays.")
                .accessibilityIdentifier("gifTimelineEditDelays")
                .popover(isPresented: $showsFrameDelays) {
                    GIFFrameDelaysPopover(frames: frames, timing: $frameDraft, drafts: $frameDelayDrafts,
                                          scope: "Saved with this animation layer")
                }
                .onChange(of: showsFrameDelays) { wasShown, isShown in
                    if wasShown, !isShown {
                        let updated = GIFFrameDelaysPopover.confirmedTiming(frameDraft, drafts: frameDelayDrafts, frames: frames)
                        frameDelayDrafts = [:]
                        onChange(updated)
                    }
                }
            }
        }
        .font(ToolHeaderStyle.controlFont)
        .roundedControls()
        .disabled(!canEdit)
        .onDisappear { finishUniformDelay() }
    }

    private func finishUniformDelay() {
        guard let uniformDraft else { return }
        let previous = timing.uniformDelay * 1000
        let value = GIFDelayField.confirmedMilliseconds(uniformDraft, previous: previous)
        self.uniformDraft = nil
        guard value != previous else { return }
        var updated = timing
        updated.uniformDelay = value / 1000
        onChange(updated)
    }
}
