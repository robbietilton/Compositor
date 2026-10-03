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

    /// Whether every value `values` makes `row` show fits its field whole, as the Mac's filter fields show them.
    private func showsWhole(_ row: SliderField, _ values: [Double]) throws -> [String] {
        let field = try #require(views(UITextField.self, in: row).first)
        let room = field.textRect(forBounds: field.bounds).width
        return values.compactMap { value in
            row.show(value)
            let text = field.text ?? ""
            let width = (text as NSString).size(withAttributes: [.font: field.font as Any]).width
            return width <= room ? nil : "\(text) needs \(width), has \(room)"
        }
    }

    /// Every row's field shows its values whole, however many digits and decimals they have: Exposure's Offset as
    /// 0.0125.
    @Test func everyFieldShowsItsValuesWhole() throws {
        let session = EditorSession()
        session.createDocument(width: 200, height: 100)
        let context = try BrushRaster.context(width: 200, height: 100, mask: false)
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Gray"))
        func laidOut(_ editor: UIViewController) {
            editor.loadViewIfNeeded()
            editor.view.frame = CGRect(x: 0, y: 0, width: 480, height: 1400)
            editor.updatePropertiesIfNeeded()
            editor.view.layoutIfNeeded()
        }
        for (kind, rows) in FilterEditorController.rows {
            session.beginFilter(kind)
            guard session.filterEdit?.kind == kind else { continue }
            let editor = FilterEditorController(session: session, kind: kind)
            laidOut(editor)
            for row in rows {
                let field = try #require(views(SliderField.self, in: editor.view).first { views(UILabel.self, in: $0).first?.text == row.caption })
                let step = pow(10, Double(row.decimals))
                let between = ((row.range.lowerBound + (row.range.upperBound - row.range.lowerBound) * 0.3719) * step).rounded() / step
                let negative = row.range.lowerBound < 0 ? [((row.range.lowerBound * 0.0371) * step).rounded() / step] : []
                #expect(try showsWhole(field, [row.range.lowerBound, row.range.upperBound, between] + negative).isEmpty, "\(kind) \(row.caption)")
            }
            session.cancelFilter()
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

    // MARK: The slider filters

    /// The captions of the editor's slider rows, in order.
    private func captions(of editor: UIViewController) -> [String] { rows(of: editor).compactMap(\.first) }

    /// Each filter's rows are the Mac panel's, in its order.
    @Test(arguments: [(FilterKind.motionBlur, ["Angle", "Distance"]), (.addNoise, ["Amount"]), (.exposure, ["Exposure", "Offset", "Gamma"]),
                      (.grain, ["Amount", "Size", "Roughness"]), (.bloomGlow, ["Amount", "Radius"]),
                      (.tonalContrast, ["Amount", "Shadows", "Midtones", "Highlights", "Radius"]), (.lensCorrection, ["Remove Distortion"])])
    func rowsMatchTheMac(kind: FilterKind, captions expected: [String]) async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        #expect(choose(filterCommand(kind), in: controller), "\(kind)")
        let editor = try await filterEditor(over: controller)
        #expect(editor.kind == kind)
        #expect(captions(of: editor) == expected)
        if kind == .lensCorrection {
            #expect(views(UILabel.self, in: editor.view).contains { $0.text?.hasPrefix("Positive straightens lines that bow outward") == true })
        }
        session.cancelFilter()
        try await eventually { controller.presentedViewController == nil }
    }

    /// Add Noise's Distribution is Uniform or Gaussian, and Monochromatic a box to tick, as on the Mac.
    @Test func addNoiseDistributionAndMonochromatic() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        choose(filterCommand(.addNoise), in: controller)
        let editor = try await filterEditor(over: controller)
        let distribution = try #require(views(UISegmentedControl.self, in: editor.view).first)
        #expect((0..<distribution.numberOfSegments).map { distribution.titleForSegment(at: $0) } == ["Uniform", "Gaussian"])
        distribution.selectedSegmentIndex = 1
        distribution.sendActions(for: .valueChanged)
        #expect(session.filterEdit?.settings.gaussian == true)
        let monochromatic = try #require(views(UIButton.self, in: editor.view).first { $0.configuration?.title == "Monochromatic" })
        let was = session.filterEdit?.settings.monochromatic ?? false
        monochromatic.isSelected.toggle()
        monochromatic.sendActions(for: .primaryActionTriggered)
        #expect(session.filterEdit?.settings.monochromatic == !was)
        session.cancelFilter()
        try await eventually { controller.presentedViewController == nil }
    }

    /// A filter set to do nothing closes on OK without a step to undo, as on the Mac.
    @Test(arguments: [FilterKind.exposure, .lensCorrection, .bloomGlow, .tonalContrast, .grain])
    func nothingToDoClosesWithoutAStep(kind: FilterKind) async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        let steps = session.history.undoCount
        choose(filterCommand(kind), in: controller)
        let editor = try await filterEditor(over: controller)
        // Each to its value that does nothing, through the editor's own rows.
        let nothing: [Int: Double] = switch kind {
        case .exposure: [0: 0, 1: 0, 2: 1]
        default: [0: 0]
        }
        let logarithmic = FilterEditorController.rows[kind]?.map(\.logarithmic) ?? []
        for (index, value) in nothing { try slide(index, to: value, in: editor, logarithmic: logarithmic[index]) }
        try press("\r", in: controller)
        try await eventually { session.filterEdit == nil }
        #expect(session.filterEdit == nil && session.history.undoCount == steps, "\(kind)")
        try await eventually { controller.presentedViewController == nil }
    }

    /// Motion Blur, Add Noise, Exposure and Grain layers open the same editor as their menu commands, and OK keeps what's
    /// set as one step.
    @Test(arguments: [AdjustmentKind.motionBlur, .addNoise, .exposure, .grain])
    func adjustmentLayersAreEdited(kind: AdjustmentKind) async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        let new = UICommand(title: kind.rawValue, action: #selector(EditorWindowController.newAdjustmentLayer(_:)), propertyList: kind.rawValue)
        #expect(choose(new, in: controller), "\(kind)")
        let id = try #require(session.activeLayerID)
        let editor = try await filterEditor(over: controller)
        #expect(editor.kind == kind.filterKind)
        let row = try #require(FilterEditorController.rows[editor.kind]?.first)
        // Three tenths of the way along, which no row starts at.
        let step = pow(10, Double(row.decimals))
        let along = row.logarithmic ? row.range.lowerBound * pow(row.range.upperBound / row.range.lowerBound, 0.3)
            : row.range.lowerBound + (row.range.upperBound - row.range.lowerBound) * 0.3
        let value = (along * step).rounded() / step
        try #require(value != FilterSettings()[keyPath: row.key])
        try slide(0, to: value, in: editor, logarithmic: row.logarithmic)
        try press("\r", in: controller)
        try await eventually { session.adjustmentEditingID == nil && session.filterEdit == nil }
        #expect(session.history.undoName == "Edit \(kind.rawValue) Adjustment")
        try await eventually { controller.presentedViewController == nil }
        // The layer keeps it: opened again, the editor starts from it.
        session.adjustmentEditingID = id
        try await eventually { session.filterEdit != nil }
        let kept = try #require(session.filterEdit?.settings[keyPath: row.key])
        #expect(abs(kept - value) < 0.5 / step, "\(kind) \(row.caption): \(kept), not \(value)")
        session.cancelFilter()
        try await eventually { controller.presentedViewController == nil }
    }

    // MARK: Content-Aware Fill

    /// Selects `rect`, in document pixels, as a marquee does.
    private func select(_ rect: CGRect, in session: EditorSession) {
        session.document?.selection = DocumentSelection(path: CGPath(rect: rect, transform: nil), antialiased: false)
    }

    /// The active layer's pixel at (`x`, `y`), its red, green and blue.
    private func pixel(_ session: EditorSession, x: Int, y: Int) throws -> (Int, Int, Int) {
        let context = try BrushRaster.copy(try #require(session.activeLayer?.asset?.image))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let i = y * context.bytesPerRow + x * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }

    /// Whether `editor`'s OK can be pressed.
    private func okEnabled(_ editor: UIViewController) throws -> Bool {
        try #require(views(UIButton.self, in: editor.view).first { $0.configuration?.title == "OK" }).isEnabled
    }

    /// Edit › Content-Aware Fill… needs a selection to fill, as on the Mac.
    @Test func contentAwareFillNeedsASelection() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        let fill = filterCommand(.contentAwareFill)
        #expect(!controller.canPerformAction(fill.action, withSender: fill))
        select(CGRect(x: 80, y: 30, width: 40, height: 40), in: session)
        #expect(controller.canPerformAction(fill.action, withSender: fill))
    }

    /// While the fill is worked out the editor says so and OK waits, Return too, as the Mac's disabled OK does; once it's
    /// ready OK fills the selection, as one step to undo.
    @Test func itWaitsThenFills() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        // A white square on the gray, selected: filled from the gray around it.
        let context = try BrushRaster.context(width: 200, height: 100, mask: false)
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 90, y: 40, width: 20, height: 20))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Square"))
        select(CGRect(x: 85, y: 35, width: 30, height: 30), in: session)
        try #require(pixel(session, x: 100, y: 50) == (255, 255, 255))
        #expect(choose(filterCommand(.contentAwareFill), in: controller))
        let editor = try await filterEditor(over: controller)
        #expect(views(UILabel.self, in: editor.view).contains { $0.text == "Fill the selection using surrounding pixels from this layer." })
        try await eventually { session.filterEdit?.preparing == false }
        // Still working: as before the fill is ready.
        session.filterEdit?.preparing = true
        editor.updatePropertiesIfNeeded()
        #expect(views(UILabel.self, in: editor.view).contains { $0.text == "Working…" && !$0.isHidden })
        #expect(try !okEnabled(editor))
        try press("\r", in: controller)
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.filterEdit != nil)
        session.filterEdit?.preparing = false
        editor.updatePropertiesIfNeeded()
        #expect(try okEnabled(editor))
        try press("\r", in: controller)
        try await eventually { session.filterEdit == nil }
        #expect(session.history.undoName == "Content-Aware Fill")
        #expect(try pixel(session, x: 100, y: 50) != (255, 255, 255))
        try await eventually { controller.presentedViewController == nil }
    }

    /// With nothing around the selection to fill from, the editor says why in orange, as the Mac's does, and OK can't be
    /// pressed.
    @Test func withNothingToFillFromItSaysWhy() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        session.selectAll()
        #expect(choose(filterCommand(.contentAwareFill), in: controller))
        let editor = try await filterEditor(over: controller)
        try await eventually { session.filterEdit?.previewError != nil }
        editor.updatePropertiesIfNeeded()
        let error = try #require(session.filterEdit?.previewError)
        #expect(views(UILabel.self, in: editor.view).contains { $0.text == error && !$0.isHidden && $0.textColor == .systemOrange })
        #expect(try !okEnabled(editor))
        session.cancelFilter()
        try await eventually { controller.presentedViewController == nil }
    }

    /// A selection reaching past the layer's edge fills there too, the layer growing over it, as on the Mac.
    @Test func itFillsPastTheLayersEdge() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        let index = try #require(session.document?.layers.firstIndex { $0.id == session.activeLayerID })
        session.document?.layers[index].transform.origin = CGPoint(x: -60, y: 0)
        select(CGRect(x: 120, y: 30, width: 40, height: 40), in: session)
        try #require(session.activeLayer.map { $0.transform.origin.x + $0.transform.size.width } == 140)
        #expect(choose(filterCommand(.contentAwareFill), in: controller))
        _ = try await filterEditor(over: controller)
        try await eventually { session.filterEdit?.preparing == false }
        try press("\r", in: controller)
        try await eventually { session.filterEdit == nil }
        let grown = try #require(session.activeLayer?.transform)
        #expect(grown.origin.x + grown.size.width >= 160)
        try await eventually { controller.presentedViewController == nil }
    }

    // MARK: Remove Background

    /// The captions of the editor's slider rows that show, in order.
    private func shownCaptions(of editor: UIViewController) -> [String] {
        views(SliderField.self, in: editor.view).filter { row in
            var view: UIView? = row
            while let current = view, current !== editor.view {
                if current.isHidden { return false }
                view = current.superview
            }
            return true
        }.compactMap { row in views(UILabel.self, in: row).first?.text }
    }

    /// Remove Background says what it does, and chooses Basic or Advanced; Advanced shows Refine, Contrast and Shift
    /// Edge, and the editor grows to hold them, as on the Mac.
    @Test func advancedShowsItsRows() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        #expect(choose(filterCommand(.removeBackground), in: controller))
        let editor = try await filterEditor(over: controller)
        #expect(views(UILabel.self, in: editor.view).contains { $0.text?.hasPrefix("Hide the background behind a layer mask") == true })
        let quality = try #require(views(UISegmentedControl.self, in: editor.view).first)
        #expect((0..<quality.numberOfSegments).map { quality.titleForSegment(at: $0) } == ["Basic", "Advanced"])
        let help = quality.interactions.compactMap { $0 as? UIToolTipInteraction }.first?.defaultToolTip
        #expect(help?.hasPrefix("Basic is quick") == true)
        #expect(shownCaptions(of: editor) == [])
        let short = editor.preferredContentSize.height
        quality.selectedSegmentIndex = 1
        quality.sendActions(for: .valueChanged)
        #expect(session.filterEdit?.settings.backgroundQuality == .advanced)
        editor.updatePropertiesIfNeeded()
        editor.view.layoutIfNeeded()
        #expect(shownCaptions(of: editor) == ["Refine", "Contrast", "Shift Edge"])
        #expect(editor.preferredContentSize.height > short)
        session.cancelFilter()
        try await eventually { controller.presentedViewController == nil }
    }

    /// While the mask is worked out, or when it can't be, OK waits; a change of settings works it out again, and the
    /// editor says so; applying, it says so too.
    @Test func removeBackgroundWaitsForItsMask() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        choose(filterCommand(.removeBackground), in: controller)
        let editor = try await filterEditor(over: controller)
        func says(_ text: String) -> Bool { views(UILabel.self, in: editor.view).contains { $0.text == text && !$0.isHidden } }
        // The simulator has no Vision to find a subject with, so the first mask ends in an error.
        try await eventually { session.filterEdit?.preparing == false }
        session.filterEdit?.previewError = "No subject"
        editor.updatePropertiesIfNeeded()
        #expect(try says("No subject") && !okEnabled(editor))
        let quality = try #require(views(UISegmentedControl.self, in: editor.view).first)
        quality.selectedSegmentIndex = 1
        quality.sendActions(for: .valueChanged)
        #expect(session.filterEdit?.preparing == true)
        editor.updatePropertiesIfNeeded()
        #expect(try says("Working…") && !okEnabled(editor))
        try await eventually { session.filterEdit?.preparing == false }
        session.filterEdit?.previewError = nil
        session.filterEdit?.committing = true
        editor.updatePropertiesIfNeeded()
        #expect(says("Applying…"))
        session.filterEdit?.committing = false
        session.cancelFilter()
        try await eventually { controller.presentedViewController == nil }
    }
}
