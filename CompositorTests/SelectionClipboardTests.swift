import AppKit
import Testing
import UniformTypeIdentifiers
@testable import Compositor

/// Serialized: every test shares the one system pasteboard.
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
    /// An image as a Retina screenshot saves it: 144 dpi, so it measures half its pixels in points.
    /// Red on the left half, blue on the right, green in the bottom-left quarter.
    private func screenshotPNG(width: Int = 30, height: Int = 20) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        context.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2)) // Context y runs up: the bottom quarter.
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()),
                                   [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
    /// Puts the screenshot on the clipboard as image data, with any text copied alongside.
    private func copyScreenshot(width: Int = 30, height: Int = 20, text: String? = nil) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(try screenshotPNG(width: width, height: height), forType: .png)
        if let text { pasteboard.setString(text, forType: .string) }
    }
    /// Puts a file on the clipboard as Finder's Copy does: its URL, its name, and its icon.
    private func copyInFinder(_ file: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(file.absoluteString, forType: .fileURL)
        pasteboard.setString(file.lastPathComponent, forType: .string)
        pasteboard.setData(NSWorkspace.shared.icon(forFile: file.path).tiffRepresentation, forType: .tiff)
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

    @Test func pasteOnAnEmptyProjectMakesACanvasTheImageSize() async throws {
        try copyScreenshot()
        #expect(NSImage(pasteboard: .general)?.size == CGSize(width: 15, height: 10)) // Points: the Retina case.
        let session = EditorSession()
        #expect(session.canPasteAsNewCanvas)
        await session.pasteAsNewCanvas()
        let document = try #require(session.document)
        #expect(document.width == 30 && document.height == 20)
        let pasted = try #require(session.activeLayer)
        #expect(document.layers.map(\.id) == [pasted.id] && pasted.name == "Layer 1")
        #expect(pasted.transform.origin == .zero && pasted.size == CGSize(width: 30, height: 20))
        #expect(try await layerPixel(session, pasted.id, x: 5, y: 5) == [255, 0, 0, 255])
        #expect(try await layerPixel(session, pasted.id, x: 5, y: 15) == [0, 255, 0, 255])
        #expect(try await layerPixel(session, pasted.id, x: 25, y: 10) == [0, 0, 255, 255])
        #expect(session.history.undoCount == 1 && session.history.undoName == "Paste")
        session.undo()
        #expect(session.document == nil)
    }

    @Test func pasteOnAnEmptyProjectImportsAFileCopiedInFinderNotItsIcon() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("photo.png")
        try screenshotPNG().write(to: photo)
        copyInFinder(photo)
        let session = EditorSession()
        #expect(session.canPasteAsNewCanvas)
        await session.pasteAsNewCanvas()
        let document = try #require(session.document)
        #expect(document.width == 30 && document.height == 20)
        let imported = try #require(session.activeLayer)
        #expect(document.layers.map(\.id) == [imported.id] && session.history.undoName == "Import Images")
        #expect(try await layerPixel(session, imported.id, x: 5, y: 5) == [255, 0, 0, 255])
        #expect(try await layerPixel(session, imported.id, x: 5, y: 15) == [0, 255, 0, 255])

        // Any other file brings only its icon, which is no image to paste.
        let notes = folder.appendingPathComponent("notes.txt")
        try Data("Some notes".utf8).write(to: notes)
        copyInFinder(notes)
        #expect(!EditorSession().canPasteAsNewCanvas)
    }

    @Test func pasteAsNewCanvasLeavesNumbersAndOpenCanvasesAlone() async throws {
        let empty = EditorSession()
        try copyScreenshot(text: "1920") // A size for the Width field, copied along with an image.
        #expect(!empty.canPasteAsNewCanvas)
        try copyScreenshot(text: "1920\n") // A spreadsheet cell ends its number with a line break.
        #expect(!empty.canPasteAsNewCanvas)
        try copyScreenshot(text: "Sunset over the bay") // Other text, such as a web page's caption.
        #expect(empty.canPasteAsNewCanvas)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("Some copied text", forType: .string)
        #expect(!empty.canPasteAsNewCanvas)

        try copyScreenshot()
        let open = await makeSession()
        let before = open.document
        #expect(!open.canPasteAsNewCanvas)
        await open.pasteAsNewCanvas()
        #expect(open.document == before)
    }

    @Test func pasteAsNewCanvasRefusesAnImagePastTheSideLimit() async throws {
        try copyScreenshot(width: DocumentLimits.maxSide + 1, height: 1)
        let session = EditorSession()
        await session.pasteAsNewCanvas()
        #expect(session.document == nil && session.importError != nil)
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
