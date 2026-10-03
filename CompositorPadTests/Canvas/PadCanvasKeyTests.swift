import CoreGraphics
import Testing
import UIKit
@testable import Compositor

/// The canvas's keys on a hardware keyboard, as the Mac's canvas has them.
@MainActor struct PadCanvasKeyTests {
    /// A window controller whose tab in front has a 400 × 300 project with one gray layer over an empty one, fitted to a
    /// view its size.
    private func window() throws -> (controller: EditorWindowController, tab: EditorTab) {
        let controller = EditorWindowController()
        controller.loadViewIfNeeded()
        let tab = try #require(controller.activeTab)
        let session = tab.session
        session.viewport.resize(to: CGSize(width: 400, height: 300), backingScale: 1, documentSize: nil)
        session.createNewProject(width: 400, height: 300)
        let context = try BrushRaster.context(width: 400, height: 300, mask: false)
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Gray"))
        return (controller, tab)
    }

    /// The canvas point over document pixel (`x`, `y`).
    private func point(_ x: CGFloat, _ y: CGFloat, in session: EditorSession) -> CGPoint {
        session.viewport.viewPoint(from: CGPoint(x: x, y: y), documentSize: CGSize(width: 400, height: 300))
    }

    /// The window's command for `input` with exactly `flags`.
    private func command(_ input: String, _ flags: UIKeyModifierFlags = [], in controller: EditorWindowController) throws -> UIKeyCommand {
        try #require(controller.keyCommands?.first { $0.input == input && $0.modifierFlags == flags })
    }

    /// Whether the window takes `command` now.
    private func takes(_ command: UIKeyCommand, in controller: EditorWindowController) -> Bool {
        guard let action = command.action else { return false }
        return controller.canPerformAction(action, withSender: command)
    }

    /// Presses `command`, as the keyboard does once the window takes it.
    private func press(_ command: UIKeyCommand, in controller: EditorWindowController) {
        guard takes(command, in: controller), let action = command.action else { return }
        controller.perform(action, with: command)
    }

    /// Waits up to a few seconds for `condition`.
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<250 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    // MARK: Escape and Return

    /// Escape in the middle of drawing a crop frame takes the frame away, and the finger still down draws no new one,
    /// as on the Mac.
    @Test func escapeEndsACropDrag() throws {
        let (controller, tab) = try window()
        let session = tab.session, input = tab.canvas.input
        session.selectTool(.crop)
        input.began(at: point(50, 40, in: session), keys: .control)
        input.moved(to: point(150, 100, in: session), keys: .control)

        press(try command(UIKeyCommand.inputEscape, in: controller), in: controller)
        input.moved(to: point(250, 190, in: session), keys: .control)
        #expect(session.cropRect == nil)
        #expect(!input.isDragging)
    }

    /// Return in the middle of drawing a crop frame crops to it, and the finger still down draws no new one.
    @Test func returnEndsACropDrag() async throws {
        let (controller, tab) = try window()
        let session = tab.session, input = tab.canvas.input
        session.selectTool(.crop)
        input.began(at: point(0, 0, in: session), keys: .control)
        input.moved(to: point(200, 150, in: session), keys: .control)

        press(try command("\r", in: controller), in: controller)
        try await eventually { session.document?.width == 200 }
        #expect(session.document?.width == 200)
        input.moved(to: point(100, 100, in: session), keys: .control)
        #expect(session.cropRect == nil)
    }

    /// A shape being drawn takes Escape, which takes it away, but not Return, as on the Mac.
    @Test func aShapeTakesEscapeButNotReturn() throws {
        let (controller, tab) = try window()
        let session = tab.session, input = tab.canvas.input
        session.selectTool(.shape)
        input.began(at: point(50, 50, in: session))
        input.moved(to: point(150, 120, in: session))
        try #require(session.shapeDraft != nil)

        #expect(!takes(try command("\r", in: controller), in: controller))
        press(try command(UIKeyCommand.inputEscape, in: controller), in: controller)
        #expect(session.shapeDraft == nil)
    }

    /// Escape takes back a stroke being drawn, as on the Mac, unless the project is busy; Return does nothing to it.
    @Test func escapeTakesBackAStroke() throws {
        let (controller, tab) = try window()
        let session = tab.session
        session.selectTool(.brush)
        let undoSteps = session.history.undoCount
        session.beginBrush(at: CGPoint(x: 50, y: 50))
        session.continueBrush(at: CGPoint(x: 150, y: 50))
        try #require(session.brushStroke != nil)
        let escape = try command(UIKeyCommand.inputEscape, in: controller)
        #expect(!takes(try command("\r", in: controller), in: controller))

        session.isProjectBusy = true
        #expect(!takes(escape, in: controller))
        session.isProjectBusy = false
        press(escape, in: controller)
        #expect(session.brushStroke == nil)
        #expect(session.history.undoCount == undoSteps)
    }

    /// Escape while a box for new text is being dragged out lets it go, and the lift opens no text.
    @Test func escapeLetsATextBoxGo() throws {
        let (controller, tab) = try window()
        let session = tab.session, input = tab.canvas.input
        session.selectTool(.type)
        input.began(at: point(50, 50, in: session))
        input.moved(to: point(200, 120, in: session))
        try #require(input.textBox != nil)

        press(try command(UIKeyCommand.inputEscape, in: controller), in: controller)
        #expect(input.textBox == nil)
        input.ended(at: point(200, 120, in: session))
        #expect(session.textDraft == nil)
    }

    /// Escape with text open but the keyboard on the canvas takes the text away, as on the Mac.
    @Test func escapeTakesAwayTextBeingTyped() throws {
        let (controller, tab) = try window()
        let session = tab.session
        session.selectTool(.type)
        session.beginText(at: CGPoint(x: 50, y: 50), newLayer: true)
        session.textDraft?.style.content = "Hello"

        press(try command(UIKeyCommand.inputEscape, in: controller), in: controller)
        #expect(session.textDraft == nil)
        #expect(session.document?.layers.count == 2)
    }
}
