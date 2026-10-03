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
}
