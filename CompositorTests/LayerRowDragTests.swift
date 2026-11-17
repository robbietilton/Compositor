import AppKit
import SwiftUI
import Testing
@testable import Compositor

/// The Layers list draws its own row drag: the picked-up row stays within the list, so dragged up over the blend and
/// opacity controls it waits at the top, and a release there puts the layer first; out of the panel, it hands over to
/// an ordinary drag. Driven here by real mouse events, as a hand would.
@MainActor struct LayerRowDragTests {
    private struct Rig {
        let session: EditorSession
        let window: NSWindow
        let host: NSView
        let table: LayerTableView
    }

    private func rig() throws -> Rig {
        let session = EditorSession()
        session.createDocument(width: 400, height: 300)
        for _ in 0..<3 { session.addBlankLayer() }
        let host = NSHostingView(rootView: LayersPanel(session: session))
        host.frame = CGRect(x: 0, y: 0, width: 261, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.13, alpha: 1)
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        session.layersPanelFrame = CGRect(origin: .zero, size: host.frame.size)
        // The controls' place, as the panel reports it once laid out.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap { descendants($0) } }
        let table = try #require(descendants(host).compactMap { $0 as? LayerTableView }.first)
        return Rig(session: session, window: window, host: host, table: table)
    }

    private func mouse(_ type: NSEvent.EventType, _ point: NSPoint, in window: NSWindow, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                        pressure: type == .leftMouseUp ? 0 : 1))
    }

    /// The middle of row `row`, in window coordinates.
    private func middle(of row: Int, in table: NSTableView) -> NSPoint {
        let frame = table.rect(ofRow: row)
        return table.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
    }

    private func names(_ session: EditorSession) -> [String] { session.filteredLayerRows.map(\.layer.name) }

    private func picture(of view: NSView) -> Data? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    @Test func draggedUpOverTheBlendAndOpacityControlsItWaitsAtTheTopAndGoesFirst() throws {
        let rig = try rig()
        defer { rig.window.orderOut(nil); LayerTableView.rowDragStepForTesting = nil }
        let before = names(rig.session)
        #expect(before.count == 3)
        let start = middle(of: 2, in: rig.table)
        // Up the list, then on up over the controls above it (window y grows upward).
        // The list's top edge and the panel's, in window coordinates: the drag ends between them, over the controls.
        let scroll = try #require(rig.table.enclosingScrollView)
        let listTop = scroll.convert(NSPoint(x: 0, y: scroll.isFlipped ? 0 : scroll.bounds.maxY), to: nil).y
        let controls = listTop + 45
        #expect(controls < rig.host.frame.height - 20, "the controls are above the list")
        let path = [start.y + 10, start.y + 40, listTop - 10, listTop + 15, controls, controls]
        var steps: [(top: CGFloat, listTop: CGFloat, target: Int?, pointerAboveList: Bool)] = []
        var shots: [Data] = []
        LayerTableView.rowDragStepForTesting = { table, picture, target in
            let scroll = table.enclosingScrollView!
            let pictureTop = picture.convert(NSPoint(x: 0, y: picture.isFlipped ? 0 : picture.bounds.maxY), to: nil).y
            let listTop = scroll.convert(NSPoint(x: 0, y: scroll.isFlipped ? 0 : scroll.bounds.maxY), to: nil).y
            let pointer = NSEvent.mouseLocation // not used; pointer is from the events
            _ = pointer
            steps.append((pictureTop, listTop, target?.row, false))
            if let data = self.picture(of: rig.host) { shots.append(data) }
        }
        for y in path { NSApp.postEvent(try mouse(.leftMouseDragged, NSPoint(x: start.x, y: y), in: rig.window), atStart: false) }
        NSApp.postEvent(try mouse(.leftMouseUp, NSPoint(x: start.x, y: path.last!), in: rig.window), atStart: false)
        var handedOver = false
        rig.table.beginsOutsideDrag = { _, _, _, _, _ in handedOver = true }
        rig.table.mouseDown(with: try mouse(.leftMouseDown, start, in: rig.window))
        #expect(!handedOver, "it left the list for an ordinary drag while still over the panel")
        #expect(steps.count >= 4, "the drag never ran: \(steps.count) steps")
        // Window y grows upward: over the controls the row's picture has followed the pointer up past the list's top.
        #expect((steps.last?.top ?? 0) > (steps.last?.listTop ?? 0), "the picture should follow up over the controls")
        #expect(steps.last?.target == 0, "over the controls it should land first, not \(String(describing: steps.last?.target))")
        let after = names(rig.session)
        #expect(after.first == before[2], "the dragged layer should be first: \(after)")
        for (index, data) in shots.enumerated() where index == 1 || index == 3 || index == shots.count - 1 {
            Attachment.record(data, named: "drag-step-\(index).png")
        }
    }

    @Test func aboveTheControlsItBecomesAnOrdinaryDrag() throws {
        let rig = try rig()
        defer { rig.window.orderOut(nil) }
        #expect(!rig.session.layerControlsFrame.isEmpty, "the panel reported where its controls are")
        let before = names(rig.session)
        var handedOver = false
        rig.table.beginsOutsideDrag = { _, _, _, _, _ in handedOver = true }
        let start = middle(of: 1, in: rig.table)
        // The controls' top edge, in window coordinates (y up), and a little above it.
        let above = rig.host.frame.height - rig.session.layerControlsFrame.minY + 12
        NSApp.postEvent(try mouse(.leftMouseDragged, NSPoint(x: start.x, y: start.y + 30), in: rig.window), atStart: false)
        NSApp.postEvent(try mouse(.leftMouseDragged, NSPoint(x: start.x, y: above), in: rig.window), atStart: false)
        rig.table.mouseDown(with: try mouse(.leftMouseDown, start, in: rig.window))
        #expect(handedOver)
        #expect(names(rig.session) == before)
    }

    /// Once a drag has left for the system's (above the controls) and comes back over them, the controls hand it to the
    /// list as at its top: a release there puts the layer first.
    @Test func aDragComingBackOverTheControlsGoesFirst() throws {
        let rig = try rig()
        defer { rig.window.orderOut(nil) }
        let dragged = rig.session.filteredLayerRows[2].layer
        rig.session.layerDragIsOutside = true
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        rig.host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap { descendants($0) } }
        let forwarder = try #require(descendants(rig.host).compactMap { $0 as? LayerDropForwarder.ForwardingView }.first,
                                     "the controls take a returning drag")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("layer-drag-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(dragged.id.uuidString, forType: NativeLayerList.Coordinator.layerType)
        pasteboard.writeObjects([item])
        let location = forwarder.convert(NSPoint(x: forwarder.bounds.midX, y: forwarder.bounds.midY), to: nil)
        let drag = FakeDrag(pasteboard: pasteboard, source: rig.table, location: location, window: rig.window)
        #expect(forwarder.draggingEntered(drag) == .move)
        #expect(forwarder.draggingUpdated(drag) == .move)
        #expect(forwarder.prepareForDragOperation(drag))
        #expect(forwarder.performDragOperation(drag))
        #expect(rig.session.filteredLayerRows.first?.layer.id == dragged.id, "the layer should be first: \(names(rig.session))")
        rig.session.layerDragIsOutside = false
    }

    @Test func aClickWithoutMovingStillSelectsAndMovesNothing() throws {
        let rig = try rig()
        defer { rig.window.orderOut(nil) }
        let before = names(rig.session)
        let point = middle(of: 1, in: rig.table)
        NSApp.postEvent(try mouse(.leftMouseUp, point, in: rig.window), atStart: false)
        rig.table.mouseDown(with: try mouse(.leftMouseDown, point, in: rig.window))
        #expect(names(rig.session) == before)
        #expect(rig.table.selectedRowIndexes == IndexSet(integer: 1))
    }

    @Test func leavingThePanelHandsOverToAnOrdinaryDrag() throws {
        let rig = try rig()
        defer { rig.window.orderOut(nil) }
        let before = names(rig.session)
        var handedOver: [UUID]?
        rig.table.beginsOutsideDrag = { _, ids, _, _, _ in handedOver = ids }
        let start = middle(of: 1, in: rig.table)
        NSApp.postEvent(try mouse(.leftMouseDragged, NSPoint(x: start.x - 20, y: start.y), in: rig.window), atStart: false)
        NSApp.postEvent(try mouse(.leftMouseDragged, NSPoint(x: -30, y: start.y), in: rig.window), atStart: false)
        rig.table.mouseDown(with: try mouse(.leftMouseDown, start, in: rig.window))
        #expect(handedOver == [rig.session.filteredLayerRows[1].layer.id])
        #expect(names(rig.session) == before, "nothing moves within the list")
    }
}

/// A drag, made up for a test: the list's own, carrying `pasteboard`, at `location` in `window`.
private final class FakeDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?
    let draggingLocation: NSPoint
    let draggingDestinationWindow: NSWindow?
    init(pasteboard: NSPasteboard, source: Any?, location: NSPoint, window: NSWindow) {
        draggingPasteboard = pasteboard; draggingSource = source; draggingLocation = location; draggingDestinationWindow = window
    }
    var draggingSourceOperationMask: NSDragOperation { [.move, .copy] }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
