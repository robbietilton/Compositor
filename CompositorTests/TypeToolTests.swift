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
        session.textDraft?.style.content = "Text"
        #expect(session.document?.layers.count == 1)
        var draft = try #require(session.textDraft)
        draft.style.content = "Hello\nCompositor"
        draft.style.fontSize = 48
        #expect(session.applyText(draft))
        #expect(session.activeLayer?.liveText?.style == draft.style)
        #expect(session.activeLayer?.origin == CGPoint(x: 30, y: 40))
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

    private func setupEditor(session: EditorSession, initialText: String = "") throws -> (CanvasView, InlineTextEditor, CanvasTextView, NSWindow) {
        let canvas = CanvasView(session: session)
        canvas.synchronizeInlineText()
        let editor = try #require(canvas.inlineTextEditor)
        let textView = editor.textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = canvas
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        if !initialText.isEmpty {
            textView.string = initialText
            editor.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
            textView.undoManager?.removeAllActions()
        }
        return (canvas, editor, textView, window)
    }

    private func endEventCycle() {
        (NSClassFromString("NSUndoManager") as? AnyObject)?.perform(NSSelectorFromString("_endTopLevelGroupings"))
    }

    private func simulateKeyType(_ character: String, in textView: CanvasTextView, window: NSWindow) {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character.lowercased(),
            isARepeat: false,
            keyCode: 0
        )!
        NSApp.sendEvent(event)
        endEventCycle()
    }

    private func simulateTypingSequence(_ text: String, in textView: CanvasTextView, window: NSWindow) {
        for char in text {
            simulateKeyType(String(char), in: textView, window: window)
        }
    }

    private func simulateDeleteSelection(range: NSRange, in textView: CanvasTextView, window: NSWindow) {
        textView.setSelectedRange(range)
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{7F}",
            charactersIgnoringModifiers: "\u{7F}",
            isARepeat: false,
            keyCode: 51
        )!
        NSApp.sendEvent(event)
        endEventCycle()
    }

    private func simulatePasteText(_ text: String, in textView: CanvasTextView) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        textView.paste(nil)
        endEventCycle()
    }

    private func simulateSelectionReplacement(range: NSRange, with text: String, in textView: CanvasTextView) {
        textView.setSelectedRange(range)
        textView.insertText(text, replacementRange: range)
        endEventCycle()
    }

    @Test func continuousTypingCharacterByCharacterUndoAndRedo() throws {
        let session = makeSession()
        session.beginText(at: .zero)
        let (_, _, textView, window) = try setupEditor(session: session)

        simulateTypingSequence("ABC", in: textView, window: window)
        #expect(textView.string == "ABC")
        #expect(session.textDraft?.style.content == "ABC")
        #expect(textView.undoManager?.canUndo == true)
        #expect(textView.undoManager?.canRedo == false)

        // Step back through individual characters
        textView.undo()
        #expect(textView.string == "AB")
        #expect(session.textDraft?.style.content == "AB")
        #expect(textView.undoManager?.canUndo == true)
        #expect(textView.undoManager?.canRedo == true)

        textView.undo()
        #expect(textView.string == "A")
        #expect(session.textDraft?.style.content == "A")
        #expect(textView.undoManager?.canUndo == true)
        #expect(textView.undoManager?.canRedo == true)

        textView.undo()
        #expect(textView.string == "")
        #expect(session.textDraft?.style.content == "")
        #expect(textView.undoManager?.canUndo == false)
        #expect(textView.undoManager?.canRedo == true)

        // Redo steps back forward through individual characters
        textView.redo()
        #expect(textView.string == "A")
        #expect(session.textDraft?.style.content == "A")
        #expect(textView.undoManager?.canUndo == true)
        #expect(textView.undoManager?.canRedo == true)

        textView.redo()
        #expect(textView.string == "AB")
        #expect(session.textDraft?.style.content == "AB")
        #expect(textView.undoManager?.canUndo == true)
        #expect(textView.undoManager?.canRedo == true)

        textView.redo()
        #expect(textView.string == "ABC")
        #expect(session.textDraft?.style.content == "ABC")
        #expect(textView.undoManager?.canUndo == true)
        #expect(textView.undoManager?.canRedo == false)
    }

    @Test func pasteRemainsSingleUndoOperation() throws {
        let session = makeSession()
        session.beginText(at: .zero)
        let (_, _, textView, _) = try setupEditor(session: session)

        simulatePasteText("ABC", in: textView)
        #expect(textView.string == "ABC")
        #expect(session.textDraft?.style.content == "ABC")
        #expect(textView.undoManager?.canUndo == true)
        #expect(textView.undoManager?.canRedo == false)

        // Pasting "ABC" must undo atomically in one step, not character-by-character
        textView.undo()
        #expect(textView.string == "")
        #expect(session.textDraft?.style.content == "")
        #expect(textView.undoManager?.canUndo == false)
        #expect(textView.undoManager?.canRedo == true)

        textView.redo()
        #expect(textView.string == "ABC")
        #expect(session.textDraft?.style.content == "ABC")
        #expect(textView.undoManager?.canUndo == true)
        #expect(textView.undoManager?.canRedo == false)
    }

    @Test func selectionDeletionRemainsSingleUndoOperation() throws {
        let session = makeSession()
        session.beginText(at: .zero)
        let (_, _, textView, window) = try setupEditor(session: session, initialText: "ABCDEF")

        let cdRange = NSRange(location: 2, length: 2) // "CD"
        simulateDeleteSelection(range: cdRange, in: textView, window: window)
        #expect(textView.string == "ABEF")
        #expect(session.textDraft?.style.content == "ABEF")
        #expect(textView.undoManager?.canUndo == true)
        #expect(textView.undoManager?.canRedo == false)

        // Deleting selection must undo in one step back to "ABCDEF"
        textView.undo()
        #expect(textView.string == "ABCDEF")
        #expect(session.textDraft?.style.content == "ABCDEF")
        #expect(textView.undoManager?.canUndo == false)
        #expect(textView.undoManager?.canRedo == true)

        textView.redo()
        #expect(textView.string == "ABEF")
        #expect(session.textDraft?.style.content == "ABEF")
        #expect(textView.undoManager?.canUndo == true)
        #expect(textView.undoManager?.canRedo == false)
    }

    @Test func selectionReplacementRemainsSingleUndoOperation() throws {
        let session = makeSession()
        session.beginText(at: .zero)
        let (_, _, textView, _) = try setupEditor(session: session, initialText: "ABCDEF")

        let cdRange = NSRange(location: 2, length: 2) // "CD"
        simulateSelectionReplacement(range: cdRange, with: "XY", in: textView)
        #expect(textView.string == "ABXYEF")
        #expect(session.textDraft?.style.content == "ABXYEF")
        #expect(textView.undoManager?.canUndo == true)
        #expect(textView.undoManager?.canRedo == false)

        // Replacing selection must undo in one step back to "ABCDEF"
        textView.undo()
        #expect(textView.string == "ABCDEF")
        #expect(session.textDraft?.style.content == "ABCDEF")
        #expect(textView.undoManager?.canUndo == false)
        #expect(textView.undoManager?.canRedo == true)

        textView.redo()
        #expect(textView.string == "ABXYEF")
        #expect(session.textDraft?.style.content == "ABXYEF")
        #expect(textView.undoManager?.canUndo == true)
        #expect(textView.undoManager?.canRedo == false)
    }

    @Test func textEditingUndoDoesNotPolluteDocumentHistory() throws {
        let session = makeSession()
        session.addBlankLayer()
        let docHistoryBefore = session.history.undoCount

        session.selectTool(.type)
        session.beginText(at: CGPoint(x: 10, y: 10))
        let (_, _, textView, window) = try setupEditor(session: session, initialText: "Hello")

        simulateTypingSequence("!", in: textView, window: window)
        #expect(session.history.undoCount == docHistoryBefore)

        textView.undo()
        #expect(textView.string == "Hello")
        #expect(session.history.undoCount == docHistoryBefore)

        #expect(session.finishText())
        #expect(session.history.undoCount == docHistoryBefore + 1)
        #expect(session.activeLayer?.liveText?.style.content == "Hello")

        session.undo()
        #expect(session.history.undoCount == docHistoryBefore)
        #expect(session.activeLayer?.liveText == nil)
    }

    @Test func textEditingResponderChainRoutingAndValidation() throws {
        let session = makeSession()
        session.beginText(at: .zero)
        let (_, _, textView, window) = try setupEditor(session: session, initialText: "Hello")

        let undoItem = NSMenuItem(title: "Undo", action: #selector(CanvasTextView.undo(_:)), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: #selector(CanvasTextView.redo(_:)), keyEquivalent: "Z")

        #expect(!textView.validateUserInterfaceItem(undoItem))
        #expect(!textView.validateUserInterfaceItem(redoItem))

        simulateTypingSequence("!", in: textView, window: window)
        #expect(textView.validateUserInterfaceItem(undoItem))
        #expect(!textView.validateUserInterfaceItem(redoItem))

        let undoPerformed = window.firstResponder?.tryToPerform(#selector(CanvasTextView.undo(_:)), with: nil) ?? false
        #expect(undoPerformed)
        #expect(textView.string == "Hello")
        #expect(session.textDraft?.style.content == "Hello")

        #expect(!textView.validateUserInterfaceItem(undoItem))
        #expect(textView.validateUserInterfaceItem(redoItem))

        let redoPerformed = window.firstResponder?.tryToPerform(#selector(CanvasTextView.redo(_:)), with: nil) ?? false
        #expect(redoPerformed)
        #expect(textView.string == "Hello!")
        #expect(session.textDraft?.style.content == "Hello!")
    }

    @Test func cancelTextEditingPreservesDocumentState() throws {
        let session = makeSession()
        session.beginText(at: .zero)
        session.textDraft?.style.content = "Original"
        #expect(session.finishText())
        let beforeUndoCount = session.history.undoCount

        session.editActiveText()
        let (_, _, textView, window) = try setupEditor(session: session, initialText: "Original")
        simulateTypingSequence(" Altered", in: textView, window: window)
        #expect(textView.string == "Original Altered")

        session.cancelText()
        #expect(session.textDraft == nil)
        #expect(session.activeLayer?.liveText?.style.content == "Original")
        #expect(session.history.undoCount == beforeUndoCount)
    }
}
