import AppKit
import Testing
import UniformTypeIdentifiers
@testable import Compositor

@MainActor struct CanvasEntryTests {
    @Test func eyedropperShortcutSelectsTool() throws {
        let session = EditorSession()
        session.createDocument(width: 100, height: 100)
        let canvas = CanvasView(session: session)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "i", charactersIgnoringModifiers: "i", isARepeat: false, keyCode: 34))
        canvas.keyDown(with: event)
        #expect(session.tool == .eyedropper)
        #expect(NavigationTool.eyedropper.symbol == "eyedropper")
    }

    @Test func commandZoomUpdatesOnKeyDownAndRepeat() throws {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 1000, height: 800), backingScale: 1, documentSize: nil)
        session.createDocument(width: 3000, height: 2000)
        session.zoom(to: 1)
        let canvas = CanvasView(session: session)

        func zoomEvent(repeat isRepeat: Bool) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0, context: nil,
                characters: "+", charactersIgnoringModifiers: "=", isARepeat: isRepeat, keyCode: 24))
        }
        canvas.keyDown(with: try zoomEvent(repeat: false))
        #expect(session.viewport.zoom == 1.25)
        canvas.keyDown(with: try zoomEvent(repeat: true))
        #expect(session.viewport.zoom == 1.5)

        let zoomOut = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
            characters: "-", charactersIgnoringModifiers: "-", isARepeat: false, keyCode: 27))
        canvas.keyDown(with: zoomOut)
        #expect(session.viewport.zoom == 1.25)
    }

    @Test func clipboardSuggestsImagePixelsAndIgnoresText() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Some copied text", forType: .string)
        #expect(NewCanvasSheet.clipboardDimensions(pasteboard) == nil)
        let url = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        pasteboard.clearContents()
        pasteboard.setData(try Data(contentsOf: url), forType: .png)
        let size = try #require(NewCanvasSheet.clipboardDimensions(pasteboard))
        #expect(size.width == 64 && size.height == 32)
    }

    @Test func mountingCanvasGivesItKeyboardFocus() async {
        let session = EditorSession()
        session.createDocument(width: 100, height: 100)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let canvas = CanvasView(session: session)
        window.contentView = canvas
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(window.firstResponder === canvas)
        window.makeFirstResponder(nil)
        canvas.consumeFocusRequest(1)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(window.firstResponder === canvas)
        window.contentView = nil
    }
}
