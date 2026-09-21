import AppKit
import Testing
@testable import Compositor

@MainActor
struct BlendShortcutTests {
    @Test func shiftPlusAndMinusStepTheActiveLayersBlendModeWhereverFocusIsExceptTextFields() throws {
        let session = EditorSession()
        session.createDocument(width: 40, height: 20)
        session.addBlankLayer()
        let canvas = CanvasView(session: session)
        canvas.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 100, height: 22))
        let content = NSView(frame: canvas.frame)
        for view in [canvas, field] { content.addSubview(view) }
        let window = NSWindow(contentRect: content.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = content
        // Through NSApplication, as a real key press arrives.
        func press(forward: Bool) throws {
            let key = forward ? "+" : "_"
            NSApp.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: forward ? 24 : 27)))
        }
        func mode() -> LayerBlendMode? { session.activeLayer?.blendMode }
        session.selectTool(.brush)
        #expect(window.makeFirstResponder(canvas))
        try press(forward: true)
        #expect(mode() == .multiply)
        session.selectTool(.lasso)
        #expect(window.makeFirstResponder(nil))
        try press(forward: false)
        try press(forward: false)
        #expect(mode() == .colorBurn) // back past Normal, wrapping to the last quick-cycle mode
        session.undo()
        #expect(mode() == .normal)
        // Typing in a text field keeps its characters.
        #expect(window.makeFirstResponder(field))
        try press(forward: true)
        #expect(mode() == .normal)
    }
}
