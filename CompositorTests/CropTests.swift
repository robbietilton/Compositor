import AppKit
import Testing
import UniformTypeIdentifiers
@testable import Compositor

@MainActor
struct CropTests {
    @Test func customRatiosAcceptPositiveNumbersAndRejectInvalidInput() {
        #expect(CropGeometry.ratio("9:20") == 0.45)
        #expect(CropGeometry.ratio(" 2.5 : 1 ") == 2.5)
        #expect(CropGeometry.ratio("2,5:1") == 2.5)
        #expect(CropGeometry.ratio("900:2000") == 0.45)
        for text in ["", "9", ":20", "9:", "9:20:1", "Free", "0:20", "9:0", "-9:20", "9:-20",
                     "nan:1", "1:inf", "1e309:1", "1e308:1e-308", "1e-308:1e308", "1:30001", "30001:1"] {
            #expect(CropGeometry.ratio(text) == nil, "\(text) must not be a crop ratio")
        }
    }

    @Test func customRatioResizesTheFrameAndPreservesTheExistingChoices() throws {
        let session = EditorSession()
        session.createDocument(width: 900, height: 600)
        session.selectTool(.crop)
        session.cropRatioChoice = "9:20"
        session.changeCropRatio()
        #expect(session.cropRect == CGRect(x: 0, y: -700, width: 900, height: 2000))
        session.cropRatioChoice = "Original"
        #expect(session.cropRatio == 1.5)
        session.cropRatioChoice = "Free"
        #expect(session.cropRatio == nil)
        session.cropRatioChoice = "4:3"
        #expect(session.cropRatio == CGFloat(4) / 3)
        session.cropRatioChoice = "1:30000"
        session.changeCropRatio()
        let rect = try #require(session.cropRect)
        #expect(CropGeometry.valid(rect))
        #expect(rect.width == 1 && rect.height == 30000)
        session.cropRatioChoice = "30000:1"
        session.changeCropRatio()
        #expect(session.cropRect?.size == CGSize(width: 30000, height: 1))
    }

