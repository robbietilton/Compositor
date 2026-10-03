import CoreGraphics
import Testing
import UIKit
@testable import Compositor

/// A layer's effects on iPad, added from the Layers panel and edited in a panel, as the Mac's effect panel has them.
@MainActor struct PadLayerEffectsTests {
    /// The views of `type` in `view`, depth first.
    private func views<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        view.subviews.flatMap { subview -> [T] in ((subview as? T).map { [$0] } ?? []) + views(type, in: subview) }
    }

    /// A window on the app's screen with a 200 × 100 project of one gray layer, once it has appeared.
    private func shownWindow() async throws -> (window: UIWindow, controller: EditorWindowController, session: EditorSession) {
        let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1194, height: 834)
        let controller = EditorWindowController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let session = try #require(controller.activeTab?.session)
        session.createNewProject(width: 200, height: 100)
        let context = try BrushRaster.context(width: 200, height: 100, mask: false)
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Gray"))
        return (window, controller, session)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<250 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// The Layers panel's effects button.
    private func effectsButton(in controller: EditorWindowController) throws -> UIButton {
        for view in views(LayersPanelView.self, in: controller.view) { view.updatePropertiesIfNeeded() }
        return try #require(views(UIButton.self, in: controller.view).first { $0.accessibilityLabel == "Layer effects" })
    }

    /// Chooses `kind` from the effects button's menu, as a finger does.
    private func add(_ kind: LayerEffectKind, in controller: EditorWindowController) throws {
        let button = try effectsButton(in: controller)
        try #require(button.isEnabled)
        let action = try #require(button.menu?.children.compactMap { $0 as? UIAction }.first { $0.title == kind.rawValue + "…" })
        action.performWithSender(nil, target: nil)
    }

    /// The effect editor the window shows, once it shows the one for `kind`.
    private func effectEditor(for kind: LayerEffectKind, over controller: EditorWindowController) async throws -> EffectEditorController {
        try await eventually { (controller.presentedViewController as? EffectEditorController)?.selection.kind == kind }
        let editor = try #require(controller.presentedViewController as? EffectEditorController)
        try #require(editor.selection.kind == kind)
        editor.view.layoutIfNeeded()
        return editor
    }

    /// Presses the window's key for `input`, as the keyboard does once the window takes it.
    private func press(_ input: String, in controller: EditorWindowController) throws {
        let command = try #require(controller.keyCommands?.first { $0.input == input && $0.modifierFlags.isEmpty })
        let action = try #require(command.action)
        try #require(controller.canPerformAction(action, withSender: command))
        controller.perform(action, with: command)
    }

    /// A row's caption, the first of its labels.
    private func caption(of row: SliderField) -> String? { views(UILabel.self, in: row).first?.text }

    /// The editor's rows' captions, in order.
    private func captions(of editor: UIViewController) -> [String?] { views(SliderField.self, in: editor.view).map(caption) }

    /// The editor's row captioned `caption`.
    private func row(_ caption: String, in editor: UIViewController) throws -> SliderField {
        try #require(views(SliderField.self, in: editor.view).first { self.caption(of: $0) == caption }, "\(caption)")
    }

    /// The editor's button titled `title`.
    private func button(_ title: String, in editor: UIViewController) throws -> UIButton {
        try #require(views(UIButton.self, in: editor.view).first { $0.configuration?.title == title }, "\(title)")
    }

    private func closes(_ controller: EditorWindowController) async throws {
        try await eventually { controller.presentedViewController == nil }
        #expect(controller.presentedViewController == nil)
    }

    // MARK: Adding

    /// The effects button lists the Mac's six effects, and works on a layer with pixels only, as on the Mac.
    @Test func theEffectsMenuListsTheMacsSix() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        let button = try effectsButton(in: controller)
        #expect(button.menu?.children.map(\.title)
            == ["Stroke…", "Drop Shadow…", "Color Overlay…", "Inner Shadow…", "Outer Glow…", "Inner Glow…"])
        #expect(button.showsMenuAsPrimaryAction)
        #expect(button.isEnabled)
        session.addBlankLayer()
        #expect(try effectsButton(in: controller).isEnabled == false)
    }

    /// Adding an effect puts it on the layer and opens its panel: the effect's name, its color, its rows, and Cancel and
    /// OK at the foot, with no Preview or Reset, as the Mac's effect panel.
    @Test func addingOpensItsPanel() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        let id = try #require(session.activeLayerID)
        try add(.shadow, in: controller)
        #expect(session.activeLayer?.effects?.shadow != nil)
        #expect(session.effectsEditing == LayerEffectSelection(layerID: id, kind: .shadow))
        #expect(session.history.undoName == "Add Drop Shadow")
        let editor = try await effectEditor(for: .shadow, over: controller)
        #expect(views(UILabel.self, in: editor.view).contains { $0.text == "Drop Shadow" })
        #expect(captions(of: editor) == ["Opacity", "Angle", "Distance", "Blur"])
        let swatch = try #require(views(SwatchButton.self, in: editor.view).first)
        #expect(swatch.accessibilityLabel == "Drop Shadow color" && swatch.color == .black)
        #expect(!views(UIButton.self, in: editor.view).contains { ["Preview", "Reset"].contains($0.configuration?.title) })
        let cancel = try button("Cancel", in: editor), ok = try button("OK", in: editor)
        #expect(cancel.convert(cancel.bounds, to: editor.view).maxX < ok.convert(ok.bounds, to: editor.view).minX)
        #expect(cancel.convert(cancel.bounds, to: editor.view).minX > editor.view.bounds.midX)
        try press(UIKeyCommand.inputEscape, in: controller)
        try await closes(controller)
    }

    /// Each effect's rows are the Mac's, and a field reaches past its slider as the Mac's do: a Drop Shadow's Distance
    /// slider goes to 100 and its field to 5000, an Inner Shadow's slider to 50. Opacity shows as a percentage.
    @Test func fieldsReachPastTheirSliders() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        try add(.shadow, in: controller)
        let editor = try await effectEditor(for: .shadow, over: controller)
        let distance = try row("Distance", in: editor)
        let field = try #require(views(NumberField.self, in: distance).first)
        field.field.text = "300"
        field.textFieldDidEndEditing(field.field)
        #expect(session.activeLayer?.effects?.shadow?.distance == 300)
        editor.updatePropertiesIfNeeded()
        let slider = try #require(views(UISlider.self, in: distance).first)
        #expect(slider.maximumValue == 100 && slider.value == 100)
        #expect(views(UITextField.self, in: try row("Opacity", in: editor)).first?.text == "50")
        try press("\r", in: controller)
        try await closes(controller)

        try add(.innerShadow, in: controller)
        let inner = try await effectEditor(for: .innerShadow, over: controller)
        #expect(views(UISlider.self, in: try row("Distance", in: inner)).first?.maximumValue == 50)
        for (kind, captions) in [(LayerEffectKind.stroke, ["Size", "Opacity"]), (.colorOverlay, ["Opacity"]),
                                 (.outerGlow, ["Size", "Opacity"]), (.innerGlow, ["Size", "Opacity"])] {
            #expect(EffectEditorController.rows[kind]?.map(\.caption) == captions, "\(kind)")
        }
        try press("\r", in: controller)
        try await closes(controller)
    }

    /// A Stroke's panel has its position beside its name, and its color on a row of its own, as the Mac's.
    @Test func aStrokeHasItsPosition() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        session.backgroundColor = PaletteColor(red: 0, green: 0, blue: 1)
        try add(.stroke, in: controller)
        let editor = try await effectEditor(for: .stroke, over: controller)
        let position = try #require(views(UISegmentedControl.self, in: editor.view).first)
        #expect((0..<position.numberOfSegments).map { position.titleForSegment(at: $0) } == ["Outside", "Inside"])
        #expect(position.selectedSegmentIndex == 0)
        #expect(views(UILabel.self, in: editor.view).contains { $0.text == "Color" })
        let swatch = try #require(views(SwatchButton.self, in: editor.view).first)
        #expect(swatch.accessibilityLabel == "Stroke color" && swatch.color == PaletteColor(red: 0, green: 0, blue: 1))
        position.selectedSegmentIndex = 1
        position.sendActions(for: .valueChanged)
        #expect(session.activeLayer?.effects?.stroke?.inside == true)
        #expect(session.history.undoName == "Edit Stroke")
        try press("\r", in: controller)
        try await closes(controller)
        #expect(session.activeLayer?.effects?.stroke?.inside == true)
    }

    // MARK: Color

    /// The effect's 36 × 18 swatch beside its name takes a finger from 18 points above or below its middle.
    @Test func theEffectsSwatchTakesATouchFromALittleWayOff() async throws {
        let (window, controller, _) = try await shownWindow()
        defer { window.isHidden = true }
        try add(.shadow, in: controller)
        let editor = try await effectEditor(for: .shadow, over: controller)
        // Once the popover has given the editor its size.
        try await eventually { editor.view.bounds.height > 0 }
        editor.view.layoutIfNeeded()
        let swatch = try #require(views(SwatchButton.self, in: editor.view).first)
        let middle = swatch.convert(CGPoint(x: swatch.bounds.midX, y: swatch.bounds.midY), to: editor.view)
        #expect(editor.view.hitTest(CGPoint(x: middle.x, y: middle.y - 18), with: nil) === swatch)
        #expect(editor.view.hitTest(CGPoint(x: middle.x, y: middle.y + 18), with: nil) === swatch)
        try press(UIKeyCommand.inputEscape, in: controller)
        try await closes(controller)
    }

    /// The swatch opens the system's color picker over the panel, and the layer shows the color as it's picked; Escape
    /// puts it back, and the panel stays. Cancel then takes the new effect away.
    @Test func theSwatchPicksAndEscapeRestores() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        try add(.shadow, in: controller)
        let editor = try await effectEditor(for: .shadow, over: controller)
        let swatch = try #require(views(SwatchButton.self, in: editor.view).first)
        swatch.sendActions(for: .primaryActionTriggered)
        try await eventually { editor.presentedViewController is UIColorPickerViewController }
        let picker = try #require(editor.presentedViewController as? UIColorPickerViewController)
        picker.delegate?.colorPickerViewController?(picker, didSelect: .red, continuously: false)
        #expect(session.activeLayer?.effects?.shadow?.color == PaletteColor(red: 1, green: 0, blue: 0))
        editor.updatePropertiesIfNeeded()
        #expect(swatch.color == PaletteColor(red: 1, green: 0, blue: 0))

        try press(UIKeyCommand.inputEscape, in: controller)
        #expect(session.colorPicker == nil && session.activeLayer?.effects?.shadow?.color == .black)
        try await eventually { editor.presentedViewController == nil }
        #expect(editor.presentedViewController == nil)
        #expect(controller.presentedViewController === editor && session.effectsEditing != nil)

        try button("Cancel", in: editor).sendActions(for: .primaryActionTriggered)
        try await closes(controller)
        #expect(session.activeLayer?.effects == nil && session.effectsEditing == nil)
    }

    /// While the panel's color picker is up, the canvas's keys wait, as over any dialog: Delete doesn't take away the
    /// effect being colored, nor the arrows move the layer. Escape and Return answer the picker.
    @Test func theCanvasKeysWaitForThePicker() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        try add(.shadow, in: controller)
        let editor = try await effectEditor(for: .shadow, over: controller)
        func takes(_ input: String) throws -> Bool {
            let command = try #require(controller.keyCommands?.first { $0.input == input && $0.modifierFlags.isEmpty }, "\(input)")
            return controller.canPerformAction(try #require(command.action), withSender: command)
        }
        #expect(try takes(UIKeyCommand.inputDelete) && takes(UIKeyCommand.inputRightArrow) && takes("b"))
        try #require(views(SwatchButton.self, in: editor.view).first).sendActions(for: .primaryActionTriggered)
        try await eventually { editor.presentedViewController is UIColorPickerViewController }
        #expect(try !takes(UIKeyCommand.inputDelete) && !takes(UIKeyCommand.inputRightArrow) && !takes("b"))
        #expect(try takes(UIKeyCommand.inputEscape) && takes("\r"))
        try press(UIKeyCommand.inputEscape, in: controller)
        try await eventually { editor.presentedViewController == nil }
        #expect(editor.presentedViewController == nil && session.effectsEditing != nil)
        try press(UIKeyCommand.inputEscape, in: controller)
        try await closes(controller)
    }

    // MARK: Ending

    /// Escape cancels the panel, taking a new effect away again; Return keeps what's set, as the Mac's Cancel and OK.
    @Test func escapeCancelsAndReturnKeeps() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        try add(.stroke, in: controller)
        var editor = try await effectEditor(for: .stroke, over: controller)
        try row("Size", in: editor).onChange(12)
        #expect(session.activeLayer?.effects?.stroke?.size == 12)
        try press(UIKeyCommand.inputEscape, in: controller)
        try await closes(controller)
        #expect(session.activeLayer?.effects == nil && session.history.undoName == "Cancel Stroke")

        try add(.stroke, in: controller)
        editor = try await effectEditor(for: .stroke, over: controller)
        try row("Size", in: editor).onChange(12)
        try press("\r", in: controller)
        try await closes(controller)
        #expect(session.activeLayer?.effects?.stroke?.size == 12 && session.effectsEditing == nil)
        #expect(session.history.undoName == "Edit Stroke")
    }

    /// Adding another effect while one's panel is open cancels that one, as on the Mac, and its panel gives way to the
    /// new one's.
    @Test func anotherEffectsPanelTakesOver() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        try add(.stroke, in: controller)
        let stroke = try await effectEditor(for: .stroke, over: controller)
        session.addEffect(.outerGlow)
        let glow = try await effectEditor(for: .outerGlow, over: controller)
        #expect(glow !== stroke)
        #expect(session.activeLayer?.effects?.stroke == nil && session.activeLayer?.effects?.outerGlow != nil)
        #expect(captions(of: glow) == ["Size", "Opacity"])
        try press(UIKeyCommand.inputEscape, in: controller)
        try await closes(controller)
    }

    /// Choosing the effect whose panel is open leaves it as it is; choosing one the layer has opens its panel without a
    /// step, and Cancel leaves the effect as it was.
    @Test func choosingAnEffectTheLayerHasAddsNoStep() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        try add(.stroke, in: controller)
        let editor = try await effectEditor(for: .stroke, over: controller)
        try row("Size", in: editor).onChange(9)
        let steps = session.history.undoCount
        try add(.stroke, in: controller)
        #expect(session.history.undoCount == steps && controller.presentedViewController === editor)
        try press("\r", in: controller)
        try await closes(controller)

        let committed = session.history.undoCount
        try add(.stroke, in: controller)
        _ = try await effectEditor(for: .stroke, over: controller)
        #expect(session.history.undoCount == committed)
        try press(UIKeyCommand.inputEscape, in: controller)
        try await closes(controller)
        #expect(session.activeLayer?.effects?.stroke?.size == 9 && session.history.undoCount == committed)
    }

    /// Undoing the effect's adding closes its panel, which has nothing left to edit.
    @Test func undoClosesThePanel() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        try add(.colorOverlay, in: controller)
        _ = try await effectEditor(for: .colorOverlay, over: controller)
        session.undo()
        try await closes(controller)
        #expect(session.activeLayer?.effects == nil && session.effectsEditing == nil)
    }

    /// Layer › Delete names the effect whose panel is open, and deleting it closes the panel.
    @Test func deletingTheEffectClosesThePanel() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        try add(.stroke, in: controller)
        _ = try await effectEditor(for: .stroke, over: controller)
        let layers = session.document?.layers.count
        let delete = UICommand(title: "Delete Layer", action: #selector(EditorWindowController.deleteLayer(_:)))
        let shown = try #require(delete.copy() as? UICommand)
        controller.validate(shown)
        #expect(shown.title == "Delete Stroke")
        try #require(controller.canPerformAction(delete.action, withSender: delete))
        controller.perform(delete.action, with: delete)
        try await closes(controller)
        #expect(session.activeLayer?.effects == nil && session.document?.layers.count == layers && session.effectsEditing == nil)
    }

    // MARK: Keys

    /// An effect's rows line up after their captions, and a drag along a caption moves the value a step a point: a
    /// point of Distance, a percent of Opacity.
    @Test func anEffectsRowsLineUpAndScrubByTheirStep() async throws {
        let (window, controller, _) = try await shownWindow()
        defer { window.isHidden = true }
        try add(.shadow, in: controller)
        let editor = try await effectEditor(for: .shadow, over: controller)
        let starts = views(SliderField.self, in: editor.view).compactMap { views(UISlider.self, in: $0).first }
            .map { $0.convert($0.bounds, to: editor.view).minX }
        #expect(starts.count == 4 && Set(starts).count == 1, "\(starts)")
        #expect(abs(try row("Opacity", in: editor).scrubbed(from: 0.5, by: 2) - 0.52) < 0.0001)
        #expect(abs(try row("Distance", in: editor).scrubbed(from: 20, by: 2) - 22) < 0.0001)
        try press(UIKeyCommand.inputEscape, in: controller)
        try await closes(controller)
    }

    /// Up and Down step a field with the keyboard, Shift ten steps, as the Mac's effect fields: a point of Distance, a
    /// percent of Opacity.
    @Test func arrowsStepTheFields() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        try add(.shadow, in: controller)
        let editor = try await effectEditor(for: .shadow, over: controller)
        func step(_ input: String, shift: Bool = false, in caption: String) async throws {
            let field = try #require(views(NumberField.self, in: try row(caption, in: editor)).first)
            try await eventually { field.field.isFirstResponder || field.field.becomeFirstResponder() }
            try #require(field.field.isFirstResponder)
            let command = try #require(field.keyCommands?.first { $0.input == input && $0.modifierFlags == (shift ? .shift : []) })
            #expect(command.wantsPriorityOverSystemBehavior)
            let action = try #require(command.action)
            field.perform(action, with: command)
        }
        try await step(UIKeyCommand.inputUpArrow, in: "Distance")
        #expect(session.activeLayer?.effects?.shadow?.distance == 21)
        try await step(UIKeyCommand.inputUpArrow, shift: true, in: "Distance")
        #expect(session.activeLayer?.effects?.shadow?.distance == 31)
        try await step(UIKeyCommand.inputDownArrow, in: "Opacity")
        #expect(abs((session.activeLayer?.effects?.shadow?.opacity ?? 0) - 0.49) < 0.0001)
        #expect(views(UITextField.self, in: try row("Opacity", in: editor)).first?.text == "49")
        editor.view.endEditing(true)
        session.finishEffectsEditing(commit: false)
        try await closes(controller)
    }
}
