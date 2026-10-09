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
                    TypeFontPicker(fontName: Binding(get: {
                        guard let draft = session.textDraft else { return session.currentTextStyle.fontName }
                        let selection = draft.selection
                        if selection.length == 0 {
                            return draft.style.fontName(at: max(0, selection.location - 1))
                        }
                        // No single face: an empty title, so choosing the first letter's face still applies to the rest.
                        return draft.style.uniformFontName(in: selection) ?? ""
                    }, set: { name in
                        let selection = session.textDraft?.selection ?? NSRange()
                        session.changeTextStyle { $0.setFont(name, in: selection) }
                    }), preview: { step in
                        switch step {
                        case .show(let name): session.previewFont(name)
                        case .revert: session.endFontPreview()
                        case .keep: session.keepFontPreview()
                        }
                    })
                        .frame(width: 210).help("Font face, including bold and italic variants")
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
                    .buttonStyle(.plain).help("Text color").accessibilityLabel("Text color")
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
                            .help(L10n.text("Align " + alignment.rawValue.lowercased()))
                            .accessibilityLabel(L10n.text("Align " + alignment.rawValue.lowercased()))
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
                        .help("Line height, baseline to baseline. Empty or 0 is Auto: 120% of the font size.")
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
    /// The open menu trying faces on the text: the one under the pointer, putting the text back, or keeping it.
    enum PreviewStep { case show(String), revert, keep }
    var preview: (PreviewStep) -> Void = { _ in }
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(fontName: $fontName, preview: preview) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = FixedWidthPopUpButton(frame: .zero, pullsDown: false)
        if !fontName.isEmpty { button.addItem(withTitle: fontName) }
        button.borderShape = .capsule
        // A long font name is cut off at its end rather than widening the control or scrolling its start away.
        button.cell?.lineBreakMode = .byTruncatingTail
        button.cell?.usesSingleLineMode = true
        button.cell?.alignment = .left
        button.setAccessibilityLabel(L10n.text("Font"))
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        button.menu?.delegate = context.coordinator
        Coordinator.prepareStyledNames()
        context.coordinator.button = button
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.fontName = $fontName
        context.coordinator.preview = preview
        button.isEnabled = isEnabled
        guard !context.coordinator.tracking else { return }
        if fontName.isEmpty { Self.showMultiple(in: button); return }
        Self.hideMultiple(in: button)
        guard button.titleOfSelectedItem != fontName else { return }
        if button.item(withTitle: fontName) == nil { button.addItem(withTitle: fontName) }
        button.selectItem(withTitle: fontName)
    }

    /// Selected letters in more than one face: the menu says so with an item of its own at the top, which isn't a font.
    private static let multiple = "(Multiple)"
    private static func isMultiple(_ item: NSMenuItem?) -> Bool { item?.representedObject as? String == multiple }
    static func showMultiple(in button: NSPopUpButton) {
        if !isMultiple(button.item(at: 0)) {
            let item = NSMenuItem(title: L10n.text(multiple), action: nil, keyEquivalent: "")
            item.representedObject = multiple
            button.menu?.insertItem(item, at: 0)
        }
        if button.indexOfSelectedItem != 0 { button.selectItem(at: 0) }
    }
    static func hideMultiple(in button: NSPopUpButton) {
        if isMultiple(button.item(at: 0)) { button.removeItem(at: 0) }
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
        var preview: (PreviewStep) -> Void
        weak var button: NSPopUpButton?
        var tracking = false
        private var loaded = false
        /// A face was chosen in the menu just closing, so its preview stays rather than being put back.
        private var chose = false

        init(fontName: Binding<String>, preview: @escaping (PreviewStep) -> Void) { self.fontName = fontName; self.preview = preview }

        /// Each face's name set in that face, made once for the app. Building them all takes about half a second, so
        /// `prepareStyledNames` does it in the background when the Type bar first appears, ahead of the menu opening.
        /// Faces that can't draw their own name (symbol fonts) keep the menu's font, so the name stays readable; they're
        /// stored as an empty string.
        @MainActor private static var styledNames: [String: NSAttributedString] = [:]
        @MainActor private static var preparing = false
        @MainActor static func styledName(_ name: String) -> NSAttributedString? {
            if styledNames[name] == nil { styledNames[name] = makeStyledName(name) }
            let styled = styledNames[name]!
            return styled.length == 0 ? nil : styled
        }
        @MainActor static func prepareStyledNames() {
            guard !preparing, styledNames.isEmpty else { return }
            preparing = true
            let names = NSFontManager.shared.availableFonts
            Task.detached(priority: .utility) {
                let made = Made(names: Dictionary(uniqueKeysWithValues: names.map { ($0, makeStyledName($0)) }))
                await MainActor.run { styledNames.merge(made.names) { current, _ in current } }
            }
        }
        /// Finished strings, never changed after they're made, handed over to the main thread.
        private struct Made: @unchecked Sendable { let names: [String: NSAttributedString] }
        nonisolated private static func makeStyledName(_ name: String) -> NSAttributedString {
            guard let font = NSFont(name: name, size: NSFont.systemFontSize),
                  name.unicodeScalars.filter({ $0.properties.isAlphabetic }).allSatisfy({ font.coveredCharacterSet.contains($0) })
            else { return NSAttributedString() }
            return NSAttributedString(string: name, attributes: [.font: font])
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard !loaded, let button else { return }
            let selected = fontName.wrappedValue
            var names = NSFontManager.shared.availableFonts
            if !selected.isEmpty, !names.contains(selected) { names.append(selected) }
            names.sort()
            button.removeAllItems()
            button.addItems(withTitles: names)
            for item in button.itemArray { item.attributedTitle = Self.styledName(item.title) }
            if selected.isEmpty { TypeFontPicker.showMultiple(in: button) } else { button.selectItem(withTitle: selected) }
            loaded = true
        }

        func menuWillOpen(_ menu: NSMenu) { tracking = true }
        func menuDidClose(_ menu: NSMenu) {
            tracking = false
            // A choice may be reported just after the menu closes: put the text back only if none came.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !self.chose { self.preview(.revert) }
                self.chose = false
            }
        }
        /// Only a face previews. Nothing highlighted (the pointer off the list, or the menu closing on a click) leaves the
        /// last face showing: reverting there flashed the old face just before the chosen one landed.
        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            if let item, !TypeFontPicker.isMultiple(item) { preview(.show(item.title)) }
        }

        @objc func choose(_ button: NSPopUpButton) {
            // The text already shows the face under the pointer: keep it as it is, so it doesn't flash back.
            chose = true
            preview(.keep)
            guard !TypeFontPicker.isMultiple(button.selectedItem),
                  let selected = button.titleOfSelectedItem, selected != fontName.wrappedValue else { return }
            fontName.wrappedValue = selected
        }
    }
}
