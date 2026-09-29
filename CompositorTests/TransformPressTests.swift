import AppKit
import Testing
@testable import Compositor

/// With the Move tool a press drags the active layer wherever it lands, not only inside its bounds.
///
/// The drags below hold Control, which is what drags a layer freely (EditorCanvas: "Control drags freely").
/// Without it the move snaps to the canvas and to the other layers, and a 20 x 10 drag from the middle of a
/// 400 x 300 canvas lands inside `TransformSnap.distance`, so the layer springs back - the snapping working,
/// not the press failing. What these tests are about is that the press drags at all.
@MainActor
struct TransformPressTests {
    private func makeCanvas() throws -> (EditorSession, CanvasView, NSWindow) {
        let session = EditorSession()
        session.createDocument(width: 400, height: 300)
        let context = try BrushRaster.context(width: 100, height: 100, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Red")) // centered: 150–250 × 100–200
        session.selectTool(.move)
        let view = CanvasView(session: session)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        session.viewport.resize(to: view.bounds.size, backingScale: 1, documentSize: try #require(session.document?.size))
        view.synchronizeDisplay()
        return (session, view, window)
    }

    private func drag(_ session: EditorSession, _ view: CanvasView, in window: NSWindow, from start: CGPoint, to end: CGPoint,
                      flags: NSEvent.ModifierFlags = []) throws {
        let size = try #require(session.document?.size)
        func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            let spot = session.viewport.viewPoint(from: point, documentSize: size)
            return try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: spot.x, y: view.bounds.height - spot.y),
                modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, at: start))
        view.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)))
        view.mouseDragged(with: try event(.leftMouseDragged, at: end))
        view.mouseUp(with: try event(.leftMouseUp, at: end))
    }

    private func near(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5 }

    @Test func draggingOutsideTheLayerMovesIt() throws {
        let (session, view, window) = try makeCanvas()
        try drag(session, view, in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 40, y: 30), flags: .control)
        #expect(session.transformEdit == nil)
        let origin = try #require(session.activeLayer?.transform.origin)
        #expect(near(origin, CGPoint(x: 170, y: 110)), "layer origin \(origin)")
    }

    @Test func optionDraggingOutsideTheLayerDuplicatesIt() throws {
        let (session, view, window) = try makeCanvas()
        try drag(session, view, in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 40, y: 30), flags: [.option, .control])
        let origins = try #require(session.document?.layers.map(\.transform.origin))
        #expect(origins.count == 2, "\(origins)")
        #expect(origins.contains { near($0, CGPoint(x: 150, y: 100)) } && origins.contains { near($0, CGPoint(x: 170, y: 110)) },
                "the original stays and the copy moves: \(origins)")
    }

    /// Command flips Auto Select for as long as it's held, as in Photoshop: with the box off it picks the layer
    /// under the pointer, and with it on it leaves the active layer where the drag goes.
    @Test(arguments: [false, true])
    func commandFlipsAutoSelectWhileHeld(autoSelect: Bool) throws {
        let (session, view, window) = try makeCanvas()
        let red = try #require(session.activeLayerID)
        let context = try BrushRaster.context(width: 400, height: 300, mask: false)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Blue"))
        let blue = try #require(session.activeLayerID)
        // The blue layer goes to the bottom, under the red square, and stays the active layer.
        let layers = try #require(session.document?.layers)
        session.document?.layers = layers.filter { $0.id == blue } + layers.filter { $0.id != blue }
        session.transformAutoSelect = autoSelect
        view.synchronizeDisplay()
        try drag(session, view, in: window, from: CGPoint(x: 210, y: 170), to: CGPoint(x: 230, y: 180), flags: [.command, .control])
        let moved = autoSelect ? blue : red
        #expect(session.activeLayerID == moved)
        let origin = try #require(session.document?.layers.first { $0.id == moved }?.transform.origin)
        #expect(near(origin, autoSelect ? CGPoint(x: 20, y: 10) : CGPoint(x: 170, y: 110)), "\(origin)")
    }

    /// Cmd-Shift-click adds the layer under the pointer to the selection even with Auto Select on.
    @Test func commandShiftClickAddsALayerWithAutoSelectOn() throws {
        let (session, view, window) = try makeCanvas()
        let red = try #require(session.activeLayerID)
        let context = try BrushRaster.context(width: 400, height: 300, mask: false)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Blue"))
        let blue = try #require(session.activeLayerID)
        let layers = try #require(session.document?.layers)
        session.document?.layers = layers.filter { $0.id == blue } + layers.filter { $0.id != blue }
        session.transformAutoSelect = true
        view.synchronizeDisplay()
        try drag(session, view, in: window, from: CGPoint(x: 210, y: 170), to: CGPoint(x: 210, y: 170), flags: [.command, .shift])
        #expect(session.selectedLayerIDs == [red, blue])
    }
}
