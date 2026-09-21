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

    @Test func clipboardSuggestsImagePixelsFromGenericImageUTI() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let url = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        pasteboard.setData(try Data(contentsOf: url), forType: NSPasteboard.PasteboardType("public.image"))
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
