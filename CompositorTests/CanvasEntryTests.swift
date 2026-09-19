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

    @Test func createDocumentWithImageSetsSizeAndPlacesLayer() throws {
        let session = EditorSession()
        let context = try #require(CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8,
            bytesPerRow: 120 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        let image = try #require(context.makeImage())
        session.createDocument(with: image, name: "Layer 1")
        let doc = try #require(session.document)
        #expect(doc.width == 120 && doc.height == 80)
        #expect(doc.layers.count == 1)
        #expect(doc.layers.first?.name == "Layer 1")
        #expect(doc.layers.first?.transform.origin == .zero)
        #expect(session.activeLayerID == doc.layers.first?.id)
        #expect(!session.showsNewDocument)
    }

    @Test func clipboardImageReadsDirectDataAndFileUrls() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let url = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }

        // Test direct data
        pasteboard.setData(try Data(contentsOf: url), forType: .png)
        let direct = try #require(EditorSession.clipboardImage(pasteboard))
        #expect(direct.width == 64 && direct.height == 32)

        // Test file URL
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        let fromURL = try #require(EditorSession.clipboardImage(pasteboard))
        #expect(fromURL.width == 64 && fromURL.height == 32)
    }
}
