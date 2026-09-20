import AppKit
import Testing
@testable import Compositor

private final class FlippedTestView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
struct TextToolTests {
    private func session() -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 600, height: 400, emptyLayer: true)
        session.selectTool(.text)
        session.textStyle.fontPostScriptName = "Helvetica"
        return session
    }

    @discardableResult
    private func add(_ content: String, to session: EditorSession, boxWidth: CGFloat? = nil) throws -> ImageLayer {
        session.beginText(at: CGPoint(x: 40, y: 50))
        if let boxWidth { session.dragText(to: CGPoint(x: 40 + boxWidth, y: 80)) }
        session.finishTextPlacement()
        _ = try #require(session.textDraft)
        session.updateTextStyle { $0.content = content }
        #expect(session.commitText())
        return try #require(session.activeLayer)
    }

    @Test func emptyAndEscapeCancelWithoutHistoryOrLayers() throws {
        let session = session()
        let before = session.history.undoCount
        let count = try #require(session.document).layers.count
        session.beginText(at: CGPoint(x: 20, y: 20))
        session.finishTextPlacement()
        #expect(session.commitText())
        session.beginText(at: CGPoint(x: 30, y: 30))
        session.finishTextPlacement()
        session.cancelText()
        #expect(session.document?.layers.count == count)
        #expect(session.history.undoCount == before)
    }

    @Test func oversizedTextStaysEditableWithoutChangingHistory() throws {
        let session = session()
        session.beginText(at: CGPoint(x: 20, y: 20))
        session.dragText(to: CGPoint(x: 30_021, y: 40))
        session.finishTextPlacement()
        session.updateTextStyle { $0.content = "Still editable" }
        let before = session.history.undoCount
        #expect(!session.commitText())
        #expect(session.textDraft != nil)
        #expect(session.history.undoCount == before)
    }

    @Test func addAndEditAreEachOneUndoStepAndKeepLayerIdentityPlacementAndParent() throws {
        let session = session()
        let before = session.history.undoCount
        let added = try add("初稿 👋", to: session, boxWidth: 180)
        #expect(session.history.undoCount == before + 1)
        let parent = UUID()
        let index = try #require(session.document?.layers.firstIndex(where: { $0.id == added.id }))
        let originalSize = try #require(session.document?.layers[index].transform.size)
        session.document?.layers[index].parentID = parent
        session.document?.layers[index].transform.size = CGSize(width: originalSize.width * 1.5,
                                                                 height: originalSize.height * 0.75)
        session.document?.layers[index].transform.rotation = 27
        session.document?.layers[index].transform.flipX = true
        let original = try #require(session.document?.layers[index])
        session.beginEditingText(added.id)
        let draft = try #require(session.textDraft)
        #expect(abs(draft.scale.width - 1.5) < 0.02)
        #expect(abs(draft.scale.height - 0.75) < 0.02)
        session.updateTextStyle { $0.content = "再次编辑\n第二行\n第三行" }
        let editCount = session.history.undoCount
        #expect(session.commitText())
        let edited = try #require(session.activeLayer)
        #expect(session.history.undoCount == editCount + 1)
        #expect(edited.id == original.id && edited.parentID == parent)
        let oldAnchor = original.transform.point(.zero), newAnchor = edited.transform.point(.zero)
        #expect(hypot(oldAnchor.x - newAnchor.x, oldAnchor.y - newAnchor.y) < 0.01)
        #expect(edited.transform.rotation == 27 && edited.transform.flipX)
        session.undo()
        #expect(session.activeLayer?.liveText?.style.content == "初稿 👋")
    }

    @Test func editingIsBlockedDuringAnotherModalEdit() throws {
        let session = session()
        let layer = try add("Keep modal state isolated", to: session)
        session.showsNewDocument = true
        session.beginEditingText(layer.id)
        #expect(session.textDraft == nil)
    }

    @Test func commitConfirmsMarkedTextBeforeCreatingHistory() throws {
        let session = session()
        session.beginText(at: CGPoint(x: 20, y: 20))
        session.finishTextPlacement()
        let draft = try #require(session.textDraft)
        let editor = draft.layout.makeTextView()
        editor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        let before = session.history.undoCount
        #expect(session.commitText())
        #expect(!editor.hasMarkedText())
        #expect(session.activeLayer?.liveText?.style.content == "拼")
        #expect(session.history.undoCount == before + 1)
    }

    @Test func pixelEditMakesTextAnOrdinaryRasterLayer() async throws {
        let session = session()
        _ = try add("Rasterize me", to: session)
        #expect(session.activeLayer?.liveText != nil)
        await session.invertPixels()
        #expect(session.activeLayer?.liveText == nil)
    }

    @Test func version8RoundTripAndMissingFontKeepCachedPixelsEditableMetadata() async throws {
        let session = session()
        _ = try add("缺字字体仍显示", to: session)
        let id = try #require(session.activeLayerID)
        let index = try #require(session.document?.layers.firstIndex(where: { $0.id == id }))
        var text = try #require(session.document?.layers[index].liveText)
        text.style.fontPostScriptName = "Definitely-Missing-Font"
        session.document?.layers[index].text = text
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Text-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.version == 8)
        #expect(loaded.manifest.layers.first(where: { $0.id == id })?.text?.fontPostScriptName == "Definitely-Missing-Font")
        let reopened = EditorSession()
        reopened.installProject(loaded, from: url)
        #expect(reopened.document?.layers.first(where: { $0.id == id })?.liveText != nil)
        let export = try await ImageExporter.shared.render(loaded)
        #expect(export.image.width == 600 && export.image.height == 400)
    }

    @Test func editorOverlayUsesNativeFlipCoordinatesForReliableHitTesting() throws {
        let session = session()
        let layer = try add("Flip me", to: session)
        let index = try #require(session.document?.layers.firstIndex(where: { $0.id == layer.id }))
        session.document?.layers[index].transform.size.width *= 1.6
        session.document?.layers[index].transform.size.height *= 0.7
        session.document?.layers[index].transform.rotation = 31
        session.document?.layers[index].transform.flipX = true
        session.document?.layers[index].transform.flipY = true
        let transformed = try #require(session.document?.layers[index].transform)
        session.beginEditingText(layer.id)

        // CanvasView is flipped; matching its coordinates is essential when checking rotation.
        let parent = FlippedTestView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let overlay = TextEditorOverlay(session: session)
        parent.addSubview(overlay)
        var viewport = CanvasViewport()
        viewport.resize(to: parent.bounds.size, backingScale: 1, documentSize: session.document?.size)
        overlay.synchronize(documentSize: try #require(session.document?.size), viewport: viewport)
        let editor = try #require(overlay.subviews.first as? EditingTextView)
        let width = editor.bounds.width
        #expect(editor.convert(CGPoint(x: 0, y: 0), to: parent).x
                > editor.convert(CGPoint(x: width, y: 0), to: parent).x)
        for unit in [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)] {
            let actual = editor.convert(CGPoint(x: unit.x * editor.bounds.width,
                                                 y: unit.y * editor.bounds.height), to: parent)
            let documentPoint = transformed.point(CGPoint(x: 1 - unit.x, y: 1 - unit.y))
            let expected = viewport.viewPoint(from: documentPoint,
                                              documentSize: try #require(session.document?.size))
            #expect(hypot(actual.x - expected.x, actual.y - expected.y) < 1)
        }

        session.cancelText()
        session.document?.layers[index].transform.flipX = false
        session.document?.layers[index].transform.flipY = false
        session.document?.layers[index].transform.rotation = 0
        session.beginEditingText(layer.id)
        overlay.synchronize(documentSize: try #require(session.document?.size), viewport: viewport)
        let resetEditor = try #require(overlay.subviews.first as? EditingTextView)
        #expect(resetEditor.convert(CGPoint(x: 0, y: 0), to: parent).x
                < resetEditor.convert(CGPoint(x: resetEditor.bounds.width, y: 0), to: parent).x)
    }
}
