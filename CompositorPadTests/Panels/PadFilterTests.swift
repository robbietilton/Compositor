import CoreGraphics
import Testing
import UIKit
@testable import Compositor

/// The filters' editor on iPad, and the controls it's made of, as the Mac's filter panel has them.
@MainActor struct PadFilterTests {
    /// The views of `type` in `view`, depth first.
    private func views<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        view.subviews.flatMap { subview -> [T] in ((subview as? T).map { [$0] } ?? []) + views(type, in: subview) }
    }

    // MARK: Controls

    /// A logarithmic slider gives the small values most of its travel, as the Mac's: halfway along 0.1 to 250 is their
    /// geometric mean, 5, and a value shows where its logarithm falls.
    @Test func aLogarithmicSliderPutsTheGeometricMeanHalfway() throws {
        let row = SliderField(caption: "Radius", sliderRange: 0.1...250, fieldRange: 0.1...250, sensitivity: 0.1, logarithmic: true, decimals: 1)
        var changed: Double?
        row.onChange = { changed = $0 }
        let slider = try #require(views(UISlider.self, in: row).first)
        slider.value = (slider.minimumValue + slider.maximumValue) / 2
        slider.sendActions(for: .valueChanged)
        #expect(changed == 5)
        row.show(1)
        #expect(abs(slider.value - Float(log(1.0))) < 0.0001)
        row.show(250)
        #expect(abs(slider.value - slider.maximumValue) < 0.0001)
    }

    /// The field shows a value with as many decimals as it needs, up to the row's, as the Mac's fields do; the slider
    /// sets values to the row's decimals.
    @Test func theFieldShowsUpToItsDecimals() throws {
        let one = SliderField(caption: "Radius", sliderRange: 0.1...250, fieldRange: 0.1...250, sensitivity: 0.1, logarithmic: true, decimals: 1)
        let field = try #require(views(UITextField.self, in: one).first)
        one.show(1)
        #expect(field.text == "1")
        one.show(1.5)
        #expect(field.text == "1.5")
        let four = SliderField(caption: "Offset", sliderRange: -0.5...0.5, fieldRange: -0.5...0.5, sensitivity: 0.0001, decimals: 4)
        let offset = try #require(views(UITextField.self, in: four).first)
        four.show(0.0125)
        #expect(offset.text == "0.0125")
        four.show(0)
        #expect(offset.text == "0")
        var changed: Double?
        four.onChange = { changed = $0 }
        let slider = try #require(views(UISlider.self, in: four).first)
        slider.value = 0.123456
        slider.sendActions(for: .valueChanged)
        #expect(changed == 0.1235)
    }

    /// Dragging along a caption moves the value evenly, a point of drag to the row's sensitivity, though its slider is
    /// logarithmic, as on the Mac.
    @Test func scrubbingIsEvenOnALogarithmicRow() {
        let row = SliderField(caption: "Radius", sliderRange: 0.1...250, fieldRange: 0.1...250, sensitivity: 0.1, logarithmic: true, decimals: 1)
        #expect(abs(row.scrubbed(from: 3, by: 10) - 4) < 0.0001)
        #expect(abs(row.scrubbed(from: 3, by: -100) - 0.1) < 0.0001)
    }

    /// A group's captions take the widest one's width, so every slider starts and ends in the same place, as the Mac's
    /// filter panel lines them up.
    @Test func captionsLineUp() throws {
        // Sliders that take the room there is, as the filter panel's do.
        let rows = [SliderField(caption: "Amount", sliderRange: 0...100, fieldRange: 0...100, sensitivity: 1, sliderWidth: nil),
                    SliderField(caption: "Highlights", sliderRange: 0...100, fieldRange: 0...100, sensitivity: 1, sliderWidth: nil)]
        SliderField.alignCaptions(rows)
        let column = UIStackView(arrangedSubviews: rows)
        column.axis = .vertical
        column.frame = CGRect(x: 0, y: 0, width: 400, height: 100)
        column.layoutIfNeeded()
        let sliders = rows.compactMap { views(UISlider.self, in: $0).first }
        try #require(sliders.count == 2)
        #expect(sliders[0].frame.minX == sliders[1].frame.minX)
        #expect(sliders[0].frame.width == sliders[1].frame.width)
    }

    // MARK: The filter editor

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

    /// The window's menu command for `kind`, as the Filter or Image menu has it.
    private func filterCommand(_ kind: FilterKind) -> UICommand {
        UICommand(title: kind.rawValue + "…", action: #selector(EditorWindowController.applyFilter(_:)), propertyList: kind.rawValue)
    }

    /// Chooses `command` from the menu bar, if the window takes it; whether it did.
    @discardableResult
    private func choose(_ command: UICommand, in controller: EditorWindowController) -> Bool {
        guard controller.canPerformAction(command.action, withSender: command) else { return false }
        controller.perform(command.action, with: command)
        return true
    }

    /// Presses the window's key for `input`, as the keyboard does once the window takes it.
    private func press(_ input: String, in controller: EditorWindowController) throws {
        let command = try #require(controller.keyCommands?.first { $0.input == input && $0.modifierFlags.isEmpty })
        let action = try #require(command.action)
        try #require(controller.canPerformAction(action, withSender: command))
        controller.perform(action, with: command)
    }

    /// The filter editor the window shows, once it shows it.
    private func filterEditor(over controller: EditorWindowController) async throws -> FilterEditorController {
        try await eventually { controller.presentedViewController is FilterEditorController }
        let editor = try #require(controller.presentedViewController as? FilterEditorController)
        editor.view.layoutIfNeeded()
        return editor
    }

    /// The editor's rows: each one's caption and unit, in order.
    private func rows(of editor: UIViewController) -> [[String]] {
        views(SliderField.self, in: editor.view).map { row in views(UILabel.self, in: row).compactMap(\.text).filter { !$0.isEmpty } }
    }

    /// Moves the slider of the editor's row `index` to `value`, as a finger does.
    private func slide(_ index: Int, to value: Double, in editor: UIViewController, logarithmic: Bool) throws {
        let sliders = views(SliderField.self, in: editor.view).compactMap { views(UISlider.self, in: $0).first }
        try #require(sliders.indices.contains(index))
        sliders[index].value = Float(logarithmic ? log(value) : value)
        sliders[index].sendActions(for: .valueChanged)
    }

    /// What the field of the editor's row `index` shows.
    private func field(_ index: Int, in editor: UIViewController) -> String? {
        let fields = views(SliderField.self, in: editor.view).compactMap { views(UITextField.self, in: $0).first }
        return fields.indices.contains(index) ? fields[index].text : nil
    }

    /// Every row's range is the one the editor's engine keeps the value to, so what the slider and field reach is what
    /// the filter applies.
    @Test func everyRowsRangeIsTheEngines() {
        #expect(!FilterEditorController.rows.isEmpty)
        for (kind, rows) in FilterEditorController.rows {
            for row in rows {
                var above = FilterSettings(), below = FilterSettings()
                above[keyPath: row.key] = row.range.upperBound + 1
                below[keyPath: row.key] = row.range.lowerBound - 1
                #expect(above.normalized[keyPath: row.key] == row.range.upperBound, "\(kind) \(row.caption)")
                #expect(below.normalized[keyPath: row.key] == row.range.lowerBound, "\(kind) \(row.caption)")
            }
        }
    }

    /// Filter › Gaussian Blur… opens its editor, with the Mac's Radius row.
    @Test func gaussianBlurOpensFromTheFilterMenu() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        #expect(choose(filterCommand(.gaussianBlur), in: controller))
        #expect(session.filterEdit?.kind == .gaussianBlur)
        let editor = try await filterEditor(over: controller)
        #expect(views(UILabel.self, in: editor.view).contains { $0.text == "Gaussian Blur" })
        #expect(rows(of: editor) == [["Radius", "px"]])
        session.cancelFilter()
        try await eventually { controller.presentedViewController == nil }
    }

    /// OK applies the blur as one step to undo, and closes the editor; Escape leaves the layer as it was.
    @Test func okAppliesAndEscapeLeavesTheLayer() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        let before = session.activeLayer?.asset?.image
        let steps = session.history.undoCount
        choose(filterCommand(.gaussianBlur), in: controller)
        var editor = try await filterEditor(over: controller)
        try slide(0, to: 3, in: editor, logarithmic: true)
        #expect(session.filterEdit?.settings.radius == 3)
        try press(UIKeyCommand.inputEscape, in: controller)
        #expect(session.filterEdit == nil)
        try await eventually { controller.presentedViewController == nil }
        #expect(session.activeLayer?.asset?.image === before && session.history.undoCount == steps)

        choose(filterCommand(.gaussianBlur), in: controller)
        editor = try await filterEditor(over: controller)
        try slide(0, to: 3, in: editor, logarithmic: true)
        try press("\r", in: controller)
        try await eventually { session.filterEdit == nil }
        #expect(session.filterEdit == nil && session.history.undoName == "Gaussian Blur" && session.history.undoCount == steps + 1)
        try await eventually { controller.presentedViewController == nil }
        #expect(controller.presentedViewController == nil)
    }

    /// The editor opens with the values last applied, as the Mac's does; values cancelled aren't kept.
    @Test func itReopensWithTheValuesLastApplied() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        choose(filterCommand(.gaussianBlur), in: controller)
        var editor = try await filterEditor(over: controller)
        try slide(0, to: 3, in: editor, logarithmic: true)
        try press("\r", in: controller)
        try await eventually { controller.presentedViewController == nil && session.filterEdit == nil }

        choose(filterCommand(.gaussianBlur), in: controller)
        editor = try await filterEditor(over: controller)
        try await eventually { self.field(0, in: editor) == "3" }
        #expect(field(0, in: editor) == "3")
        try slide(0, to: 7, in: editor, logarithmic: true)
        try press(UIKeyCommand.inputEscape, in: controller)
        try await eventually { controller.presentedViewController == nil }

        choose(filterCommand(.gaussianBlur), in: controller)
        editor = try await filterEditor(over: controller)
        try await eventually { self.field(0, in: editor) == "3" }
        #expect(field(0, in: editor) == "3")
        session.cancelFilter()
        try await eventually { controller.presentedViewController == nil }
    }

    /// A quick filter never says it's working while its preview is made, as the Mac's doesn't: the panel would flicker
    /// at every step of a slider.
    @Test func aQuickFilterNeverSaysWorking() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        choose(filterCommand(.gaussianBlur), in: controller)
        let editor = try await filterEditor(over: controller)
        session.filterEdit?.preparing = true
        editor.updatePropertiesIfNeeded()
        #expect(!views(UILabel.self, in: editor.view).contains { $0.text == "Working…" && !$0.isHidden })
        session.filterEdit?.preparing = false
        session.cancelFilter()
        try await eventually { controller.presentedViewController == nil }
    }

    /// A Gaussian Blur adjustment layer opens the same editor from Layer › New Adjustment Layer: what it sets shows on
    /// the layer at once, OK keeps it as one step, and Cancel leaves the layer as it was.
    @Test func aGaussianBlurLayerIsEditedInTheSameEditor() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        let new = UICommand(title: "Gaussian Blur…", action: #selector(EditorWindowController.newAdjustmentLayer(_:)),
                            propertyList: AdjustmentKind.gaussianBlur.rawValue)
        #expect(choose(new, in: controller))
        let id = try #require(session.activeLayerID)
        var editor = try await filterEditor(over: controller)
        try await eventually { self.field(0, in: editor) == "10" }
        #expect(field(0, in: editor) == "10")
        try slide(0, to: 20, in: editor, logarithmic: true)
        try await eventually { session.document?.layers.first { $0.id == id }?.adjustment?.gaussianRadius == 20 }
        #expect(session.document?.layers.first { $0.id == id }?.adjustment?.gaussianRadius == 20)
        try press("\r", in: controller)
        try await eventually { session.filterEdit == nil && session.adjustmentEditingID == nil }
        #expect(session.history.undoName == "Edit Gaussian Blur Adjustment")
        try await eventually { controller.presentedViewController == nil }

        session.adjustmentEditingID = id
        editor = try await filterEditor(over: controller)
        try await eventually { self.field(0, in: editor) == "20" }
        try slide(0, to: 40, in: editor, logarithmic: true)
        try press(UIKeyCommand.inputEscape, in: controller)
        try await eventually { session.adjustmentEditingID == nil }
        #expect(session.document?.layers.first { $0.id == id }?.adjustment?.gaussianRadius == 20)
        try await eventually { controller.presentedViewController == nil }
    }

    /// The adjustment layers the iPad has no editor for yet are dimmed wherever they're offered, and can't be opened for
    /// editing, which would hold the project with nothing to close it; those it has can.
    @Test func adjustmentKindsWithoutAnEditorAreDimmed() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        for kind in AdjustmentKind.allCases where kind != .invert {
            let new = UICommand(title: kind.rawValue, action: #selector(EditorWindowController.newAdjustmentLayer(_:)),
                                propertyList: kind.rawValue)
            #expect(controller.canPerformAction(new.action, withSender: new) == AdjustmentEditors.kinds.contains(kind), "\(kind)")
        }
        #expect(AdjustmentEditors.kinds.contains(.gaussianBlur))
        let menu = try #require(views(UIButton.self, in: controller.view).first { $0.accessibilityLabel == "New adjustment layer" }?.menu)
        for case let item as UIAction in menu.children {
            let kind = try #require(AdjustmentKind.allCases.first { item.title.hasPrefix($0.rawValue) })
            #expect(item.attributes.contains(.disabled) == !(AdjustmentEditors.kinds.contains(kind) || kind == .invert), "\(kind)")
        }
        _ = session
    }
}
