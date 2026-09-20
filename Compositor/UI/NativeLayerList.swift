import AppKit
import SwiftUI

/// Native mouse-down selection and drag tracking, without a double-click delay.
struct NativeLayerList: NSViewRepresentable {
    let session: EditorSession
    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = LayerTableView()
        table.session = session
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.rowHeight = 52
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("layer"))
        column.width = 252
        table.addTableColumn(column)
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.renameClickedLayer(_:))
        table.action = #selector(Coordinator.clickedLayer(_:))
        table.registerForDraggedTypes([Coordinator.layerType, Coordinator.maskType, Coordinator.effectType])
        table.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        table.setAccessibilityIdentifier("layersList")
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        context.coordinator.update(table)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let table = scroll.documentView as? NSTableView { context.coordinator.update(table) }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let layerType = NSPasteboard.PasteboardType("com.compositor.layer-row")
        /// An Option-drag from a mask thumbnail: the id of the layer whose mask is being copied.
        static let effectType = NSPasteboard.PasteboardType("com.compositor.layer-effect")
        static let maskType = NSPasteboard.PasteboardType("com.compositor.layer-mask")
        let session: EditorSession
        private var rows: [ImageLayer] = []
        private var rowDetails: [UUID: LayerHierarchy.Entry] = [:]
        private var oldCollapsed: Set<UUID> = []
        private var editingEnabled = false
        private var synchronizing = false
        init(session: EditorSession) { self.session = session }

        func update(_ table: NSTableView) {
            let entries = session.layerRows
            let byID = Dictionary(uniqueKeysWithValues: (session.document?.layers ?? []).map { ($0.id, $0) })
            let next = entries.compactMap { byID[$0.layer.id] }
            let previousDetails = rowDetails
            rowDetails = Dictionary(uniqueKeysWithValues: entries.map { ($0.layer.id, $0) })
            let expansionChanged = oldCollapsed != session.collapsedGroupIDs
            oldCollapsed = session.collapsedGroupIDs
            let enabled = session.canEditLayers
            synchronizing = true
            defer { synchronizing = false }
            let old = rows
            rows = next
            let editableChanged = editingEnabled != enabled
            editingEnabled = enabled
            if old.map(\.id) != next.map(\.id) {
                table.reloadData()
            } else {
                // Selection never reloads cells or recreates thumbnails.
                let changed = IndexSet(next.indices.filter {
                    editableChanged || expansionChanged || (old[$0].name != next[$0].name || old[$0].isVisible != next[$0].isVisible || old[$0].size != next[$0].size || old[$0].parentID != next[$0].parentID || old[$0].isGroup != next[$0].isGroup || old[$0].asset?.image !== next[$0].asset?.image || (old[$0].liveText != nil) != (next[$0].liveText != nil) || old[$0].effects != next[$0].effects || old[$0].mask != next[$0].mask || old[$0].maskSourceID != next[$0].maskSourceID) || previousDetails[next[$0].id]?.depth != rowDetails[next[$0].id]?.depth || previousDetails[next[$0].id]?.visible != rowDetails[next[$0].id]?.visible
                })
                let resized = IndexSet(next.indices.filter { (old[$0].effects?.kinds.count ?? 0) != (next[$0].effects?.kinds.count ?? 0) })
                // Adding or removing an effect only changes how tall a row is. Left to AppKit that is animated, and
                // the row appears to be taken away and put back; here it simply becomes its new height.
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0
                if !resized.isEmpty { table.noteHeightOfRows(withIndexesChanged: resized) }
                if !changed.isEmpty { table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0)) }
                NSAnimationContext.endGrouping()
            }
            let indices = IndexSet(next.indices.filter { session.selectedEffect == nil && session.selectedLayerIDs.contains(next[$0].id) })
            if table.selectedRowIndexes != indices { table.selectRowIndexes(indices, byExtendingSelection: false) }
            // Border-only updates: selecting a target never rebuilds thumbnails or canvas pixels.
            let visible = table.rows(in: table.visibleRect)
            if visible.location != NSNotFound {
                for row in visible.location..<min(next.count, NSMaxRange(visible)) {
                    (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? LayerCell)?.updateTarget()
                }
            }
            // A rename — double-click, the row's menu, or the Layer menu — is typed in the row itself.
            if let id = session.renamingLayerID, let row = next.firstIndex(where: { $0.id == id }) {
                table.scrollRowToVisible(row)
                DispatchQueue.main.async {
                    (table.view(atColumn: 0, row: row, makeIfNecessary: true) as? LayerCell)?.beginRenaming()
                }
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            52 + CGFloat(rows[row].effects?.kinds.count ?? 0) * 24
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("layerCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? LayerCell ?? LayerCell()
            cell.identifier = identifier
            cell.configure(rows[row], enabled: editingEnabled, session: session, depth: rowDetails[rows[row].id]?.depth ?? 0, visible: rowDetails[rows[row].id]?.visible ?? true)
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !synchronizing, let table = notification.object as? NSTableView else { return }
            let selected = table.selectedRowIndexes.filter { rows.indices.contains($0) }
            let ids = Set(selected.map { rows[$0].id })
            let primary = selected.contains(table.clickedRow) ? rows[table.clickedRow].id : selected.first.map { rows[$0].id }
            session.selectLayers(ids, primary: primary)
        }
        /// A click on a row's name (its thumbnails are buttons of their own) targets the layer itself, even when its
        /// mask was selected — so transforming then moves layer and mask together.
        @objc func clickedLayer(_ table: NSTableView) {
            guard rows.indices.contains(table.clickedRow), session.isMaskSelected,
                  session.selectedLayerIDs == [rows[table.clickedRow].id],
                  // Clicks on the row's buttons (the mask thumbnail among them) reach the table too.
                  let event = NSApp.currentEvent,
                  (table.view(atColumn: 0, row: table.clickedRow, makeIfNecessary: false) as? LayerCell)?.isOnControl(event.locationInWindow) != true
            else { return }
            session.commitTransform()
            session.selectLayerTarget(rows[table.clickedRow].id, mask: false)
        }
        @objc func renameClickedLayer(_ table: NSTableView) {
            guard session.canEditLayers, rows.indices.contains(table.clickedRow) else { return }
            let id = rows[table.clickedRow].id
            session.activeLayerID = id
            // On the thumbnail (or another of the row's controls) a double-click opens what the layer holds: its
            // text, or an adjustment's settings. On the name it renames the layer, as it does for every other layer.
            let point = NSApp.currentEvent?.locationInWindow ?? .zero
            let cell = table.view(atColumn: 0, row: table.clickedRow, makeIfNecessary: false) as? LayerCell
            if cell?.isOnControl(point) == true {
                if rows[table.clickedRow].liveText != nil { session.editActiveText(); return }
                if rows[table.clickedRow].adjustment != nil { session.adjustmentEditingID = id; return }
            }
            session.renamingLayerID = id
        }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard session.canEditLayers, rows.indices.contains(row) else { return nil }
            let item = NSPasteboardItem()
            item.setString(rows[row].id.uuidString, forType: Self.layerType)
            return item
        }
        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            if let source = info.draggingSource as? LayerEffectRow {
                let target = tableView.row(at: tableView.convert(info.draggingLocation, from: nil))
                guard source.session === session, rows.indices.contains(target),
                      session.canCopyEffect(source.kind, from: source.layerID, to: rows[target].id) else { return [] }
                tableView.setDropRow(target, dropOperation: .on)
                return .copy
            }
            if let source = draggedMask(info) {
                // A mask lands on whichever row is under the pointer.
                let target = tableView.row(at: tableView.convert(info.draggingLocation, from: nil))
                guard rows.indices.contains(target), session.canCopyMask(from: source, to: rows[target].id) else { return [] }
                tableView.setDropRow(target, dropOperation: .on)
                return .copy
            }
            guard session.canEditLayers, info.draggingSource as? NSTableView === tableView,
                  (0...rows.count).contains(row) else { return [] }
            let ids = draggedLayers(info)
            guard !ids.isEmpty else { return [] }
            // With Option held the drag offers only Copy, including complete folder trees.
            let copying = info.draggingSourceOperationMask == .copy
            let intoFolder = operation == .on && rows.indices.contains(row) && rows[row].isGroup
            let parent = intoFolder ? rows[row].id : (rows.indices.contains(row) ? rows[row].parentID : nil)
            guard ids.allSatisfy({ session.canPlaceLayer($0, in: parent) }) else { return [] }
            tableView.setDropRow(row, dropOperation: intoFolder ? .on : .above)
            return copying ? .copy : .move
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            if let source = info.draggingSource as? LayerEffectRow {
                guard source.session === session, rows.indices.contains(row),
                      session.canCopyEffect(source.kind, from: source.layerID, to: rows[row].id) else { return false }
                session.copyEffect(source.kind, from: source.layerID, to: rows[row].id)
                return true
            }
            if let source = draggedMask(info) {
                guard rows.indices.contains(row), session.canCopyMask(from: source, to: rows[row].id) else { return false }
                session.copyMask(from: source, to: rows[row].id)
                return true
            }
            guard info.draggingSource as? NSTableView === tableView else { return false }
            let ids = draggedLayers(info)
            guard !ids.isEmpty else { return false }
            let copying = info.draggingSourceOperationMask == .copy
            // Where the drop lands is worked out once: each layer placed shifts the rows beneath it.
            let current = session.layerRows
            let intoFolder = dropOperation == .on && rows.indices.contains(row) && rows[row].isGroup
            let parent: UUID?, above: UUID?, atBottom: Bool
            if intoFolder {
                parent = rows[row].id; above = nil; atBottom = false
            } else if row >= current.count {
                parent = nil; above = nil; atBottom = true
            } else {
                let target = current[row].layer
                parent = target.parentID; above = target.id; atBottom = false
            }
            // Dropped above a layer (or at the very bottom) the last one placed ends up nearest it, so they go in
            // from the top down; dropped into a folder each lands on top, so they go in from the bottom up.
            let order = intoFolder ? Array(ids.reversed()) : ids
            session.beginEdit(copying ? (ids.count > 1 ? "Duplicate Layers" : "Duplicate Layer")
                                      : (ids.count > 1 ? "Move Layers" : "Move Layer"))
            var placed = false
            for id in order {
                let done = copying ? session.duplicateLayer(id, in: parent, above: above, atBottom: atBottom)
                                   : session.placeLayer(id, in: parent, above: above, atBottom: atBottom)
                placed = done || placed
            }
            // The layers that moved stay selected, so they can be dragged on as a group.
            if placed, !copying { session.selectLayers(Set(ids), primary: ids.first) }
            session.endEdit()
            return placed
        }
        private func draggedMask(_ info: NSDraggingInfo) -> UUID? {
            info.draggingPasteboard.string(forType: Self.maskType).flatMap(UUID.init(uuidString:))
        }
        /// Every layer being dragged, in the order the list shows them: a row's pasteboard item each, leaving out
        /// anything inside a dragged folder, which the folder brings along itself.
        private func draggedLayers(_ info: NSDraggingInfo) -> [UUID] {
            let dropped = (info.draggingPasteboard.pasteboardItems ?? []).compactMap {
                $0.string(forType: Self.layerType).flatMap(UUID.init(uuidString:))
            }
            let dragged = Set(dropped)
            let carried = dragged.reduce(into: Set<UUID>()) { $0.formUnion(session.descendantIDs(of: $1)) }
            return session.layerRows.map(\.layer.id).filter { dragged.contains($0) && !carried.contains($0) }
        }
    }
}

