import AppKit
import Testing
@testable import Compositor

@MainActor
@Suite(.serialized)
struct RenderComparisonTests {
    private func session() throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 80, height: 60)
        let context = try BrushRaster.context(width: 80, height: 60, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Comparison"))
        session.beginFilter(.renderFinish)
        return session
    }

    private func key(_ text: String, code: UInt16, repeated: Bool = false) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: repeated, keyCode: code))
    }

    @Test func paneZoomKeepsTheDisplayedPixelUnderThePointer() {
        // Odd pane widths produce fractional midpoints; drawing rounds translations to display pixels.
        for scale: CGFloat in [1, 2] {
            let size = CGSize(width: 1201, height: 799)
            let bounds = CGRect(origin: .zero, size: size)
            var viewport = CanvasViewport()
            let document = CGSize(width: 4096, height: 2731)
            viewport.resize(to: size, backingScale: scale, documentSize: document)
            for pane in FinishComparisonGeometry.panes(in: bounds) {
                let translation = FinishComparisonGeometry.paneOffset(pane, in: bounds, backingScale: scale)
                #expect(translation * scale == (translation * scale).rounded())
                let pointer = CGPoint(x: pane.midX + 47, y: 239)
                let unshifted = CGPoint(x: pointer.x - translation, y: pointer.y)
                let pixel = viewport.documentPoint(from: unshifted, documentSize: document)
                let anchor = FinishComparisonGeometry.centeredAnchor(pointer, view: size, backingScale: scale)
                viewport.setZoom(1, anchoredAt: anchor, documentSize: document)
                let displayed = viewport.viewPoint(from: pixel, documentSize: document)
                #expect(abs(displayed.x + translation - pointer.x) < 0.0001)
                #expect(abs(displayed.y - pointer.y) < 0.0001)
            }
        }
    }

    @Test func finishingIgnoresUnderlyingToolShortcutsAndKeyRepeat() throws {
        let session = try session()
        let view = CanvasView(session: session)
        let tool = session.tool, document = session.document
        view.keyDown(with: try key("b", code: 11))
        view.keyDown(with: try key("c", code: 8))
        view.keyDown(with: try key("5", code: 23))
        view.keyDown(with: try key("\u{7f}", code: 51))
        #expect(session.tool == tool)
        #expect(session.document == document)
        #expect(session.cropRect == nil)
        view.keyDown(with: try key("\\", code: 42))
        #expect(session.filterEdit?.showingOriginal == true)
        view.keyDown(with: try key("\\", code: 42, repeated: true))
        #expect(session.filterEdit?.showingOriginal == true)
        view.keyDown(with: try key("\\", code: 42))
        #expect(session.filterEdit?.showingOriginal == false)
        view.keyDown(with: try key("\u{1b}", code: 53))
        #expect(session.filterEdit == nil)
        #expect(session.document == document)
    }

    @Test func closingOrDisablingPreviewCancelsPendingDetailWork() throws {
        let session = try session()
        let edit = try #require(session.filterEdit)
        func pendingTask() -> Task<Void, Never> { Task { try? await Task.sleep(for: .seconds(30)) } }
        let offTask = pendingTask()
        edit.finishDetailTask = offTask
        edit.finishDetailPending = FinishDetail.Request(valid: CGRect(x: 0, y: 0, width: 40, height: 30), settings: edit.settings)
        session.updateFilter(edit.settings, preview: false)
        #expect(offTask.isCancelled)
        #expect(edit.finishDetailPending == nil)
        let cancelTask = pendingTask()
        edit.finishDetailTask = cancelTask
        session.cancelFilter()
        #expect(cancelTask.isCancelled)
        #expect(session.filterEdit == nil)
    }
}
