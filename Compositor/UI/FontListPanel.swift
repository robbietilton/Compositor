import AppKit

/// The Type bar's font list: a search box that stays at the top, a line, and below it the faces, each set in its own
/// face, scrolling on their own. A menu can't keep one item still while the rest scroll, so this is a panel that opens
/// below the font control. Highlighting a face (pointer or arrow keys) previews it on the text; a click or Return
/// chooses it, and Escape or a click elsewhere puts the text back.
@MainActor
final class FontListPanel: NSPanel, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var onHighlight: ((String) -> Void)?
    /// Faces a search brought in from a family macOS leaves out of its list, so they stay listed next time.
    var onFound: (([String]) -> Void)?
    /// The face chosen, or nil when the list closed without one.
    var onClose: ((String?) -> Void)?

    private var names: [String]
    private var shown: [String]
    private let selected: String
    private let styledName: (String) -> NSAttributedString?
    private let search = NSTextField()
    /// Clears the search; only there while something's typed.
    private let clear = NSButton()
    private let table = FontListTable()
    private let scroll = NSScrollView()
    private var closing = false

    private static let width: CGFloat = 300
    private static let searchHeight: CGFloat = 46

    init(names: [String], selected: String, styledName: @escaping (String) -> NSAttributedString?) {
        self.names = names
        shown = names
        self.selected = selected
        self.styledName = styledName
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 420), styleMask: [.borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        build()
    }

    override var canBecomeKey: Bool { true }
    override func resignKey() {
        super.resignKey()
        dismiss(choosing: nil)
    }

    private func build() {
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        background.autoresizingMask = [.width, .height]
        contentView = background

        // The search box: a thin border in the app's accent blue, in place of the system's thick focus ring.
        let box = NSView(frame: NSRect(x: 8, y: frame.height - Self.searchHeight + 8, width: frame.width - 16, height: 30))
        box.wantsLayer = true
        box.layer?.cornerRadius = 6
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.controlAccentColor.cgColor
        box.autoresizingMask = [.width, .minYMargin]
        // A plain field beside a magnifier of its own: a borderless search field draws its icon over its text.
        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.frame = NSRect(x: 8, y: (box.bounds.height - 16) / 2, width: 16, height: 16)
        icon.autoresizingMask = [.minYMargin, .maxYMargin]
        box.addSubview(icon)
        search.isBordered = false
        search.isBezeled = false
        search.drawsBackground = false
        search.focusRingType = .none
        search.font = .systemFont(ofSize: NSFont.systemFontSize)
        search.placeholderString = "Search Fonts"
        search.cell?.usesSingleLineMode = true
        search.cell?.isScrollable = true
        search.delegate = self
        let height = search.fittingSize.height
        search.frame = NSRect(x: 30, y: ((box.bounds.height - height) / 2).rounded(), width: box.bounds.width - 56, height: height)
        search.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        box.addSubview(search)
        clear.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear search")
        clear.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        clear.contentTintColor = .secondaryLabelColor
        clear.isBordered = false
        clear.imagePosition = .imageOnly
        clear.refusesFirstResponder = true
        clear.target = self
        clear.action = #selector(clearSearch)
        clear.isHidden = true
        clear.frame = NSRect(x: box.bounds.width - 24, y: (box.bounds.height - 16) / 2, width: 16, height: 16)
        clear.autoresizingMask = [.minXMargin, .minYMargin, .maxYMargin]
        box.addSubview(clear)
        background.addSubview(box)

        let line = NSView(frame: NSRect(x: 0, y: frame.height - Self.searchHeight - 1, width: frame.width, height: 1))
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.cgColor
        line.autoresizingMask = [.width, .minYMargin]
        background.addSubview(line)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("face"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 24
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.onHover = { [weak self] row in self?.highlight(row) }
        scroll.frame = NSRect(x: 0, y: 0, width: frame.width, height: frame.height - Self.searchHeight - 1)
        scroll.autoresizingMask = [.width, .height]
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        background.addSubview(scroll)
        column.width = scroll.contentSize.width
    }

    /// Opens below `rect` (the font control, in `window`'s coordinates), or above it when there's no room below, with
    /// the face in use highlighted in the middle of the list.
    func show(below rect: NSRect, in window: NSWindow) {
        let control = window.convertToScreen(rect)
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? control.insetBy(dx: -1000, dy: -1000)
        let below = control.minY - 4 - visible.minY, above = visible.maxY - control.maxY - 4
        let height = min(440, below >= 240 || below >= above ? below : above)
        let width = max(Self.width, control.width)
        let x = min(max(visible.minX, control.minX), visible.maxX - width)
        let y = below >= 240 || below >= above ? control.minY - 4 - height : control.maxY + 4
        setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)
        table.tableColumns.first?.width = scroll.contentSize.width
        table.reloadData()
        if let row = shown.firstIndex(of: selected) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            // The face in use in the middle of the list, as a pop-up menu opens with it over its control.
            let middle = table.rect(ofRow: row).midY - scroll.contentSize.height / 2
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, middle)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        window.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(search)
    }

    /// Closes the list once, handing the editor back the keyboard when the list still had it.
    func dismiss(choosing name: String?) {
        guard !closing else { return }
        closing = true
        let parent = parent
        let hadKeyboard = isKeyWindow
        parent?.removeChildWindow(self)
        orderOut(nil)
        if hadKeyboard { parent?.makeKey() }
        onClose?(name)
    }

    private func highlight(_ row: Int, scrolling: Bool = false) {
        guard shown.indices.contains(row) else { return }
        if table.selectedRow != row { table.selectRowIndexes([row], byExtendingSelection: false) }
        if scrolling { table.scrollRowToVisible(row) }
        onHighlight?(shown[row])
    }

    @objc private func clicked() {
        guard shown.indices.contains(table.clickedRow) else { return }
        dismiss(choosing: shown[table.clickedRow])
    }

    /// Shows only the faces whose names hold every word typed, first listing any family it names that macOS leaves
    /// out, and highlights the first one left for Return.
    private func filter(_ query: String) {
        clear.isHidden = query.isEmpty
        let query = query.trimmingCharacters(in: .whitespaces)
        let found = FontMenuFaces.family(named: query).filter { !names.contains($0) }
        if !found.isEmpty {
            names = (names + found).sorted()
            onFound?(found)
        }
        shown = query.isEmpty ? names : names.filter { FontMenuFaces.matches($0, query) }
        table.reloadData()
        if shown.isEmpty { table.deselectAll(nil) } else {
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
    }

    func controlTextDidChange(_ notification: Notification) { filter(search.stringValue) }

    @objc private func clearSearch() {
        search.stringValue = ""
        filter("")
        makeFirstResponder(search)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            highlight(min(shown.count - 1, table.selectedRow + 1), scrolling: true)
        case #selector(NSResponder.moveUp(_:)):
            highlight(max(0, table.selectedRow - 1), scrolling: true)
        case #selector(NSResponder.insertNewline(_:)):
            let row = table.selectedRow >= 0 ? table.selectedRow : 0
            if shown.indices.contains(row) { dismiss(choosing: shown[row]) }
        case #selector(NSResponder.cancelOperation(_:)):
            // Escape clears a search first, then closes the list.
            if search.stringValue.isEmpty { dismiss(choosing: nil) } else { search.stringValue = ""; filter("") }
        default:
            return false
        }
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("face")
        let label = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField ?? {
            let label = NSTextField(labelWithString: "")
            label.identifier = id
            label.lineBreakMode = .byTruncatingTail
            return label
        }()
        let name = shown[row]
        if let styled = styledName(name) { label.attributedStringValue = styled } else {
            label.stringValue = name
            label.font = .systemFont(ofSize: NSFont.systemFontSize)
        }
        return label
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { FontListRow() }
}

/// The list of faces, reporting the row under the pointer so it can be previewed.
final class FontListTable: NSTableView {
    var onHover: ((Int) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onHover?(row) }
    }
}

/// A face's row: its name inset from the edges, on a rounded highlight when it's the one highlighted.
final class FontListRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
    override func layout() {
        super.layout()
        for view in subviews {
            let height = view.fittingSize.height
            view.frame = NSRect(x: 14, y: ((bounds.height - height) / 2).rounded(), width: bounds.width - 28, height: height)
        }
    }
}