final class LayerTableView: NSTableView {
    weak var session: EditorSession?
    private var clippingTracking: NSTrackingArea?
    private var clippingMonitor: Any?
    private var clippingCursorActive = false
    private static func clippingCursor(releasing: Bool) -> NSCursor {
        let image = NSImage(size: NSSize(width: 30, height: 28), flipped: false) { _ in
            let arrow = NSImage(systemSymbolName: "arrow.turn.down.right", accessibilityDescription: nil)!
            let box = NSImage(systemSymbolName: releasing ? "rectangle.badge.minus" : "rectangle.badge.plus", accessibilityDescription: nil)!
            func drawOutlined(_ symbol: NSImage, in rect: NSRect) {
                let white = symbol.withSymbolConfiguration(.init(paletteColors: [.white]))!
                let black = symbol.withSymbolConfiguration(.init(paletteColors: [.black]))!
                for step in 0..<16 {
                    let angle = CGFloat(step) * .pi / 8
                    white.draw(in: rect.offsetBy(dx: cos(angle), dy: sin(angle)))
                }
                black.draw(in: rect)
            }
            drawOutlined(arrow, in: NSRect(x: 1, y: 11, width: 16, height: 15))
            drawOutlined(box, in: NSRect(x: 10, y: 1, width: 19, height: 17))
            return true
        }
        image.accessibilityDescription = releasing ? "Release clipping mask" : "Create clipping mask"
        return NSCursor(image: image, hotSpot: NSPoint(x: 3, y: 3))
    }
    private static let createClippingCursor = clippingCursor(releasing: false)
    private static let releaseClippingCursor = clippingCursor(releasing: true)
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let clippingTracking { removeTrackingArea(clippingTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate], owner: self)
        addTrackingArea(area); clippingTracking = area
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let clippingMonitor { NSEvent.removeMonitor(clippingMonitor); self.clippingMonitor = nil }
        if window != nil {
            clippingMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                guard let self else { return event }
                self.refreshClippingCursor(event.modifierFlags)
                // A modifier change is not a mouse event: AppKit restores its own cursor once this one is handled,
                // so the cursor is worked out again right after, from wherever the pointer is by then.
                DispatchQueue.main.async { [weak self] in self?.refreshClippingCursor(NSEvent.modifierFlags) }
                return event
            }
        }
    }
    /// Keeps the cursor right over the layer list: with Option held, the clipping cursor over the bottom quarter
    /// of a row, as in Photoshop, and the duplicate cursor over the rest of it (a mask thumbnail copies the mask); a thumbnail's own cursor with Command held over
    /// it; otherwise the arrow — even when a
    /// tool's cursor followed the mouse in. `location` is in window coordinates; without one
    /// (a modifier change) the current mouse position is used.
    func refreshClippingCursor(_ flags: NSEvent.ModifierFlags, at location: NSPoint? = nil) {
        guard let window else { return }
        let point = convert(location ?? window.mouseLocationOutsideOfEventStream, from: nil)
        let inside = visibleRect.contains(point)
        guard inside, flags.contains(.option), !flags.contains(.command) else {
            // Outside the list, a modifier change must not touch another view's cursor.
            if clippingCursorActive || (inside && !thumbnailOwnsCursor(at: point, flags: flags)) { NSCursor.arrow.set() }
            clippingCursorActive = false
            return
        }
        clippingCursorActive = true
        (clippingCursor(at: point) ?? .arrow).set()
    }

    /// With Option held, the cursor for whatever is under `point`: the clipping cursor over the bottom of a row,
    /// the duplicate cursor over the rest of it and over a mask thumbnail an Option-drag can copy.
    private func clippingCursor(at point: NSPoint) -> NSCursor? {
        let index = row(at: point)
        guard let session, session.layerRows.indices.contains(index) else { return nil }
        let layer = session.layerRows[index].layer
        if let thumbnail = thumbnail(at: point), thumbnail.isMaskTarget, !thumbnail.isHidden {
            return session.canEditLayers ? CanvasView.duplicateCursor : NSCursor.arrow
        }
        guard isClippingZone(point, row: index) else {
            return session.canEditLayers ? CanvasView.duplicateCursor : NSCursor.arrow
        }
        guard session.canToggleClippingMask(layer.id) else { return NSCursor.arrow }
        return layer.maskSourceID == nil ? Self.createClippingCursor : Self.releaseClippingCursor
    }

    /// Option-click clips along the bottom edge of a row: a fixed strip, not a share of the row's height, so a row
    /// listing several effects keeps the rest of itself free for Option-dragging those effects.
    private static let clippingStrip: CGFloat = 10
    private func isClippingZone(_ point: NSPoint, row: Int) -> Bool {
        guard row >= 0 else { return false }
        if let entries = session?.layerRows, entries.indices.contains(row), entries[row].layer.isGroup == true { return false }
        let rect = rect(ofRow: row)
        return point.y >= rect.maxY - min(Self.clippingStrip, rect.height / 3)
    }
    /// Command held over a thumbnail that loads a selection: that thumbnail shows its cursor.
    private func thumbnailOwnsCursor(at point: NSPoint, flags: NSEvent.ModifierFlags) -> Bool {
        guard flags.contains(.command), let thumbnail = thumbnail(at: point) else { return false }
        return thumbnail.cmdClickLoads && thumbnail.isEnabled
    }
    /// The layer or mask thumbnail under a point in this view's coordinates, if any.
    private func thumbnail(at point: NSPoint) -> LayerThumbnailButton? {
        guard let superview else { return nil }
        var view = superview.hitTest(convert(point, to: superview))
        while let current = view, current !== self {
            if let thumbnail = current as? LayerThumbnailButton { return thumbnail }
            view = current.superview
        }
        return nil
    }
    override func mouseEntered(with event: NSEvent) { refreshClippingCursor(event.modifierFlags, at: event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { refreshClippingCursor(event.modifierFlags, at: event.locationInWindow) }
    override func cursorUpdate(with event: NSEvent) { refreshClippingCursor(event.modifierFlags, at: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) {
        // Reloading rows (after a brush stroke, say) rebuilds the tracking areas, which sends an exit even though
        // the pointer never left: taking the cursor back then makes it flicker. Only a real exit resets it.
        if let window, visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            refreshClippingCursor(NSEvent.modifierFlags)
            return
        }
        if clippingCursorActive { NSCursor.arrow.set(); clippingCursorActive = false }
    }

    /// Effect rows are interactive subviews. In the clipping zone, Option-click belongs to the table
    /// instead, so the same region that advertises the clipping cursor also handles the click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard hit != nil else { return nil }
        let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        let local = convert(point, from: superview)
        guard flags.contains(.option), !flags.contains(.command),
              isClippingZone(local, row: row(at: local)) else { return hit }
        // Option-dragging a mask thumbnail must still copy its mask.
        var target = hit
        while let view = target, view !== self {
            if let thumbnail = view as? LayerThumbnailButton, thumbnail.isMaskTarget { return hit }
            target = view.superview
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        // Handle clipping before effect selection: effects occupy the lower portion of taller rows.
        if event.modifierFlags.contains(.option), !event.modifierFlags.contains(.command), isClippingZone(point, row: row),
           thumbnail(at: point)?.isMaskTarget != true,
           let entries = session?.layerRows, entries.indices.contains(row) {
            session?.effectSelection = nil
            session?.toggleClippingMask(entries[row].layer.id)
            refreshClippingCursor(event.modifierFlags)
            return
        }
        if row >= 0, let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? LayerCell,
           cell.selectEffect(at: event.locationInWindow, editing: event.clickCount > 1) {
            window?.makeFirstResponder(self)
            return
        }
        session?.effectSelection = nil
        if row >= 0, event.modifierFlags.intersection([.command, .shift]).isEmpty,
           !(selectedRowIndexes.count > 1 && selectedRowIndexes.contains(row)) {
            // Paint selection before AppKit enters its click/drag tracking loop.
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            window?.makeFirstResponder(self)
            displayIfNeeded()
        }
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        guard let event = ShortcutSettings.shared.canvasEvent(event) else { return }
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        if event.keyCode == 53, session?.transformEdit != nil {
            session?.cancelTransform()
        } else if [36, 76].contains(event.keyCode), session?.transformEdit != nil {
            session?.commitTransform()
        } else if plain, event.keyCode == 48 {
            session?.cycleToolMode()
        } else if plain, event.charactersIgnoringModifiers?.lowercased() == "x" {
            session?.swapPaletteColors()
        } else if plain, event.charactersIgnoringModifiers?.lowercased() == "d" {
            session?.resetPaletteColors()
        } else if plain, event.charactersIgnoringModifiers?.lowercased() == "t" {
            session?.selectTool(.type)
        } else if plain, ["a", "v", "h", "z", "b", "e", "g", "l", "m", "w", "j", "s", "u", "r", "i", "c"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "") {
            let key = event.charactersIgnoringModifiers?.lowercased()
            if key == "m" { if !event.isARepeat { session?.pressMarqueeKey() } }
            else if key == "l" { if !event.isARepeat { session?.pressLassoKey() } }
            else if key == "b" || key == "e" {
                session?.selectTool(.brush)
                session?.brushMode = key == "e" ? .erase : .paint
            }
            else if key == "w" { if !event.isARepeat { session?.pressWandKey() } }
            else { session?.selectTool(key == "a" ? .idle : key == "i" ? .eyedropper : key == "c" ? .crop : key == "r" ? .blur : key == "b" ? .brush : key == "g" ? .gradient : key == "l" ? .lasso : key == "m" ? .marquee : key == "j" ? .spotHealing : key == "s" ? .cloneStamp : key == "u" ? .shape : key == "v" ? .move : key == "h" ? .hand : .zoom) }
        } else if plain, let digit = Int(event.charactersIgnoringModifiers ?? ""), session?.usesOpacityKeys == true {
            session?.typeOpacityDigit(digit)
        // With the Move tool the arrows move the layer, as on the canvas, rather than changing the row selection.
        } else if plain, session?.transformEdit != nil || session?.tool == .move, [123, 124, 125, 126].contains(event.keyCode) {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            session?.nudgeLayer(dx: event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0,
                                dy: event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0)
        } else if [51, 117].contains(event.keyCode), plain {
            session?.deleteKeyPressed()
        } else { super.keyDown(with: event) }
    }
}

private final class LayerCell: NSTableCellView, NSTextFieldDelegate {
    /// The layer's own name, without the mark a clipped layer's row shows in front of it.
    private var layerName = ""
    private var renaming = false
    private let eye = EyeSwipeButton()
    private let effectRows = NSStackView()
    private var effectButtons: [LayerEffectRow] = []
    private let disclosure = NSButton()
    private var indentation: NSLayoutConstraint!
    private let thumbnail = LayerThumbnailButton()
    private let maskThumbnail = LayerThumbnailButton()
    private let disabledMaskMark = MaskDisabledMark(labelWithString: "╱")
    /// Between the thumbnails: the chain while layer and mask are linked, empty (still clickable) once unlinked.
    private let linkButton = NSButton()
    private var maskGap: NSLayoutConstraint!
    /// The chain symbol runs corner to corner; turned 45° counterclockwise it stands upright in a narrow gap.
    private static let linkImage: NSImage? = {
        guard let symbol = NSImage(systemSymbolName: "link", accessibilityDescription: "Linked")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)) else { return nil }
        let side = max(symbol.size.width, symbol.size.height)
        let image = NSImage(size: NSSize(width: ceil(side * 0.7), height: ceil(side * 1.45)), flipped: false) { rect in
            let turn = NSAffineTransform()
            turn.translateX(by: rect.midX, yBy: rect.midY)
            turn.rotate(byDegrees: 45)
            turn.concat()
            symbol.draw(in: NSRect(x: -symbol.size.width / 2, y: -symbol.size.height / 2, width: symbol.size.width, height: symbol.size.height))
            return true
        }
        image.isTemplate = true
        return image
    }()
    private var maskWidth: NSLayoutConstraint!
    /// Fixed slots keep names aligned while the thumbnails inside take the canvas's shape.
    private let thumbnailSlot = NSLayoutGuide()
    private let maskSlot = NSLayoutGuide()
    private var thumbnailWidth: NSLayoutConstraint!
    private var thumbnailHeight: NSLayoutConstraint!
    private var maskThumbnailWidth: NSLayoutConstraint!
    private var maskThumbnailHeight: NSLayoutConstraint!
    private let nameLabel = NSTextField(labelWithString: "")
    private let dimensions = NSTextField(labelWithString: "")
    private var layerID: UUID?
    private weak var session: EditorSession?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        effectRows.orientation = .vertical
        effectRows.alignment = .leading
        effectRows.spacing = 0
        effectRows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effectRows)
        NSLayoutConstraint.activate([
            effectRows.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectRows.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectRows.topAnchor.constraint(equalTo: topAnchor, constant: 52)
        ])
        disclosure.isBordered = false
        disclosure.target = self
        disclosure.action = #selector(toggleExpansion)
        eye.isBordered = false
        eye.target = self
        eye.action = #selector(toggleVisibility)
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        for button in [thumbnail, maskThumbnail] {
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.wantsLayer = true
            button.layer?.cornerRadius = 3
            button.target = self
        }
        thumbnail.action = #selector(selectImage)
        maskThumbnail.action = #selector(selectMask)
        maskThumbnail.isMaskTarget = true
        thumbnail.loadsSelection = true
        thumbnail.toolTip = "Select layer; Cmd-click to select its pixels (Cmd-Shift adds, Cmd-Option subtracts)"
        maskThumbnail.imageScaling = .scaleProportionallyUpOrDown
        linkButton.isBordered = false
        linkButton.title = ""
        linkButton.imagePosition = .imageOnly
        linkButton.contentTintColor = .secondaryLabelColor
        linkButton.target = self
        linkButton.action = #selector(toggleMaskLink)
        disabledMaskMark.font = .systemFont(ofSize: 32, weight: .medium)
        disabledMaskMark.textColor = .systemRed
        disabledMaskMark.isHidden = true
        nameLabel.lineBreakMode = .byTruncatingTail
        // One line, whatever the name holds: a text layer named after a paragraph would otherwise grow the row.
        nameLabel.usesSingleLineMode = true
        nameLabel.maximumNumberOfLines = 1
        nameLabel.font = .systemFont(ofSize: 13)
        dimensions.font = .systemFont(ofSize: 10)
        dimensions.textColor = .secondaryLabelColor
        for view in [eye, disclosure, thumbnail, linkButton, maskThumbnail, disabledMaskMark, nameLabel, dimensions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // A faint hairline along the bottom of each row marks where one layer ends and the next begins.
        let edge = RowEdgeLine()
        edge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(edge)
        NSLayoutConstraint.activate([
            edge.leadingAnchor.constraint(equalTo: leadingAnchor), edge.trailingAnchor.constraint(equalTo: trailingAnchor),
            edge.bottomAnchor.constraint(equalTo: bottomAnchor), edge.heightAnchor.constraint(equalToConstant: 1),
        ])
        indentation = disclosure.leadingAnchor.constraint(equalTo: eye.trailingAnchor, constant: 0)
        addLayoutGuide(thumbnailSlot)
        addLayoutGuide(maskSlot)
        maskWidth = maskSlot.widthAnchor.constraint(equalToConstant: 0)
        maskGap = maskSlot.leadingAnchor.constraint(equalTo: thumbnailSlot.trailingAnchor, constant: 5)
        thumbnailWidth = thumbnail.widthAnchor.constraint(equalToConstant: 36)
        thumbnailHeight = thumbnail.heightAnchor.constraint(equalToConstant: 36)
        maskThumbnailWidth = maskThumbnail.widthAnchor.constraint(equalToConstant: 30)
        maskThumbnailHeight = maskThumbnail.heightAnchor.constraint(equalToConstant: 30)
        NSLayoutConstraint.activate([
            eye.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            eye.centerYAnchor.constraint(equalTo: topAnchor, constant: 26),
            eye.widthAnchor.constraint(equalToConstant: 20), eye.heightAnchor.constraint(equalToConstant: 32),
            indentation,
            disclosure.centerYAnchor.constraint(equalTo: topAnchor, constant: 26),
            disclosure.widthAnchor.constraint(equalToConstant: 16), disclosure.heightAnchor.constraint(equalToConstant: 24),
            thumbnailSlot.leadingAnchor.constraint(equalTo: disclosure.trailingAnchor, constant: -2),
            thumbnailSlot.widthAnchor.constraint(equalToConstant: 36),
            thumbnailSlot.topAnchor.constraint(equalTo: topAnchor), thumbnailSlot.bottomAnchor.constraint(equalTo: topAnchor, constant: 52),
            thumbnail.centerXAnchor.constraint(equalTo: thumbnailSlot.centerXAnchor),
            thumbnail.centerYAnchor.constraint(equalTo: topAnchor, constant: 26),
            thumbnailWidth, thumbnailHeight,
            maskGap,
            linkButton.centerXAnchor.constraint(equalTo: maskSlot.leadingAnchor, constant: -6.5),
            linkButton.centerYAnchor.constraint(equalTo: topAnchor, constant: 26),
            linkButton.widthAnchor.constraint(equalToConstant: 9), linkButton.heightAnchor.constraint(equalToConstant: 20),
            maskWidth,
            maskSlot.topAnchor.constraint(equalTo: topAnchor), maskSlot.bottomAnchor.constraint(equalTo: topAnchor, constant: 52),
            maskThumbnail.centerXAnchor.constraint(equalTo: maskSlot.centerXAnchor),
            maskThumbnail.centerYAnchor.constraint(equalTo: topAnchor, constant: 26),
            maskThumbnailWidth, maskThumbnailHeight,
            disabledMaskMark.centerXAnchor.constraint(equalTo: maskThumbnail.centerXAnchor),
            disabledMaskMark.centerYAnchor.constraint(equalTo: maskThumbnail.centerYAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: maskSlot.trailingAnchor, constant: 5),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            dimensions.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            dimensions.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            dimensions.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3)
        ])
        let menu = NSMenu()
        for (title, action) in [("Rename…", #selector(rename)), ("Hide/Show Layer", #selector(toggleVisibility)),
                                ("Add White Mask", #selector(addWhiteMask)), ("Add Black Mask", #selector(addBlackMask)),
                                ("Enable/Disable Mask", #selector(toggleMask)), ("Delete Mask", #selector(deleteMask)), ("Release Clipping Mask", #selector(removeLiveMask)),
                                ("Move Out of Folder", #selector(moveOut)), ("Delete Layer / Folder", #selector(deleteLayer))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        self.menu = menu
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ layer: ImageLayer, enabled: Bool, session: EditorSession, depth: Int, visible: Bool) {
        self.session = session
        for row in effectButtons { effectRows.removeArrangedSubview(row); row.removeFromSuperview() }
        effectButtons = (layer.effects?.kinds ?? []).map { kind in
            let row = LayerEffectRow(session: session, layerID: layer.id, kind: kind,
                                     enabled: layer.effects?.isEnabled(kind) == true,
                                     // The same step in as the row above them, so a clipped layer's effects sit
                                     // under its name rather than out to the left of it.
                                     indent: CGFloat(min(depth, 8)) * 24 + (layer.maskSourceID == nil ? 0 : 24))
            effectRows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: effectRows.widthAnchor).isActive = true
            return row
        }
        // A folder steps its contents in by the same distance a clipping mask does; the two add up.
        indentation.constant = CGFloat(min(depth, 8)) * 24 + (layer.maskSourceID == nil ? 0 : 24)
        disclosure.isHidden = !layer.isGroup
        disclosure.isEnabled = enabled
        disclosure.image = NSImage(systemSymbolName: session.collapsedGroupIDs.contains(layer.id) ? "chevron.right" : "chevron.down", accessibilityDescription: "Expand or collapse folder")
        // Pixel layers and masks show the whole canvas with their pixels where they sit, as Photoshop does;
        // editable text, adjustments and folders keep a square icon. Pictures redraw only when what they show changes.
        let canvas = session.document?.size ?? CGSize(width: 1, height: 1)
        let editableText = layer.liveText != nil
        let framed = layer.adjustment == nil && !layer.isGroup && !editableText
        let layerSize = framed ? CanvasThumbnail.fittedSize(canvas: canvas, box: 36) : CGSize(width: 36, height: 36)
        thumbnailWidth.constant = layerSize.width
        thumbnailHeight.constant = layerSize.height
        let key = ThumbnailKey(image: layer.asset.map { ObjectIdentifier($0.thumbnail) }, transform: layer.transform, canvas: canvas, editableText: editableText)
        if layerID != layer.id || thumbnailKey != key {
            thumbnail.image = layer.adjustment.map { Self.adjustmentIcon($0.kind.symbol, description: $0.kind.rawValue, quarterTurnClockwise: $0.kind == .curves) }
                ?? (layer.isGroup ? Self.folderIcon
                    : editableText ? Self.adjustmentIcon("textformat", description: "Editable text")
                    : CanvasThumbnail.layer(layer.asset?.thumbnail, transform: layer.transform, canvas: canvas, box: 36))
            thumbnailKey = key
        }
        let maskSize = CanvasThumbnail.fittedSize(canvas: canvas, box: 30)
        maskThumbnailWidth.constant = maskSize.width
        maskThumbnailHeight.constant = maskSize.height
        let maskKey = ThumbnailKey(image: layer.mask.map { ObjectIdentifier($0.asset.thumbnail) }, transform: layer.maskTransform, canvas: canvas)
        if layerID != layer.id || maskThumbnailKey != maskKey {
            maskThumbnail.image = layer.mask.map { CanvasThumbnail.mask($0.asset.thumbnail, transform: layer.maskTransform, canvas: canvas, box: 30) }
            maskThumbnailKey = maskKey
        }
        layerID = layer.id
        maskThumbnail.isHidden = layer.mask == nil
        maskThumbnail.layerID = layer.id
        maskWidth.constant = layer.mask == nil ? 0 : 30
        disabledMaskMark.isHidden = layer.mask?.isEnabled != false
        thumbnail.isEnabled = !session.showsBusy && !session.isImporting
        maskThumbnail.isEnabled = thumbnail.isEnabled
        let linkable = layer.mask != nil && layer.adjustment == nil && !layer.isGroup
        maskGap.constant = linkable ? 13 : 5
        linkButton.isHidden = !linkable
        linkButton.image = layer.mask?.isLinked == false ? nil : Self.linkImage
        linkButton.isEnabled = thumbnail.isEnabled
        linkButton.toolTip = layer.mask?.isLinked == false ? "Link layer and mask so they move together"
            : "Unlink layer and mask to move or transform them separately"
        linkButton.setAccessibilityLabel(layer.mask?.isLinked == false ? "Link mask: \(layer.name)" : "Unlink mask: \(layer.name)")
        thumbnail.toolTip = editableText ? "Editable text layer" : "Select image pixels"
        maskThumbnail.toolTip = "Select layer mask; Shift-click to enable/disable; Cmd-click to select its black areas (Cmd-Shift adds, Cmd-Option subtracts)"
        thumbnail.setAccessibilityLabel("Select \(editableText ? "text" : "image"): \(layer.name)")
        maskThumbnail.setAccessibilityLabel("Select mask: \(layer.name)")
        updateTarget()
        layerName = layer.name
        // A reused cell must not carry another row's half-finished rename.
        if renaming, layerID != layer.id { restoreLabel() }
        if !renaming { nameLabel.stringValue = (layer.maskSourceID == nil ? "" : "↳ ") + layer.name }
        dimensions.stringValue = layer.liveText != nil ? "Text" : layer.adjustment != nil ? "Adjustment · Double-click to edit" : layer.isGroup ? "Folder" : "\(Int(layer.size.width.rounded())) × \(Int(layer.size.height.rounded())) px"
        if let source = layer.maskSourceID {
            let sourceName = session.document?.layers.first(where: { $0.id == source })?.name ?? "Missing source"
            dimensions.stringValue = "Clipped to \(sourceName)"
            dimensions.toolTip = "Clipping mask based on \(sourceName). Option-click the bottom of its row to release."
        } else { dimensions.toolTip = nil }
        eye.image = NSImage(systemSymbolName: layer.isVisible ? "eye" : "eye.slash", accessibilityDescription: nil)
        eye.setAccessibilityLabel("\(layer.isVisible ? "Hide" : "Show") \(layer.name)")
        eye.isEnabled = enabled
        eye.layerID = layer.id
        eye.session = session
        alphaValue = visible ? 1 : 0.35
    }
    private var maskThumbnailKey: ThumbnailKey?
    func selectEffect(at point: NSPoint, editing: Bool) -> Bool {
        guard let row = effectButtons.first(where: { $0.bounds.contains($0.convert(point, from: nil)) }) else { return false }
        row.select(editing: editing)
        return true
    }
    func updateTarget() {
        effectButtons.forEach { $0.updateSelection() }
        if let layer = session?.document?.layers.first(where: { $0.id == layerID }),
           let sourceID = layer.maskSourceID,
           let source = session?.document?.layers.first(where: { $0.id == sourceID }) {
            dimensions.stringValue = "Clipped to \(source.name)"
            dimensions.toolTip = "Clipping mask based on \(source.name). Option-click the bottom of its row to release."
        }
        let active = session?.activeLayerID == layerID && session?.selectedLayerIDs.count == 1
        let mask = session?.isMaskSelected == true
        thumbnail.layer?.borderColor = NSColor.controlAccentColor.cgColor
        maskThumbnail.layer?.borderColor = NSColor.controlAccentColor.cgColor
        thumbnail.layer?.borderWidth = active && !mask ? 2 : 0
        maskThumbnail.layer?.borderWidth = active && mask ? 2 : 0
    }
    /// Types the layer's name in the row: Return keeps it, Escape leaves it as it was, as does clicking away.
    func beginRenaming() {
        // Not `canEditLayers`: that is false while a rename is pending, which is exactly when this runs.
        guard !renaming, let session, layerID != nil,
              session.document != nil, !session.isProjectBusy, !session.isImporting else { return }
        renaming = true
        nameLabel.isEditable = true
        nameLabel.isSelectable = true
        nameLabel.isBezeled = true
        nameLabel.bezelStyle = .roundedBezel
        nameLabel.drawsBackground = true
        nameLabel.delegate = self
        nameLabel.stringValue = layerName
        window?.makeFirstResponder(nameLabel)
        nameLabel.currentEditor()?.selectAll(nil)
    }
    private func restoreLabel() {
        renaming = false
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        nameLabel.isBezeled = false
        nameLabel.drawsBackground = false
        nameLabel.delegate = nil
    }
    private func endRenaming(keeping: Bool) {
        guard renaming, let session, let layerID else { return }
        let typed = nameLabel.stringValue
        restoreLabel()
        if keeping { session.renameLayer(layerID, to: typed) }
        if session.renamingLayerID == layerID { session.renamingLayerID = nil }
        // Show whatever name the layer ended up with, marked as the row shows it.
        if let layer = session.document?.layers.first(where: { $0.id == layerID }) {
            layerName = layer.name
            nameLabel.stringValue = (layer.maskSourceID == nil ? "" : "↳ ") + layer.name
        }
        // Hand focus back to the list, so tool shortcuts and the arrow keys work straight away.
        var ancestor = superview
        while ancestor != nil && !(ancestor is NSTableView) { ancestor = ancestor?.superview }
        if let table = ancestor { window?.makeFirstResponder(table) }
    }
    func controlTextDidEndEditing(_ notification: Notification) { endRenaming(keeping: true) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        endRenaming(keeping: false)
        return true
    }
    @objc private func selectImage() { if let layerID { session?.selectLayerTarget(layerID, mask: false) } }
    @objc private func toggleMaskLink() { if let layerID { session?.toggleMaskLink(layerID) } }
    /// Whether a window point lands on one of the row's buttons rather than its name.
    func isOnControl(_ windowPoint: NSPoint) -> Bool {
        [eye, disclosure, thumbnail, linkButton, maskThumbnail].contains { !$0.isHidden && $0.bounds.contains($0.convert(windowPoint, from: nil)) }
    }
    @objc func loadMaskSelection() {
        guard let layerID else { return }
        session?.loadMaskSelection(layerID: layerID, mode: Self.loadMode)
    }
    @objc func loadLayerSelection() {
        guard let layerID else { return }
        session?.loadLayerSelection(layerID: layerID, mode: Self.loadMode)
    }
    /// Cmd-Shift adds and Cmd-Option subtracts, as in Photoshop.
    private static var loadMode: SelectionMode {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        return flags.contains(.option) ? .subtract : flags.contains(.shift) ? .add : .replace
    }
    @objc private func selectMask() {
        guard let layerID else { return }
        session?.selectLayerTarget(layerID, mask: true)
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { session?.toggleLayerMask() }
    }
    @objc private func addWhiteMask() { selectImage(); session?.addMask() }
    @objc private func addBlackMask() { selectImage(); session?.addMask(revealing: false) }
    @objc private func toggleMask() { selectImage(); session?.toggleLayerMask() }
    @objc private func removeLiveMask() { if let layerID { session?.removeLiveMask(from: layerID) } }
    @objc private func deleteMask() { selectImage(); session?.deleteLayerMask() }
    @objc private func toggleExpansion() { if let layerID { session?.toggleGroupExpansion(layerID) } }
    @objc private func moveOut() {
        guard let session, let layerID else { return }
        session.selectLayer(layerID)
        session.moveActiveLayerOutOfGroup()
    }
    private var thumbnailKey: ThumbnailKey?
    @objc private func toggleVisibility() { if let layerID { session?.toggleLayerVisibility(layerID) } }
    /// Delete on a row that's part of a multi-selection removes the whole selection, like the trash button.
    @objc private func deleteLayer() {
        guard let layerID, let session else { return }
        if session.selectedLayerIDs.count > 1, session.selectedLayerIDs.contains(layerID) { session.deleteSelectedLayers() }
        else { session.deleteLayer(layerID) }
    }
    @objc private func rename() {
        guard let session, session.canEditLayers, let layerID else { return }
        session.activeLayerID = layerID
        session.renamingLayerID = layerID
    }
    /// Adjustment layers' icons, a little smaller than a bare symbol shows in the thumbnail (roughly
    /// 15.5 pt instead of 18). Drawn into a 36 pt template image (the thumbnail's size), which the button
    /// shows 1:1 and still tints; 1.21× the symbol's natural size lands the glyph there.
    private static var adjustmentIcons: [String: NSImage] = [:]
    /// The folder symbol at 80% of the size it would fill the thumbnail slot with.
    private static let folderIcon: NSImage? = {
        guard let symbol = NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder") else { return nil }
        let fit = 36 * 0.8 / max(symbol.size.width, symbol.size.height)
        let size = NSSize(width: symbol.size.width * fit, height: symbol.size.height * fit)
        let icon = NSImage(size: NSSize(width: 36, height: 36), flipped: false) { bounds in
            symbol.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
            return true
        }
        icon.isTemplate = true
        icon.accessibilityDescription = "Folder"
        return icon
    }()
    private static func adjustmentIcon(_ symbolName: String, description: String, quarterTurnClockwise: Bool = false) -> NSImage? {
        if let icon = adjustmentIcons[symbolName] { return icon }
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: description) else { return nil }
        let size = NSSize(width: symbol.size.width * 1.21, height: symbol.size.height * 1.21)
        let icon = NSImage(size: NSSize(width: 36, height: 36), flipped: false) { bounds in
            let transform = NSAffineTransform()
            transform.translateX(by: bounds.midX, yBy: bounds.midY)
            // y points up in this image, so a negative angle turns clockwise.
            if quarterTurnClockwise { transform.rotate(byDegrees: -90) }
            transform.concat()
            symbol.draw(in: NSRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
            return true
        }
        icon.isTemplate = true
        icon.accessibilityDescription = description
        adjustmentIcons[symbolName] = icon
        return icon
    }
}

/// An effect belongs visually to its layer but has its own selection and visibility control.
private final class LayerEffectRow: NSView, NSDraggingSource {
    fileprivate weak var session: EditorSession?
    fileprivate let layerID: UUID
    fileprivate let kind: LayerEffectKind
    private var copyDown: NSEvent?
    private let eye = NSButton()
    private let label: NSTextField
    init(session: EditorSession, layerID: UUID, kind: LayerEffectKind, enabled: Bool, indent: CGFloat) {
        self.session = session; self.layerID = layerID; self.kind = kind
        label = NSTextField(labelWithString: kind.localizedName)
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        eye.isBordered = false
        eye.image = NSImage(systemSymbolName: enabled ? "eye" : "eye.slash", accessibilityDescription: nil)
        eye.imagePosition = .imageOnly
        eye.contentTintColor = .secondaryLabelColor
        eye.target = self; eye.action = #selector(toggle)
        eye.isEnabled = session.canEditLayers
        eye.setAccessibilityLabel(String(format: localizedString(enabled ? "Hide %@" : "Show %@"), kind.localizedName))
        label.font = .systemFont(ofSize: 11)
        label.textColor = enabled ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        for view in [eye, label] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            eye.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 38 + indent),
            eye.centerYAnchor.constraint(equalTo: centerYAnchor),
            eye.widthAnchor.constraint(equalToConstant: 20), eye.heightAnchor.constraint(equalToConstant: 22),
            label.leadingAnchor.constraint(equalTo: eye.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        ])
        toolTip = String(format: localizedString("Click to select; double-click to edit; Option-drag to copy %@"), kind.localizedName)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(format: localizedString("%@ effect"), kind.localizedName))
        updateSelection()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        if flags.contains(.option), !flags.contains(.command) { return self }
        return eye.frame.contains(local) ? eye : self
    }
    func select(editing: Bool) {
        session?.selectEffect(kind, on: layerID, editing: editing)
        var ancestor = superview
        while let view = ancestor, !(view is NSTableView) { ancestor = view.superview }
        if let ancestor { window?.makeFirstResponder(ancestor) }
        updateSelection()
    }
    override func mouseDown(with event: NSEvent) {
        copyDown = nil
        if event.modifierFlags.contains(.option), !event.modifierFlags.contains(.command), session?.canEditLayers == true {
            copyDown = event
        } else { select(editing: event.clickCount > 1) }
    }
    override func mouseUp(with event: NSEvent) {
        if copyDown != nil { copyDown = nil; select(editing: false) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let down = copyDown else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard dx * dx + dy * dy >= 9 else { return }
        copyDown = nil
        guard event.modifierFlags.contains(.option), session?.canEditLayers == true else { return }
        let item = NSPasteboardItem()
        item.setString(layerID.uuidString + ":" + kind.rawValue, forType: NativeLayerList.Coordinator.effectType)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let snapshot = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            snapshot.addRepresentation(rep)
        }
        dragging.setDraggingFrame(bounds, contents: snapshot)
        beginDraggingSession(with: [dragging], event: down, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : []
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { select(editing: false); return true }
    @objc private func toggle() { session?.toggleEffect(kind, on: layerID) }
    func updateSelection() {
        let selected = session?.selectedEffect == LayerEffectSelection(layerID: layerID, kind: kind)
        layer?.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor : NSColor.clear.cgColor
    }
}

/// Select on mouse-down, then let the table retain native drag and multiselect tracking.
private final class LayerThumbnailButton: NSButton, NSDraggingSource {
    /// The row's layer, for a mask thumbnail's Option-drag.
    var layerID: UUID?
    var isMaskTarget = false { didSet { updateTrackingAreas() } }
    /// Image thumbnails also load a selection on Cmd-click (masks always do).
    var loadsSelection = false { didSet { updateTrackingAreas() } }
    var cmdClickLoads: Bool { isMaskTarget || loadsSelection }
    private var hoverArea: NSTrackingArea?
    private var hovering = false
    private var modifierMonitor: Any?

    // Mask thumbnails show the load-selection cursor while hovered with Cmd held.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = nil
        guard cmdClickLoads else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate,
                                                         .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) {
        guard cmdClickLoads else { return }
        hovering = true
        if modifierMonitor == nil {
            modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                guard let self else { return event }
                self.updateCursor(event.modifierFlags)
                DispatchQueue.main.async { [weak self] in self?.updateCursor(NSEvent.modifierFlags) }
                return event
            }
        }
        updateCursor(event.modifierFlags)
    }
    override func mouseMoved(with event: NSEvent) { if hovering { updateCursor(event.modifierFlags) } }
    override func cursorUpdate(with event: NSEvent) {
        if hovering { updateCursor(event.modifierFlags) } else { super.cursorUpdate(with: event) }
    }
    override func mouseExited(with event: NSEvent) {
        guard hovering else { return }
        hovering = false
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
        modifierMonitor = nil
        // The list decides what the cursor is anywhere else in the row; leaving a thumbnail is not a reason to
        // drop the clipping or duplicate cursor it is showing.
        var ancestor = superview
        while ancestor != nil && !(ancestor is LayerTableView) { ancestor = ancestor?.superview }
        if let table = ancestor as? LayerTableView { table.refreshClippingCursor(NSEvent.modifierFlags) }
        else { NSCursor.arrow.set() }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, let modifierMonitor { NSEvent.removeMonitor(modifierMonitor); self.modifierMonitor = nil }
    }
    private func updateCursor(_ flags: NSEvent.ModifierFlags) {
        guard hovering, isEnabled else { return }
        if flags.contains(.option), !flags.contains(.command) {
            var ancestor = superview
            while ancestor != nil && !(ancestor is LayerTableView) { ancestor = ancestor?.superview }
            (ancestor as? LayerTableView)?.refreshClippingCursor(flags)
            return
        }
        (flags.contains(.command) ? CanvasView.loadSelectionCursor : NSCursor.arrow).set()
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        var ancestor = superview
        while ancestor != nil && !(ancestor is NSTableView) { ancestor = ancestor?.superview }
        guard let table = ancestor as? NSTableView else { super.mouseDown(with: event); return }
        if event.modifierFlags.contains(.option), !event.modifierFlags.contains(.command) {
            if isMaskTarget, !isHidden { dragMaskCopy(event); return }
            table.mouseDown(with: event)
            return
        }
        if cmdClickLoads && event.modifierFlags.contains(.command) {
            // Cmd-click on a thumbnail loads a selection; elsewhere in the row it multi-selects.
            _ = target?.perform(isMaskTarget ? #selector(LayerCell.loadMaskSelection) : #selector(LayerCell.loadLayerSelection))
            return
        }
        if isMaskTarget && event.modifierFlags.contains(.shift) {
            sendAction(action, to: target)
            return
        }
        if event.modifierFlags.intersection([.command, .shift]).isEmpty { sendAction(action, to: target) }
        table.mouseDown(with: event)
    }
}

