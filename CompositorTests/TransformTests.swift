import AppKit
import Testing
@testable import Compositor

@MainActor
struct TransformTests {
    @Test func duplicateTransformPreservesOriginalAndSupportsUndoAndCancel() throws {
        let session = EditorSession()
        session.createDocument(width: 400, height: 200)
        try insertPaintedLayer(into: session)
        let original = try #require(session.activeLayer)
        let count = session.history.undoCount
        session.beginDuplicateTransform()
        var moved = original.transform
        moved.origin.x += 50
        session.previewTransform(moved)
        session.commitTransform()
        #expect(session.document?.layers.count == 2)
        #expect(session.document?.layers.first?.transform == original.transform)
        #expect(session.activeLayer?.transform == moved)
        #expect(session.history.undoCount == count + 1)
        session.undo()
        #expect(session.document?.layers.count == 1)
        #expect(session.activeLayerID == original.id)
        session.beginDuplicateTransform()
        session.previewTransform(moved)
        session.cancelTransform()
        #expect(session.document?.layers.count == 1)
        #expect(session.activeLayerID == original.id)
        #expect(session.history.undoCount == count)
    }
    @Test func autoSelectCanBeDisabledAndCommandClickOverridesIt() throws {
        let session = EditorSession()
        session.createDocument(width: 400, height: 200)
        try insertPaintedLayer(into: session)
        let first = try #require(session.activeLayerID)
        session.document?.layers[0].transform = LayerTransform(origin: .zero, size: CGSize(width: 100, height: 100))
        try insertPaintedLayer(into: session)
        let second = try #require(session.activeLayerID)
        session.document?.layers[1].transform = LayerTransform(origin: CGPoint(x: 250, y: 0), size: CGSize(width: 100, height: 100))
        session.selectLayer(first)
        let view = CanvasView(session: session)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        session.viewport.resize(to: view.bounds.size, backingScale: 1, documentSize: session.document?.size)
        session.zoom(to: 1)
        func click(_ point: CGPoint, command: Bool = false) throws {
            let location = view.convert(session.viewport.viewPoint(from: point, documentSize: CGSize(width: 400, height: 200)), to: nil)
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
                modifierFlags: command ? .command : [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            view.mouseDown(with: event)
            view.mouseUp(with: event)
            session.commitTransform()
        }
        #expect(!session.transformAutoSelect, "Auto Select starts off; a press drags the active layer")
        session.transformAutoSelect = true
        try click(CGPoint(x: 300, y: 50))
        #expect(session.activeLayerID == second)
        session.selectLayer(first)
        session.transformAutoSelect = false
        try click(CGPoint(x: 300, y: 50))
        #expect(session.activeLayerID == first)
        try click(CGPoint(x: 300, y: 50), command: true)
        #expect(session.activeLayerID == second)
        #expect(!session.transformAutoSelect)
    }

    @Test func autoSelectPicksForegroundLayerStackedOnSelectedBackground() throws {
        let session = EditorSession()
        session.createDocument(width: 400, height: 200)
        try insertPaintedLayer(into: session)
        let background = try #require(session.activeLayerID)
        session.document?.layers[0].transform = LayerTransform(origin: .zero, size: CGSize(width: 400, height: 200))
        try insertPaintedLayer(into: session)
        let foreground = try #require(session.activeLayerID)
        session.document?.layers[1].transform = LayerTransform(origin: CGPoint(x: 150, y: 50), size: CGSize(width: 80, height: 60))
        session.selectLayer(background)
        let view = CanvasView(session: session)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        session.viewport.resize(to: view.bounds.size, backingScale: 1, documentSize: session.document?.size)
        session.zoom(to: 1)
        func click(_ point: CGPoint) throws {
            let location = view.convert(session.viewport.viewPoint(from: point, documentSize: CGSize(width: 400, height: 200)), to: nil)
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            view.mouseDown(with: event)
            view.mouseUp(with: event)
            session.commitTransform()
        }
        session.transformAutoSelect = true
        try click(CGPoint(x: 180, y: 70))
        #expect(session.activeLayerID == foreground)
        try click(CGPoint(x: 20, y: 20))
        #expect(session.activeLayerID == background)
        try click(CGPoint(x: 180, y: 70))
        #expect(session.activeLayerID == foreground)
        session.selectLayer(background)
        session.transformAutoSelect = false
        try click(CGPoint(x: 180, y: 70))
        #expect(session.activeLayerID == background)
    }

    @Test func hoverRegionsMatchRotatedEdgesCornersAndRotationHandle() {
        var viewport = CanvasViewport()
        let size = CGSize(width: 1000, height: 800)
        viewport.resize(to: CGSize(width: 1000, height: 800), backingScale: 1, documentSize: size)
        let transform = LayerTransform(origin: CGPoint(x: 100, y: 100), size: CGSize(width: 400, height: 300), rotation: 37)
        let geometry = TransformOverlayGeometry(transform: transform, viewport: viewport, documentSize: size)
        for (start, end, expected) in [(0, 2, 1), (2, 4, 3), (4, 6, 5), (6, 0, 7)] {
            let a = geometry.handles[start], b = geometry.handles[end]
            let point = CGPoint(x: a.x * 0.75 + b.x * 0.25, y: a.y * 0.75 + b.y * 0.25)
            if case .resize(let index) = geometry.hit(point) { #expect(index == expected) }
            else { Issue.record("Rotated edge was not recognized") }
        }
        for index in [0, 2, 4, 6] {
            if case .resize(let hit) = geometry.hit(geometry.handles[index]) { #expect(hit == index) }
            else { Issue.record("Corner was not recognized") }
        }
        if case .rotate = geometry.hit(geometry.rotationHandle) {} else { Issue.record("Rotation handle was not recognized") }
        #expect(geometry.hit(viewport.viewPoint(from: transform.center, documentSize: size)) == nil)
    }
    private func insertPaintedLayer(into session: EditorSession) throws {
        let size = try #require(session.document?.size)
        let context = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: Int(size.width) * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Painted layer"))
    }

    @Test func blankLayersHaveNoTransformHandlesOrEditing() throws {
        let session = EditorSession()
        session.createDocument(width: 100, height: 100)
        session.addBlankLayer()
        #expect(!session.canTransform)
        #expect(TransformOverlay(session: session).geometry == nil)
        session.beginTransform()
        #expect(session.transformEdit == nil)
        try insertPaintedLayer(into: session)
        #expect(session.canTransform)
        #expect(TransformOverlay(session: session).geometry != nil)
    }

    private func near(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) < 0.0001 }

    @Test func rotatedResizeKeepsOppositeAnchorAtEveryHandle() {
        let original = LayerTransform(origin: CGPoint(x: 31, y: -19), size: CGSize(width: 200, height: 100), rotation: 37)
        for index in LayerTransform.handles.indices {
            let handle = LayerTransform.handles[index]
            let opposite = CGPoint(x: 1 - handle.x, y: 1 - handle.y)
            let start = original.point(handle)
            let drag = TransformDrag(original: original, start: start, mode: .resize(index))
            for locked in [true, false] {
                let changed = drag.updated(to: CGPoint(x: start.x + 34, y: start.y + 17), lockRatio: locked, shift: false)
                #expect(near(original.point(opposite), changed.point(opposite)))
                if locked { #expect(abs(changed.size.width / changed.size.height - 2) < 0.0001) }
                #expect(changed.isValid)
            }
        }
    }

    @Test func moveRotateAndShiftConstraints() {
        let original = LayerTransform(origin: .zero, size: CGSize(width: 100, height: 50))
        let move = TransformDrag(original: original, start: CGPoint(x: 40, y: 20), mode: .move)
        let moved = move.updated(to: CGPoint(x: 60, y: 25), lockRatio: true, shift: true)
        #expect(moved.origin == CGPoint(x: 20, y: 0))
        let rotate = TransformDrag(original: original, start: CGPoint(x: 100, y: 25), mode: .rotate)
        let rotated = rotate.updated(to: CGPoint(x: 50, y: 75), lockRatio: true, shift: false)
        #expect(abs(rotated.rotation - 90) < 0.0001)
        #expect(rotated.center == original.center)
        let snapped = rotate.updated(to: CGPoint(x: 99, y: 45), lockRatio: true, shift: true)
        #expect(snapped.rotation.truncatingRemainder(dividingBy: 15) == 0)
        let resize = TransformDrag(original: original, start: CGPoint(x: 100, y: 50), mode: .resize(4))
        let free = resize.updated(to: CGPoint(x: 150, y: 50), lockRatio: true, shift: true)
        #expect(free.size == CGSize(width: 150, height: 50))
    }

    @Test func documentMappingAndRotatedHitTesting() {
        var viewport = CanvasViewport()
        let size = CGSize(width: 1000, height: 800)
        viewport.resize(to: CGSize(width: 900, height: 600), backingScale: 2, documentSize: size)
        viewport.setZoom(1.5, anchoredAt: CGPoint(x: 300, y: 200), documentSize: size)
        viewport.translate(by: CGSize(width: 57, height: -30))
        let transform = LayerTransform(origin: CGPoint(x: 100, y: 200), size: CGSize(width: 100, height: 50), rotation: 90)
        let geometry = TransformOverlayGeometry(transform: transform, viewport: viewport, documentSize: size)
        #expect(near(viewport.documentPoint(from: geometry.handles[4], documentSize: size), transform.point(CGPoint(x: 1, y: 1))))
        #expect(transform.contains(transform.center))
        #expect(transform.contains(CGPoint(x: 150, y: 265)))
        #expect(!transform.contains(CGPoint(x: 190, y: 225)))
        if case .rotate? = geometry.hit(geometry.rotationHandle) {} else { Issue.record("Missing rotation handle hit") }
        for index in geometry.handles.indices {
            if case .resize(let hit)? = geometry.hit(geometry.handles[index]) { #expect(hit == index) }
            else { Issue.record("Missing resize handle hit") }
        }
    }

    @Test func previewCommitCancelAndUndoPreserveSources() throws {
        let session = EditorSession()
        session.createDocument(width: 200, height: 100)
        try insertPaintedLayer(into: session)
        let original = try #require(session.activeLayer)
        let count = session.history.undoCount
        session.beginTransform()
        var value = original.transform
        value.origin = CGPoint(x: -45, y: 34)
        value.size = CGSize(width: 80, height: 140)
        value.rotation = 23
        value.flipX = true
        for _ in 0..<30 { session.previewTransform(value) }
        #expect(session.activeLayer?.transform == original.transform)
        #expect(session.history.undoCount == count)
        session.cancelTransform()
        #expect(session.activeLayer == original)
        session.beginTransform()
        session.previewTransform(value)
        session.commitTransform()
        #expect(session.history.undoCount == count + 1)
        #expect(session.activeLayer?.transform == value)
        session.undo()
        #expect(session.activeLayer == original)
        session.redo()
        #expect(session.activeLayer?.transform == value)
        #expect(session.activeLayerID == original.id)
    }

    @Test func scalePercentSetsBothSidesAboutTheCenter() throws {
        let session = EditorSession()
        session.createDocument(width: 400, height: 200)
        try insertPaintedLayer(into: session)
        let pixels = try #require(session.transformPixelSize)
        var stretched = try #require(session.activeLayer).transform
        stretched.size = CGSize(width: pixels.width * 2, height: pixels.height * 3)
        stretched.rotation = 30
        #expect(stretched.scalePercent(pixelSize: pixels) == 200)
        let scaled = stretched.scaled(toPercent: 50, pixelSize: pixels)
        #expect(scaled.size == CGSize(width: pixels.width / 2, height: pixels.height / 2))
        #expect(abs(scaled.center.x - stretched.center.x) < 0.001 && abs(scaled.center.y - stretched.center.y) < 0.001)
        #expect(scaled.rotation == 30)
        #expect(scaled.scalePercent(pixelSize: pixels) == 50)
    }
    @Test func noOpInvalidValuesAndSwitchingTools() throws {
        let session = EditorSession()
        session.createDocument(width: 200, height: 100)
        try insertPaintedLayer(into: session)
        let count = session.history.undoCount
        session.beginTransform()
        session.commitTransform()
        #expect(session.history.undoCount == count)
        session.beginTransform()
        var invalid = try #require(session.transformEdit?.draft)
        invalid.size.width = 0
        session.previewTransform(invalid)
        #expect(session.transformEdit?.draft.size.width == 200)
        invalid.size.width = .infinity
        session.previewTransform(invalid)
        #expect(session.transformEdit?.draft.size.width == 200)
        var moved = try #require(session.transformEdit?.draft)
        moved.origin.x = 10
        session.previewTransform(moved)
        session.selectTool(.hand)
        #expect(session.transformEdit == nil)
        #expect(session.activeLayer?.origin.x == 10)
        #expect(session.history.undoCount == count + 1)
    }

    @Test func renderingRotatesScalesAndFlipsWithoutReplacingPixels() throws {
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 32, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 8))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 4, y: 0, width: 4, height: 8))
        let image = try #require(context.makeImage())
        let session = EditorSession()
        session.createDocument(width: 32, height: 32)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Two colors"))
        session.viewport.resize(to: CGSize(width: 32, height: 32), backingScale: 1, documentSize: session.document?.size)
        session.zoom(to: 1)
        let view = CanvasView(session: session)
        view.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
        session.beginTransform()
        var value = LayerTransform(origin: CGPoint(x: 8, y: 8), size: CGSize(width: 16, height: 16), rotation: 90)
        value.sampling = .nearest
        session.previewTransform(value)
        func pixel(_ x: Int, _ y: Int) throws -> NSColor {
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            // Reproduce AppKit's top-left view CTM when calling draw directly.
            NSGraphicsContext.current?.cgContext.translateBy(x: 0, y: 32)
            NSGraphicsContext.current?.cgContext.scaleBy(x: 1, y: -1)
            view.draw(view.bounds)
            return try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        }
        #expect(try pixel(16, 12).redComponent > 0.95)
        #expect(try pixel(16, 20).blueComponent > 0.95)
        value.flipX = true
        session.previewTransform(value)
        #expect(try pixel(16, 12).blueComponent > 0.95)
        session.commitTransform()
        #expect(session.activeLayer?.asset?.image === image)
        session.undo()
        #expect(session.activeLayer?.size == CGSize(width: 8, height: 8))
    }

    @Test func layerListToolKeysAndTransformNudge() throws {
        let session = EditorSession()
        session.createDocument(width: 100, height: 100)
        try insertPaintedLayer(into: session)
        let table = LayerTableView()
        table.session = session
        func key(_ code: UInt16, _ text: String) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
            table.keyDown(with: event)
        }
        try key(4, "h")
        #expect(session.tool == .hand)
        try key(9, "v")
        #expect(session.tool == .move)
        session.beginTransform()
        try key(124, "")
        #expect(session.transformEdit?.draft.origin.x == 1)
        #expect(session.activeLayer?.origin.x == 0)
        try key(53, "")
        #expect(session.transformEdit == nil)
        #expect(session.activeLayer?.origin.x == 0)
    }
}
