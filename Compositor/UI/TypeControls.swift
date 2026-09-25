import SwiftUI
import AppKit

struct TypeControls: View {
    @Bindable var session: EditorSession
    private func value<T>(_ key: WritableKeyPath<LayerTextStyle, T>) -> Binding<T> {
        Binding(get: { session.currentTextStyle[keyPath: key] }, set: { value in
            session.changeTextStyle { $0[keyPath: key] = value }
        })
    }
    private func number(_ key: WritableKeyPath<LayerTextStyle, CGFloat>) -> Binding<Double> {
        Binding(get: { Double(session.currentTextStyle[keyPath: key]) }, set: { value in
            session.changeTextStyle { $0[keyPath: key] = CGFloat(value) }
        })
    }
    var body: some View {
        HStack(spacing: 12) {
            Text("Type").font(ToolHeaderStyle.titleFont)
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    TypeFontPicker(fontName: value(\.fontName))
                        .frame(width: 210).help(localized("Font face, including bold and italic variants"))
                    TextField("Size", value: number(\.fontSize), format: .number).frame(width: 52)
                        .unitSuffix("px", scrubValue: value(\.fontSize), sensitivity: 1, range: 1...2000, step: 1)
                        .arrowSteps(value: { Double(session.currentTextStyle.fontSize) },
                                    change: { stepped in session.changeTextStyle { $0.fontSize = CGFloat(min(2000, max(1, stepped))) } })
                    Button { session.openTextColorPicker() } label: {
                        let color = session.typeColor
                        let swatch = RoundedRectangle(cornerRadius: 3, style: .continuous)
                        swatch.fill(Color(red: color.red, green: color.green, blue: color.blue))
                            .overlay { swatch.strokeBorder(.black.opacity(0.5), lineWidth: 1) }
                            .frame(width: 36, height: 18)
                    }
                    .buttonStyle(.plain).help(localized("Text color")).accessibilityLabel(localized("Text color"))
                    HStack(spacing: 2) {
                        ForEach(TextAlignment.allCases, id: \.self) { alignment in
                            let selected = session.currentTextStyle.alignment == alignment
                            Button {
                                session.changeTextStyle { $0.alignment = alignment }
                            } label: {
                                Image(systemName: alignment == .left ? "text.alignleft" : alignment == .center ? "text.aligncenter" : "text.alignright")
                                    .frame(width: 30, height: 26)
                                    .background(selected ? Color.white.opacity(0.14) : .clear,
                                                in: RoundedRectangle(cornerRadius: 4))
                                    // Without this the glyph's own strokes are the only thing a click lands on.
                                    .contentShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)
                            .help(String(localized: "Align \(localized(alignment.rawValue.lowercased()))"))
                            .accessibilityLabel(String(localized: "Align \(localized(alignment.rawValue.lowercased()))"))
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                    Text("Tracking").scrubbable(sensitivity: 1, value: value(\.tracking), range: -100...1000, step: 1)
                    TextField("Tracking", value: number(\.tracking), format: .number).frame(width: 45)
                        .arrowSteps(value: { Double(session.currentTextStyle.tracking) },
                                    change: { stepped in session.changeTextStyle { $0.tracking = CGFloat(stepped) } })
                    Text("Leading").scrubbable(sensitivity: 1, value: value(\.leading), range: 0...5000, step: 1)
                    // 0 means Auto: the field is left empty so its "Auto" placeholder shows through.
                    TextField("Leading", text: Binding(get: {
                        let leading = session.currentTextStyle.leading
                        return leading > 0 ? String(Int(leading.rounded())) : ""
                    }, set: { typed in
                        let value = Double(typed.trimmingCharacters(in: .whitespaces)) ?? 0
                        session.changeTextStyle { $0.leading = CGFloat(max(0, min(5000, value))) }
                    }), prompt: Text("Auto"))
                        .frame(width: 52)
                        .arrowSteps(value: { Double(session.currentTextStyle.lineHeight) },
                                    change: { stepped in session.changeTextStyle { $0.leading = CGFloat(max(0, stepped)) } })
                        .help(localized("Line height, baseline to baseline. Empty or 0 is Auto: 120% of the font size."))
                }
            }.scrollIndicators(.hidden)
            if session.textDraft != nil {
                Button("Cancel") { session.cancelText() }
                Button("Done") { _ = session.finishText() }
            } else {
                Button("Edit Text") { session.editActiveText() }.disabled(session.activeLayer?.liveText == nil)
            }
        }
        .textFieldStyle(.roundedBorder).padding(.horizontal, 18).toolHeaderBar()
        .disabled(session.document == nil || session.showsBusy)
        .onChange(of: session.colorPicker?.color) { _, _ in session.previewTextColor() }
    }
}

/// Keep the installed-font catalog out of SwiftUI's per-keystroke view updates.
/// The closed control needs only the current name; populate its menu on demand.
private struct TypeFontPicker: NSViewRepresentable {
    @Binding var fontName: String
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(fontName: $fontName) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = FixedWidthPopUpButton(frame: .zero, pullsDown: false)
        button.addItem(withTitle: fontName)
        button.borderShape = .capsule
        // A long font name is cut off at its end rather than widening the control or scrolling its start away.
        button.cell?.lineBreakMode = .byTruncatingTail
        button.cell?.usesSingleLineMode = true
        button.cell?.alignment = .left
        button.setAccessibilityLabel(localized("Font"))
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        button.menu?.delegate = context.coordinator
        context.coordinator.button = button
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.fontName = $fontName
        button.isEnabled = isEnabled
        guard !context.coordinator.tracking, button.titleOfSelectedItem != fontName else { return }
        if button.item(withTitle: fontName) == nil { button.addItem(withTitle: fontName) }
        button.selectItem(withTitle: fontName)
    }

    static func dismantleNSView(_ button: NSPopUpButton, coordinator: Coordinator) {
        button.menu?.delegate = nil
        button.target = nil
    }

    /// The font list holds names of every length; the control keeps whatever width it is given, so choosing a long
    /// name can't stretch it — or leave it stretched once a short one is chosen again.
    final class FixedWidthPopUpButton: NSPopUpButton {
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: super.intrinsicContentSize.height)
        }
    }

    final class Coordinator: NSObject, NSMenuDelegate {
        var fontName: Binding<String>
        weak var button: NSPopUpButton?
        var tracking = false
        private var loaded = false

        init(fontName: Binding<String>) { self.fontName = fontName }

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard !loaded, let button else { return }
            let selected = fontName.wrappedValue
            let names = Array(Set(NSFontManager.shared.availableFonts + [selected])).sorted()
            button.removeAllItems()
            button.addItems(withTitles: names)
            button.selectItem(withTitle: selected)
            loaded = true
        }

        func menuWillOpen(_ menu: NSMenu) { tracking = true }
        func menuDidClose(_ menu: NSMenu) { tracking = false }

        @objc func choose(_ button: NSPopUpButton) {
            guard let selected = button.titleOfSelectedItem, selected != fontName.wrappedValue else { return }
            fontName.wrappedValue = selected
        }
    }
}
