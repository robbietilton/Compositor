import SwiftUI

struct PenControls: View {
    @Bindable var session: EditorSession

    var body: some View {
        HStack(spacing: 12) {
            Text("Pen").font(ToolHeaderStyle.titleFont)
            Picker("Action", selection: Binding(get: { session.penAction }, set: { action in
                session.selectPenAction(action)
            })) {
                ForEach(PenAction.allCases, id: \.self) { action in
                    Text(action.rawValue).tag(action)
                }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Draw creates paths; Bend curves a segment; X cuts; Shift-E erases. Tab switches tools")

            if session.penAction == .erase {
                Text("Size").scrubbable(sensitivity: 1, value: $session.brushSettings.diameter, range: 1...2000)
                TextField("Size", value: Binding<Double>(
                    get: { Double(session.brushSettings.diameter) },
                    set: { session.brushSettings.diameter = $0.isFinite ? CGFloat(min(2_000, max(1, $0))) : 40 }
                ), format: .number.precision(.fractionLength(0)))
                .frame(width: 48).textFieldStyle(.roundedBorder)
                .arrowSteps(value: { Double(session.brushSettings.diameter) },
                            change: { session.brushSettings.diameter = CGFloat(min(2_000, max(1, $0))) })
                .onChange(of: session.brushSettings.diameter) { _, value in
                    session.brushSettings.diameter = value.isFinite ? min(2_000, max(1, value)) : 40
                }
                .unitSuffix("px")
                .help("Vector eraser diameter; [ and ] change it")
            }

            HStack(spacing: 6) {
                Text("Foreground")
                Button { session.openColorPicker(background: false) } label: {
                    let swatch = RoundedRectangle(cornerRadius: 3, style: .continuous)
                    swatch.fill(Color(nsColor: session.foregroundColor.nsColor))
                        .overlay { swatch.strokeBorder(.black.opacity(0.5), lineWidth: 1) }
                        .frame(width: 36, height: 18)
                }
                .buttonStyle(.plain)
                .help("Use the foreground color")
            }

            Button("Fill Path") { session.fillPenPathWithForeground() }
                .disabled(!session.canFillPenPath)
                .help("Add or update the foreground-color fill while keeping the path editable")
            Button("Stroke Path with Brush") { session.strokePenPathWithBrush() }
                .disabled(!session.canStrokePenPath)
                .help("Add or update an editable path stroke using the current \(Int(session.brushSettings.diameter.rounded())) px Brush, hardness and opacity")
            Button("Load Path as Selection") { session.loadPenPathSelection() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!session.canLoadPenPathSelection)
                .help("Convert the current path to a selection without filling it (⌘Return). Open paths close between their endpoints")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).toolHeaderBar().releasesFocusOnCommit(session)
        .disabled(session.showsBusy || session.document == nil)
    }
}
