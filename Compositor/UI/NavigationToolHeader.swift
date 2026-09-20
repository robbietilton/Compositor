import SwiftUI

struct NavigationToolHeader: View {
    @Bindable var session: EditorSession
    @State private var zoomText = ""
    @State private var displayedZoomText = ""
    @State private var stepper = ArrowStepper()
    @FocusState private var editingZoom: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(session.tool == .hand ? L10n.string("Pan") : L10n.string("Zoom")).font(ToolHeaderStyle.titleFont)
            if session.tool == .zoom {
                TextField(L10n.string("Zoom"), text: $zoomText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                    .multilineTextAlignment(.trailing)
                    .focused($editingZoom)
                    .onSubmit { releaseFocus() }
                    .onExitCommand { releaseFocus() }
                    .onChange(of: editingZoom) { _, focused in if !focused { applyZoom() } }
                    .arrowSteps(editing: editingZoom, stepper: stepper,
                                value: { Double(zoomText.filter { $0.isNumber || $0 == "." }) ?? Double(session.viewport.zoom * 100) },
                                change: { step($0) })
                    .accessibilityLabel(L10n.string("Zoom percentage"))
                    .help(L10n.string("Zoom percentage (0.1–3200%). Press Return to apply."))
                    .disabled(session.document == nil || session.showsBusy)
                    .unitSuffix("%")
            }
            Spacer()
        }
        .padding(.horizontal, 18).toolHeaderBar()
        .onAppear { syncZoom() }
        .onChange(of: session.viewport.zoom) { _, _ in
            if !editingZoom { syncZoom() }
        }
    }

    /// Up and Down nudge the zoom by one percent, or ten with Shift.
    private func step(_ percent: Double) {
        zoomText = String(format: "%g", min(3200, max(0.1, percent)))
        applyZoom()
    }
    /// Losing focus applies the zoom; the canvas takes the focus back so a tool's key works straight away.
    private func releaseFocus() {
        editingZoom = false
        session.canvasFocusRequest += 1
    }
    private func applyZoom() {
        defer { syncZoom() }
        guard zoomText != displayedZoomText else { return }
        let text = zoomText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "%", with: "")
        if let value = Double(text), value.isFinite, value > 0, !session.isProjectBusy {
            session.zoom(to: CGFloat(value / 100))
        }
    }

    private func syncZoom() {
        zoomText = String(format: "%.2f", Double(session.viewport.zoom * 100))
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
        displayedZoomText = zoomText
    }
}