    @Test func dragGeometrySupportsReverseRatioMoveAndEveryHandle() {
        let rect = CropGeometry.create(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 20, y: 60), ratio: 2)
        #expect(rect == CGRect(x: 20, y: 60, width: 80, height: 40))
        let move = CropDrag(start: CGPoint(x: 40, y: 70), original: rect, mode: .move)
        #expect(move.updated(to: CGPoint(x: 30, y: 40), ratio: nil) == rect.offsetBy(dx: -10, dy: -30))
        for index in 0..<8 {
            let unit = LayerTransform.handles[index]
            let start = CGPoint(x: rect.minX + unit.x * rect.width, y: rect.minY + unit.y * rect.height)
            let drag = CropDrag(start: start, original: rect, mode: .resize(index))
            let next = drag.updated(to: CGPoint(x: start.x + (unit.x * 2 - 1) * 20,
                                                y: start.y + (unit.y * 2 - 1) * 10), ratio: 2)
            #expect(CropGeometry.valid(next))
            #expect(abs(next.width / next.height - 2) < 0.05)
            #expect(next != rect)
        }
    }

    @Test func cropTranslatesWithoutResamplingAndUndoRestoresBounds() async throws {
        let url = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let before = try #require(session.document)
        let image = try #require(before.layers.first?.asset?.image)
        session.selectTool(.crop)
        session.cropRect = CGRect(x: 8, y: 4, width: 32, height: 16)
        await session.commitCrop()
        #expect(session.cropRect == nil)
        #expect(session.visibleCropRect == CGRect(x: 0, y: 0, width: 32, height: 16))
        #expect(session.document?.size == CGSize(width: 32, height: 16))
        #expect(session.document?.layers.first?.origin == CGPoint(x: -8, y: -4))
        #expect(session.document?.layers.first?.asset?.image === image)
        session.undo()
        #expect(session.document == before)
        session.redo()
        #expect(session.document?.width == 32)
    }

    @Test func sameSizeOffsetCropAndExpansionUseExactBounds() async throws {
        let session = EditorSession()
        session.createDocument(width: 100, height: 50)
        session.addBlankLayer()
        session.selectTool(.crop)
        session.cropRect = CGRect(x: -20, y: 10, width: 100, height: 50)
        await session.commitCrop()
        #expect(session.document?.layers.first?.origin == CGPoint(x: 20, y: -10))
        session.cropRect = CGRect(x: -10, y: -10, width: 140, height: 80)
        await session.commitCrop()
        #expect(session.document?.size == CGSize(width: 140, height: 80))
        #expect(session.document?.layers.first?.origin == CGPoint(x: 30, y: 0))
        let output = try await ImageExporter.shared.pngData(try #require(session.projectSnapshot()))
        let bitmap = try #require(NSBitmapImageRep(data: output))
        #expect(bitmap.pixelsWide == 140 && bitmap.pixelsHigh == 80)
        #expect(try #require(bitmap.colorAt(x: 0, y: 0)).alphaComponent == 0)
    }

    @Test func cancellationAndViewportMappingDoNotEditDocument() {
        let session = EditorSession()
        session.createDocument(width: 1000, height: 500)
        let original = session.document
        session.selectTool(.crop)
        #expect(session.cropRect == CGRect(x: 0, y: 0, width: 1000, height: 500))
        #expect(session.document == original)
        session.cropRect = CGRect(x: 25, y: 20, width: 200, height: 100)
        session.cancelCrop()
        #expect(session.visibleCropRect == CGRect(x: 0, y: 0, width: 1000, height: 500))
        #expect(session.document == original)
        session.cropRect = CGRect(x: 0, y: 0, width: 200, height: 100)
        session.selectTool(.move)
        #expect(session.cropRect == nil && session.document == original)
        for scale: CGFloat in [1, 2] {
            session.viewport.resize(to: CGSize(width: 800, height: 600), backingScale: scale, documentSize: original?.size)
            session.viewport.translate(by: CGSize(width: 37, height: -19))
            let point = CGPoint(x: -20, y: 135)
            let view = session.viewport.viewPoint(from: point, documentSize: original!.size)
            let result = session.viewport.documentPoint(from: view, documentSize: original!.size)
            #expect(abs(result.x - point.x) < 0.001 && abs(result.y - point.y) < 0.001)
        }
    }

    @Test func cropEdgesSnapToNearbyEdges() throws {
        let snap = CropSnap(xs: [0, 200, 50, 150], ys: [0, 100, 20, 80], tolerance: 6)
        let rect = CGRect(x: 10, y: 10, width: 60, height: 40)
        // Moving: the nearest edge on each axis lands on a target; the size is kept.
        let move = CropDrag(start: CGPoint(x: 30, y: 30), original: rect, mode: .move)
        let movedTo = CGPoint(x: 26, y: 34)
        #expect(snap.apply(move.updated(to: movedTo, ratio: nil), drag: move, point: movedTo, ratio: nil)
                == CGRect(x: 0, y: 20, width: 60, height: 40))
        // Resizing the bottom-right corner snaps just those two edges.
        let cornerIndex = try #require(LayerTransform.handles.firstIndex { $0.x == 1 && $0.y == 1 })
        let resize = CropDrag(start: CGPoint(x: 70, y: 50), original: rect, mode: .resize(cornerIndex))
        let near = CGPoint(x: 146, y: 83)
        #expect(snap.apply(resize.updated(to: near, ratio: nil), drag: resize, point: near, ratio: nil)
                == CGRect(x: 10, y: 10, width: 140, height: 70))
        // Too far away: no snap.
        let far = CGPoint(x: 120, y: 60)
        #expect(snap.apply(resize.updated(to: far, ratio: nil), drag: resize, point: far, ratio: nil)
                == CGRect(x: 10, y: 10, width: 110, height: 50))
        // A fixed ratio only snaps moves, so the ratio stays exact.
        let ratioRect = CGRect(x: 10, y: 10, width: 138, height: 69)
        #expect(snap.apply(ratioRect, drag: resize, point: CGPoint(x: 148, y: 79), ratio: 2) == ratioRect)
        // Creating snaps the dragged corner, not the anchor (even though the anchor sits near a target).
        let create = CropDrag(start: CGPoint(x: 52, y: 18), original: .zero, mode: .create)
        let dragged = CGPoint(x: 147, y: 77)
        #expect(snap.apply(create.updated(to: dragged, ratio: nil), drag: create, point: dragged, ratio: nil)
                == CGRect(x: 52, y: 18, width: 98, height: 62))
    }

    @Test func snapTargetsAreTheCanvasAndLayerBounds() throws {
        let session = EditorSession()
        session.createDocument(width: 400, height: 300)
        let context = try BrushRaster.context(width: 100, height: 60, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 60))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Red")) // centered: 150–250 × 120–180
        let targets = session.cropSnapTargets()
        #expect(Set(targets.xs) == Set<CGFloat>([0, 400, 150, 250]))
        #expect(Set(targets.ys) == Set<CGFloat>([0, 300, 120, 180]))
    }

    /// Dragging the crop frame inside the canvas must redraw only the overlay: the overlays have layers of
    /// their own, so the canvas (checkerboard and layer composite) isn't redrawn on every mouse move.
    @Test func cropDraggingRedrawsOnlyTheOverlay() throws {
        let session = EditorSession()
        session.createDocument(width: 800, height: 600)
        let context = try BrushRaster.context(width: 400, height: 300, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Red"))
        let view = CanvasView(session: session)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 450), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        session.viewport.resize(to: view.bounds.size, backingScale: 1, documentSize: try #require(session.document?.size))
        session.selectTool(.crop)
        view.synchronizeDisplay()
        view.displayIfNeeded()
        #expect(view.subviews.allSatisfy { $0.wantsLayer }, "every overlay draws into its own layer")
        func event(_ type: NSEvent.EventType, _ p: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: p.x, y: view.bounds.height - p.y), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 150, y: 120)))
        var canvasRedraws = 0
        for step in 0..<10 {
            view.needsDisplay = false
            view.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 170 + CGFloat(step) * 10, y: 140 + CGFloat(step) * 8)))
            if view.needsDisplay { canvasRedraws += 1 }
        }
        view.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 260, y: 212)))
        #expect(session.cropRect != nil)
        let layers = view.subviews.map { "\(type(of: $0)) layer \($0.layer != nil)" }.joined(separator: ", ")
        #expect(canvasRedraws == 0, "the canvas redrew on \(canvasRedraws) of 10 crop drag steps; canvas layer \(view.layer != nil); \(layers)")
    }
}
