import AppKit
import Testing
@testable import Compositor

/// Regression coverage for Photoshop-style commands when the canvas owns keyboard focus.
@MainActor @Suite(.serialized)
struct EditorCommandRouterTests {
    private func key(_ characters: String, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                      timestamp: 0, windowNumber: 0, context: nil,
                                      characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: 0))
    }

    private func select(_ session: EditorSession) {
        session.applySelection(CGPath(rect: CGRect(x: 4, y: 4, width: 8, height: 8), transform: nil),
                               mode: .replace, name: "Magic")
    }

    @Test func commandDeselectsAndUndoRedoRoundTripsTheSelection() throws {
        let session = EditorSession()
        session.createDocument(width: 32, height: 32, emptyLayer: true)
        select(session)
        let router = EditorCommandRouter(session: session)

        #expect(router.handle(try key("d", modifiers: .command)))
        #expect(session.selection == nil)
        #expect(session.history.undoName == "Deselect")

        #expect(router.handle(try key("z", modifiers: .command)))
        #expect(session.selection != nil)
        #expect(router.handle(try key("z", modifiers: [.command, .shift])))
        #expect(session.selection == nil)
    }

    @Test func commandCopyAndPasteUseTheCanvasClipboard() async throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }

        let session = EditorSession()
        session.createDocument(width: 32, height: 32, emptyLayer: true)
        await session.fillSelection(with: .foreground)
        select(session)
        let router = EditorCommandRouter(session: session)
        let layerCount = try #require(session.document?.layers.count)

        #expect(router.handle(try key("c", modifiers: .command)))
        #expect(session.canPaste)
        #expect(router.handle(try key("v", modifiers: .command)))
        #expect(session.document?.layers.count == layerCount + 1)
        #expect(session.history.undoName == "Paste")
    }

    @Test func commandPasteFromBrowserImageCanCreateCanvasEvenWithDimensionFieldFocus() throws {
        let context = try BrushRaster.context(width: 16, height: 8, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.8, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 8))
        let image = try #require(context.makeImage())
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: NSPasteboard.PasteboardType("public.image"))
        defer { pasteboard.clearContents() }

        let session = EditorSession()
        let router = EditorCommandRouter(session: session)
        #expect(router.handle(try key("v", modifiers: .command), firstResponder: NSTextField()))
        #expect(session.document?.size == CGSize(width: 16, height: 8))
        #expect(session.document?.layers.count == 1)
    }
}
