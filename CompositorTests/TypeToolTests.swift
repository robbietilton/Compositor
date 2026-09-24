import AppKit
import Testing
@testable import Compositor

@MainActor
struct TypeToolTests {
    private func makeSession() -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 800, height: 600, emptyLayer: true)
        session.selectTool(.type)
        return session
    }

    @Test func createEditCancelAndUndo() throws {
        let session = makeSession()
        let before = session.history.undoCount
        session.beginText(at: CGPoint(x: 30, y: 40))
        // A click starts the first letter on the pointer: the box sits its padding to the left and its first
        // baseline's height above.
        let start = try #require(session.textDraft)
        let style = start.style
        let descent = abs((EditorSession.textAttributes(style)[.font] as? NSFont)?.descender ?? 0)
        #expect(start.origin == CGPoint(x: 30 - LayerTextStyle.padding, y: 40 - (LayerTextStyle.padding + style.lineHeight - descent)))
        session.textDraft?.style.content = "Text"
        #expect(session.document?.layers.count == 1)
        var draft = try #require(session.textDraft)
        draft.style.content = "Hello\nCompositor"
        draft.style.fontSize = 48
        #expect(session.applyText(draft))
        #expect(session.activeLayer?.liveText?.style == draft.style)
        #expect(session.activeLayer?.origin == start.origin)
        #expect(session.history.undoCount == before + 1)
        session.editActiveText()
        session.textDraft = nil
        #expect(session.history.undoCount == before + 1)
        session.editActiveText()
        draft = try #require(session.textDraft)
        draft.style.content = "Changed"
        #expect(session.applyText(draft))
        session.undo()
        #expect(session.activeLayer?.liveText?.style.content == "Hello\nCompositor")
        session.undo()
        #expect(session.document?.layers.count == 1)
        session.redo()
        #expect(session.activeLayer?.liveText != nil)
    }

    @Test func textColorPickerPreviewsAndRestoresDraft() throws {
        let session = makeSession()
        session.beginText(at: CGPoint(x: 30, y: 40))
        let original = try #require(session.textDraft?.style)

        session.openTextColorPicker()
        try #require(session.colorPicker).hsb.setRGB(PaletteColor(red: 1, green: 0, blue: 0))
        session.previewTextColor()
        #expect(session.textDraft?.style.red == 1)
        #expect(session.textDraft?.style.green == 0)
        #expect(session.foregroundColor == .black)

        session.closeColorPicker(commit: false)
        #expect(session.textDraft?.style == original)
        #expect(session.foregroundColor == .black)

        session.openTextColorPicker()
        try #require(session.colorPicker).hsb.setRGB(PaletteColor(red: 0, green: 0, blue: 1))
        session.previewTextColor()
        session.closeColorPicker(commit: true)
        #expect(session.textDraft?.style.blue == 1)
        #expect(session.foregroundColor == PaletteColor(red: 0, green: 0, blue: 1))
    }

    @Test func transformsDuplicatesAndClippingKeepTextEditable() throws {
        let session = makeSession()
        session.beginText(at: CGPoint(x: 20, y: 20))
        session.textDraft?.style.content = "Text"
        #expect(session.applyText(try #require(session.textDraft)))
        let id = try #require(session.activeLayerID)
        let index = try #require(session.document?.layers.firstIndex(where: { $0.id == id }))
        session.document?.layers[index].transform.rotation = 30
        session.document?.layers[index].transform.size.width *= 2
        let old = try #require(session.activeLayer?.transform)
        session.editActiveText()
        var draft = try #require(session.textDraft)
        draft.style.content = "Longer text"
        #expect(session.applyText(draft))
        let updated = try #require(session.activeLayer?.transform)
        #expect(updated.rotation == 30)
        #expect(abs(updated.point(.zero).x - old.point(.zero).x) < 0.001)
        #expect(abs(updated.point(.zero).y - old.point(.zero).y) < 0.001)
        session.duplicateActiveLayer()
        #expect(session.activeLayer?.liveText?.style.content == "Longer text")
        let target = try #require(session.activeLayerID)
        #expect(session.linkMask(source: id, target: target))
        #expect(session.activeLayer?.maskSourceID == id)
        #expect(session.document?.layers.first(where: { $0.id == id })?.liveText != nil)
    }

    @Test func saveReopenAndRasterize() async throws {
        let session = makeSession()
        session.beginText(at: .zero)
        session.textDraft?.style.content = "Text"
        var draft = try #require(session.textDraft)
        draft.style.content = "Café 日本語\nSecond line"
        draft.style.alignment = .right
        draft.style.tracking = 3
        #expect(session.applyText(draft))
        let snapshot = try #require(session.projectSnapshot())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".compositor")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(snapshot, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        let reopened = makeSession()
        reopened.installProject(loaded, from: url)
        #expect(reopened.activeLayer?.liveText?.style == draft.style)
        let index = try #require(reopened.document?.layers.firstIndex(where: { $0.id == reopened.activeLayerID }))
        let replacement = try EditorSession.shapeImage(.rectangle, size: CGSize(width: 10, height: 10), color: PaletteColor(red: 1, green: 0, blue: 0))
        reopened.document?.layers[index].asset = ImportedImage(image: replacement, thumbnail: replacement, name: "Painted")
        #expect(reopened.activeLayer?.liveText == nil)
        #expect(reopened.projectSnapshot()?.manifest.layers[index].text == nil)
    }

    @Test func rasterHasTransparentBackgroundAndColoredGlyphs() throws {
        var style = LayerTextStyle()
        style.content = "TYPE"
        style.red = 1
        let image = try EditorSession.textImage(style)
        let bytes = try #require(image.dataProvider?.data) as Data
        var ink = 0, clear = 0
        for i in stride(from: 0, to: bytes.count - 3, by: 4) {
            if bytes[i + 3] == 0 { clear += 1 }
            else { ink += 1; #expect(bytes[i] > 0 && bytes[i + 1] == 0 && bytes[i + 2] == 0) }
        }
        #expect(ink > 100 && clear > 100)
    }

    @Test func clippingToTextExportsColoredGlyphsOnTransparency() async throws {
        let session = makeSession()
        session.beginText(at: .zero)
        // The box on the canvas's corner, where the clipped fill below is placed.
        session.textDraft?.origin = .zero
        session.textDraft?.style.content = "Text"
        #expect(session.applyText(try #require(session.textDraft)))
        let source = try #require(session.activeLayerID)
        let size = try #require(session.activeLayer?.size)
        let fill = try EditorSession.shapeImage(.rectangle, size: size, color: PaletteColor(red: 1, green: 0, blue: 0))
        session.addPixelLayer(fill, at: .zero, name: "Clipped color", editName: "Fill")
        #expect(session.linkMask(source: source, target: try #require(session.activeLayerID)))
        let exported = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let context = try #require(CGContext(data: nil, width: exported.width, height: exported.height,
            bitsPerComponent: 8, bytesPerRow: exported.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(exported, in: CGRect(x: 0, y: 0, width: exported.width, height: exported.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var ink = 0, clear = 0
        for i in stride(from: 0, to: exported.width * exported.height * 4, by: 4) {
            if bytes[i + 3] == 0 { clear += 1 }
            else if bytes[i + 3] == 255 { ink += 1; #expect(bytes[i] == 255 && bytes[i + 1] == 0) }
        }
        #expect(ink > 100 && clear > 100)
    }

    @Test func paragraphBoxAndToolSwitchCommitEditableText() throws {
        let session = makeSession()
        session.beginText(in: CGRect(x: 40, y: 60, width: 200, height: 120))
        #expect(session.textDraft?.style.content == "")
        session.textDraft?.style.content = "Text that wraps inside its paragraph box"
        session.selectTool(.brush)
        #expect(session.textDraft == nil && session.tool == .brush)
        #expect(session.activeLayer?.size == CGSize(width: 200, height: 120))
        #expect(session.activeLayer?.liveText?.style.boxSize == CGSize(width: 200, height: 120))
        session.selectTool(.type)
        session.editActiveText()
        session.textDraft?.style.content = "Edited on canvas"
        session.cancelText()
        #expect(session.activeLayer?.liveText?.style.content == "Text that wraps inside its paragraph box")
    }

    @Test func emptyNewParagraphIsDiscarded() {
        let session = makeSession()
        let count = session.document?.layers.count
        session.beginText(in: CGRect(x: 0, y: 0, width: 100, height: 100))
        session.selectTool(.brush)
        #expect(session.document?.layers.count == count)
        #expect(session.textDraft == nil)
    }

    @Test func invalidAndStaleDraftsDoNotChangeDocument() throws {
        let session = makeSession()
        session.beginText(at: .zero)
        session.textDraft?.style.content = "Text"
        var draft = try #require(session.textDraft)
        draft.style.fontSize = .nan
        #expect(!session.applyText(draft))
        draft.style.fontSize = 72
        draft.style.boxSize = CGSize(width: 0, height: 100)
        #expect(!session.applyText(draft))
        draft.style.boxSize = CGSize(width: 360, height: 160)
        draft.style.content = "Valid"
        session.textDraft = nil
        session.createDocument(width: 100, height: 100, emptyLayer: true)
        #expect(!session.applyText(draft))
        #expect(session.document?.layers.count == 1)
    }

    /// Zoomed in, text being typed shows as the pixels it will be committed as, so confirming it changes nothing on
    /// screen — at a zoom that smooths pixels and at one that shows them hard-edged.
    @Test(arguments: [1.5, 4] as [CGFloat])
    func textLooksTheSameWhileEditingAndOnceCommitted(zoom: CGFloat) throws {
        let session = makeSession()
        let view = CanvasView(session: session)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        session.viewport.resize(to: view.bounds.size, backingScale: 1, documentSize: CGSize(width: 800, height: 600))
        session.zoom(to: zoom)
        func snapshot() throws -> [UInt8] {
            // The canvas's own drawing, without the editor's box and handles over it.
            view.synchronizeDisplay()
            view.subviews.forEach { $0.isHidden = true }
            defer { view.subviews.forEach { $0.isHidden = false } }
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let data = try #require(rep.bitmapData)
            return Array(UnsafeBufferPointer(start: data, count: rep.bytesPerRow * rep.pixelsHigh))
        }
        let blank = try snapshot()
        session.beginText(at: CGPoint(x: 380, y: 300))
        session.textDraft?.style.content = "Sharp"
        session.textDraft?.style.fontSize = 24
        view.synchronizeDisplay()
        let editor = try #require(view.inlineTextEditor)
        #expect(editor.textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .clear)

        let editing = try snapshot()
        #expect(editing != blank, "the text being typed wasn't drawn on the canvas")
        #expect(session.finishText())
        #expect(session.activeLayer?.liveText != nil)
        let committed = try snapshot()
        #expect(editing.count == committed.count)
        let largest = zip(editing, committed).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(largest <= 2, "the canvas changed by up to \(largest) when the text was committed")
    }
}