extension LayerThumbnailButton {
    /// Option-drag from a mask thumbnail carries a copy of the mask to another row; a click without a drag just
    /// selects the mask.
    fileprivate func dragMaskCopy(_ down: NSEvent) {
        guard let window, let layerID else { return }
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if event.type == .leftMouseUp { sendAction(action, to: target); return }
            let dx = event.locationInWindow.x - down.locationInWindow.x, dy = event.locationInWindow.y - down.locationInWindow.y
            guard dx * dx + dy * dy >= 9 else { continue }
            let item = NSPasteboardItem()
            item.setString(layerID.uuidString, forType: NativeLayerList.Coordinator.maskType)
            let dragging = NSDraggingItem(pasteboardWriter: item)
            let snapshot = NSImage(size: bounds.size)
            if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
                cacheDisplay(in: bounds, to: rep)
                snapshot.addRepresentation(rep)
            }
            dragging.setDraggingFrame(bounds, contents: snapshot)
            beginDraggingSession(with: [dragging], event: down, source: self)
            return
        }
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : []
    }
}
/// One device pixel of faint white, ignored by clicks.
private final class RowEdgeLine: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let scale = window?.backingScaleFactor ?? 2
        NSColor.white.withAlphaComponent(0.06).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1 / scale).fill()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
