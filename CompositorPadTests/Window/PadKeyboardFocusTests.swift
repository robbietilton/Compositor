import CoreGraphics
import Testing
import UIKit
@testable import Compositor

/// Where the keyboard goes once a field is done with it: back to the canvas, as on the Mac, so a tool's key and the
/// menu bar's shortcuts work straight away rather than waiting for the canvas to be touched.
@MainActor struct PadKeyboardFocusTests {
    /// A window on the app's screen showing `controller`, whose views can take the keyboard: once it has appeared,
    /// which gives the controller the keyboard after the first frame, so nothing a test gives it is taken back.
    private func window(showing controller: EditorWindowController) async throws -> UIWindow {
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

    /// The views of `type` in `view`, depth first.
    private func views<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        view.subviews.flatMap { subview -> [T] in ((subview as? T).map { [$0] } ?? []) + views(type, in: subview) }
    }

    /// Waits up to a few seconds for `condition`, as the window's own tasks finish.
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<250 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// The window's tab in front, with a 400 × 300 project of one gray layer and the Move tool, laid out, once the
    /// canvas has taken the keyboard the new project gives it.
    private func project(in controller: EditorWindowController) async throws -> EditorTab {
        let tab = try #require(controller.activeTab)
        tab.session.createNewProject(width: 400, height: 300)
        let context = try BrushRaster.context(width: 400, height: 300, mask: false)
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let image = try #require(context.makeImage())
        tab.session.insert(ImportedImage(image: image, thumbnail: image, name: "Gray"))
        tab.session.selectTool(.move)
        controller.updatePropertiesIfNeeded()
        controller.view.layoutIfNeeded()
        for bar in views(ToolOptionsBar.self, in: controller.view) { bar.updatePropertiesIfNeeded() }
        controller.view.layoutIfNeeded()
        try await eventually { tab.canvas.isFirstResponder }
        try #require(tab.canvas.isFirstResponder)
        return tab
    }

    /// `field` given the keyboard, and keeping it once whatever was waiting has run.
    private func focus(_ field: UITextField) async throws {
        try #require(field.becomeFirstResponder())
        try await Task.sleep(for: .milliseconds(50))
        try #require(field.isFirstResponder)
    }

    /// The options bar's field captioned `caption`.
    private func barField(_ caption: String, in controller: EditorWindowController) throws -> NumberField {
        let bar = try #require(views(ToolOptionsBar.self, in: controller.view).first)
        return try #require(views(NumberField.self, in: bar).first { $0.field.accessibilityLabel == caption })
    }

    /// Return in a field of the tool's bar hands the keyboard back to the canvas, as the Mac's tool bars do.
    @Test func returnInTheToolBarGivesTheCanvasTheKeyboard() async throws {
        let controller = EditorWindowController()
        let window = try await window(showing: controller)
        defer { window.isHidden = true }
        let tab = try await project(in: controller)
        let x = try barField("X", in: controller)
        try await focus(x.field)

        _ = x.field.delegate?.textFieldShouldReturn?(x.field)
        try await eventually { tab.canvas.isFirstResponder }
        #expect(!x.field.isFirstResponder)
        #expect(tab.canvas.isFirstResponder)
    }

    /// So does Escape, which ends the typing.
    @Test func escapeInTheToolBarGivesTheCanvasTheKeyboard() async throws {
        let controller = EditorWindowController()
        let window = try await window(showing: controller)
        defer { window.isHidden = true }
        let tab = try await project(in: controller)
        let x = try barField("X", in: controller)
        try await focus(x.field)

        let escape = try #require(x.keyCommands?.first { $0.input == UIKeyCommand.inputEscape && $0.modifierFlags.isEmpty })
        x.perform(escape.action, with: escape)
        try await eventually { tab.canvas.isFirstResponder }
        #expect(!x.field.isFirstResponder)
        #expect(tab.canvas.isFirstResponder)
    }

    /// A dialog's fields leave Escape to the dialog, whose Cancel it is; a tool bar's take it to end the typing.
    @Test func aDialogsFieldsLeaveEscapeToTheDialog() async throws {
        let controller = EditorWindowController()
        let window = try await window(showing: controller)
        defer { window.isHidden = true }
        let field = NumberField(caption: "Width", width: 64, range: 1...100)
        controller.view.addSubview(field)
        defer { field.removeFromSuperview() }
        try await focus(field.field)
        #expect(field.keyCommands?.contains { $0.input == UIKeyCommand.inputEscape } != true)
        field.onCommit = {}
        #expect(field.keyCommands?.contains { $0.input == UIKeyCommand.inputEscape } == true)
    }

    /// A new canvas made from the New Canvas card has the keyboard once it's made, as a new document does on the Mac.
    @Test func aNewCanvasHasTheKeyboard() async throws {
        let controller = EditorWindowController()
        let window = try await window(showing: controller)
        defer { window.isHidden = true }
        let tab = try #require(controller.activeTab)
        let card = try #require(views(NewCanvasView.self, in: controller.view).first)
        let fields = views(UITextField.self, in: card)
        try #require(fields.count == 2)
        fields[0].text = "200"
        fields[1].text = "100"
        fields[1].sendActions(for: .editingChanged)
        try #require(fields[1].becomeFirstResponder())

        _ = fields[1].delegate?.textFieldShouldReturn?(fields[1])
        try await eventually { tab.session.document != nil && tab.canvas.isFirstResponder }
        #expect(tab.session.document?.width == 200)
        #expect(tab.canvas.isFirstResponder)
        try await eventually { tab.document != nil }
        if let url = tab.document?.fileURL {
            await tab.close()
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The editor asking for the keyboard gives it to the canvas, or to the text being typed when there is some, as
    /// the Mac's canvas does.
    @Test func askingForTheKeyboardGivesItToTheCanvasOrTheText() async throws {
        let controller = EditorWindowController()
        let window = try await window(showing: controller)
        defer { window.isHidden = true }
        let tab = try await project(in: controller)
        let x = try barField("X", in: controller)
        try await focus(x.field)
        tab.session.canvasFocusRequest += 1
        controller.updatePropertiesIfNeeded()
        try await eventually { tab.canvas.isFirstResponder }
        #expect(tab.canvas.isFirstResponder)

        tab.session.selectTool(.type)
        tab.session.beginText(at: CGPoint(x: 50, y: 50), newLayer: true)
        controller.updatePropertiesIfNeeded()
        try await eventually { tab.canvas.textEditor?.textView.isFirstResponder == true }
        let text = try #require(tab.canvas.textEditor?.textView)
        // The Type tool's bar has no X; the canvas takes the keyboard from the text instead.
        try #require(tab.canvas.becomeFirstResponder())
        try await Task.sleep(for: .milliseconds(50))
        try #require(!text.isFirstResponder)
        tab.session.canvasFocusRequest += 1
        controller.updatePropertiesIfNeeded()
        try await eventually { text.isFirstResponder }
        #expect(text.isFirstResponder)
        tab.session.cancelText()
    }

    /// A field left as soon as it's entered stays left: selecting its value, which waits a moment so a tap doesn't
    /// undo it, would otherwise take the keyboard back.
    @Test func aFieldLeftAtOnceStaysLeft() async throws {
        let controller = EditorWindowController()
        let window = try await window(showing: controller)
        defer { window.isHidden = true }
        _ = try await project(in: controller)
        let x = try barField("X", in: controller)
        try #require(x.field.becomeFirstResponder())
        try #require(x.field.resignFirstResponder())

        try await Task.sleep(for: .milliseconds(300))
        #expect(!x.field.isFirstResponder)
    }
}
