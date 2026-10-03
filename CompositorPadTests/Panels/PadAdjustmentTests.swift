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
}
