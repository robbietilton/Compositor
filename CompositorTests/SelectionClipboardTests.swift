import AppKit
import Testing
@testable import Compositor

/// Serialized: every test in this process shares its one pasteboard (`SystemPasteboard.pasteboard`, private to the process,
/// so other test processes running in parallel can't copy over it).
@MainActor @Suite(.serialized)
struct SelectionClipboardTests {
    private let red = PaletteColor(red: 1, green: 0, blue: 0)
    private let blue = PaletteColor(red: 0, green: 0, blue: 1)

    /// A 100×40 canvas whose layer is red on the left half and blue on the right.
    private func makeSession() async -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 100, height: 40, emptyLayer: true)
        session.setPaletteColor(red, background: false)
        session.setPaletteColor(blue, background: true)
        await session.fillSelection(with: .background)
        select(session, CGRect(x: 0, y: 0, width: 50, height: 40))
        await session.fillSelection(with: .foreground)
        session.deselect()
        return session
    }
    private func select(_ session: EditorSession, _ rect: CGRect) {
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
    /// Renders only one layer, to check a layer's own pixels.
    private func layerPixel(_ session: EditorSession, _ id: UUID, x: Int, y: Int) async throws -> [Int] {
        let full = try #require(session.document)
        var solo = full
        solo.layers = full.layers.filter { $0.id == id }
        session.document = solo
        defer { session.document = full }
        return try pixel(try await render(session), x: x, y: y)
    }

    /// PNG data for a `width`×`height` image, at 8 or 16 bits a channel, as another app puts on the clipboard.
    private func png(width: Int, height: Int, bits: Int = 8) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: bits,
            bytesPerRow: width * 4 * bits / 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | (bits == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0)))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    /// Cmd-V on the New canvas screen with an image on the clipboard makes a canvas its size with it in it; a 16-bit one
    /// comes in as a 16-bit layer, as importing it would.
    @Test(arguments: [8, 16])
    func pastingAnImageOnTheNewCanvasScreenMakesTheCanvas(bits: Int) async throws {
        let session = EditorSession()
        let pasteboard = SystemPasteboard.pasteboard
        pasteboard.clearContents()
        pasteboard.setData(try png(width: 320, height: 200, bits: bits), forType: .png)
        #expect(session.document == nil && session.canPasteImageAsNewCanvas)
        await session.pasteImageAsNewCanvas()
        let document = try #require(session.document, "a canvas")
        #expect(document.width == 320 && document.height == 200)
        #expect(document.layers.count == 1 && document.layers.first?.size == CGSize(width: 320, height: 200))
        #expect((document.layers.first?.asset?.deep != nil) == (bits == 16))
        #expect(session.canPasteImageAsNewCanvas == false, "with a canvas, Paste pastes into it")
    }

    /// A size copied as text goes into the size field, image or not.
    @Test func aSizeOnTheClipboardIsLeftForTheField() throws {
        let session = EditorSession()
        let pasteboard = SystemPasteboard.pasteboard
        pasteboard.clearContents()
        pasteboard.setString("1920", forType: .string)
        #expect(!session.canPasteImageAsNewCanvas)
        pasteboard.setData(try png(width: 10, height: 10), forType: .png)
        #expect(!session.canPasteImageAsNewCanvas, "a size and an image: the size")
        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        #expect(!session.canPasteImageAsNewCanvas, "text alone has no image to make a canvas from")
    }

    @Test func copyAndPastePutsPixelsOnANewLayerInPlace() async throws {
        let session = await makeSession()
        let source = try #require(session.activeLayerID)
        select(session, CGRect(x: 40, y: 10, width: 20, height: 20)) // Straddles red and blue.
        session.copySelection()
        let count = session.history.undoCount
        #expect(session.canPaste)
        session.paste()
        #expect(session.history.undoCount == count + 1 && session.history.undoName == "Paste")
        let pasted = try #require(session.activeLayer)
        #expect(pasted.id != source && pasted.name == "Layer 2" && session.selection == nil)
        #expect(pasted.transform.origin == CGPoint(x: 40, y: 10) && pasted.size == CGSize(width: 20, height: 20))
        #expect(try await layerPixel(session, pasted.id, x: 45, y: 15) == [255, 0, 0, 255])
        #expect(try await layerPixel(session, pasted.id, x: 55, y: 15) == [0, 0, 255, 255])
        #expect(try await layerPixel(session, pasted.id, x: 30, y: 15)[3] == 0)
        #expect(try await layerPixel(session, source, x: 45, y: 15) == [255, 0, 0, 255]) // Source untouched.
        session.undo()
        #expect(session.document?.layers.count == 1)
    }

    @Test func cutLeavesAHoleAndPasteRestoresThePixels() async throws {
        let session = await makeSession()
        let source = try #require(session.activeLayerID)
        select(session, CGRect(x: 10, y: 10, width: 10, height: 10))
        await session.cutSelection()
        #expect(try await layerPixel(session, source, x: 15, y: 15)[3] == 0)
        session.paste()
        #expect(try pixel(try await render(session), x: 15, y: 15) == [255, 0, 0, 255])
    }

    @Test func layerViaCopyCopiesTheSelectionOrDuplicatesTheLayer() async throws {
        let session = await makeSession()
        let source = try #require(session.activeLayer)
        select(session, CGRect(x: 60, y: 0, width: 10, height: 40))
        session.layerViaCopy()
        #expect(session.history.undoName == "Layer via Copy" && session.document?.layers.count == 2)
        #expect(session.activeLayer?.size == CGSize(width: 10, height: 40) && session.selection == nil,
                "size \(String(describing: session.activeLayer?.size))")
        session.selectLayer(source.id)
        session.layerViaCopy()
        #expect(session.history.undoName == "Duplicate Layer" && session.activeLayer?.name == "\(source.name) copy")
        #expect(session.activeLayer?.asset?.image === source.asset?.image)
    }

    @Test func duplicateGIFReservesThumbnailBudgetForEachSavedLayer() throws {
        let asset = try LiveMaskTests().asset([255, 255, 255, 255])
        let context = try BrushRaster.context(width: 96, height: 96, mask: false)
        let thumbnail = try #require(context.makeImage())
        let frames = (0..<1_000).map { GIFTimelineFrame(index: $0, thumbnail: thumbnail, duration: 0.1) }
        let source = GIFSource(data: Data([0]), frames: frames, width: 2, height: 2)
        let session = EditorSession()
        session.insert(asset, gifAnimation: GIFAnimation(source: source))
        let layer = try #require(session.activeLayer)
        #expect(session.canRetainGIFSources(in: [layer]))
        // Reused images and source bytes still produce two complete thumbnail sets when the package is reopened.
        #expect(!session.canRetainGIFSources(in: [layer, layer]))
        let count = session.history.undoCount
        session.duplicateActiveLayer()
        #expect(session.document?.layers.count == 1)
        #expect(session.activeLayerID == layer.id)
        #expect(session.history.undoCount == count)
    }

    @Test func transformSelectionMovesPixelsAndOutlineAsOneUndo() async throws {
        let session = await makeSession()
        let source = try #require(session.activeLayerID)
        select(session, CGRect(x: 10, y: 10, width: 10, height: 10))
        let before = session.document
        let count = session.history.undoCount
        #expect(session.canTransformSelection)
        await session.beginSelectionTransform()
        var draft = try #require(session.transformEdit?.draft)
        #expect(session.transformEdit?.floating != nil && session.tool == .move)
        draft.origin = CGPoint(x: 70, y: 20)
        session.previewTransform(draft)
        #expect(session.displayedSelection?.path.boundingBoxOfPath == CGRect(x: 70, y: 20, width: 10, height: 10))
        session.commitTransform()
        #expect(session.history.undoCount == count + 1 && session.history.undoName == "Transform Selection")
        #expect(session.document?.layers.count == 1 && session.activeLayerID == source)
        #expect(session.selection?.path.boundingBoxOfPath == CGRect(x: 70, y: 20, width: 10, height: 10))
        let result = try await render(session)
        #expect(try pixel(result, x: 15, y: 15)[3] == 0)                // Hole where they were.
        #expect(try pixel(result, x: 75, y: 25) == [255, 0, 0, 255])    // Red now on the blue side.
        #expect(try pixel(result, x: 85, y: 25) == [0, 0, 255, 255])
        session.undo()
        #expect(session.document == before)
    }

    @Test func escapeRestoresExactlyWithoutAnUndoStep() async throws {
        let session = await makeSession()
        select(session, CGRect(x: 10, y: 10, width: 10, height: 10))
        let before = session.document, active = session.activeLayerID
        let count = session.history.undoCount
        await session.beginSelectionTransform()
        var draft = try #require(session.transformEdit?.draft)
        draft.origin.x += 30
        session.previewTransform(draft)
        session.cancelTransform()
        #expect(session.document == before && session.activeLayerID == active)
        #expect(session.transformEdit == nil && session.history.undoCount == count)
    }

    @Test func applyingAnUnchangedTransformLeavesSoftEdgesUntouched() async throws {
        let session = await makeSession()
        session.selectionAntialiased = true
        session.applySelection(CGPath(ellipseIn: CGRect(x: 10.3, y: 5.7, width: 30, height: 25), transform: nil),
                               mode: .replace, name: "Select")
        let before = session.document
        let count = session.history.undoCount
        await session.beginSelectionTransform()
        session.commitTransform()
        #expect(session.document == before && session.history.undoCount == count)
    }

    @Test func scalingAndMovingPastTheLayerEdgeGrowsTheLayer() async throws {
        let session = await makeSession()
        let source = try #require(session.activeLayerID)
        select(session, CGRect(x: 0, y: 0, width: 10, height: 10))
        await session.beginSelectionTransform()
        var draft = try #require(session.transformEdit?.draft)
        draft.size = CGSize(width: 20, height: 20)   // 2× larger…
        draft.origin = CGPoint(x: 90, y: 30)          // …and hanging off the canvas corner.
        session.previewTransform(draft)
        session.selectTool(.lasso)                    // Switching tools applies it.
        #expect(session.transformEdit == nil && session.history.undoName == "Transform Selection")
        let layer = try #require(session.document?.layers.first { $0.id == source })
        #expect(layer.size == CGSize(width: 110, height: 50))
        let result = try await render(session)
        #expect(try pixel(result, x: 95, y: 35) == [255, 0, 0, 255])
        #expect(try pixel(result, x: 5, y: 5)[3] == 0)
        #expect(session.selection?.path.boundingBoxOfPath == CGRect(x: 90, y: 30, width: 20, height: 20))
    }

    @Test func lassoShapedSelectionCopiesAndPastes() async throws {
        let session = await makeSession()
        session.selectTool(.lasso)
        // A triangle drawn with the lasso, over the red half.
        session.beginLasso(at: CGPoint(x: 10, y: 5), mode: .replace)
        for point in [CGPoint(x: 40, y: 5), CGPoint(x: 10, y: 35)] { session.extendLasso(to: point) }
        session.finishLasso()
        #expect(session.history.undoName == "Lasso" && session.canCopyPixels)
        session.copySelection()
        session.paste()
        let pasted = try #require(session.activeLayer)
        #expect(pasted.transform.origin == CGPoint(x: 10, y: 5) && pasted.size == CGSize(width: 30, height: 30))
        #expect(try await layerPixel(session, pasted.id, x: 15, y: 10) == [255, 0, 0, 255]) // Inside the triangle.
        #expect(try await layerPixel(session, pasted.id, x: 38, y: 33)[3] == 0)             // Past the diagonal.
    }

    @Test func copyMergedTakesEveryVisibleLayerNotJustTheActiveOne() async throws {
        let session = await makeSession()
        // A small green layer on top of the red/blue one.
        let context = try BrushRaster.context(width: 20, height: 20, mask: false)
        context.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let square = try #require(context.makeImage())
        session.insert(ImportedImage(image: square, thumbnail: square, name: "Green"))
        let green = try #require(session.activeLayerID)
        let index = try #require(session.document?.layers.firstIndex { $0.id == green })
        session.document?.layers[index].transform = LayerTransform(origin: CGPoint(x: 60, y: 10), size: CGSize(width: 20, height: 20))
        select(session, CGRect(x: 55, y: 5, width: 30, height: 30))

        session.copySelection() // Active layer only: just the green square.
        session.paste()
        var pasted = try #require(session.activeLayer)
        #expect(try await layerPixel(session, pasted.id, x: 65, y: 15) == [0, 255, 0, 255])
        #expect(try await layerPixel(session, pasted.id, x: 58, y: 8)[3] == 0)
        session.undo()

        session.selectLayer(green)
        select(session, CGRect(x: 55, y: 5, width: 30, height: 30))
        #expect(session.canCopyMerged)
        session.copyMergedSelection() // Every visible layer.
        session.paste()
        pasted = try #require(session.activeLayer)
        #expect(try await layerPixel(session, pasted.id, x: 65, y: 15) == [0, 255, 0, 255])
        #expect(try await layerPixel(session, pasted.id, x: 58, y: 8) == [0, 0, 255, 255])
        session.undo()

        // Hidden layers are left out.
        session.selectLayer(green)
        session.toggleLayerVisibility(green)
        select(session, CGRect(x: 55, y: 5, width: 30, height: 30))
        session.copyMergedSelection()
        session.paste()
        pasted = try #require(session.activeLayer)
        #expect(try await layerPixel(session, pasted.id, x: 65, y: 15) == [0, 0, 255, 255])
    }
}
