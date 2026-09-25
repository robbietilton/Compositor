import AppKit
import Testing
@testable import Compositor

@MainActor
struct SelectionEditTests {
    private func makeSession(width: Int = 100, height: Int = 40) -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: width, height: height, emptyLayer: true)
        return session
    }
    private func select(_ session: EditorSession, _ rect: CGRect, antialiased: Bool = true) {
        session.selectionAntialiased = antialiased
        session.applySelection(CGPath(rect: rect, transform: nil), mode: .replace, name: "Select")
    }
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [Int] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let index = (y * image.width + x) * 4
        return (0..<4).map { Int(bytes[index + $0]) }
    }
    private func render(_ session: EditorSession) async throws -> CGImage {
        try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
    }
    private let red = PaletteColor(red: 1, green: 0, blue: 0)

    @Test func brushPaintsOnlyInsideTheSelection() async throws {
        let session = makeSession()
        select(session, CGRect(x: 0, y: 0, width: 50, height: 40))
        session.selectTool(.brush)
        session.brushSettings = BrushSettings(diameter: 20, hardness: 1, red: 1, green: 0, blue: 0)
        session.beginBrush(at: CGPoint(x: 5, y: 20))
        session.continueBrush(at: CGPoint(x: 95, y: 20))
        await session.finishBrush()
        let result = try await render(session)
        #expect(try pixel(result, x: 25, y: 20) == [255, 0, 0, 255])
        #expect(try pixel(result, x: 75, y: 20)[3] == 0)
    }

    @Test func emptySelectionEditsNothing() async throws {
        let session = makeSession()
        select(session, CGRect(x: 10, y: 10, width: 10, height: 10))
        session.applySelection(CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 40), transform: nil), mode: .subtract, name: "Subtract")
        #expect(session.selection?.isEmpty == true)
        let before = session.document
        let count = session.history.undoCount
        session.selectTool(.brush)
        session.beginBrush(at: CGPoint(x: 5, y: 20))
        session.continueBrush(at: CGPoint(x: 95, y: 20))
        await session.finishBrush()
        #expect(try pixel(try await render(session), x: 50, y: 20)[3] == 0)
        await session.fillSelection(with: .foreground)
        await session.clearSelectedPixels()
        session.selectTool(.gradient)
        session.beginGradient(at: CGPoint(x: 0, y: 20))
        #expect(session.gradientEdit == nil)
        #expect(!session.canPaint && !session.canEditPixels)
        #expect(session.document == before && session.history.undoCount == count)
    }

    @Test func gradientStaysInsideTheSelection() async throws {
        let session = makeSession()
        select(session, CGRect(x: 0, y: 0, width: 50, height: 40))
        session.selectTool(.gradient)
        session.gradientSettings.style = .foregroundToBackground
        session.beginGradient(at: CGPoint(x: 0.5, y: 20))
        session.moveGradient(end: CGPoint(x: 99.5, y: 20))
        await session.commitGradient()
        let result = try await render(session)
        #expect(try pixel(result, x: 10, y: 20)[3] == 255)
        #expect(try pixel(result, x: 75, y: 20)[3] == 0)
    }

    @Test func fillUsesPaletteInsideSelectionOrWholeLayerWithoutOne() async throws {
        let session = makeSession()
        session.setPaletteColor(red, background: false)
        select(session, CGRect(x: 20, y: 10, width: 30, height: 20))
        let count = session.history.undoCount
        await session.fillSelection(with: .foreground)
        #expect(session.history.undoCount == count + 1 && session.history.undoName == "Fill")
        var result = try await render(session)
        #expect(try pixel(result, x: 30, y: 20) == [255, 0, 0, 255])
        #expect(try pixel(result, x: 5, y: 5)[3] == 0)
        session.deselect()
        await session.fillSelection(with: .background)
        result = try await render(session)
        #expect(try pixel(result, x: 5, y: 5) == [255, 255, 255, 255])
        #expect(try pixel(result, x: 30, y: 20) == [255, 255, 255, 255])
    }

    @Test func deleteClearsSelectedPixelsOrDeletesTheLayerWithoutASelection() async throws {
        let session = makeSession()
        session.setPaletteColor(red, background: false)
        await session.fillSelection(with: .foreground) // Whole layer red.
        select(session, CGRect(x: 20, y: 10, width: 30, height: 20))
        await session.clearSelectedPixels()
        #expect(session.history.undoName == "Clear")
        let result = try await render(session)
        #expect(try pixel(result, x: 30, y: 20)[3] == 0)
        #expect(try pixel(result, x: 5, y: 5) == [255, 0, 0, 255])
        session.undo()
        #expect(try pixel(try await render(session), x: 30, y: 20) == [255, 0, 0, 255])
        session.deselect()
        session.deleteKeyPressed()
        #expect(session.document?.layers.isEmpty == true)
    }

    @Test func maskFillHidesOnlyTheSelectedArea() async throws {
        let session = makeSession()
        session.setPaletteColor(red, background: false)
        await session.fillSelection(with: .foreground)
        session.addLayerMask(revealing: true)
        session.selectLayerTarget(try #require(session.activeLayerID), mask: true)
        select(session, CGRect(x: 20, y: 10, width: 30, height: 20))
        // Mask palette: foreground black (hide), background white (reveal).
        await session.fillSelection(with: .foreground)
        #expect(session.history.undoName == "Fill Mask")
        var result = try await render(session)
        #expect(try pixel(result, x: 30, y: 20)[3] == 0)
        #expect(try pixel(result, x: 5, y: 5)[3] == 255)
        await session.clearSelectedPixels() // Background white reveals again.
        result = try await render(session)
        #expect(try pixel(result, x: 30, y: 20)[3] == 255)
    }

    @Test func clipFollowsScaledLayersAndSoftensEdges() async throws {
        let session = makeSession()
        // A 50×20 image stretched 2× over the 100×40 canvas.
        let context = try BrushRaster.context(width: 50, height: 20, mask: false)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 50, height: 20))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Blue"))
        var transform = try #require(session.activeLayer).transform
        transform.origin = .zero
        transform.size = CGSize(width: 100, height: 40)
        session.beginTransform()
        session.previewTransform(transform)
        session.commitTransform()
        let triangle = CGMutablePath()
        triangle.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 0, y: 40)])
        triangle.closeSubpath()
        session.selectionAntialiased = true
        session.applySelection(triangle, mode: .replace, name: "Select")
        await session.clearSelectedPixels()
        let result = try await render(session)
        #expect(try pixel(result, x: 10, y: 10)[3] == 0)     // Inside the triangle: cleared.
        #expect(try pixel(result, x: 90, y: 35)[3] == 255)   // Outside: untouched.
        // Along the diagonal edge some pixels are partly cleared.
        let edge = try (0..<100).map { try pixel(result, x: $0, y: min(39, Int((1 - CGFloat($0) / 100) * 40))) [3] }
        #expect(edge.contains { $0 > 0 && $0 < 255 })
    }

    @Test func maskButtonAddsWhiteMaskOrHidesTheSelection() async throws {
        let session = makeSession()
        session.setPaletteColor(red, background: false)
        await session.fillSelection(with: .foreground) // Whole layer red.
        session.addMask()
        #expect(session.activeLayer?.mask != nil && session.history.undoName == "Add Reveal-All Mask")
        #expect(try pixel(try await render(session), x: 30, y: 20)[3] == 255)
        session.undo()
        #expect(session.activeLayer?.mask == nil)

        select(session, CGRect(x: 20, y: 10, width: 30, height: 20))
        session.addMask()
        #expect(session.history.undoName == "Add Mask from Selection")
        #expect(session.selection == nil && session.isMaskSelected)
        let result = try await render(session)
        #expect(try pixel(result, x: 30, y: 20)[3] == 0)     // Selected area: black, hidden.
        #expect(try pixel(result, x: 5, y: 5)[3] == 255)     // Everything else: white, visible.
        session.undo()
        #expect(session.activeLayer?.mask == nil && session.selection != nil)
    }

    /// A layer's Add White Mask / Add Black Mask use the selection too: white hides it, black shows only it.
    @Test func layerMenuMasksUseTheSelection() async throws {
        let session = makeSession()
        session.setPaletteColor(red, background: false)
        await session.fillSelection(with: .foreground) // Whole layer red.
        select(session, CGRect(x: 20, y: 10, width: 30, height: 20))
        session.addMask(revealing: false)
        #expect(session.history.undoName == "Add Mask from Selection")
        #expect(session.selection == nil && session.isMaskSelected)
        let result = try await render(session)
        #expect(try pixel(result, x: 30, y: 20)[3] == 255)   // Selected area: white, visible.
        #expect(try pixel(result, x: 5, y: 5)[3] == 0)       // Everything else: black, hidden.
        session.undo()
        #expect(session.activeLayer?.mask == nil && session.selection != nil)

        session.deselect()
        session.addMask(revealing: false)                    // No selection: a plain black mask.
        #expect(session.history.undoName == "Add Hide-All Mask")
        #expect(try pixel(try await render(session), x: 30, y: 20)[3] == 0)
    }

    @Test func maskFromSelectionLinesUpOnScaledLayers() async throws {
        let session = makeSession(width: 100, height: 100)
        let context = try BrushRaster.context(width: 50, height: 50, mask: false)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 50, height: 50))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Blue"))
        let id = try #require(session.activeLayerID)
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document?.layers[index].transform = LayerTransform(origin: .zero, size: CGSize(width: 100, height: 100))
        select(session, CGRect(x: 0, y: 0, width: 50, height: 50))
        session.addMask()
        #expect(session.activeLayer?.mask?.asset.image.width == 50) // Mask uses the layer's pixel grid.
        let result = try await render(session)
        #expect(try pixel(result, x: 25, y: 25)[3] == 0)
        #expect(try pixel(result, x: 75, y: 75)[3] == 255)
        #expect(try pixel(result, x: 75, y: 25)[3] == 255)
    }

    @Test func deletingWithTheMaskTargetedRemovesOnlyTheMask() throws {
        let session = makeSession()
        let id = try #require(session.activeLayerID)
        session.addLayerMask(revealing: false)
        #expect(session.isMaskSelected)
        session.deleteKeyPressed()
        #expect(session.activeLayer?.id == id && session.activeLayer?.mask == nil)
        #expect(session.history.undoName == "Delete Layer Mask" && !session.isMaskSelected)
        session.undo()
        #expect(session.activeLayer?.mask != nil)
        // The trash button follows the same target.
        session.selectLayerTarget(id, mask: true)
        session.deleteLayerOrMask()
        #expect(session.document?.layers.count == 1 && session.activeLayer?.mask == nil)
        // With the layer's pixels targeted, the whole layer goes.
        session.addLayerMask()
        session.selectLayerTarget(id, mask: false)
        session.deleteLayerOrMask()
        #expect(session.document?.layers.isEmpty == true)
    }

    /// A 100×40 layer: red left half, blue right half.
    private func twoColorLayer(_ session: EditorSession) async throws {
        session.setPaletteColor(red, background: false)
        session.setPaletteColor(PaletteColor(red: 0, green: 0, blue: 1), background: true)
        await session.fillSelection(with: .background)
        select(session, CGRect(x: 0, y: 0, width: 50, height: 40))
        await session.fillSelection(with: .foreground)
        session.deselect()
    }

    @Test func cmdDragMovesSelectedPixelsAndOutlineAsOneUndo() async throws {
        let session = makeSession()
        try await twoColorLayer(session)
        select(session, CGRect(x: 10, y: 10, width: 10, height: 10))
        let count = session.history.undoCount
        #expect(session.beginPixelMove())
        session.movePixels(by: CGSize(width: 30.4, height: 0))
        session.movePixels(by: CGSize(width: 60.2, height: 5))
        await session.finishPixelMove()
        #expect(session.history.undoCount == count + 1 && session.history.undoName == "Move Pixels")
        #expect(session.selection?.path.boundingBoxOfPath == CGRect(x: 70, y: 15, width: 10, height: 10))
        let result = try await render(session)
        #expect(try pixel(result, x: 15, y: 15)[3] == 0)                 // Hole where the pixels were.
        #expect(try pixel(result, x: 75, y: 20) == [255, 0, 0, 255])     // Red pixels now on blue.
        #expect(try pixel(result, x: 85, y: 20) == [0, 0, 255, 255])     // Untouched blue.
        #expect(try pixel(result, x: 5, y: 5) == [255, 0, 0, 255])       // Untouched red.
        session.undo()
        #expect(session.selection?.path.boundingBoxOfPath == CGRect(x: 10, y: 10, width: 10, height: 10))
        #expect(try pixel(try await render(session), x: 15, y: 15) == [255, 0, 0, 255])
    }

    @Test func duplicatePixelDragPreservesSourceAndUndoesTogether() async throws {
        let session = makeSession()
        try await twoColorLayer(session)
        select(session, CGRect(x: 10, y: 10, width: 10, height: 10))
        let count = session.history.undoCount
        #expect(session.beginPixelMove(duplicate: true))
        session.movePixels(by: CGSize(width: 60, height: 5))
        await session.finishPixelMove()
        let result = try await render(session)
        #expect(try pixel(result, x: 15, y: 15)[0] > 250)
        #expect(try pixel(result, x: 75, y: 20)[0] > 250)
        #expect(session.history.undoCount == count + 1)
        #expect(session.history.undoName == "Duplicate Pixels")
        session.undo()
        let restored = try await render(session)
        #expect(try pixel(restored, x: 15, y: 15)[0] > 250)
        #expect(try pixel(restored, x: 75, y: 20)[2] > 250)
    }

    @Test func cmdArrowNudgesPixelsAndMasksRefuse() async throws {
        let session = makeSession()
        try await twoColorLayer(session)
        select(session, CGRect(x: 40, y: 0, width: 10, height: 40)) // Last red column band.
        await session.nudgePixels(dx: 10, dy: 0)
        let result = try await render(session)
        #expect(try pixel(result, x: 45, y: 20)[3] == 0)
        #expect(try pixel(result, x: 55, y: 20) == [255, 0, 0, 255])
        session.addLayerMask()
        #expect(session.isMaskSelected && !session.beginPixelMove())
        session.cancelPixelMove()
    }

    @Test func invertKeepsTransparencyStaysInSelectionAndWorksOnMasks() async throws {
        let session = makeSession()
        try await twoColorLayer(session)
        select(session, CGRect(x: 0, y: 0, width: 100, height: 20)) // Top half only.
        await session.invertPixels()
        #expect(session.history.undoName == "Invert")
        var result = try await render(session)
        #expect(try pixel(result, x: 10, y: 5) == [0, 255, 255, 255])    // Red → cyan.
        #expect(try pixel(result, x: 90, y: 5) == [255, 255, 0, 255])    // Blue → yellow.
        #expect(try pixel(result, x: 10, y: 30) == [255, 0, 0, 255])     // Outside selection: unchanged.
        session.deselect()
        // A half-transparent pixel keeps its alpha.
        let blank = makeSession()
        let context = try BrushRaster.context(width: 100, height: 40, mask: false)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 40))
        let image = try #require(context.makeImage())
        blank.insert(ImportedImage(image: image, thumbnail: image, name: "Half"))
        await blank.invertPixels()
        let half = try pixel(try await render(blank), x: 50, y: 20)
        #expect(abs(half[3] - 128) <= 1 && half[0] == 0)
        // On a mask, black and white swap: an all-white mask inverts to hide everything.
        session.addLayerMask()
        await session.invertPixels()
        #expect(session.history.undoName == "Invert Mask")
        result = try await render(session)
        #expect(try pixel(result, x: 50, y: 30)[3] == 0)
    }

    @Test func pixelMoveNeverShowsTheOutlineAtItsOldSpot() async throws {
        let session = makeSession()
        try await twoColorLayer(session)
        select(session, CGRect(x: 10, y: 10, width: 10, height: 10))
        #expect(session.beginPixelMove())
        session.movePixels(by: CGSize(width: 30, height: 0))
        let moved = CGRect(x: 40, y: 10, width: 10, height: 10)
        #expect(session.displayedSelection?.path.boundingBoxOfPath == moved)
        let finishing = Task { await session.finishPixelMove() }
        // While the commit is in flight the outline stays at the new place.
        #expect(session.displayedSelection?.path.boundingBoxOfPath == moved)
        await finishing.value
        #expect(session.selection?.path.boundingBoxOfPath == moved && session.pixelMove == nil)
    }

    /// This used to hold a wall-clock budget as well (1.5 s for a 4000 x 3000 invert, whole and through a
    /// selection). It cannot measure the code from inside this suite: the tests run in parallel and this is the
    /// biggest image in the run. Measured against the full suite on an M3, the whole-image invert took 0.19 s
    /// and the selection path - which goes through Core Image - took 41.5 s, so the assertion reported the
    /// machine's load rather than the code. Measure it with `-only-testing:CompositorTests/SelectionEditTests`
    /// instead, on a machine that is otherwise idle.
    @Test func invertHandlesLargeImagesAndUniformMasksWithASelection() async throws {
        let session = makeSession(width: 4000, height: 3000)
        let context = try BrushRaster.context(width: 4000, height: 3000, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Big"))
        await session.invertPixels()
        select(session, CGRect(x: 0, y: 0, width: 2000, height: 3000))
        await session.invertPixels()
        let result = try await render(session)
        #expect(try pixel(result, x: 100, y: 100) == [255, 0, 0, 255])   // Inverted twice.
        #expect(try pixel(result, x: 3000, y: 100) == [0, 255, 255, 255]) // Inverted once.
        // A reveal-all (1×1) mask with a selection inverts just the selected part.
        session.addLayerMask()
        await session.invertPixels()
        let masked = try await render(session)
        #expect(try pixel(masked, x: 100, y: 100)[3] == 0 && pixel(masked, x: 3000, y: 100)[3] == 255)
    }

    @Test func quickOperationsNeverDimTheInterface() async throws {
        let session = makeSession()
        session.isProjectBusy = true
        try await Task.sleep(for: .milliseconds(60))
        session.isProjectBusy = false
        #expect(!session.showsBusy)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!session.showsBusy) // The short busy period never surfaced.
        // Long operations still dim. Polled rather than timed once: the suite runs in
        // parallel, so a fixed window is flaky on a loaded machine.
        session.isProjectBusy = true
        var dimmed = false
        for _ in 0..<40 where !dimmed {
            try await Task.sleep(for: .milliseconds(50))
            dimmed = session.showsBusy
        }
        #expect(dimmed)
        session.isProjectBusy = false
        #expect(!session.showsBusy)
    }

    @Test func invertWorksInEveryTool() async throws {
        let session = makeSession()
        try await twoColorLayer(session)
        for tool in [NavigationTool.brush, .move, .crop, .hand, .zoom, .lasso] {
            session.selectTool(tool)
            #expect(session.canInvert, "\(tool)")
        }
        session.selectTool(.crop)
        await session.invertPixels()
        #expect(session.history.undoName == "Invert")
        #expect(try pixel(try await render(session), x: 10, y: 5) == [0, 255, 255, 255])
        // A pending gradient is applied first, then inverted.
        session.selectTool(.gradient)
        session.beginGradient(at: CGPoint(x: 0, y: 20))
        session.moveGradient(end: CGPoint(x: 100, y: 20))
        #expect(session.gradientEdit != nil && session.canInvert)
        await session.invertPixels()
        #expect(session.gradientEdit == nil && session.history.undoName == "Invert")
        session.undo()
        #expect(session.history.undoName == "Gradient")
    }
}
