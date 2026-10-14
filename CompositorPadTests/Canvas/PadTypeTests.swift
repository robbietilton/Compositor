import CoreGraphics
import Metal
import Testing
import UIKit
@testable import Compositor

/// The Type tool on iPad: text started, opened and typed through the canvas's touch input and the on-canvas editor, as
/// the Mac's mouse and InlineTextEditor have them.
@MainActor struct PadTypeTests {
    /// A 400 × 300 canvas fitted to a view its size, with one gray layer covering it, and the Type tool in hand.
    private func session(_ tool: NavigationTool = .type) throws -> EditorSession {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 400, height: 300), backingScale: 1, documentSize: nil)
        session.createDocument(width: 400, height: 300)
        let context = try BrushRaster.context(width: 400, height: 300, mask: false)
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Gray"))
        session.selectTool(tool)
        return session
    }

    /// The canvas point over document pixel (`x`, `y`).
    private func point(_ x: CGFloat, _ y: CGFloat, in session: EditorSession) -> CGPoint {
        session.viewport.viewPoint(from: CGPoint(x: x, y: y), documentSize: CGSize(width: 400, height: 300))
    }

    /// Text layer "Hello" at (100, 100), made as typing and Done make it.
    private func addText(to session: EditorSession) throws -> UUID {
        session.selectTool(.type)
        session.beginText(at: CGPoint(x: 100, y: 100), newLayer: true)
        session.textDraft?.style.content = "Hello"
        #expect(session.finishText())
        return try #require(session.activeLayer?.liveText != nil ? session.activeLayerID : nil)
    }

    /// A tap starts a line of text where it lands; a drag draws a box for a paragraph.
    @Test func aTapStartsALineAndADragABox() throws {
        let session = try session()
        let input = PadCanvasInput(session: session)
        let tap = point(50, 60, in: session)
        input.began(at: tap)
        input.ended(at: tap)
        let line = try #require(session.textDraft)
        #expect(line.layerID == nil && line.style.boxSize == nil)
        // The tap is where the first line starts, on its baseline, as in Photoshop.
        #expect(abs(line.origin.x - (50 - LayerTextStyle.padding)) <= 1 && line.origin.y < 60)

        // A touch elsewhere keeps the text being typed first; this one's empty, so it goes.
        input.began(at: point(100, 100, in: session))
        input.moved(to: point(200, 160, in: session))
        input.moved(to: point(300, 200, in: session))
        input.ended(at: point(300, 200, in: session))
        let box = try #require(session.textDraft)
        #expect(box.id != line.id)
        let size = try #require(box.style.boxSize)
        #expect(abs(size.width - 200) <= 1 && abs(size.height - 100) <= 1)
        #expect(input.textBox == nil)
    }

    /// A touch on text with the Type tool opens it, and so does a double tap with the Move tool, as a double click does
    /// on the Mac; the canvas is told where, to put the caret there.
    @Test func aTouchOnTextOpensIt() throws {
        let session = try session()
        let id = try addText(to: session)
        let input = PadCanvasInput(session: session)
        var opened: CGPoint?
        input.textOpened = { opened = $0 }
        let on = point(110, 110, in: session)
        #expect(!input.began(at: on))
        #expect(session.textDraft?.layerID == id && opened == on)

        session.cancelText()
        session.selectTool(.move)
        opened = nil
        #expect(!input.began(at: on, tapCount: 2))
        #expect(session.textDraft?.layerID == id && opened == on)
    }

    /// What's typed into the editor becomes the text, and colored letters keep their color as text goes in before them.
    @Test func typingChangesTheText() throws {
        let session = try session()
        session.beginText(at: CGPoint(x: 20, y: 20), newLayer: true)
        session.textDraft?.style.content = "World"
        session.textDraft?.style.setColor(PaletteColor(red: 1, green: 0, blue: 0), in: NSRange(location: 0, length: 5))
        let editor = PadTextEditor(session: session)
        editor.synchronize(try #require(session.textDraft))
        #expect(editor.textView.text == "World")

        // As UIKit types: it asks, makes the change, and says so.
        let range = NSRange(location: 0, length: 0)
        #expect(editor.textView(editor.textView, shouldChangeTextIn: range, replacementText: "Hello "))
        editor.textView.textStorage.replaceCharacters(in: range, with: "Hello ")
        editor.textViewDidChange(editor.textView)
        let draft = try #require(session.textDraft)
        #expect(draft.style.content == "Hello World")
        #expect(draft.style.color(at: 6) == PaletteColor(red: 1, green: 0, blue: 0))
        // The text keeps its own undo, apart from the project's.
        #expect(editor.textView.undoManager != nil && !(editor.textView.undoManager is SessionUndoManager))
    }

    /// The editor stands where the text goes and the canvas draws the text there, in its color, as it's typed.
    @Test func theCanvasDrawsTheTextBeingTyped() throws {
        let session = try session()
        session.zoom(to: 1)
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        session.textDefaults.fontSize = 120
        session.beginText(at: CGPoint(x: 20, y: 200), newLayer: true)
        session.textDraft?.style.content = "███"
        let editor = PadTextEditor(session: session)
        editor.synchronize(try #require(session.textDraft))
        let shown = try #require(editor.shownTransform)
        #expect(shown.origin == session.textDraft?.origin)

        let compositor = PadCanvasCompositor(session: session)
        compositor.textShownTransform = { editor.shownTransform }
        let renderer = try #require(GPUCanvasRenderer.shared)
        let size = CGSize(width: 400, height: 300)
        let document = try #require(session.document)
        let frame = try #require(compositor.frame(document, renderer: renderer, size: size))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 400, height: 300, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        let texture = try #require(renderer.device.makeTexture(descriptor: descriptor))
        let buffer = try #require(renderer.queue.makeCommandBuffer())
        renderer.context.render(frame, to: texture, commandBuffer: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: renderer.space)
        buffer.commit()
        buffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: 400 * 300 * 4)
        texture.getBytes(&bytes, bytesPerRow: 1600, from: MTLRegionMake2D(0, 0, 400, 300), mipmapLevel: 0)
        // Somewhere in the text's box, its red letters over the gray layer.
        let box = CGRect(origin: shown.origin, size: shown.size).intersection(CGRect(x: 0, y: 0, width: 400, height: 300))
        var red = 0
        for y in Int(box.minY)..<min(300, Int(box.maxY)) {
            for x in Int(box.minX)..<min(400, Int(box.maxX)) {
                let i = (y * 400 + x) * 4
                if bytes[i] > 220 && bytes[i + 1] < 40 && bytes[i + 2] < 40 { red += 1 }
            }
        }
        #expect(red > 500, "\(red) red pixels")
    }

    /// Option with the arrows sets the spacing while typing, as on the Mac: left and right the tracking, up and down the
    /// leading, counting from what Auto works out to, each a step of ten with Shift. They go before the text view's own
    /// Option-arrows, which move by word.
    @Test func optionArrowsSetTheSpacing() throws {
        let session = try session()
        session.beginText(at: CGPoint(x: 20, y: 20), newLayer: true)
        session.textDraft?.style.content = "Spacing"
        let editor = PadTextEditor(session: session)
        editor.synchronize(try #require(session.textDraft))
        func command(_ input: String, _ flags: UIKeyModifierFlags) throws -> UIKeyCommand {
            try #require(editor.textView.keyCommands?.first { $0.input == input && $0.modifierFlags == flags })
        }
        func press(_ input: String, _ flags: UIKeyModifierFlags) throws {
            let key = try command(input, flags)
            #expect(key.wantsPriorityOverSystemBehavior)
            #expect(key.title.hasSuffix(flags.contains(.shift) ? "by 10" : "ing"))
            editor.textView.perform(key.action, with: key)
        }
        // Named as the Mac's Keyboard Shortcuts names them.
        #expect(try command(UIKeyCommand.inputRightArrow, .alternate).title == "Increase tracking")
        #expect(try command(UIKeyCommand.inputUpArrow, [.alternate, .shift]).title == "Decrease leading by 10")
        #expect(try command("\r", .command).title == "Finish editing text")
        let style = try #require(session.textDraft?.style)
        try press(UIKeyCommand.inputRightArrow, .alternate)
        #expect(session.textDraft?.style.tracking == style.tracking + 1)
        try press(UIKeyCommand.inputLeftArrow, [.alternate, .shift])
        #expect(session.textDraft?.style.tracking == style.tracking - 9)
        try press(UIKeyCommand.inputUpArrow, [.alternate, .shift])
        #expect(session.textDraft?.style.leading == style.lineHeight - 10)
        let leading = try #require(session.textDraft?.style.lineHeight)
        try press(UIKeyCommand.inputDownArrow, .alternate)
        #expect(session.textDraft?.style.leading == leading + 1)
        #expect(session.textDraft?.style.content == "Spacing")
    }
}
