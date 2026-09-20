import SwiftUI

struct LayerAppearanceControls: View {
    @Bindable var session: EditorSession
    let layerID: UUID?
    @State private var percentage = "100"
    @State private var stepper = ArrowStepper()
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(L10n.string("Blend")).font(.caption)
                BlendModePicker(session: session)
            }
            HStack(spacing: 6) {
                Text(L10n.string("Opacity")).font(.caption)
                Slider(value: Binding(get: { session.activeLayer?.opacity ?? 1 },
                                      set: { session.setLayerOpacity($0) }), in: 0...1,
                       onEditingChanged: { if $0 { session.beginOpacityEdit() } else { session.finishOpacityEdit() } })
                HStack(spacing: 2) {
                    TextField(L10n.string("Opacity percent"), text: $percentage)
                        .textFieldStyle(.roundedBorder).frame(width: 44).focused($focused)
                        .onSubmit { releaseFocus() }
                        .onExitCommand { releaseFocus() }
                        .onChange(of: focused) { _, isFocused in if !isFocused { applyPercentage() } }
                        .arrowSteps(editing: focused, stepper: stepper,
                                    value: { ((session.activeLayer?.opacity ?? 1) * 100).rounded() },
                                    change: { step($0) })
                    Text("%").font(.caption)
                }
            }
        }.padding(12).disabled(!session.canEditAppearance)
            .onAppear { sync() }
            .onChange(of: session.activeLayer?.opacity) { _, _ in if !focused { sync() } }
            .onDisappear { session.finishOpacityEdit() }
    }
    /// Up and Down nudge the opacity by one percent, or ten with Shift.
    private func step(_ percent: Double) {
        guard session.activeLayerID == layerID else { return }
        session.setLayerOpacity(min(100, max(0, percent)) / 100)
        sync()
    }
    /// Losing focus applies the value; the canvas takes the focus back so a tool's key works straight away.
    private func releaseFocus() {
        focused = false
        session.canvasFocusRequest += 1
    }
    private func sync() { percentage = String(Int(((session.activeLayer?.opacity ?? 1) * 100).rounded())) }
    private func applyPercentage() {
        guard session.activeLayerID == layerID else { return }
        if let value = Double(percentage), value.isFinite { session.setLayerOpacity(value / 100) }
        sync()
    }
}
