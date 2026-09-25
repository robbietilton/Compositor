import AppKit
import SwiftUI
import Testing
@testable import Compositor

/// A tool's cursor must not stay behind once the mouse is over the Layers panel.
@MainActor
@Suite(.serialized)
struct CursorTests {
    private func mouse(at point: NSPoint, flags: NSEvent.ModifierFlags = [], in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: flags, timestamp: 0,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
    }

    @Test func emptyCanvasLeavesTheScrubberCursorAloneAndRestoresTrackingForADocument() {
        let session = EditorSession()
        let view = CanvasView(session: session)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        let pointer = mouse(at: NSPoint(x: 200, y: 150), in: window)
        defer { NSCursor.arrow.set() }

        func hasCanvasTracking() -> Bool {
            view.trackingAreas.contains { $0.owner === view && $0.options.contains(.mouseEnteredAndExited) }
        }
        func checkEmptyCanvas() {
            view.synchronizeDisplay()
            #expect(!hasCanvasTracking())
            NSCursor.resizeLeftRight.set()
            view.resetCursorRects()
            view.mouseMoved(with: pointer)
            view.cursorUpdate(with: pointer)
            view.mouseExited(with: pointer)
            let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 200, y: 150),
                                          modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            let release = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: -20, y: 150),
                                             modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
            view.mouseDragged(with: drag)
            view.mouseUp(with: release)
            #expect(NSCursor.current === NSCursor.resizeLeftRight,
                    "Document-close callbacks must not replace a form control's cursor")
        }

        checkEmptyCanvas()
        session.createDocument(width: 400, height: 300)
        view.synchronizeDisplay()
        #expect(hasCanvasTracking())
        session.clearProject()
        checkEmptyCanvas()
    }

    @Test func leavingTheCanvasRestoresTheArrowWithEveryTool() {
        let session = EditorSession()
        session.createDocument(width: 400, height: 300)
        let view = CanvasView(session: session)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        for tool in NavigationTool.allCases {
            session.selectTool(tool)
            view.synchronizeDisplay()
            #expect(view.trackingAreas.contains { $0.owner === view && $0.options.contains(.mouseEnteredAndExited) },
                    "\(tool): the canvas never hears the mouse leave")
            NSCursor.crosshair.set()
            view.mouseExited(with: mouse(at: NSPoint(x: -5, y: 150), in: window))
            #expect(NSCursor.current === NSCursor.arrow, "\(tool): the tool's cursor stayed after leaving the canvas")
        }
    }

    @Test func aDragReleasedOutsideTheCanvasRestoresTheArrow() {
        let session = EditorSession()
        session.createDocument(width: 400, height: 300)
        session.selectTool(.hand)
        let view = CanvasView(session: session)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        func click(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: click(.leftMouseDown, at: NSPoint(x: 200, y: 150)))
        #expect(NSCursor.current === NSCursor.closedHand)
        view.mouseUp(with: click(.leftMouseUp, at: NSPoint(x: -20, y: 150)))
        #expect(NSCursor.current === NSCursor.arrow)
    }

    @Test func theLayerListShowsTheArrowUnlessAModifierCursorApplies() throws {
        let session = EditorSession()
        session.createDocument(width: 400, height: 300)
        session.addBlankLayer()
        let host = NSHostingView(rootView: LayersPanel(session: session))
        host.frame = CGRect(x: 0, y: 0, width: 252, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> LayerTableView? {
            if let table = view as? LayerTableView { return table }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        let table = try #require(find(host))
        // Over the first row's name, away from its thumbnails.
        let inside = table.convert(NSPoint(x: table.visibleRect.midX, y: table.visibleRect.minY + 4), to: nil)
        // A tool's cursor that followed the mouse in gives way to the arrow.
        NSCursor.crosshair.set()
        table.mouseEntered(with: mouse(at: inside, in: window))
        #expect(NSCursor.current === NSCursor.arrow)
        NSCursor.crosshair.set()
        table.cursorUpdate(with: mouse(at: inside, in: window))
        #expect(NSCursor.current === NSCursor.arrow)
        // Command away from a thumbnail has no cursor of its own either.
        NSCursor.crosshair.set()
        table.mouseMoved(with: mouse(at: inside, flags: .command, in: window))
        #expect(NSCursor.current === NSCursor.arrow)
        // A modifier change while the mouse is elsewhere leaves that view's cursor alone.
        NSCursor.crosshair.set()
        table.refreshClippingCursor([], at: NSPoint(x: -50, y: -50))
        #expect(NSCursor.current === NSCursor.crosshair)
    }

    /// Move tool: Option anywhere shows the duplicate cursor and Cmd over a handle the distort cursor.
    /// Selection tools: Cmd-Option inside a selection shows the duplicate cursor.
    @Test func duplicateAndDistortCursors() throws {
        let session = EditorSession()
        session.createDocument(width: 400, height: 300)
        let context = try BrushRaster.context(width: 100, height: 100, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Red")) // centered: 150–250 × 100–200
        let size = try #require(session.document?.size)
        let view = CanvasView(session: session)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        session.viewport.resize(to: view.bounds.size, backingScale: 1, documentSize: size)
        view.synchronizeDisplay()
        func spot(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            let point = session.viewport.viewPoint(from: CGPoint(x: x, y: y), documentSize: size)
            return NSPoint(x: point.x, y: view.bounds.height - point.y)
        }

        session.selectTool(.move)
        view.mouseMoved(with: mouse(at: spot(200, 150), in: window))
        #expect(NSCursor.current === CanvasView.moveCursor, "the move pointer where a press drags the layer")
        view.mouseMoved(with: mouse(at: spot(200, 150), flags: .option, in: window))
        #expect(NSCursor.current === CanvasView.duplicateCursor, "Option over the layer should offer to duplicate it")
        // AppKit sends a cursor update after every key change with no modifier flags, so it must read the
        // keys as they are now; trusting the event's flags hid the duplicate cursor while Option was held.
        view.cursorUpdate(with: mouse(at: spot(200, 150), flags: .option, in: window))
        #expect(NSCursor.current === (NSEvent.modifierFlags.contains(.option) ? CanvasView.duplicateCursor : CanvasView.moveCursor))
        view.mouseMoved(with: mouse(at: spot(20, 20), flags: .option, in: window))
        #expect(NSCursor.current === CanvasView.duplicateCursor, "a press anywhere drags the active layer, so Option anywhere duplicates it")
        view.mouseMoved(with: mouse(at: spot(20, 20), in: window))
        #expect(NSCursor.current === CanvasView.moveCursor, "outside the layer's bounds a press still drags it")
        let corner = spot(150, 100)
        view.mouseMoved(with: mouse(at: corner, in: window))
        #expect(![NSCursor.arrow, CanvasView.distortCursor, CanvasView.moveCursor].contains { $0 === NSCursor.current }, "a plain handle resizes")
        view.mouseMoved(with: mouse(at: corner, flags: .command, in: window))
        #expect(NSCursor.current === CanvasView.distortCursor, "Cmd over a handle distorts")

        session.selectTool(.marquee)
        session.selectAll()
        view.mouseMoved(with: mouse(at: spot(200, 150), flags: .command, in: window))
        #expect(NSCursor.current === CanvasView.movePixelsCursor)
        view.mouseMoved(with: mouse(at: spot(200, 150), flags: [.command, .option], in: window))
        #expect(NSCursor.current === CanvasView.duplicateCursor, "Cmd-Option inside the selection should offer to copy its pixels")
    }

    /// Hiding the transform controls (⌘H) leaves only moving: no handles to resize or distort, until a
    /// persistent transform brings the box back.
    @Test func hiddenTransformControlsLeaveOnlyMoving() throws {
        let session = EditorSession()
        session.createDocument(width: 400, height: 300)
        let context = try BrushRaster.context(width: 100, height: 100, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Red")) // centered: 150–250 × 100–200
        let size = try #require(session.document?.size)
        let view = CanvasView(session: session)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        session.viewport.resize(to: view.bounds.size, backingScale: 1, documentSize: size)
        session.selectTool(.move)
        view.synchronizeDisplay()
        let corner = session.viewport.viewPoint(from: CGPoint(x: 150, y: 100), documentSize: size)
        let spot = NSPoint(x: corner.x, y: view.bounds.height - corner.y)

        #expect(session.showsTransformControls)
        view.mouseMoved(with: mouse(at: spot, in: window))
        #expect(NSCursor.current !== CanvasView.moveCursor, "with controls shown the corner is a handle")
        session.showsTransformControls = false
        view.mouseMoved(with: mouse(at: spot, in: window))
        #expect(NSCursor.current === CanvasView.moveCursor, "hidden controls leave no handle there")
        view.mouseMoved(with: mouse(at: spot, flags: .command, in: window))
        #expect(NSCursor.current === CanvasView.moveCursor, "nor a distort handle")
        session.beginTransform(persistent: true)
        view.mouseMoved(with: mouse(at: spot, in: window))
        #expect(NSCursor.current !== CanvasView.moveCursor, "a pending transform shows its box again")
        session.cancelTransform()
    }

    /// In the layer list, Option offers to duplicate the layer by dragging, over a row's name and over its
    /// thumbnail alike. The clipping cursor is not the thumbnail's business at all: `clippingCursor(at:)`
    /// reserves it for the bottom quarter of a row (`isClippingZone`). This comment, and the test's name, used
    /// to say a thumbnail kept Option for clipping masks.
    @Test func optionOverALayerRowOffersDuplicatingIncludingOverThumbnails() throws {
        let session = EditorSession()
        session.createDocument(width: 400, height: 300)
        session.addBlankLayer()
        session.addBlankLayer()
        let host = NSHostingView(rootView: LayersPanel(session: session))
        host.frame = CGRect(x: 0, y: 0, width: 252, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap { descendants($0) } }
        let table = try #require(descendants(host).compactMap { $0 as? LayerTableView }.first)
        // Over the first row's name, away from its thumbnails.
        let name = table.convert(NSPoint(x: table.visibleRect.midX, y: table.visibleRect.minY + 4), to: nil)
        NSCursor.arrow.set()
        table.mouseMoved(with: mouse(at: name, flags: .option, in: window))
        #expect(NSCursor.current === CanvasView.duplicateCursor, "Option over a layer's name offers to duplicate it")
        let row = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: false))
        let thumbnail = try #require(descendants(row).first {
            $0 is NSButton && !$0.isHiddenOrHasHiddenAncestor && $0.accessibilityLabel()?.hasPrefix("Select image") == true
        })
        row.layoutSubtreeIfNeeded()
        #expect(thumbnail.frame.size == CGSize(width: 36, height: 27), "the thumbnail takes the 400 × 300 canvas's shape")
        let center = thumbnail.convert(NSPoint(x: thumbnail.bounds.midX, y: thumbnail.bounds.midY), to: nil)
        table.mouseMoved(with: mouse(at: center, flags: .option, in: window))
        // The thumbnail's centre is not in the row's bottom quarter, which is the only place Option means
        // clipping (`clippingCursor(at:)` -> `isClippingZone`), so the list offers to duplicate here as it does
        // over the rest of the row. This asserted the opposite, from when thumbnails kept Option for themselves.
        #expect(NSCursor.current === CanvasView.duplicateCursor, "Option over a thumbnail still offers to duplicate")
        table.mouseMoved(with: mouse(at: name, in: window))
        #expect(NSCursor.current === NSCursor.arrow)
    }
}
