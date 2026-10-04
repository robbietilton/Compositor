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
        field.field.sendActions(for: .editingChanged)
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

    /// Image › Image Size…, Canvas Size… and the exports, which waited for nothing to be over the window, don't wait
    /// for an effect's panel: their dialog takes its place, the effect OK'd.
    @Test func theProjectsCommandsDontWaitForThePanel() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        try add(.stroke, in: controller)
        let editor = try await effectEditor(for: .stroke, over: controller)
        try row("Size", in: editor).onChange(9)
        for action in [#selector(EditorWindowController.imageSize(_:)), #selector(EditorWindowController.canvasSize(_:)),
                       #selector(EditorWindowController.exportPNG(_:))] {
            #expect(controller.canPerformAction(action, withSender: nil), "\(action)")
        }
        controller.perform(#selector(EditorWindowController.imageSize(_:)), with: nil)
        try await eventually { controller.presentedViewController != nil && !(controller.presentedViewController is EffectEditorController) }
        #expect(controller.presentedViewController != nil && !(controller.presentedViewController is EffectEditorController))
        #expect(session.effectsEditing == nil && session.activeLayer?.effects?.stroke?.size == 9)
        controller.dismiss(animated: false)
        try await closes(controller)
    }

    /// A slider moved while its row's field has the keyboard shows its value in the field, and leaving the field
    /// keeps it: the field puts in only what was typed there. Here, Size taken to 20 with its field selected at 4, then
    /// Opacity's field tapped.
    @Test func aSliderMovedWhileItsFieldIsSelectedKeepsItsValue() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        try add(.stroke, in: controller)
        let editor = try await effectEditor(for: .stroke, over: controller)
        let size = try #require(views(NumberField.self, in: try row("Size", in: editor)).first)
        let opacity = try #require(views(NumberField.self, in: try row("Opacity", in: editor)).first)
        try await eventually { size.field.isFirstResponder || size.field.becomeFirstResponder() }
        try #require(size.field.isFirstResponder && size.field.text == "4")
        try slide(views(UISlider.self, in: try row("Size", in: editor)).first, to: 20)
        editor.updatePropertiesIfNeeded()
        #expect(session.activeLayer?.effects?.stroke?.size == 20)
        #expect(size.field.text == "20")
        try await eventually { opacity.field.isFirstResponder || opacity.field.becomeFirstResponder() }
        try #require(opacity.field.isFirstResponder && !size.field.isFirstResponder)
        editor.updatePropertiesIfNeeded()
        #expect(session.activeLayer?.effects?.stroke?.size == 20)
        #expect(size.field.text == "20")
        editor.view.endEditing(true)
        try press(UIKeyCommand.inputEscape, in: controller)
        try await closes(controller)
    }

    /// What's typed goes in when the field is left; a slider moved after it, last, wins, as the last thing done.
    @Test func whatsTypedGoesInUnlessTheSliderMovesAfter() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        try add(.stroke, in: controller)
        let editor = try await effectEditor(for: .stroke, over: controller)
        let size = try #require(views(NumberField.self, in: try row("Size", in: editor)).first)
        func type(_ text: String) {
            size.field.text = text
            size.field.sendActions(for: .editingChanged)
        }
        try await eventually { size.field.isFirstResponder || size.field.becomeFirstResponder() }
        type("7")
        editor.view.endEditing(true)
        editor.updatePropertiesIfNeeded()
        #expect(session.activeLayer?.effects?.stroke?.size == 7 && size.field.text == "7")

        try await eventually { size.field.isFirstResponder || size.field.becomeFirstResponder() }
        type("9")
        try slide(views(UISlider.self, in: try row("Size", in: editor)).first, to: 15)
        editor.updatePropertiesIfNeeded()
        #expect(size.field.text == "15")
        editor.view.endEditing(true)
        editor.updatePropertiesIfNeeded()
        #expect(session.activeLayer?.effects?.stroke?.size == 15 && size.field.text == "15")
        try press(UIKeyCommand.inputEscape, in: controller)
        try await closes(controller)
    }

    /// Moves `slider` to `value`, as a finger does.
    private func slide(_ slider: UISlider?, to value: Float) throws {
        let slider = try #require(slider)
        slider.value = value
        slider.sendActions(for: .valueChanged)
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

    // MARK: Beside the panel

    /// Beside an effect's panel the Layers panel, the tools and their options stay free, as beside the Mac's; beside
    /// another editor only the canvas does.
    @Test func onlyAnEffectsPanelLeavesThePanelsFree() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        try add(.stroke, in: controller)
        let editor = try await effectEditor(for: .stroke, over: controller)
        let free = editor.popoverPresentationController?.passthroughViews ?? []
        for panel in [views(LayersPanelView.self, in: controller.view).first, views(ToolRailView.self, in: controller.view).first,
                      views(ToolOptionsBar.self, in: controller.view).first] as [UIView?] {
            let panel = try #require(panel)
            #expect(free.contains { $0 === panel }, "\(type(of: panel))")
        }
        #expect(free.count == 4)
        try press(UIKeyCommand.inputEscape, in: controller)
        try await closes(controller)

        controller.perform(#selector(EditorWindowController.levels(_:)), with: nil)
        try await eventually { controller.presentedViewController is AdjustmentEditorController }
        let levels = try #require(controller.presentedViewController as? AdjustmentEditorController)
        #expect(levels.popoverPresentationController?.passthroughViews?.count == 1)
        #expect(levels.popoverPresentationController?.passthroughViews?.contains { $0 is LayersPanelView } == false)
        session.cancelLevels()
        try await closes(controller)
    }

    /// Another edit's editor takes the place of an effect's panel, from wherever it's opened, the effect kept as its
    /// OK keeps it: the iPad shows one at a time.
    @Test(arguments: ["Gaussian Blur", "Levels", "Curves", "Hue/Saturation", "Levels layer"])
    func anotherEditorTakesItsPlace(_ entry: String) async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        try add(.stroke, in: controller)
        let effect = try await effectEditor(for: .stroke, over: controller)
        try row("Size", in: effect).onChange(7)
        switch entry {
        case "Gaussian Blur":
            let command = UICommand(title: "Gaussian Blur…", action: #selector(EditorWindowController.applyFilter(_:)),
                                    propertyList: FilterKind.gaussianBlur.rawValue)
            try #require(controller.canPerformAction(command.action, withSender: command))
            controller.perform(command.action, with: command)
        case "Levels", "Curves", "Hue/Saturation":
            let action = entry == "Levels" ? #selector(EditorWindowController.levels(_:))
                : entry == "Curves" ? #selector(EditorWindowController.curves(_:)) : #selector(EditorWindowController.hueSaturation(_:))
            try #require(controller.canPerformAction(action, withSender: nil))
            controller.perform(action, with: nil)
        default:
            let button = try #require(views(UIButton.self, in: controller.view).first { $0.accessibilityLabel == "New adjustment layer" })
            let levels = try #require(button.menu?.children.compactMap { $0 as? UIAction }.first { $0.title == "Levels" })
            levels.performWithSender(nil, target: nil)
        }
        try await eventually {
            controller.presentedViewController is AdjustmentEditorController && !(controller.presentedViewController is EffectEditorController)
        }
        let editor = try #require(controller.presentedViewController as? AdjustmentEditorController)
        #expect(!(editor is EffectEditorController))
        #expect(session.effectsEditing == nil)
        #expect(session.document?.layers.contains { $0.effects?.stroke?.size == 7 } == true)
        try press(UIKeyCommand.inputEscape, in: controller)
        try await closes(controller)
        #expect(session.document?.layers.contains { $0.effects?.stroke?.size == 7 } == true)
    }

    /// So does anything else the window shows, as the rail's color picker and Layer › Rename's question, which can't
    /// come over the panel.
    @Test func whatElseTheWindowShowsTakesItsPlace() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        try add(.stroke, in: controller)
        let effect = try await effectEditor(for: .stroke, over: controller)
        try row("Size", in: effect).onChange(7)
        let rail = try #require(views(ToolRailView.self, in: controller.view).first)
        rail.chooseColor(background: false)
        try await eventually { controller.presentedViewController is UIColorPickerViewController }
        #expect(controller.presentedViewController is UIColorPickerViewController)
        #expect(session.effectsEditing == nil && session.activeLayer?.effects?.stroke?.size == 7)
        controller.dismiss(animated: false)
        try await closes(controller)

        try add(.shadow, in: controller)
        _ = try await effectEditor(for: .shadow, over: controller)
        let rename = #selector(EditorWindowController.renameLayer(_:))
        try #require(controller.canPerformAction(rename, withSender: nil))
        controller.perform(rename, with: nil)
        try await eventually { controller.presentedViewController is UIAlertController }
        #expect((controller.presentedViewController as? UIAlertController)?.title == "Rename Layer")
        #expect(session.effectsEditing == nil && session.activeLayer?.effects?.shadow != nil)
        controller.dismiss(animated: false)
        try await closes(controller)
    }

    /// Going to another tab, the panel goes with the tab it edits, OK'd, as when anything else takes its place, rather
    /// than staying over the new tab, bound to a layer that isn't there.
    @Test func thePanelGoesWhenAnotherTabComesForward() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        try add(.stroke, in: controller)
        let editor = try await effectEditor(for: .stroke, over: controller)
        try row("Size", in: editor).onChange(9)
        controller.newCanvasTab(nil)
        try await closes(controller)
        #expect(session.effectsEditing == nil && session.activeLayer?.effects?.stroke?.size == 9)
        #expect(controller.activeTab?.session !== session)
    }

    /// Something the editor asks the window to say, as an error, takes the panel's place too, OK'd; while the panel's
    /// color picker is up, it waits, rather than being lost.
    @Test func aMessageWaitsForThePickerThenTakesThePanelsPlace() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        try add(.shadow, in: controller)
        let editor = try await effectEditor(for: .shadow, over: controller)
        try #require(views(SwatchButton.self, in: editor.view).first).sendActions(for: .primaryActionTriggered)
        try await eventually { editor.presentedViewController is UIColorPickerViewController }
        session.brushError = "The brush ran out of room."
        try await Task.sleep(for: .milliseconds(400))
        #expect(session.brushError != nil && editor.presentedViewController is UIColorPickerViewController)
        try press(UIKeyCommand.inputEscape, in: controller)
        try await eventually { controller.presentedViewController is UIAlertController }
        #expect((controller.presentedViewController as? UIAlertController)?.title == "Couldn’t paint")
        #expect(session.brushError == nil && session.effectsEditing == nil && session.activeLayer?.effects?.shadow != nil)
        controller.dismiss(animated: false)
        try await closes(controller)
    }

    /// The panel stays with the layer it was opened on, as the Mac's: another layer chosen in the Layers panel, its
    /// rows still set the first one's effect.
    @Test func thePanelStaysWithItsLayer() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        let gray = try #require(session.activeLayerID)
        try add(.stroke, in: controller)
        let editor = try await effectEditor(for: .stroke, over: controller)
        let other = try #require(session.document?.layers.first { $0.id != gray }?.id)
        session.selectLayers([other], primary: other)
        try #require(session.activeLayerID == other)
        try row("Size", in: editor).onChange(11)
        #expect(session.document?.layers.first { $0.id == gray }?.effects?.stroke?.size == 11)
        #expect(session.document?.layers.first { $0.id == other }?.effects == nil)
        #expect(controller.presentedViewController === editor)
        try press("\r", in: controller)
        try await closes(controller)
    }

    /// Merging its layer away closes the panel, which has nothing left to edit.
    @Test func mergingItsLayerAwayClosesThePanel() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        try add(.stroke, in: controller)
        _ = try await effectEditor(for: .stroke, over: controller)
        let merge = #selector(EditorWindowController.mergeLayers(_:))
        try #require(controller.canPerformAction(merge, withSender: nil))
        controller.perform(merge, with: nil)
        try await closes(controller)
        #expect(session.effectsEditing == nil)
    }

    /// Beside an effect's panel, Escape and Return go to an edit of the canvas's own first: a crop, then a transform.
    /// The panel has them once it's done.
    @Test func escapeAndReturnGoToTheCanvasFirst() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        try add(.stroke, in: controller)
        let editor = try await effectEditor(for: .stroke, over: controller)
        session.selectTool(.crop)
        try #require(session.cropRect != nil)
        try press(UIKeyCommand.inputEscape, in: controller)
        #expect(session.cropRect == nil && session.effectsEditing != nil && controller.presentedViewController === editor)
        session.selectTool(.move)
        session.transformCommand()
        try #require(session.transformEdit != nil)
        try press("\r", in: controller)
        #expect(session.transformEdit == nil && session.effectsEditing != nil && controller.presentedViewController === editor)
        try press(UIKeyCommand.inputEscape, in: controller)
        try await closes(controller)
        #expect(session.effectsEditing == nil && session.activeLayer?.effects == nil)
    }

    /// The panel keeps working while a crop, a transform or text is under way, as the Mac's does: its rows set the
    /// effect, and its Cancel takes a new one away.
    @Test func itKeepsWorkingBesideACrop() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        try add(.stroke, in: controller)
        let editor = try await effectEditor(for: .stroke, over: controller)
        session.selectTool(.crop)
        try #require(session.cropRect != nil)
        try row("Size", in: editor).onChange(13)
        #expect(session.activeLayer?.effects?.stroke?.size == 13)
        try button("Cancel", in: editor).sendActions(for: .primaryActionTriggered)
        try await closes(controller)
        #expect(session.activeLayer?.effects == nil && session.cropRect != nil)
    }

    /// The panel goes with its tab, and closing the tab cancels it, as closing the Mac's window does.
    @Test func thePanelGoesWithItsTab() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        let tab = try #require(controller.activeTab)
        try add(.stroke, in: controller)
        _ = try await effectEditor(for: .stroke, over: controller)
        controller.close(tab.id)
        try await closes(controller)
        try await eventually { session.effectsEditing == nil }
        #expect(session.effectsEditing == nil && session.document?.layers.contains { $0.effects != nil } != true)
        if let url = tab.document?.fileURL { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: Selecting

    /// The gray layer's row in the Layers panel, laid out, with a Stroke and a Drop Shadow under it and neither selected.
    private func rowWithTwoEffects() async throws -> (window: UIWindow, controller: EditorWindowController, session: EditorSession,
                                                     panel: LayersPanelView, cell: LayerRowCell, layer: UUID) {
        let (window, controller, session) = try await shownWindow()
        let layer = try #require(session.activeLayerID)
        for kind in [LayerEffectKind.stroke, .shadow] {
            try add(kind, in: controller)
            _ = try await effectEditor(for: kind, over: controller)
            try press("\r", in: controller)
            try await closes(controller)
        }
        // No effect selected yet, as adding one leaves it selected.
        session.effectSelection = nil
        let panel = try #require(views(LayersPanelView.self, in: controller.view).first)
        let cell = try self.cell(for: layer, in: panel)
        try #require(cell.contentView.bounds.height == LayerRowCell.height + 2 * LayerRowCell.effectHeight)
        return (window, controller, session, panel, cell, layer)
    }

    private func cell(for layer: UUID, in panel: LayersPanelView) throws -> LayerRowCell {
        panel.updatePropertiesIfNeeded()
        panel.layoutIfNeeded()
        let cell = try #require(views(LayerRowCell.self, in: panel).first { $0.layerID == layer })
        cell.layoutIfNeeded()
        return cell
    }

    /// The middle of the effect row `index` under the layer, in the cell.
    private func effectPoint(_ index: Int, in cell: LayerRowCell) -> CGPoint {
        CGPoint(x: cell.contentView.bounds.midX, y: LayerRowCell.height + LayerRowCell.effectHeight * (CGFloat(index) + 0.5))
    }

    /// Whether the effect's row reads as selected.
    private func shownSelected(_ kind: LayerEffectKind, in cell: LayerRowCell) throws -> Bool {
        let label = try #require(views(UILabel.self, in: cell).first { $0.accessibilityLabel == kind.rawValue + " effect" })
        return label.accessibilityTraits.contains(.selected)
    }

    /// A point on an effect's row finds that effect; one on the layer's own row, none.
    @Test func aPointFindsItsEffect() async throws {
        let (window, _, _, _, cell, _) = try await rowWithTwoEffects()
        defer { window.isHidden = true }
        #expect(cell.effect(at: effectPoint(0, in: cell)) == .stroke)
        #expect(cell.effect(at: effectPoint(1, in: cell)) == .shadow)
        #expect(cell.effect(at: CGPoint(x: cell.contentView.bounds.midX, y: LayerRowCell.height / 2)) == nil)
    }

    /// A tap on an effect's row selects it, highlighted in place of its layer, as a click does on the Mac; a tap on
    /// the layer's own row lets it go.
    @Test func aTapSelectsTheEffect() async throws {
        let (window, _, session, panel, cell, layer) = try await rowWithTwoEffects()
        defer { window.isHidden = true }
        cell.tap(at: effectPoint(1, in: cell))
        #expect(session.selectedEffect == LayerEffectSelection(layerID: layer, kind: .shadow))
        var shown = try self.cell(for: layer, in: panel)
        #expect(try shownSelected(.shadow, in: shown) && !shownSelected(.stroke, in: shown))
        let name = try #require(views(UILabel.self, in: shown).first { $0.text == "Gray" })
        #expect(!name.accessibilityTraits.contains(.selected))

        shown.tap(at: CGPoint(x: shown.contentView.bounds.midX, y: LayerRowCell.height / 2))
        #expect(session.selectedEffect == nil && session.effectSelection == nil && session.selectedLayerIDs == [layer])
        shown = try self.cell(for: layer, in: panel)
        #expect(try !shownSelected(.shadow, in: shown))
    }

    /// Delete takes away the effect tapped, and only it, as the Mac's does; the Layer menu names it.
    @Test func deleteRemovesTheTappedEffect() async throws {
        let (window, controller, session, _, cell, layer) = try await rowWithTwoEffects()
        defer { window.isHidden = true }
        let layers = session.document?.layers.count
        cell.tap(at: effectPoint(0, in: cell))
        let delete = UICommand(title: "Delete Layer", action: #selector(EditorWindowController.deleteLayer(_:)))
        let shown = try #require(delete.copy() as? UICommand)
        controller.validate(shown)
        #expect(shown.title == "Delete Stroke")
        try press(UIKeyCommand.inputDelete, in: controller)
        #expect(session.history.undoName == "Remove Stroke")
        let effects = session.document?.layers.first { $0.id == layer }?.effects
        #expect(effects?.stroke == nil && effects?.shadow != nil && session.document?.layers.count == layers)
    }

    /// A double tap on an effect's row opens its panel rather than renaming the layer; one on another effect gives way
    /// to that one's.
    @Test func aDoubleTapEdits() async throws {
        let (window, controller, session, _, cell, layer) = try await rowWithTwoEffects()
        defer { window.isHidden = true }
        cell.tap(at: effectPoint(0, in: cell))
        cell.doubleTap(at: effectPoint(0, in: cell))
        #expect(session.effectsEditing == LayerEffectSelection(layerID: layer, kind: .stroke))
        _ = try await effectEditor(for: .stroke, over: controller)
        #expect(!(controller.presentedViewController is UIAlertController))
        cell.doubleTap(at: effectPoint(1, in: cell))
        _ = try await effectEditor(for: .shadow, over: controller)
        #expect(session.document?.layers.first { $0.id == layer }?.effects?.stroke != nil)
        try press(UIKeyCommand.inputEscape, in: controller)
        try await closes(controller)
    }

    /// Pressing an effect's row selects the effect, and its menu deletes it, named as the Layer menu names it.
    @Test func theRowsMenuDeletesThePressedEffect() async throws {
        let (window, _, session, panel, cell, layer) = try await rowWithTwoEffects()
        defer { window.isHidden = true }
        let list = try #require(views(UICollectionView.self, in: panel).first)
        let indexPath = try #require(list.indexPath(for: cell))
        let point = cell.contentView.convert(effectPoint(1, in: cell), to: list)
        #expect(panel.collectionView(list, contextMenuConfigurationForItemsAt: [indexPath], point: point) != nil)
        #expect(session.selectedEffect == LayerEffectSelection(layerID: layer, kind: .shadow))
        func titles(_ menu: UIMenu) -> [String] {
            menu.children.flatMap { ($0 as? UIMenu).map(titles) ?? [$0.title] }
        }
        let menu = panel.menu(for: layer, in: session)
        #expect(titles(menu).contains("Delete Drop Shadow") && !titles(menu).contains("Delete Layer"))

        let layerPoint = cell.contentView.convert(CGPoint(x: cell.contentView.bounds.midX, y: LayerRowCell.height / 2), to: list)
        _ = panel.collectionView(list, contextMenuConfigurationForItemsAt: [indexPath], point: layerPoint)
        #expect(session.selectedEffect == nil)
        #expect(titles(panel.menu(for: layer, in: session)).contains("Delete Layer"))
    }

    /// A touch on the canvas lets go of a selected effect, as a click on the Mac's canvas does.
    @Test func aCanvasTouchLetsGoOfTheEffect() async throws {
        let (window, controller, session, _, cell, _) = try await rowWithTwoEffects()
        defer { window.isHidden = true }
        cell.tap(at: effectPoint(0, in: cell))
        try #require(session.selectedEffect != nil)
        let canvas = try #require(views(PadCanvasView.self, in: controller.view).first)
        canvas.touchesBegan([], with: nil)
        #expect(session.selectedEffect == nil && session.effectSelection == nil)
    }

    // MARK: Copying by dragging

    /// A Drop Shadow on the gray layer, which has a copy in a folder above it, and the blank layer the project began
    /// with beneath.
    private func layersToDropOn() async throws -> (window: UIWindow, controller: EditorWindowController, session: EditorSession,
                                                   panel: LayersPanelView, list: UICollectionView, source: UUID) {
        let (window, controller, session) = try await shownWindow()
        let source = try #require(session.activeLayerID)
        session.duplicateActiveLayer()
        session.groupSelectedLayers()
        session.selectLayers([source], primary: source)
        try add(.shadow, in: controller)
        let editor = try await effectEditor(for: .shadow, over: controller)
        try row("Distance", in: editor).onChange(42)
        try press("\r", in: controller)
        try await closes(controller)
        session.effectSelection = nil
        let panel = try #require(views(LayersPanelView.self, in: controller.view).first)
        let list = try #require(views(UICollectionView.self, in: panel).first)
        _ = try cell(for: source, in: panel)
        return (window, controller, session, panel, list, source)
    }

    /// The middle of the layer's own row, or of its effect row `effect`, in the list.
    private func point(on layer: UUID, effect: Int? = nil, in panel: LayersPanelView, list: UICollectionView) throws -> CGPoint {
        let cell = try self.cell(for: layer, in: panel)
        let local = effect.map { effectPoint($0, in: cell) } ?? CGPoint(x: cell.contentView.bounds.midX, y: LayerRowCell.height / 2)
        return cell.contentView.convert(local, to: list)
    }

    private func indexPath(of layer: UUID, in panel: LayersPanelView, list: UICollectionView) throws -> IndexPath {
        try #require(list.indexPath(for: try cell(for: layer, in: panel)))
    }

    /// Dragging from an effect's row carries the effect alone, its row lifted on its own; from the layer's own row, the
    /// layer, as before.
    @Test func aDragFromAnEffectsRowCarriesTheEffect() async throws {
        let (window, _, _, panel, list, source) = try await layersToDropOn()
        defer { window.isHidden = true }
        let at = try indexPath(of: source, in: panel, list: list)
        let fromEffect = FakeDragSession(at: try point(on: source, effect: 0, in: panel, list: list), in: list)
        let items = panel.collectionView(list, itemsForBeginning: fromEffect, at: at)
        let effect = try #require(items.first?.localObject as? LayersPanelView.EffectDrag)
        #expect(items.count == 1 && effect.layerID == source && effect.kind == .shadow)
        let lifted = try #require(panel.collectionView(list, dragPreviewParametersForItemAt: at)?.visiblePath?.bounds)
        #expect(abs(lifted.minY - LayerRowCell.height) < 0.5 && abs(lifted.height - LayerRowCell.effectHeight) < 0.5)

        let fromLayer = FakeDragSession(at: try point(on: source, in: panel, list: list), in: list)
        let layers = panel.collectionView(list, itemsForBeginning: fromLayer, at: at)
        #expect(layers.first?.localObject as? [UUID] == [source])
        #expect(panel.collectionView(list, dragPreviewParametersForItemAt: at) == nil)
    }

    /// An effect can go onto another layer with pixels, as on the Mac; not back onto its own, a folder, or a layer with
    /// nothing in it.
    @Test func anEffectGoesOntoAnotherLayerWithPixels() async throws {
        let (window, _, session, panel, list, source) = try await layersToDropOn()
        defer { window.isHidden = true }
        let layers = try #require(session.document?.layers)
        let copy = try #require(layers.first { $0.id != source && !$0.isGroup && $0.asset != nil }?.id)
        let folder = try #require(layers.first(where: \.isGroup)?.id)
        let blank = try #require(layers.first { !$0.isGroup && $0.asset == nil }?.id)
        let item = UIDragItem(itemProvider: NSItemProvider())
        item.localObject = LayersPanelView.EffectDrag(layerID: source, kind: .shadow)
        for (layer, operation) in [(copy, UIDropOperation.copy), (source, .forbidden), (folder, .forbidden), (blank, .forbidden)] {
            let drop = FakeDropSession(items: [item], at: try point(on: layer, in: panel, list: list), in: list)
            let proposal = panel.collectionView(list, dropSessionDidUpdate: drop, withDestinationIndexPath: nil)
            #expect(proposal.operation == operation, "\(layers.first { $0.id == layer }?.name ?? "")")
        }
    }

    /// Dropped on another layer, the effect is copied there with its settings, as one step, and selected there.
    @Test func droppingCopiesTheEffect() async throws {
        let (window, _, session, panel, list, source) = try await layersToDropOn()
        defer { window.isHidden = true }
        let copy = try #require(session.document?.layers.first { $0.id != source && !$0.isGroup && $0.asset != nil }?.id)
        let item = UIDragItem(itemProvider: NSItemProvider())
        item.localObject = LayersPanelView.EffectDrag(layerID: source, kind: .shadow)
        let drop = FakeDropSession(items: [item], at: try point(on: copy, in: panel, list: list), in: list)
        panel.collectionView(list, performDropWith: FakeDropCoordinator(session: drop))
        let effects = { (id: UUID) in session.document?.layers.first { $0.id == id }?.effects }
        #expect(effects(copy)?.shadow?.distance == 42 && effects(copy)?.shadow == effects(source)?.shadow)
        #expect(session.history.undoName == "Copy Drop Shadow")
        #expect(session.selectedEffect == LayerEffectSelection(layerID: copy, kind: .shadow))
    }

    /// Dropped on a layer whose same effect's panel is open, the panel is OK'd first, so its Cancel can't take back the
    /// copy, as on the Mac.
    @Test func droppingOntoAnOpenEffectOKsItFirst() async throws {
        let (window, controller, session, panel, list, source) = try await layersToDropOn()
        defer { window.isHidden = true }
        let copy = try #require(session.document?.layers.first { $0.id != source && !$0.isGroup && $0.asset != nil }?.id)
        session.selectLayers([copy], primary: copy)
        try add(.shadow, in: controller)
        _ = try await effectEditor(for: .shadow, over: controller)
        let item = UIDragItem(itemProvider: NSItemProvider())
        item.localObject = LayersPanelView.EffectDrag(layerID: source, kind: .shadow)
        let drop = FakeDropSession(items: [item], at: try point(on: copy, in: panel, list: list), in: list)
        panel.collectionView(list, performDropWith: FakeDropCoordinator(session: drop))
        try await closes(controller)
        #expect(session.effectsEditing == nil)
        #expect(session.document?.layers.first { $0.id == copy }?.effects?.shadow?.distance == 42)
    }
}

/// A drag begun at a point, as the system's drag session reports it.
@MainActor private final class FakeDragSession: NSObject, UIDragSession {
    private let point: CGPoint
    private let view: UIView
    var localContext: Any?
    var items: [UIDragItem] = []
    init(at point: CGPoint, in view: UIView) {
        self.point = point
        self.view = view
    }
    func location(in view: UIView) -> CGPoint { view.convert(point, from: self.view) }
    var allowsMoveOperation: Bool { true }
    var isRestrictedToDraggingApplication: Bool { false }
    func hasItemsConforming(toTypeIdentifiers typeIdentifiers: [String]) -> Bool { false }
    func canLoadObjects(ofClass aClass: any NSItemProviderReading.Type) -> Bool { false }
}

/// A drop from within the app, over a point, as the system's drop session reports it.
@MainActor private final class FakeDropSession: NSObject, UIDropSession {
    let items: [UIDragItem]
    private let point: CGPoint
    private let view: UIView
    private let drag: FakeDragSession
    init(items: [UIDragItem], at point: CGPoint, in view: UIView) {
        self.items = items
        self.point = point
        self.view = view
        drag = FakeDragSession(at: point, in: view)
    }
    var localDragSession: (any UIDragSession)? { drag }
    var progressIndicatorStyle: UIDropSessionProgressIndicatorStyle = .none
    nonisolated let progress = Progress()
    func location(in view: UIView) -> CGPoint { view.convert(point, from: self.view) }
    var allowsMoveOperation: Bool { true }
    var isRestrictedToDraggingApplication: Bool { false }
    func hasItemsConforming(toTypeIdentifiers typeIdentifiers: [String]) -> Bool { false }
    func canLoadObjects(ofClass aClass: any NSItemProviderReading.Type) -> Bool { false }
    func loadObjects(ofClass aClass: any NSItemProviderReading.Type, completion: @escaping ([any NSItemProviderReading]) -> Void) -> Progress {
        progress
    }
}

/// The drop's coordinator, which the panel only asks for the session.
@MainActor private final class FakeDropCoordinator: NSObject, UICollectionViewDropCoordinator {
    let session: any UIDropSession
    init(session: any UIDropSession) { self.session = session }
    var items: [any UICollectionViewDropItem] { [] }
    var destinationIndexPath: IndexPath? { nil }
    var proposal: UICollectionViewDropProposal { UICollectionViewDropProposal(operation: .copy) }
    func drop(_ dragItem: UIDragItem, to placeholder: UICollectionViewDropPlaceholder) -> any UICollectionViewDropPlaceholderContext {
        fatalError("The panel doesn't drop to a placeholder")
    }
    func drop(_ dragItem: UIDragItem, toItemAt indexPath: IndexPath) -> any UIDragAnimating { Animating() }
    func drop(_ dragItem: UIDragItem, intoItemAt indexPath: IndexPath, rect: CGRect) -> any UIDragAnimating { Animating() }
    func drop(_ dragItem: UIDragItem, to target: UIDragPreviewTarget) -> any UIDragAnimating { Animating() }
    private final class Animating: NSObject, UIDragAnimating {
        func addAnimations(_ animations: @escaping () -> Void) {}
        func addCompletion(_ completion: @escaping (UIViewAnimatingPosition) -> Void) {}
    }
}
