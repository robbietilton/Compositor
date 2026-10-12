import SwiftUI

struct PenControls: View {
    @Bindable var session: EditorSession

    var body: some View {
        HStack(spacing: 12) {
            Text(L10n.string("Pen")).font(ToolHeaderStyle.titleFont)
            Picker(L10n.string("Mode"), selection: Binding(get: { session.penMode }, set: { mode in
                session.cancelPen()
                session.penMode = mode
            })) {
                ForEach(PenMode.allCases, id: \.self) { Text(L10n.string($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help(Text(L10n.string("Shape closes and fills the path; Line keeps an open stroked path")))
            if session.penMode == .line || session.editablePenLine != nil {
                HStack(spacing: 6) {
                    Text(L10n.string("Width")).scrubbable(sensitivity: 1, value: lineWidth, range: 1...5000,
                        onStart: { session.beginPenLineWidthEdit() }, onEnd: { session.finishPenLineWidthEdit() })
                    Slider(value: Binding(get: { min(100, session.currentPenLineWidth) },
                                          set: { session.setPenLineWidth($0.rounded()) }), in: 1...100,
                           onEditingChanged: { $0 ? session.beginPenLineWidthEdit() : session.finishPenLineWidthEdit() })
                        .frame(width: 100)
                    TextField(L10n.string("Width"), value: lineWidth,
                              format: .number.precision(.fractionLength(0)))
                        .frame(width: 48).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                        .arrowSteps(value: { session.currentPenLineWidth },
                                    change: { session.setPenLineWidth($0) })
                        .unitSuffix("px")
                }
            }
            HStack(spacing: 6) {
                Text(L10n.string(session.penMode == .shape ? "Fill" : "Stroke"))
                Button { session.openColorPicker(background: false) } label: {
                    let swatch = RoundedRectangle(cornerRadius: 3, style: .continuous)
                    swatch.fill(Color(nsColor: session.foregroundColor.nsColor))
                        .overlay { swatch.strokeBorder(.black.opacity(0.5), lineWidth: 1) }
                        .frame(width: 36, height: 18)
                }
                .buttonStyle(.plain)
                .help(Text(L10n.string("Use the foreground color")))
            }
            if session.editablePenLine != nil {
                Button { _ = session.deleteSelectedPenNode() } label: {
                    Label(L10n.string("Delete Anchor"), systemImage: "minus.circle")
                }
                .disabled(!session.canDeleteSelectedPenNode)
                .help(Text(L10n.string("Select an anchor on the canvas, then remove it")))
            }
            Text(L10n.string(session.editablePenLine == nil
                ? "Click for a corner · Drag for a curve"
                : "Click the line to add an anchor · Drag an anchor to move · Delete removes it"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).toolHeaderBar().releasesFocusOnCommit(session)
        .disabled(session.showsBusy || session.document == nil)
    }

    private var lineWidth: Binding<Double> {
        Binding(get: { session.currentPenLineWidth }, set: { session.setPenLineWidth($0) })
    }
}
