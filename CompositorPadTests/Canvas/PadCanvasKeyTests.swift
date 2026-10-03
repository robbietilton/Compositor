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

    // MARK: Single keys

    /// A window on the app's screen showing `controller`, once it has appeared, so the keyboard is where a test puts it.
    private func shown(_ controller: EditorWindowController) async throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1194, height: 834)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        try await eventually { controller.isFirstResponder }
        return window
    }

    /// A puts the tool down, as on the Mac.
    @Test func aPutsTheToolDown() throws {
        let (controller, tab) = try window()
        tab.session.selectTool(.brush)
        press(try command("a", in: controller), in: controller)
        #expect(tab.session.tool == .idle)
    }

    /// Shift with a tool's letter chooses the tool, as on the Mac, where the letter is read without Shift; Shift-U still
    /// steps through the shapes, and Shift-X swaps the colors.
    @Test func shiftWithAToolsLetterChoosesIt() throws {
        let (controller, tab) = try window()
        let session = tab.session
        session.selectTool(.move)
        session.brushMode = .erase
        press(try command("b", .shift, in: controller), in: controller)
        #expect(session.tool == .brush && session.brushMode == .paint)
        press(try command("v", .shift, in: controller), in: controller)
        #expect(session.tool == .move)
        session.selectTool(.shape)
        let kind = session.shapeKind
        press(try command("u", .shift, in: controller), in: controller)
        #expect(session.tool == .shape && session.shapeKind != kind)
        let foreground = session.foregroundColor
        press(try command("x", .shift, in: controller), in: controller)
        #expect(session.backgroundColor == foreground)
    }

    /// Tab switches the tool's mode while the canvas has the keyboard, as on the Mac, and goes before the system's
    /// own use of Tab; not while a field or text being typed has it.
    @Test func tabSwitchesTheToolsMode() async throws {
        let (controller, tab) = try window()
        let window = try await shown(controller)
        defer { window.isHidden = true }
        let session = tab.session
        session.selectTool(.marquee)
        session.marqueeKind = .rectangle
        let tabKey = try command("\t", in: controller)
        #expect(tabKey.wantsPriorityOverSystemBehavior)
        press(tabKey, in: controller)
        #expect(session.marqueeKind == .ellipse)

        let field = UITextField(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
        controller.view.addSubview(field)
        try #require(field.becomeFirstResponder())
        #expect(!takes(tabKey, in: controller))
        field.removeFromSuperview()
        try #require(controller.becomeFirstResponder())
        session.selectTool(.type)
        session.beginText(at: CGPoint(x: 50, y: 50), newLayer: true)
        #expect(!takes(tabKey, in: controller))
        session.cancelText()
    }

    /// The digits set the opacity of the brush, or with the Move tool the layer's, as on the Mac: two typed quickly set
    /// an exact value. Not with a tool that has none.
    @Test func theDigitsSetTheOpacity() throws {
        let (controller, tab) = try window()
        let session = tab.session
        session.selectTool(.brush)
        press(try command("4", in: controller), in: controller)
        press(try command("5", in: controller), in: controller)
        #expect(abs(session.brushSettings.opacity - 0.45) < 0.001)

        session.selectTool(.move)
        press(try command("7", in: controller), in: controller)
        #expect(abs((session.activeLayer?.opacity ?? 0) - 0.7) < 0.001)
        session.selectTool(.marquee)
        #expect(!takes(try command("3", in: controller), in: controller))
    }

    /// Shift-[ and Shift-] set a brush's hardness, as on the Mac; not with a tool that has none.
    @Test func shiftBracketsSetTheHardness() throws {
        let (controller, tab) = try window()
        let session = tab.session
        session.selectTool(.brush)
        session.brushSettings.hardness = 0.5
        press(try command("]", .shift, in: controller), in: controller)
        #expect(session.brushSettings.hardness == 0.75)
        press(try command("[", .shift, in: controller), in: controller)
        #expect(session.brushSettings.hardness == 0.5)
        session.selectTool(.move)
        #expect(!takes(try command("]", .shift, in: controller), in: controller))
    }

    /// Shift-= and Shift-- step the layer's blend mode with any tool, as on the Mac.
    @Test func shiftEqualsAndMinusStepTheBlendMode() throws {
        let (controller, tab) = try window()
        let session = tab.session
        session.selectTool(.brush)
        let modes = LayerBlendMode.allCases
        try #require(session.activeLayer?.blendMode == .normal)
        press(try command("=", .shift, in: controller), in: controller)
        #expect(session.activeLayer?.blendMode == modes[1])
        press(try command("-", .shift, in: controller), in: controller)
        press(try command("-", .shift, in: controller), in: controller)
        #expect(session.activeLayer?.blendMode == modes.last)
    }

    /// ⌘+, which is ⌘ and Shift with =, zooms in as ⌘= does, as on the Mac.
    @Test func commandPlusZoomsIn() throws {
        let (controller, tab) = try window()
        let zoom = tab.session.viewport.zoom
        press(try command("=", [.command, .shift], in: controller), in: controller)
        #expect(tab.session.viewport.zoom > zoom)
    }

    /// While a stroke is drawn the canvas's keys do nothing but Escape, as on the Mac.
    @Test func aStrokeTakesNoKeysButEscape() throws {
        let (controller, tab) = try window()
        let session = tab.session
        session.selectTool(.brush)
        session.beginBrush(at: CGPoint(x: 50, y: 50))
        try #require(session.brushStroke != nil)
        for (input, flags) in [("v", UIKeyModifierFlags()), ("5", []), ("]", .shift), ("]", []), ("=", .shift), ("x", [])] {
            #expect(!takes(try command(input, flags, in: controller), in: controller), "\(input)")
        }
        #expect(takes(try command(UIKeyCommand.inputEscape, in: controller), in: controller))
        session.cancelBrush()
    }

    /// With Hue/Saturation open beside the canvas a tool's key still chooses the tool, as on the Mac; with Levels open
    /// it doesn't.
    @Test func toolKeysWorkBesideAnEditorButLevels() async throws {
        let (controller, tab) = try window()
        let window = try await shown(controller)
        defer { window.isHidden = true }
        let session = tab.session
        session.selectTool(.brush)
        session.beginHueSaturation()
        try await eventually { controller.presentedViewController is AdjustmentEditorController }
        try #require(controller.presentedViewController is AdjustmentEditorController)
        press(try command("v", in: controller), in: controller)
        #expect(session.tool == .move)
        session.cancelHueSaturation()
        try await eventually { controller.presentedViewController == nil }

        session.beginLevels()
        try await eventually { controller.presentedViewController is AdjustmentEditorController }
        #expect(!takes(try command("b", in: controller), in: controller))
        session.cancelLevels()
        try await eventually { controller.presentedViewController == nil }
    }

    // MARK: Space

    /// Space held down, a touch moves the canvas whatever the tool, Apple Pencil's too, as a click does on the Mac.
    @Test func spaceHeldATouchMovesTheCanvas() {
        for tool in NavigationTool.allCases {
            #expect(PadCanvasView.touchMovesCanvas(tool: tool, pencil: true, fingerPaints: true, spaceHeld: true), "\(tool)")
        }
        #expect(!PadCanvasView.touchMovesCanvas(tool: .brush, pencil: true, fingerPaints: false, spaceHeld: false))
        #expect(!PadCanvasView.touchMovesCanvas(tool: .move, pencil: false, fingerPaints: false, spaceHeld: false))
    }

    /// Space is held from when it goes down until it comes up, or the keyboard goes elsewhere, or the app does.
    @Test func spaceIsHeldUntilItsLetGo() async throws {
        let (controller, tab) = try window()
        let window = try await shown(controller)
        defer { window.isHidden = true }
        #expect(controller.holdSpace())
        #expect(tab.canvas.spaceHeld)
        controller.releaseSpace()
        #expect(!tab.canvas.spaceHeld)

        // The canvas giving the keyboard to a field, which takes Space as a space.
        try #require(tab.canvas.becomeFirstResponder())
        #expect(controller.holdSpace())
        let field = UITextField()
        controller.view.addSubview(field)
        defer { field.removeFromSuperview() }
        try #require(field.becomeFirstResponder())
        #expect(!tab.canvas.spaceHeld)
        #expect(!controller.holdSpace())
        #expect(!tab.canvas.spaceHeld)

        // The app going to the background, or the switcher, which takes the key's coming up with it.
        let scenes = SceneDelegate()
        let other = EditorWindowController()
        scenes.window = UIWindow(windowScene: try #require(window.windowScene))
        scenes.window?.rootViewController = UINavigationController(rootViewController: other)
        other.loadViewIfNeeded()
        let otherTab = try #require(other.activeTab)
        otherTab.canvas.spaceHeld = true
        scenes.sceneWillResignActive(try #require(window.windowScene))
        #expect(!otherTab.canvas.spaceHeld)
    }

    /// The canvas taking the keyboard from the window, as a touch does, keeps Space held, so the touch moves the canvas.
    @Test func theCanvasTakingTheKeyboardKeepsSpaceHeld() async throws {
        let (controller, tab) = try window()
        let window = try await shown(controller)
        defer { window.isHidden = true }
        try #require(controller.isFirstResponder)
        #expect(controller.holdSpace())
        try #require(tab.canvas.becomeFirstResponder())
        try await Task.sleep(for: .milliseconds(100))
        #expect(tab.canvas.spaceHeld)
    }

    /// A stroke being drawn takes no Space, as it takes no other key on the Mac.
    @Test func aStrokeTakesNoSpace() async throws {
        let (controller, tab) = try window()
        let window = try await shown(controller)
        defer { window.isHidden = true }
        tab.session.selectTool(.brush)
        tab.session.beginBrush(at: CGPoint(x: 100, y: 100))
        #expect(!controller.holdSpace())
        #expect(!tab.canvas.spaceHeld)
        tab.session.cancelBrush()
    }

    /// Beside Levels, which holds the other keys, Space still moves the canvas, as on the Mac.
    @Test func spaceMovesTheCanvasBesideLevels() async throws {
        let (controller, tab) = try window()
        let window = try await shown(controller)
        defer { window.isHidden = true }
        tab.session.beginLevels()
        try await eventually { controller.presentedViewController is AdjustmentEditorController }
        try #require(controller.presentedViewController is AdjustmentEditorController)
        #expect(controller.holdSpace())
        #expect(tab.canvas.spaceHeld)
        controller.releaseSpace()
        tab.session.cancelLevels()
        try await eventually { controller.presentedViewController == nil }
    }

    /// Space held, the brush's circle goes from under the pointer, which is a hand on the Mac.
    @Test func spaceHeldTheBrushShowsNoCircle() throws {
        let (_, tab) = try window()
        tab.session.selectTool(.brush)
        tab.canvas.hover(at: CGPoint(x: 200, y: 150))
        #expect(tab.canvas.overlayView.brushCursor != nil)
        tab.canvas.spaceHeld = true
        #expect(tab.canvas.overlayView.brushCursor == nil)
        tab.canvas.spaceHeld = false
        #expect(tab.canvas.overlayView.brushCursor != nil)
    }

    // MARK: Names

    /// The canvas's keys go by the names the Mac's Keyboard Shortcuts list gives them, and are made once.
    @Test func theKeysHaveTheMacsNames() throws {
        let (controller, _) = try window()
        let names: [(String, UIKeyModifierFlags, String)] = [
            ("v", [], "Move / Transform tool"), ("b", [], "Brush tool"), ("e", [], "Eraser"), ("m", [], "Marquee / cycle shape"),
            ("x", [], "Swap foreground/background"), ("d", [], "Reset colors"), ("[", [], "Decrease brush size"),
            ("]", [], "Increase brush size"), ("u", .shift, "Cycle shape kind"), (UIKeyCommand.inputEscape, [], "Cancel current canvas operation"),
            ("\r", [], "Apply current canvas operation"), (UIKeyCommand.inputLeftArrow, .shift, "Nudge Left 10 px"),
            (UIKeyCommand.inputUpArrow, .command, "Move selected pixels Up 1 px"),
        ]
        for (input, flags, name) in names {
            #expect(try command(input, flags, in: controller).title == name, "\(input)")
        }
        let first = try #require(controller.keyCommands), second = try #require(controller.keyCommands)
        #expect(first.count == second.count && zip(first, second).allSatisfy { $0 === $1 })
    }
}