/// A layer's eye. Pressing it shows or hides the layer; keeping the button down and dragging up or down the list
/// gives every eye passed over the same state, as in Photoshop.
private final class EyeSwipeButton: NSButton {
    var layerID: UUID?
    weak var session: EditorSession?
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let layerID, let session, let window,
              let visible = session.beginVisibilitySwipe(layerID) else { return }
        // Showing or hiding a layer reloads its row, which can take this very button out of the list; tracking the
        // drag here, rather than waiting for mouseDragged and mouseUp to arrive, keeps the undo step from being left
        // open if it does.
        defer { session.endVisibilitySwipe() }
        var ancestor = superview
        while ancestor != nil && !(ancestor is NSTableView) { ancestor = ancestor?.superview }
        guard let table = ancestor as? NSTableView else { return }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { return }
            let row = table.row(at: table.convert(next.locationInWindow, from: nil))
            guard session.layerRows.indices.contains(row) else { continue }
            session.setVisibilityInSwipe(session.layerRows[row].layer.id, visible: visible)
            table.autoscroll(with: next)
        }
    }
}
private final class MaskDisabledMark: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// What a row's canvas-framed thumbnail shows, so it redraws only when one of these changes.
private struct ThumbnailKey: Equatable {
    let image: ObjectIdentifier?
    let transform: LayerTransform
    let canvas: CGSize
    var editableText = false
}
