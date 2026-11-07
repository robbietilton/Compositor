import CoreGraphics
import Testing
import UIKit
@testable import Compositor

/// The Move tool's handles under a finger, and transforms through the window.
@MainActor struct PadTransformTests {
    /// The box of an upright `size` layer at (300, 300) on a 1000 × 800 canvas fitted to a view its size.
    private func box(_ size: CGSize) -> TransformOverlayGeometry {
        var viewport = CanvasViewport()
        let canvas = CGSize(width: 1000, height: 800)
        viewport.resize(to: canvas, backingScale: 1, documentSize: canvas)
        return TransformOverlayGeometry(transform: LayerTransform(origin: CGPoint(x: 300, y: 300), size: size, rotation: 0),
                                        viewport: viewport, documentSize: canvas)
    }

    /// A finger finds a handle further off than a pointer would, the nearer one where two reach, and a press inside
    /// the box away from them still moves the layer.
    @Test func aFingerFindsTheNearestHandleWithinReach() {
        let box = box(CGSize(width: 400, height: 300))
        // 18 points out from the bottom right corner: past a pointer's 10, within a finger's 22.
        let corner = CGPoint(x: box.handles[4].x + 18, y: box.handles[4].y)
        #expect(box.hit(corner) == nil)
        if case .resize(let index) = box.hit(touch: corner) { #expect(index == 4) } else { Issue.record("No corner") }
        // Above the top middle handle, the rotation handle 28 points further up takes over past halfway.
        let top = box.handles[1]
        if case .resize(let index) = box.hit(touch: CGPoint(x: top.x, y: top.y - 12)) { #expect(index == 1) }
        else { Issue.record("No top handle") }
        if case .rotate = box.hit(touch: CGPoint(x: top.x, y: top.y - 20)) {} else { Issue.record("No rotation handle") }
        let middle = CGPoint(x: (box.handles[0].x + box.handles[4].x) / 2, y: (box.handles[0].y + box.handles[4].y) / 2)
        #expect(box.hit(touch: middle) == nil)
    }

    /// Around a small box the handles reach less far, so a finger pressing inside it moves the layer rather than
    /// resizing it.
    @Test func aSmallBoxStillMovesUnderAFinger() {
        let box = box(CGSize(width: 30, height: 30))
        let middle = CGPoint(x: (box.handles[0].x + box.handles[4].x) / 2, y: (box.handles[0].y + box.handles[4].y) / 2)
        #expect(box.hit(touch: middle) == nil)
        if case .resize(let index) = box.hit(touch: box.handles[2]) { #expect(index == 2) } else { Issue.record("No corner") }
    }

    /// Export PNG keeps a transform still waiting for Apply first, as the Mac's exports do, so the image has it.
    @Test func exportingKeepsATransformInProgress() throws {
        let window = EditorWindowController()
        window.loadViewIfNeeded()
        let session = try #require(window.activeTab?.session)
        session.createNewProject(width: 100, height: 100)
        let context = try BrushRaster.context(width: 40, height: 40, mask: false)
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Red"))
        let id = try #require(session.activeLayerID)
        let start = try #require(session.activeLayer?.transform.origin)

        window.transformLayer(nil)
        var moved = try #require(session.transformEdit?.draft)
        moved.origin.x += 30
        session.previewTransform(moved)
        window.exportPNG(nil)

        #expect(session.transformEdit == nil)
        #expect(session.document?.layers.first { $0.id == id }?.transform.origin == CGPoint(x: start.x + 30, y: start.y))
    }

    /// A resize's size beside the pointer, and a move's distances, last only while the finger drags, as the Mac's end
    /// with the mouse up: under Free Transform, which stays open after the drag, nothing still reports them, lifted or
    /// cancelled.
    @Test func aDragsSizeAndDistancesEndWithIt() throws {
        let window = EditorWindowController()
        window.loadViewIfNeeded()
        let tab = try #require(window.activeTab)
        let session = tab.session, input = tab.canvas.input
        let canvas = CGSize(width: 400, height: 300)
        session.viewport.resize(to: canvas, backingScale: 1, documentSize: nil)
        session.createNewProject(width: 400, height: 300)
        let context = try BrushRaster.context(width: 100, height: 80, mask: false)
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Red"))
        session.selectTool(.move)
        session.showsDistances = true
        defer { session.showsDistances = false }
        func point(_ pixel: CGPoint) -> CGPoint { session.viewport.viewPoint(from: pixel, documentSize: canvas) }

        for cancels in [false, true] {
            window.transformLayer(nil)
            let box = try #require(session.transformEdit?.draft)
            let corner = CGPoint(x: box.origin.x + box.size.width, y: box.origin.y + box.size.height)
            input.began(at: point(corner))
            input.moved(to: point(CGPoint(x: corner.x + 20, y: corner.y + 10)))
            try #require(session.resizeSize != nil, "cancels: \(cancels)")
            if cancels { input.cancelled() } else { input.ended(at: point(CGPoint(x: corner.x + 20, y: corner.y + 10))) }
            #expect(session.transformEdit != nil && session.resizeSize == nil && session.dragOutSize == nil, "cancels: \(cancels)")

            let center = CGPoint(x: box.origin.x + box.size.width / 2, y: box.origin.y + box.size.height / 2)
            input.began(at: point(center))
            input.moved(to: point(CGPoint(x: center.x + 15, y: center.y + 5)))
            try #require(!session.distanceLines.isEmpty, "cancels: \(cancels)")
            if cancels { input.cancelled() } else { input.ended(at: point(CGPoint(x: center.x + 15, y: center.y + 5))) }
            #expect(session.distanceLines.isEmpty, "cancels: \(cancels)")
            session.cancelTransform()
        }
    }

    /// Transforming a selection's pixels, from the window, keeps the layer's effects once it's applied, as on the Mac.
    @Test func transformingASelectionKeepsTheLayersEffects() async throws {
        let window = EditorWindowController()
        window.loadViewIfNeeded()
        let session = try #require(window.activeTab?.session)
        session.createNewProject(width: 100, height: 100)
        let context = try BrushRaster.context(width: 40, height: 40, mask: false)
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Red"))
        let id = try #require(session.activeLayerID)
        let effects = LayerEffects(stroke: StrokeEffect(size: 4), shadow: ShadowEffect(distance: 20, blur: 10))
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document?.layers[index].effects = effects
        session.applySelection(CGPath(rect: CGRect(x: 40, y: 40, width: 20, height: 20), transform: nil), mode: .replace, name: "Select")

        window.transformLayer(nil)
        for _ in 0..<250 where session.transformEdit == nil { try await Task.sleep(for: .milliseconds(20)) }
        var moved = try #require(session.transformEdit?.draft)
        moved.origin.x += 10
        session.previewTransform(moved)
        session.commitTransform()

        #expect(session.history.undoName == "Transform Selection")
        #expect(session.document?.layers.first { $0.id == id }?.effects == effects)
    }
}
