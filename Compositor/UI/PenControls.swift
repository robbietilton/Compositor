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
            if session.penMode == .line {
                HStack(spacing: 6) {
                    Text(L10n.string("Width")).scrubbable(sensitivity: 1, value: $session.penLineWidth, range: 1...5000)
                    Slider(value: Binding(get: { min(100, session.penLineWidth) },
                                          set: { session.penLineWidth = $0.rounded() }), in: 1...100)
                        .frame(width: 100)
                    TextField(L10n.string("Width"), value: Binding(get: { session.penLineWidth },
                                                      set: { session.penLineWidth = $0.isFinite ? min(5000, max(1, $0)) : 4 }),
                              format: .number.precision(.fractionLength(0)))
                        .frame(width: 48).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                        .arrowSteps(value: { session.penLineWidth },
                                    change: { session.penLineWidth = min(5000, max(1, $0)) })
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
            Text(L10n.string("Click for a corner · Drag for a curve"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).toolHeaderBar().releasesFocusOnCommit(session)
        .disabled(session.showsBusy || session.document == nil)
    }
}
