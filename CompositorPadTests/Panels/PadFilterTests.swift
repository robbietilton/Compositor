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
    /// 0.0125, an effect's Distance as 5000.
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
        for kind in LayerEffectKind.allCases {
            session.addEffect(kind)
            let selection = try #require(session.effectsEditing)
            let editor = EffectEditorController(session: session, selection: selection)
            laidOut(editor)
            for (row, field) in zip(EffectEditorController.rows[kind] ?? [], views(SliderField.self, in: editor.view)) {
                #expect(try showsWhole(field, [row.field.lowerBound, row.field.upperBound]).isEmpty, "\(kind) \(row.caption)")
            }
            session.finishEffectsEditing(commit: false)
        }
    }

    /// The editors' own rows line up after their captions, the Color caption's too, and a drag along a caption moves the
    /// value a row's step a point, as the Mac's panels do.
    @Test func anEditorsRowsLineUpAndScrubByTheirStep() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        choose(filterCommand(.vignette), in: controller)
        var editor = try await filterEditor(over: controller)
        let starts = views(SliderField.self, in: editor.view).compactMap { views(UISlider.self, in: $0).first }
            .map { $0.convert($0.bounds, to: editor.view).minX }
        let swatch = try #require(views(SwatchButton.self, in: editor.view).first)
        #expect(starts.count == 5 && Set(starts).count == 1, "\(starts)")
        #expect(abs(swatch.convert(swatch.bounds, to: editor.view).minX - (starts.first ?? 0)) < 1)
        session.cancelFilter()
        try await eventually { controller.presentedViewController == nil }

        choose(filterCommand(.gaussianBlur), in: controller)
        editor = try await filterEditor(over: controller)
        let radius = try #require(views(SliderField.self, in: editor.view).first)
        #expect(abs(radius.scrubbed(from: 10, by: 3) - 10.3) < 0.0001)
        session.cancelFilter()
        try await eventually { controller.presentedViewController == nil }
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
    @Test(arguments: [AdjustmentKind.motionBlur, .addNoise, .exposure, .grain, .blackWhite, .colorBalance])
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

    // MARK: Black & White and Color Balance

    /// The editor's row captioned `caption`.
    private func row(_ caption: String, in editor: UIViewController) throws -> SliderField {
        try #require(views(SliderField.self, in: editor.view).first { views(UILabel.self, in: $0).first?.text == caption }, "\(caption)")
    }

    /// Image › Black & White… has a row for each family of colors, at Photoshop's defaults, each with the Mac's track,
    /// dark to light in that family's hue; Tint adds Hue and Saturation, whose track follows the hue, and the editor
    /// grows to hold them.
    @Test func blackWhitesRows() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        #expect(choose(filterCommand(.blackWhite), in: controller))
        let editor = try await filterEditor(over: controller)
        let families = ["Reds", "Yellows", "Greens", "Cyans", "Blues", "Magentas"]
        #expect(shownCaptions(of: editor) == families)
        for (index, family) in families.enumerated() {
            let row = try row(family, in: editor)
            #expect(row.track == .luminance(Double(index) * 60), "\(family)")
            #expect(views(UITextField.self, in: row).first?.text == ["40", "60", "40", "60", "20", "80"][index], "\(family)")
        }
        let short = editor.preferredContentSize.height
        let tint = try #require(views(UIButton.self, in: editor.view).first { $0.configuration?.title == "Tint" })
        tint.isSelected = true
        tint.sendActions(for: .primaryActionTriggered)
        #expect(session.filterEdit?.settings.blackWhite.tint == true)
        editor.updatePropertiesIfNeeded()
        editor.view.layoutIfNeeded()
        #expect(shownCaptions(of: editor) == families + ["Hue", "Saturation"])
        #expect(editor.preferredContentSize.height > short)
        #expect(try row("Hue", in: editor).track == .plain && row("Saturation", in: editor).track == .saturation(40))
        try row("Hue", in: editor).onChange(200)
        editor.updatePropertiesIfNeeded()
        #expect(try row("Saturation", in: editor).track == .saturation(200))
        session.cancelFilter()
        try await eventually { controller.presentedViewController == nil }
    }

    /// A double tap on a colored row's caption puts its value back, as on the Mac: Reds to 40, and Tint's Hue, which
    /// has the system's track, to 40 too.
    @Test func aDoubleTapResetsAColoredRow() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        choose(filterCommand(.blackWhite), in: controller)
        let editor = try await filterEditor(over: controller)
        var settings = try #require(session.filterEdit?.settings)
        settings.blackWhite.reds = 150
        settings.blackWhite.tint = true
        settings.blackWhite.tintHue = 200
        session.updateFilter(settings, preview: true)
        editor.updatePropertiesIfNeeded()
        editor.view.layoutIfNeeded()
        for caption in ["Reds", "Hue"] {
            let row = try row(caption, in: editor)
            let label = try #require(views(UILabel.self, in: row).first)
            #expect(row.resets(at: label.convert(CGPoint(x: label.bounds.midX, y: label.bounds.midY), to: row)), "\(caption)")
        }
        #expect(session.filterEdit?.settings.blackWhite.reds == 40 && session.filterEdit?.settings.blackWhite.tintHue == 40)
        session.cancelFilter()
        try await eventually { controller.presentedViewController == nil }
    }

    /// A value typed past a slider's end is held to it, as on the Mac now: Reds at 400 is 300, and the preview works.
    @Test func aValueTypedPastTheEndIsHeldToIt() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        choose(filterCommand(.blackWhite), in: controller)
        let editor = try await filterEditor(over: controller)
        let field = try #require(views(NumberField.self, in: try row("Reds", in: editor)).first)
        field.field.text = "400"
        field.textFieldDidEndEditing(field.field)
        #expect(session.filterEdit?.settings.blackWhite.reds == 300)
        try await eventually { session.filterEdit?.preparing == false }
        #expect(session.filterEdit?.previewError == nil)
        session.cancelFilter()
        try await eventually { controller.presentedViewController == nil }
    }

    /// Image › Color Balance… has the Mac's three sections, Shadows, Midtones and Highlights, each with three rows whose
    /// tracks run from each color to its opposite, and Preserve Luminosity, on at first.
    @Test func colorBalancesRows() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        #expect(choose(filterCommand(.colorBalance), in: controller))
        let editor = try await filterEditor(over: controller)
        let labels = views(UILabel.self, in: editor.view).compactMap(\.text)
        #expect(["Shadows", "Midtones", "Highlights"].allSatisfy(labels.contains))
        let rows = views(SliderField.self, in: editor.view)
        #expect(rows.compactMap { views(UILabel.self, in: $0).first?.text } == Array(repeating: ["Cyan / Red", "Magenta / Green", "Yellow / Blue"], count: 3).flatMap { $0 })
        #expect(rows.map(\.track) == Array(repeating: [CameraRawSliderTrack.cyanRed, .magentaGreen, .yellowBlue], count: 3).flatMap { $0 })
        let preserve = try #require(views(UIButton.self, in: editor.view).first { $0.configuration?.title == "Preserve Luminosity" })
        #expect(preserve.isSelected && session.filterEdit?.settings.colorBalance.preserveLuminosity == true)
        // The middle row of Midtones is Midtones' Magenta / Green.
        rows[4].onChange(-35)
        #expect(session.filterEdit?.settings.colorBalance.midMagentaGreen == -35)
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

    // MARK: Vignette and colors

    /// Filter › Vignette… frames an empty layer too, as on the Mac, filling the canvas.
    @Test func vignetteFramesAnEmptyLayer() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        session.addBlankLayer()
        try #require(session.activeLayer?.asset == nil)
        #expect(choose(filterCommand(.vignette), in: controller))
        let editor = try await filterEditor(over: controller)
        #expect(captions(of: editor) == ["Amount", "Midpoint", "Roundness", "Feather", "Highlights"])
        try press("\r", in: controller)
        try await eventually { session.filterEdit == nil }
        #expect(session.activeLayer?.asset != nil && session.activeLayer?.transform.size == CGSize(width: 200, height: 100))
        try await eventually { controller.presentedViewController == nil }
    }

    /// A vignette of no amount closes on OK without a step to undo.
    @Test func noVignetteLeavesNoStep() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        let steps = session.history.undoCount
        choose(filterCommand(.vignette), in: controller)
        let editor = try await filterEditor(over: controller)
        try slide(0, to: 0, in: editor, logarithmic: false)
        try press("\r", in: controller)
        try await eventually { session.filterEdit == nil }
        #expect(session.history.undoCount == steps)
        try await eventually { controller.presentedViewController == nil }
    }

    /// The editor's color swatch, with the editor open and its color picker showing over it.
    private func pickingVignetteColor() async throws -> (window: UIWindow, controller: EditorWindowController, session: EditorSession,
                                                         editor: FilterEditorController, picker: UIColorPickerViewController) {
        let (window, controller, session) = try await shownWindow()
        choose(filterCommand(.vignette), in: controller)
        let editor = try await filterEditor(over: controller)
        let swatch = try #require(views(SwatchButton.self, in: editor.view).first)
        #expect(swatch.accessibilityLabel == "Color")
        swatch.sendActions(for: .primaryActionTriggered)
        #expect(session.colorPicker?.target == .vignette)
        try await eventually { editor.presentedViewController is UIColorPickerViewController }
        let picker = try #require(editor.presentedViewController as? UIColorPickerViewController)
        return (window, controller, session, editor, picker)
    }

    /// A finger can take a swatch from a little way off, above or below it too, though its row is only as tall as the
    /// swatch: 44 points a side, as decision 10 asked.
    @Test func aSwatchTakesATouchFromALittleWayOff() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        choose(filterCommand(.vignette), in: controller)
        let editor = try await filterEditor(over: controller)
        // Once the popover has given the editor its size.
        try await eventually { editor.view.bounds.height > 0 }
        editor.view.layoutIfNeeded()
        let swatch = try #require(views(SwatchButton.self, in: editor.view).first)
        let middle = swatch.convert(CGPoint(x: swatch.bounds.midX, y: swatch.bounds.midY), to: editor.view)
        for offset in [CGPoint(x: 0, y: -18), CGPoint(x: 0, y: 18), CGPoint(x: 18, y: 0)] {
            let hit = editor.view.hitTest(CGPoint(x: middle.x + offset.x, y: middle.y + offset.y), with: nil)
            #expect(hit === swatch, "\(offset)")
        }
        #expect(editor.view.hitTest(CGPoint(x: middle.x, y: middle.y - 30), with: nil) !== swatch)
        session.cancelFilter()
        try await eventually { controller.presentedViewController == nil }
    }

    /// The Color swatch opens the color picker over the editor, and the canvas shows the color as it's picked.
    @Test func theSwatchPicksAndPreviews() async throws {
        let (window, controller, session, _, picker) = try await pickingVignetteColor()
        defer { window.isHidden = true }
        picker.delegate?.colorPickerViewController?(picker, didSelect: .red, continuously: false)
        let color = try #require(session.filterEdit?.settings.vignetteColor)
        #expect(color.red == 1 && color.green == 0 && color.blue == 0)
        session.cancelFilter()
        try await eventually { controller.presentedViewController == nil }
    }

    /// Escape with the picker up puts the color back and closes the picker, as the Mac picker's Cancel; Return keeps it,
    /// as its OK. The editor stays.
    @Test func escapeRestoresAndReturnKeepsThePickersColor() async throws {
        let (window, controller, session, editor, picker) = try await pickingVignetteColor()
        defer { window.isHidden = true }
        let original = try #require(session.filterEdit?.settings.vignetteColor)
        picker.delegate?.colorPickerViewController?(picker, didSelect: .red, continuously: false)
        try press(UIKeyCommand.inputEscape, in: controller)
        #expect(session.colorPicker == nil && session.filterEdit?.settings.vignetteColor == original)
        try await eventually { editor.presentedViewController == nil }
        #expect(editor.presentedViewController == nil)
        #expect(controller.presentedViewController === editor && session.filterEdit != nil)

        let swatch = try #require(views(SwatchButton.self, in: editor.view).first)
        swatch.sendActions(for: .primaryActionTriggered)
        try await eventually { editor.presentedViewController is UIColorPickerViewController }
        let again = try #require(editor.presentedViewController as? UIColorPickerViewController)
        again.delegate?.colorPickerViewController?(again, didSelect: .red, continuously: false)
        try press("\r", in: controller)
        #expect(session.colorPicker == nil && session.filterEdit?.settings.vignetteColor.red == 1)
        try await eventually { editor.presentedViewController == nil }
        #expect(editor.presentedViewController == nil)
        #expect(controller.presentedViewController === editor && session.filterEdit != nil)
        session.cancelFilter()
        try await eventually { controller.presentedViewController == nil }
    }

    /// Cancel with the picker up closes both, picker and editor.
    @Test func cancelWithThePickerUpClosesBoth() async throws {
        let (window, controller, session, _, _) = try await pickingVignetteColor()
        defer { window.isHidden = true }
        session.cancelFilter()
        try await eventually { controller.presentedViewController == nil }
        #expect(controller.presentedViewController == nil && session.colorPicker == nil)
    }

    /// Closing the tab with the picker up takes both with it.
    @Test func closingTheTabWithThePickerUpTakesBoth() async throws {
        let (window, controller, session, _, _) = try await pickingVignetteColor()
        defer { window.isHidden = true }
        let url = controller.activeTab?.document?.fileURL
        controller.closeTab(nil)
        try await eventually { controller.presentedViewController == nil }
        #expect(controller.presentedViewController == nil && session.colorPicker == nil)
        if let url { try? FileManager.default.removeItem(at: url) }
    }
}
