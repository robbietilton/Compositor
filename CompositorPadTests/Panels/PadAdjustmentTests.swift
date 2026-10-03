import CoreGraphics
import Testing
import UIKit
@testable import Compositor

/// Adjustments on iPad: adjustment layers and their editors, as the Mac's panels edit them.
@MainActor struct PadAdjustmentTests {
    /// A 200 × 100 canvas with one gray layer on it.
    private func session() throws -> EditorSession {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 200, height: 100), backingScale: 1, documentSize: nil)
        session.createDocument(width: 200, height: 100)
        let context = try BrushRaster.context(width: 200, height: 100, mask: false)
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Gray"))
        return session
    }

    /// The input triangles keep black and white a level apart, and the gray one sets gamma by where it stands between
    /// them: halfway is 1, a quarter of the way is 2.
    @Test func theLevelsTrianglesSetTheInputRange() {
        var range = LevelRange()
        range = LevelsEditorController.range(range, input: 0, at: 30.4)
        #expect(range.black == 30)
        range = LevelsEditorController.range(range, input: 2, at: 10)
        #expect(range.white == 31)
        range = LevelRange(black: 0, gamma: 1, white: 200)
        #expect(abs(LevelsEditorController.range(range, input: 1, at: 100).gamma - 1) < 0.0001)
        #expect(abs(LevelsEditorController.range(range, input: 1, at: 50).gamma - 2) < 0.0001)
    }

    /// A press grabs the nearest point within reach, or else adds one there; a dragged point keeps between its
    /// neighbors, and the end points move only up and down, as on the Mac.
    @Test func aCurveIsShapedAsOnTheMac() {
        var points = [CurvePoint(x: 0, y: 0), CurvePoint(x: 255, y: 255)]
        let added = CurveEditing.press(&points, x: 128, y: 160)
        #expect(added == 1)
        #expect(points.count == 3)
        #expect(CurveEditing.press(&points, x: 132, y: 150) == 1)
        #expect(points.count == 3)
        CurveEditing.drag(&points, index: 1, x: 300, y: 170)
        #expect(points[1] == CurvePoint(x: 254, y: 170))
        CurveEditing.drag(&points, index: 0, x: 60, y: 20)
        #expect(points[0] == CurvePoint(x: 0, y: 20))
        // No room right by an end.
        #expect(CurveEditing.press(&points, x: 0.5, y: 200, reach: 0) == nil)
    }

    /// A new Levels layer opens its editor on the pixels beneath it; OK keeps what was set, as one step to undo.
    @Test func aLevelsLayerIsEditedAndKept() async throws {
        let session = try session()
        session.addAdjustment(.levels)
        let id = try #require(session.adjustmentEditingID)
        await session.beginAdjustmentEditing(id)

        let editor = try #require(AdjustmentEditors.editor(for: session) as? LevelsEditorController)
        editor.loadViewIfNeeded()
        #expect(editor.isOpen)
        var settings = try #require(session.levels?.settings)
        settings.current = LevelsEditorController.range(settings.current, input: 0, at: 40)
        session.updateLevels(settings, preview: true)
        await session.commitLevels()

        #expect(!editor.isOpen)
        #expect(session.adjustmentEditingID == nil)
        #expect(session.document?.layers.first { $0.id == id }?.adjustment?.levels.ranges[0].black == 40)
        #expect(session.history.undoName == "Edit Levels Adjustment")
    }

    /// Cancel leaves a Hue/Saturation layer as it was.
    @Test func cancelLeavesTheLayerAsItWas() async throws {
        let session = try session()
        session.addAdjustment(.hsv)
        let id = try #require(session.adjustmentEditingID)
        await session.beginAdjustmentEditing(id)
        let editor = try #require(AdjustmentEditors.editor(for: session) as? HueSaturationEditorController)
        editor.loadViewIfNeeded()
        var settings = try #require(session.hueSaturation?.settings)
        settings.hue = 90
        session.updateHueSaturation(settings, preview: true)
        editor.cancel()

        #expect(session.hueSaturation == nil)
        #expect(session.document?.layers.first { $0.id == id }?.adjustment?.resolvedHSV.hue == 0)
    }

    /// Curves applied to a layer's own pixels opens the Curves editor, as Image › Curves does.
    @Test func curvesFromTheImageMenuOpensItsEditor() throws {
        let session = try session()
        session.beginFilter(.curves)
        #expect(AdjustmentEditors.editor(for: session) is CurvesEditorController)
        session.cancelFilter()
        #expect(AdjustmentEditors.editor(for: session) == nil)
    }

    /// An adjustment the iPad has no editor for yet can't be opened for editing, which would hold the project with
    /// nothing to close it; one it has can.
    @Test func onlyAdjustmentsWithAnEditorOpen() throws {
        let window = EditorWindowController()
        window.loadViewIfNeeded()
        let tab = try #require(window.activeTab)
        tab.session.createNewProject(width: 100, height: 100)
        tab.session.addAdjustment(.invert)
        #expect(!window.canPerformAction(#selector(EditorWindowController.editAdjustment(_:)), withSender: nil))
        tab.session.addAdjustment(.levels)
        tab.session.adjustmentEditingID = nil
        #expect(window.canPerformAction(#selector(EditorWindowController.editAdjustment(_:)), withSender: nil))
    }

    // MARK: Keys

    /// A window controller on the app's screen, its tab in front holding a 200 × 100 project with a gray layer, once
    /// it has appeared.
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

    /// Presses the window's key for `input` with `flags`, as the keyboard does once the window takes it; false when it
    /// doesn't.
    @discardableResult
    private func press(_ input: String, _ flags: UIKeyModifierFlags = [], in controller: UIResponder) -> Bool {
        guard let command = controller.keyCommands?.first(where: { $0.input == input && $0.modifierFlags == flags }),
              let action = command.action, controller.canPerformAction(action, withSender: command) else { return false }
        controller.perform(action, with: command)
        return true
    }

    /// Escape cancels an adjustment's editor and Return applies it, as the Mac's do, though the keyboard is the
    /// canvas's beside it.
    @Test func escapeAndReturnAnswerTheEditor() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        controller.levels(nil)
        try await eventually { controller.presentedViewController is LevelsEditorController }
        try #require(controller.presentedViewController is LevelsEditorController)
        #expect(press(UIKeyCommand.inputEscape, in: controller))
        #expect(session.levels == nil)
        try await eventually { controller.presentedViewController == nil }

        controller.levels(nil)
        try await eventually { controller.presentedViewController is LevelsEditorController }
        var settings = try #require(session.levels?.settings)
        settings.current = LevelsEditorController.range(settings.current, input: 0, at: 40)
        session.updateLevels(settings, preview: true)
        #expect(press("\r", in: controller))
        try await eventually { session.levels == nil }
        #expect(session.history.undoName == "Levels")
        try await eventually { controller.presentedViewController == nil }
    }

    /// Option-P turns Levels' preview off and on, as on the Mac; Curves has no such key, and Escape cancels it too.
    @Test func optionPTurnsLevelsPreviewOffAndOn() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        controller.levels(nil)
        try await eventually { controller.presentedViewController is LevelsEditorController }
        #expect(session.levels?.preview == true)
        #expect(press("p", .alternate, in: controller))
        #expect(session.levels?.preview == false)
        #expect(press("p", .alternate, in: controller))
        #expect(session.levels?.preview == true)
        session.cancelLevels()
        try await eventually { controller.presentedViewController == nil }

        controller.curves(nil)
        try await eventually { controller.presentedViewController is CurvesEditorController }
        #expect(!press("p", .alternate, in: controller))
        #expect(press(UIKeyCommand.inputEscape, in: controller))
        #expect(session.filterEdit == nil)
        try await eventually { controller.presentedViewController == nil }
    }

    /// The views of `type` in `view`, depth first.
    private func views<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        view.subviews.flatMap { subview -> [T] in ((subview as? T).map { [$0] } ?? []) + views(type, in: subview) }
    }

    /// The `index`th of the editor's fields that shows, with the keyboard, once the editor has settled.
    private func focusedField(_ index: Int, in editor: AdjustmentEditorController) async throws -> NumberField {
        func field() -> NumberField? {
            editor.view.layoutIfNeeded()
            let fields = views(NumberField.self, in: editor.view).filter { $0.window != nil && $0.field.bounds.width > 0 }
            return fields.indices.contains(index) ? fields[index] : nil
        }
        try await eventually { field()?.field.becomeFirstResponder() == true }
        let found = try #require(field())
        try #require(found.field.isFirstResponder)
        return found
    }

    /// Escape in one of the editor's own fields cancels it, as on the Mac, where the field passes it to Cancel.
    @Test func escapeInAnEditorsFieldCancelsIt() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        session.beginHueSaturation()
        try await eventually { controller.presentedViewController is HueSaturationEditorController }
        let editor = try #require(controller.presentedViewController as? HueSaturationEditorController)
        _ = try await focusedField(1, in: editor)
        #expect(press(UIKeyCommand.inputEscape, in: editor))
        #expect(session.hueSaturation == nil)
        try await eventually { controller.presentedViewController == nil }
    }

    /// Return in one of Hue/Saturation's fields applies it with the value typed, as on the Mac.
    @Test func returnInHueSaturationsFieldsAppliesIt() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        session.beginHueSaturation()
        try await eventually { controller.presentedViewController is HueSaturationEditorController }
        let editor = try #require(controller.presentedViewController as? HueSaturationEditorController)
        // Hue, Saturation, then Lightness.
        let lightness = try await focusedField(2, in: editor)
        lightness.field.text = "40"
        _ = lightness.field.delegate?.textFieldShouldReturn?(lightness.field)
        try await eventually { session.hueSaturation == nil }
        #expect(session.hueSaturation == nil)
        #expect(session.history.undoName == "Hue/Saturation")
        let context = try BrushRaster.copy(try #require(session.activeLayer?.asset?.image))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        #expect(bytes[50 * context.bytesPerRow + 100 * 4] > 160)
        try await eventually { controller.presentedViewController == nil }
    }

    /// Return in one of Levels' fields only ends the typing, as on the Mac, where the field keeps it.
    @Test func returnInLevelsFieldsKeepsItOpen() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        controller.levels(nil)
        try await eventually { controller.presentedViewController is LevelsEditorController }
        let editor = try #require(controller.presentedViewController as? LevelsEditorController)
        let field = try await focusedField(0, in: editor)
        _ = field.field.delegate?.textFieldShouldReturn?(field.field)
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.levels != nil && controller.presentedViewController is LevelsEditorController)
        session.cancelLevels()
        try await eventually { controller.presentedViewController == nil }
    }

    // MARK: Layout

    /// The editor of `type` the window shows, once it shows it.
    private func editor<T: AdjustmentEditorController>(_ type: T.Type, over controller: EditorWindowController) async throws -> T {
        try await eventually { controller.presentedViewController is T }
        let editor = try #require(controller.presentedViewController as? T)
        editor.view.layoutIfNeeded()
        return editor
    }

    /// The titles of the buttons in the row holding the one titled `title`, in order.
    private func rowTitles(holding title: String, in editor: UIViewController) throws -> [String] {
        let button = try #require(views(UIButton.self, in: editor.view).first { $0.configuration?.title == title }, "\(title)")
        let row = try #require(button.superview as? UIStackView)
        return row.arrangedSubviews.compactMap { ($0 as? UIButton)?.configuration?.title }
    }

    /// The titles of every button in `editor`.
    private func buttonTitles(in editor: UIViewController) -> [String] {
        views(UIButton.self, in: editor.view).compactMap { $0.configuration?.title }
    }

    /// Whether `editor` shows a label reading `text`, none of its own or its containers' hidden.
    private func shows(_ text: String, in editor: UIViewController) -> Bool {
        views(UILabel.self, in: editor.view).contains { label in
            guard label.text == text else { return false }
            var view: UIView? = label
            while let current = view, current !== editor.view {
                if current.isHidden { return false }
                view = current.superview
            }
            return true
        }
    }

    /// Each editor lays out as its Mac panel: its own controls, then Preview in the row the Mac gives it, then Cancel and
    /// OK apart along the foot. Curves resets its curve among its own controls.
    @Test func editorsLayOutAsTheMac() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        controller.levels(nil)
        let levels = try await editor(LevelsEditorController.self, over: controller)
        #expect(try rowTitles(holding: "Preview", in: levels) == ["Preview", "Reset"])
        #expect(try rowTitles(holding: "OK", in: levels) == ["Cancel", "OK"])
        session.cancelLevels()
        try await eventually { controller.presentedViewController == nil }

        session.beginHueSaturation()
        let hue = try await editor(HueSaturationEditorController.self, over: controller)
        #expect(try rowTitles(holding: "Preview", in: hue) == ["Colorize", "Preview", "Reset"])
        #expect(try rowTitles(holding: "OK", in: hue) == ["Cancel", "OK"])
        session.cancelHueSaturation()
        try await eventually { controller.presentedViewController == nil }

        controller.curves(nil)
        let curves = try await editor(CurvesEditorController.self, over: controller)
        #expect(try rowTitles(holding: "Preview", in: curves) == ["Preview"])
        #expect(try rowTitles(holding: "OK", in: curves) == ["Cancel", "OK"])
        let titles = buttonTitles(in: curves)
        #expect(titles.contains("Reset curve") && titles.contains("Remove point") && !titles.contains("Reset"))
        session.cancelFilter()
        try await eventually { controller.presentedViewController == nil }
    }

    /// Hue/Saturation and Curves say when the selection limits them, as the Mac's do, but not on an adjustment layer,
    /// which a selection doesn't limit; Levels says which pixels its histogram reads instead.
    @Test func editorsSayWhenTheSelectionLimitsThem() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        session.selectAll()
        session.beginHueSaturation()
        let hue = try await editor(HueSaturationEditorController.self, over: controller)
        #expect(shows("Limited to the selection", in: hue))
        session.cancelHueSaturation()
        try await eventually { controller.presentedViewController == nil }

        controller.curves(nil)
        let curves = try await editor(CurvesEditorController.self, over: controller)
        #expect(shows("Limited to the selection", in: curves))
        session.cancelFilter()
        try await eventually { controller.presentedViewController == nil }

        controller.levels(nil)
        let levels = try await editor(LevelsEditorController.self, over: controller)
        #expect(!shows("Limited to the selection", in: levels))
        #expect(shows("Original pixels · selection and alpha-weighted histogram", in: levels))
        session.cancelLevels()
        try await eventually { controller.presentedViewController == nil }

        session.addAdjustment(.hsv)
        let layer = try await editor(HueSaturationEditorController.self, over: controller)
        #expect(session.selection != nil && !shows("Limited to the selection", in: layer))
        session.cancelHueSaturation()
        try await eventually { controller.presentedViewController == nil }
    }

    /// While OK applies the edit, Levels shows a spinner by it and Curves says "Applying…", as their Mac panels do, and
    /// neither takes a touch meanwhile.
    @Test func applyingShowsWhatTheMacShows() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        func spinning(_ editor: UIViewController) -> Bool {
            views(UIActivityIndicatorView.self, in: editor.view).contains { $0.isAnimating && !$0.isHidden }
        }
        controller.levels(nil)
        let levels = try await editor(LevelsEditorController.self, over: controller)
        #expect(!spinning(levels))
        session.levels?.committing = true
        try await eventually { spinning(levels) }
        #expect(spinning(levels) && !shows("Applying…", in: levels) && !levels.view.isUserInteractionEnabled)
        session.levels?.committing = false
        session.cancelLevels()
        try await eventually { controller.presentedViewController == nil }

        controller.curves(nil)
        let curves = try await editor(CurvesEditorController.self, over: controller)
        #expect(!spinning(curves) && !shows("Applying…", in: curves))
        session.filterEdit?.committing = true
        try await eventually { shows("Applying…", in: curves) }
        #expect(spinning(curves) && shows("Applying…", in: curves) && !curves.view.isUserInteractionEnabled)
        session.filterEdit?.committing = false
        session.cancelFilter()
        try await eventually { controller.presentedViewController == nil }
    }

    /// Whether the editor's button titled `title` has its own height, not squashed to fit.
    private func keepsItsHeight(_ title: String, in editor: UIViewController) throws -> Bool {
        let button = try #require(views(UIButton.self, in: editor.view).first { $0.configuration?.title == title })
        return button.bounds.height >= button.intrinsicContentSize.height - 0.5
    }

    /// An editor given less room than it needs scrolls, its Cancel and OK still in view, as the keyboard or a short
    /// window would otherwise push them off; its controls keep their size.
    @Test func aTallEditorScrolls() throws {
        let session = try session()
        session.beginLevels()
        let editor = LevelsEditorController(session: session)
        editor.loadViewIfNeeded()
        editor.view.frame = CGRect(x: 0, y: 0, width: 440, height: 1200)
        editor.view.layoutIfNeeded()
        let tall = editor.preferredContentSize.height
        try #require(tall > 400)
        editor.view.frame.size.height = 300
        editor.view.layoutIfNeeded()
        let scroll = try #require(views(UIScrollView.self, in: editor.view).first)
        #expect(scroll.contentSize.height > scroll.bounds.height + 50)
        let ok = try #require(views(UIButton.self, in: editor.view).first { $0.configuration?.title == "OK" })
        #expect(ok.convert(ok.bounds, to: editor.view).maxY <= 300)
        #expect(try keepsItsHeight("Preview", in: editor) && keepsItsHeight("Reset", in: editor))
        // A little short, too.
        editor.view.frame.size.height = tall - 20
        editor.view.layoutIfNeeded()
        #expect(try keepsItsHeight("Preview", in: editor) && keepsItsHeight("Reset", in: editor))
        #expect(scroll.contentSize.height > scroll.bounds.height)
        #expect(editor.preferredContentSize.height == tall)
        session.cancelLevels()
    }

    /// An editor that scrolls leaves a drag that starts on a curve or a Levels triangle to it, and doesn't hold the
    /// touch back first; the editor still scrolls from anywhere else.
    @Test func aScrollingEditorLeavesItsDragsToThem() throws {
        let session = try session()
        session.beginFilter(.curves)
        let editor = CurvesEditorController(session: session)
        editor.loadViewIfNeeded()
        let scroll = try #require(views(UIScrollView.self, in: editor.view).first)
        #expect(!scroll.delaysContentTouches)
        #expect(!scroll.touchesShouldCancel(in: try #require(views(CurveView.self, in: editor.view).first)))
        #expect(!scroll.touchesShouldCancel(in: LevelsHandlesView(count: 3)))
        #expect(scroll.touchesShouldCancel(in: UIView()))
        session.cancelFilter()
    }

    /// The room the popover keeps for its arrow, at the editor's top, counts in the editor's height, so the controls
    /// don't scroll for it.
    @Test func theArrowsRoomCounts() async throws {
        let session = try session()
        session.beginLevels()
        let editor = LevelsEditorController(session: session)
        editor.additionalSafeAreaInsets.top = 13
        // In a window, where safe areas count.
        let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 440, height: 1200)
        window.rootViewController = editor
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        editor.view.layoutIfNeeded()
        try #require(editor.view.safeAreaInsets.top >= 13)
        let tall = editor.preferredContentSize.height
        window.frame.size.height = tall
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
        editor.view.layoutIfNeeded()
        try #require(editor.view.bounds.height == tall)
        let scroll = try #require(views(UIScrollView.self, in: editor.view).first)
        #expect(scroll.contentSize.height <= scroll.bounds.height + 0.5)
        #expect(try keepsItsHeight("Preview", in: editor))
        session.cancelLevels()
    }

    // MARK: Colored sliders

    /// Hue/Saturation's editor, open on the gray layer, laid out.
    private func hueSaturationEditor(_ session: EditorSession) throws -> (HueSaturationEditorController, [SliderField]) {
        session.beginHueSaturation()
        let editor = try #require(AdjustmentEditors.editor(for: session) as? HueSaturationEditorController)
        editor.loadViewIfNeeded()
        editor.view.frame = CGRect(x: 0, y: 0, width: 480, height: 600)
        editor.updatePropertiesIfNeeded()
        editor.view.layoutIfNeeded()
        let rows = views(SliderField.self, in: editor.view)
        try #require(rows.count == 3)
        return (editor, rows)
    }

    /// The Hue slider's track is the hue circle, centered on the range's color, as the Mac's: Reds on red, Greens on
    /// green, and red to red while colorizing.
    @Test func theHueTrackFollowsTheRange() throws {
        let session = try session()
        var (editor, rows) = try hueSaturationEditor(session)
        #expect(rows[0].track == .spectrum(0))
        var settings = try #require(session.hueSaturation?.settings)
        settings.range = .greens
        session.updateHueSaturation(settings, preview: true)
        editor.updatePropertiesIfNeeded()
        #expect(rows[0].track == .spectrum(120))
        session.updateHueSaturation(.colorizeStart, preview: true)
        editor.updatePropertiesIfNeeded()
        rows = views(SliderField.self, in: editor.view)
        #expect(rows.first?.track == .spectrum(180))
        session.cancelHueSaturation()
    }

    /// The Saturation slider runs gray to red on Master, to the range's color on a range, and to the hue being set while
    /// colorizing; Lightness runs black to white.
    @Test func theSaturationAndLightnessTracks() throws {
        let session = try session()
        var (editor, rows) = try hueSaturationEditor(session)
        #expect(rows[1].track == .chroma && rows[2].track == .opposing(.black, .white))
        var settings = try #require(session.hueSaturation?.settings)
        settings.range = .blues
        session.updateHueSaturation(settings, preview: true)
        editor.updatePropertiesIfNeeded()
        #expect(rows[1].track == .saturation(240))
        settings = .colorizeStart
        settings.hue = 30
        session.updateHueSaturation(settings, preview: true)
        editor.updatePropertiesIfNeeded()
        rows = views(SliderField.self, in: editor.view)
        #expect(rows[1].track == .saturation(30))
        // Drawn: the system's track gives way to the colors, gray at the left end and orange at the right, past the thumb.
        let slider = try #require(views(GradientSlider.self, in: rows[1]).first)
        #expect(slider.colors == CameraRawSliderTrack.saturation(30).colors)
        editor.view.layoutIfNeeded()
        let track = slider.trackRect(forBounds: slider.bounds)
        let image = UIGraphicsImageRenderer(bounds: slider.bounds).image { slider.layer.render(in: $0.cgContext) }
        let left = try pixel(image, at: CGPoint(x: track.minX + 3, y: track.midY))
        let right = try pixel(image, at: CGPoint(x: track.maxX - 3, y: track.midY))
        #expect(abs(left.red - left.blue) < 0.08 && left.red > 0.4, "left \(left)")
        #expect(right.red > 0.8 && right.blue < 0.25, "right \(right)")
        session.cancelHueSaturation()
    }

    /// The three sliders start together after their captions, as the Mac's do, though Hue's has a unit.
    @Test func theSlidersStartTogether() throws {
        let session = try session()
        let (editor, rows) = try hueSaturationEditor(session)
        let starts = rows.compactMap { views(UISlider.self, in: $0).first }.map { $0.convert($0.bounds, to: editor.view).minX }
        #expect(starts.count == 3 && Set(starts).count == 1, "\(starts)")
        session.cancelHueSaturation()
    }

    /// A colored track changes at once, as the Mac's redraws: one that eased to its new colors or place would trail a
    /// drag that changes them, as Tint's Hue does Tint's Saturation track.
    @Test func aColoredTrackChangesAtOnce() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 100)
        let slider = GradientSlider()
        slider.frame = CGRect(x: 20, y: 20, width: 300, height: 34)
        window.addSubview(slider)
        window.isHidden = false
        defer { window.isHidden = true }
        slider.colors = CameraRawSliderTrack.chroma.colors
        slider.layoutIfNeeded()
        CATransaction.flush()
        func animating() -> [String] {
            ([slider.layer] + (slider.layer.sublayers ?? []) + slider.subviews.map(\.layer)).filter { $0 is CAGradientLayer }
                .flatMap { $0.animationKeys() ?? [] }
        }
        slider.colors = CameraRawSliderTrack.saturation(200).colors
        slider.frame.size.width = 200
        slider.layoutIfNeeded()
        #expect(animating().isEmpty, "\(animating())")
    }

    /// A double tap on a slider's caption or thumb puts that one value back, as a double-click does on the Mac: Hue to
    /// no change, and while colorizing Saturation to Photoshop's colorize start, 25. Elsewhere on the track it doesn't.
    @Test func aDoubleTapResetsOneValue() throws {
        let session = try session()
        var (editor, rows) = try hueSaturationEditor(session)
        var settings = try #require(session.hueSaturation?.settings)
        settings.hue = 30
        settings.lightness = 40
        session.updateHueSaturation(settings, preview: true)
        editor.updatePropertiesIfNeeded()
        editor.view.layoutIfNeeded()
        let caption = try #require(views(UILabel.self, in: rows[0]).first)
        #expect(rows[0].resets(at: caption.convert(CGPoint(x: caption.bounds.midX, y: caption.bounds.midY), to: rows[0])))
        #expect(session.hueSaturation?.settings.hue == 0 && session.hueSaturation?.settings.lightness == 40)

        session.updateHueSaturation(.colorizeStart, preview: true)
        settings = try #require(session.hueSaturation?.settings)
        settings.saturation = 80
        session.updateHueSaturation(settings, preview: true)
        editor.updatePropertiesIfNeeded()
        editor.view.layoutIfNeeded()
        rows = views(SliderField.self, in: editor.view)
        let slider = try #require(views(UISlider.self, in: rows[1]).first)
        let thumb = slider.thumbRect(forBounds: slider.bounds, trackRect: slider.trackRect(forBounds: slider.bounds), value: slider.value)
        let far = CGPoint(x: thumb.midX > slider.bounds.midX ? slider.bounds.minX + 4 : slider.bounds.maxX - 4, y: thumb.midY)
        #expect(!rows[1].resets(at: slider.convert(far, to: rows[1])))
        #expect(session.hueSaturation?.settings.saturation == 80)
        #expect(rows[1].resets(at: slider.convert(CGPoint(x: thumb.midX, y: thumb.midY), to: rows[1])))
        #expect(session.hueSaturation?.settings.saturation == 25)
        session.cancelHueSaturation()
    }

    /// A double tap on an Invert layer's thumbnail renames it, as on the Mac, where only an adjustment with settings
    /// opens an editor.
    @Test func anInvertThumbnailDoubleTapRenames() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1194, height: 834)
        let controller = EditorWindowController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        let session = try #require(controller.activeTab?.session)
        session.createNewProject(width: 200, height: 100)
        session.addAdjustment(.invert)
        let id = try #require(session.activeLayerID)
        let panel = try #require(views(LayersPanelView.self, in: controller.view).first)
        panel.updatePropertiesIfNeeded()
        panel.layoutIfNeeded()
        let cell = try #require(views(LayerRowCell.self, in: panel).first { $0.layerID == id })
        cell.layoutIfNeeded()
        let thumbnail = try #require(views(UIControl.self, in: cell).first { $0.accessibilityLabel == "Select image: Invert" })
        cell.doubleTap(at: thumbnail.convert(CGPoint(x: thumbnail.bounds.midX, y: thumbnail.bounds.midY), to: cell.contentView))
        try await eventually { controller.presentedViewController is UIAlertController }
        #expect((controller.presentedViewController as? UIAlertController)?.title == "Rename Layer")
        #expect(session.adjustmentEditingID == nil)
        controller.dismiss(animated: false)
    }

    /// The color at `point` in `image`, in its points.
    private func pixel(_ image: UIImage, at point: CGPoint) throws -> PaletteColor {
        let cgImage = try #require(image.cgImage)
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let scale = image.scale
        context.draw(cgImage, in: CGRect(x: -point.x * scale, y: -(CGFloat(cgImage.height) - point.y * scale), width: CGFloat(cgImage.width),
                                         height: CGFloat(cgImage.height)))
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return PaletteColor(red: CGFloat(data[0]) / 255, green: CGFloat(data[1]) / 255, blue: CGFloat(data[2]) / 255)
    }
}
