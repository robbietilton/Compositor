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
                            .help("Align " + alignment.rawValue.lowercased())
                            .accessibilityLabel("Align " + alignment.rawValue.lowercased())
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

/// The faces the font menu lists.
enum FontMenuFaces {
    /// Every face `availableFonts` reports, plus the family of each name in `inUse`. macOS leaves some installed
    /// families out of that list (Rockwell, Athelas, Seravek and others it bundles), though their faces still draw when
    /// named; text set in one of them, often from an imported Photoshop file, would otherwise offer none of its siblings.
    static func names(available: [String] = NSFontManager.shared.availableFonts, inUse: [String]) -> [String] {
        var names = Set(available)
        for name in inUse where !name.isEmpty {
            names.insert(name)
            names.formUnion(family(of: name))
        }
        return names.sorted()
    }

    /// The faces of a family named by search words ("iowan old style", "rockwell bold"), longest name first, so a
    /// family macOS doesn't list can still be found by typing it.
    static func family(named query: String) -> [String] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        for count in stride(from: words.count, through: 1, by: -1) {
            let words = words.prefix(count)
            for name in [words.joined(separator: " "), words.map(\.capitalized).joined(separator: " ")] {
                if let members = NSFontManager.shared.availableMembers(ofFontFamily: name), !members.isEmpty {
                    return members.compactMap { $0.first as? String }
                }
            }
        }
        return []
    }

    /// Whether a face's name holds every word of the search, in any case.
    static func matches(_ name: String, _ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { name.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// The faces of `name`'s family, by PostScript name, including families macOS doesn't list.
    static func family(of name: String) -> [String] {
        guard let family = NSFont(name: name, size: NSFont.systemFontSize)?.familyName,
              let members = NSFontManager.shared.availableMembers(ofFontFamily: family) else { return [] }
        return members.compactMap { $0.first as? String }
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
        button.setAccessibilityLabel("Font")
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
    /// The search box at the top of the open menu; not a font either.
    private static let search = "(Search)"
    fileprivate static func isSearch(_ item: NSMenuItem?) -> Bool { item?.representedObject as? String == search }
    /// The (Multiple) item goes first, below the search box when the menu has one.
    private static func multipleIndex(in button: NSPopUpButton) -> Int { isSearch(button.item(at: 0)) ? 1 : 0 }
    static func showMultiple(in button: NSPopUpButton) {
        let index = multipleIndex(in: button)
        if !isMultiple(button.item(at: index)) {
            let item = NSMenuItem(title: multiple, action: nil, keyEquivalent: "")
            item.representedObject = multiple
            button.menu?.insertItem(item, at: index)
        }
        if button.indexOfSelectedItem != index { button.selectItem(at: index) }
    }
    static func hideMultiple(in button: NSPopUpButton) {
        let index = multipleIndex(in: button)
        if isMultiple(button.item(at: index)) { button.removeItem(at: index) }
    }
    private static func isFont(_ item: NSMenuItem) -> Bool { !isMultiple(item) && !isSearch(item) }

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

    final class Coordinator: NSObject, NSMenuDelegate, NSSearchFieldDelegate {
        var fontName: Binding<String>
        var preview: (PreviewStep) -> Void
        weak var button: NSPopUpButton?
        var tracking = false
        private var loaded = false
        /// Faces the text has used while this menu was around: their families stay listed (see `FontMenuFaces`).
        private var facesInUse: Set<String> = []
        /// A face was chosen in the menu just closing, so its preview stays rather than being put back.
        private var chose = false

        init(fontName: Binding<String>, preview: @escaping (PreviewStep) -> Void) { self.fontName = fontName; self.preview = preview }

        /// Typing narrows the list to faces whose names hold every word; Return chooses the first one left.
        private lazy var searchField: NSSearchField = {
            let field = NSSearchField(frame: NSRect(x: 10, y: 4, width: 200, height: 22))
            field.placeholderString = "Search Fonts"
            field.autoresizingMask = .width
            field.delegate = self
            return field
        }()
        private lazy var searchItem: NSMenuItem = {
            let box = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 30))
            box.autoresizingMask = .width
            box.addSubview(searchField)
            let item = NSMenuItem()
            item.view = box
            item.representedObject = TypeFontPicker.search
            return item
        }()

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
            guard let button else { return }
            let selected = fontName.wrappedValue
            // Built once, but rebuilt when the face in use brings in a family the list doesn't have yet.
            if loaded, selected.isEmpty || FontMenuFaces.family(of: selected).allSatisfy({ button.item(withTitle: $0) != nil }) { return }
            if !selected.isEmpty { facesInUse.insert(selected) }
            let names = FontMenuFaces.names(inUse: Array(facesInUse))
            button.removeAllItems()
            button.addItems(withTitles: names)
            for item in button.itemArray { item.attributedTitle = Self.styledName(item.title) }
            menu.insertItem(searchItem, at: 0)
            if selected.isEmpty { TypeFontPicker.showMultiple(in: button) } else { button.selectItem(withTitle: selected) }
            loaded = true
        }

        func menuWillOpen(_ menu: NSMenu) {
            tracking = true
            // The menu's window exists once it's showing: give the search box the keys from the start.
            RunLoop.main.perform(inModes: [.eventTracking, .default]) { [weak self] in
                guard let self else { return }
                searchField.window?.makeFirstResponder(searchField)
            }
        }
        func menuDidClose(_ menu: NSMenu) {
            tracking = false
            searchField.stringValue = ""
            filter("")
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
            if let item, TypeFontPicker.isFont(item) { preview(.show(item.title)) }
        }

        func controlTextDidChange(_ notification: Notification) {
            filter(searchField.stringValue)
            keepMenuAtTheControl()
        }

        /// A window keeps its bottom edge when it shrinks, so a list cut down by a search fell to wherever the full
        /// list ended, often the foot of the screen. Once the menu has resized, put its top level with the control.
        private func keepMenuAtTheControl() {
            RunLoop.main.perform(inModes: [.eventTracking, .default]) { [weak self] in
                guard let self, let button, let control = button.window, let window = searchField.window,
                      let screen = window.screen ?? control.screen else { return }
                let top = min(control.convertToScreen(button.convert(button.bounds, to: nil)).maxY, screen.visibleFrame.maxY)
                window.setFrameOrigin(NSPoint(x: window.frame.minX, y: max(screen.visibleFrame.minY, top - window.frame.height)))
            }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)), let button,
                  let first = button.itemArray.first(where: { TypeFontPicker.isFont($0) && !$0.isHidden }) else { return false }
            button.select(first)
            button.menu?.cancelTracking()
            choose(button)
            return true
        }

        /// Shows only the faces matching `query`, first listing any family it names that macOS leaves out.
        private func filter(_ query: String) {
            guard let button, let menu = button.menu else { return }
            let query = query.trimmingCharacters(in: .whitespaces)
            for name in FontMenuFaces.family(named: query) where button.item(withTitle: name) == nil {
                facesInUse.insert(name)
                let index = button.itemArray.firstIndex { TypeFontPicker.isFont($0) && $0.title > name } ?? button.numberOfItems
                let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
                item.attributedTitle = Self.styledName(name)
                menu.insertItem(item, at: index)
            }
            for item in button.itemArray where TypeFontPicker.isFont(item) {
                item.isHidden = !query.isEmpty && !FontMenuFaces.matches(item.title, query)
            }
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
