import CoreGraphics
import Testing
import UIKit
@testable import Compositor

/// The Layers panel's rows on iPad, double tapped where the Mac's are double clicked: the row's buttons press for each
/// tap, as the Mac's track the mouse themselves; the name renames; the thumbnails open what the layer holds.
@MainActor struct PadLayersPanelTests {
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

    /// Layer `layer`'s row in the Layers panel, as it shows now, laid out.
    private func cell(for layer: UUID, in controller: EditorWindowController) throws -> LayerRowCell {
        let panel = try #require(views(LayersPanelView.self, in: controller.view).first)
        panel.updatePropertiesIfNeeded()
        panel.layoutIfNeeded()
        let cell = try #require(views(LayerRowCell.self, in: panel).first { $0.layerID == layer })
        cell.layoutIfNeeded()
        return cell
    }

    /// The row's view that VoiceOver reads as `label`.
    private func view(_ label: String, in cell: LayerRowCell) throws -> UIView {
        try #require(views(UIView.self, in: cell).first { $0.accessibilityLabel == label && !$0.isHidden }, "\(label)")
    }

    /// The middle of `view`, in the cell's content.
    private func middle(of view: UIView, in cell: LayerRowCell) -> CGPoint {
        view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: cell.contentView)
    }

    /// A finger at `point` in the cell's content, as UIKit hands it to a gesture recognizer's delegate: on the view
    /// hit there, which passes over a disabled control, and where it is in any view.
    private final class Finger: UITouch {
        private let point: CGPoint
        private let content: UIView
        private let touched: UIView?
        init(at point: CGPoint, in cell: LayerRowCell) {
            self.point = point
            content = cell.contentView
            touched = cell.contentView.hitTest(point, with: nil)
            super.init()
        }
        override var view: UIView? { touched }
        override func location(in view: UIView?) -> CGPoint { content.convert(point, to: view) }
    }

    /// Whether the row's `recognizer` is let have a finger at `point` in the cell's content.
    private func receives(_ recognizer: UIGestureRecognizer, at point: CGPoint, in cell: LayerRowCell) -> Bool {
        recognizer.delegate?.gestureRecognizer?(recognizer, shouldReceive: Finger(at: point, in: cell)) ?? true
    }

    /// The row's tap, or with `taps` 2 its double tap.
    private func tapRecognizer(of cell: LayerRowCell, taps: Int = 1) throws -> UITapGestureRecognizer {
        try #require(cell.contentView.gestureRecognizers?.lazy.compactMap { $0 as? UITapGestureRecognizer }
            .first { $0.numberOfTapsRequired == taps })
    }

    /// Two quick taps at `point` in the cell's content, as UIKit delivers them. When the row's tap is let have the
    /// finger and no control is under it, it selects for the first tap. When the row's double tap is let have the
    /// finger, it acts, having taken the second tap from a control under it, which is pressed for the first only.
    /// When it isn't, a control under the finger is pressed for each tap, as any is; the panel shows the first press
    /// while the second tap is down, and a control it takes away by then loses that tap.
    private func doubleTap(at point: CGPoint, in cell: LayerRowCell) throws {
        let touched = try #require(cell.contentView.hitTest(point, with: nil))
        let control = sequence(first: touched, next: \.superview).lazy.compactMap { $0 as? UIControl }.first
        if control == nil, receives(try tapRecognizer(of: cell), at: point, in: cell) { cell.tap(at: point) }
        if receives(try tapRecognizer(of: cell, taps: 2), at: point, in: cell) {
            if control?.isEnabled == true { control?.sendActions(for: .primaryActionTriggered) }
            cell.doubleTap(at: point)
        } else if let control, control.isEnabled {
            control.sendActions(for: .primaryActionTriggered)
            let panel = try #require(sequence(first: cell, next: \.superview).lazy.compactMap { $0 as? LayersPanelView }.first)
            panel.updatePropertiesIfNeeded()
            panel.layoutIfNeeded()
            if control.window != nil { control.sendActions(for: .primaryActionTriggered) }
        }
    }

    /// Whether the window asks for a new name for a layer, a moment after the double tap.
    private func asksForAName(_ controller: EditorWindowController) async throws -> Bool {
        try await Task.sleep(for: .milliseconds(100))
        return (controller.presentedViewController as? UIAlertController)?.title == "Rename Layer"
    }

    // MARK: The row's buttons

    /// A double tap on a layer's eye hides it and shows it again, two steps to undo, as the Mac's eye, which tracks
    /// the mouse itself, takes a double click as two clicks; it never renames the layer.
    @Test func aDoubleTapOnTheEyePressesItTwice() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        let gray = try #require(session.activeLayerID)
        let cell = try cell(for: gray, in: controller)
        let eye = try view("Hide Gray", in: cell)
        // Neither the row's tap nor its double tap gets the finger.
        let taps = cell.contentView.gestureRecognizers?.filter { $0 is UITapGestureRecognizer && $0.delegate === cell } ?? []
        #expect(taps.count == 2)
        for recognizer in taps { #expect(!receives(recognizer, at: middle(of: eye, in: cell), in: cell)) }

        let steps = session.history.undoCount
        try doubleTap(at: middle(of: eye, in: cell), in: cell)
        #expect(try await !asksForAName(controller))
        #expect(session.document?.layers.first { $0.id == gray }?.isVisible == true)
        #expect(session.history.undoCount == steps + 2 && session.history.undoName == "Show Layer")
        session.undo()
        #expect(session.document?.layers.first { $0.id == gray }?.isVisible == false)
    }

    /// So do the mask's link, unlinked and linked again, and a folder's disclosure, closed and opened again; neither
    /// renames the layer.
    @Test func aDoubleTapOnTheLinkOrTheDisclosurePressesItTwice() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        let gray = try #require(session.activeLayerID)
        session.addMask()
        try #require(session.activeLayer?.mask?.isLinked == true)
        var cell = try cell(for: gray, in: controller)
        let link = try view("Unlink mask: Gray", in: cell)
        let steps = session.history.undoCount
        try doubleTap(at: middle(of: link, in: cell), in: cell)
        #expect(try await !asksForAName(controller))
        #expect(session.document?.layers.first { $0.id == gray }?.mask?.isLinked == true)
        #expect(session.history.undoCount == steps + 2 && session.history.undoName == "Link Layer Mask")

        session.groupSelectedLayers()
        let folder = try #require(session.activeLayerID)
        try #require(folder != gray && session.activeLayer?.isGroup == true)
        cell = try self.cell(for: folder, in: controller)
        let disclosure = try view("Collapse folder", in: cell)
        try doubleTap(at: middle(of: disclosure, in: cell), in: cell)
        #expect(try await !asksForAName(controller))
        #expect(!session.collapsedGroupIDs.contains(folder))
    }

    /// An effect's eye hides the effect and shows it again, as the Mac's, a button of its own in the effect's row; it
    /// neither edits the effect nor renames the layer. Anywhere else on the effect's row, a double tap edits it.
    @Test func aDoubleTapOnAnEffectsEyePressesItTwice() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        let gray = try #require(session.activeLayerID)
        session.setEffects(LayerEffects(stroke: StrokeEffect()), on: gray, name: "Add Stroke")
        try #require(session.activeLayer?.effects?.isEnabled(.stroke) == true)
        let cell = try cell(for: gray, in: controller)
        let eye = try view("Hide Stroke", in: cell)
        let steps = session.history.undoCount
        try doubleTap(at: middle(of: eye, in: cell), in: cell)
        #expect(try await !asksForAName(controller))
        #expect(session.effectsEditing == nil && controller.presentedViewController == nil)
        #expect(session.document?.layers.first { $0.id == gray }?.effects?.isEnabled(.stroke) == true)
        #expect(session.history.undoCount == steps + 2 && session.history.undoName == "Show Stroke")

        let label = try view("Stroke effect", in: cell)
        try doubleTap(at: middle(of: label, in: cell), in: cell)
        #expect(session.effectsEditing == LayerEffectSelection(layerID: gray, kind: .stroke))
        try await eventually { controller.presentedViewController is EffectEditorController }
        #expect(controller.presentedViewController is EffectEditorController)
        #expect(try await !asksForAName(controller))
    }

    /// A disabled eye, while text is typed or a transform waits for Apply, takes a double tap as the Mac's takes a
    /// double click, doing nothing: the row neither selects the layer, which would end the typing or apply the
    /// transform, nor renames it.
    @Test func aDoubleTapOnADisabledEyeDoesNothing() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        let gray = try #require(session.activeLayerID)
        session.addBlankLayer()
        let blank = try #require(session.activeLayerID)
        try #require(blank != gray)
        let steps = session.history.undoCount

        session.selectTool(.type)
        session.beginText(at: CGPoint(x: 20, y: 40), newLayer: true)
        session.textDraft?.style.content = "Hello"
        var selected = session.selectedLayerIDs
        var cell = try cell(for: gray, in: controller)
        var eye = try #require(try view("Hide Gray", in: cell) as? UIButton)
        try #require(!eye.isEnabled)
        try doubleTap(at: middle(of: eye, in: cell), in: cell)
        #expect(try await !asksForAName(controller))
        #expect(session.textDraft?.style.content == "Hello" && session.selectedLayerIDs == selected)
        #expect(session.history.undoCount == steps && session.document?.layers.first { $0.id == gray }?.isVisible == true)
        session.cancelText()

        session.selectLayers([gray], primary: gray)
        session.selectTool(.move)
        session.beginTransform()
        var moved = try #require(session.transformEdit?.draft)
        moved.origin.x += 10
        session.previewTransform(moved)
        try #require(session.transformEdit != nil)
        selected = session.selectedLayerIDs
        cell = try self.cell(for: blank, in: controller)
        let name = try #require(session.document?.layers.first { $0.id == blank }?.name)
        eye = try #require(try view("Hide \(name)", in: cell) as? UIButton)
        try #require(!eye.isEnabled)
        try doubleTap(at: middle(of: eye, in: cell), in: cell)
        #expect(try await !asksForAName(controller))
        #expect(session.transformEdit?.draft == moved && session.selectedLayerIDs == selected)
        #expect(session.history.undoCount == steps && session.document?.layers.first { $0.id == blank }?.isVisible == true)
        session.cancelTransform()
    }

    /// An effect's eye stands in by its layer's indent, as the layer's own disclosure does: a layer moved into a
    /// folder takes its effects' eyes in with it.
    @Test func anEffectsEyeMovesInWithItsLayer() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        let gray = try #require(session.activeLayerID)
        session.setEffects(LayerEffects(stroke: StrokeEffect()), on: gray, name: "Add Stroke")
        func places() throws -> (eye: CGFloat, disclosure: CGFloat) {
            let cell = try cell(for: gray, in: controller)
            let eye = try view("Hide Stroke", in: cell)
            // A layer's disclosure is hidden, but still where a folder's would be.
            let disclosure = try #require(views(UIButton.self, in: cell).first { $0.accessibilityLabel == "Collapse folder" })
            return (eye.convert(eye.bounds, to: cell.contentView).minX, disclosure.convert(disclosure.bounds, to: cell.contentView).minX)
        }
        let before = try places()
        session.groupSelectedLayers()
        try #require(session.document?.layers.first { $0.id == gray }?.parentID != nil)
        let after = try places()
        #expect(abs(after.disclosure - before.disclosure - 20) < 0.5, "\(before.disclosure) → \(after.disclosure)")
        #expect(abs(after.eye - before.eye - 20) < 0.5, "\(before.eye) → \(after.eye)")
    }

    // MARK: The name and the thumbnails

    /// A double tap on the name renames the layer, and so does one on a pixel layer's thumbnail or its mask's, the
    /// corner the link's turned bounds reach under included, as on the Mac, where they hold nothing else to open, and
    /// one where a folder's disclosure would be, hidden in a layer's row.
    @Test func aDoubleTapOnTheNameOrAPixelLayersThumbnailRenames() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        let gray = try #require(session.activeLayerID)
        session.addMask()
        let cell = try cell(for: gray, in: controller)
        let name = try #require(views(UILabel.self, in: cell).first { $0.text == "Gray" })
        let disclosure = try #require(views(UIButton.self, in: cell).first { $0.accessibilityLabel == "Collapse folder" && $0.isHidden })
        let mask = try view("Select mask: Gray", in: cell)
        // The link's bounds, turned, reach under the mask's lower left, where UIKit hits the mask, above the link.
        let link = try view("Unlink mask: Gray", in: cell)
        let corner = mask.convert(CGPoint(x: 1, y: mask.bounds.height * 3 / 4), to: cell.contentView)
        try #require(link.bounds.contains(cell.contentView.convert(corner, to: link)))
        try #require(cell.contentView.hitTest(corner, with: nil) === mask)
        let points = [name, try view("Select image: Gray", in: cell), mask, disclosure].map { middle(of: $0, in: cell) } + [corner]
        for point in points {
            try doubleTap(at: point, in: cell)
            try await eventually { controller.presentedViewController is UIAlertController }
            #expect((controller.presentedViewController as? UIAlertController)?.title == "Rename Layer", "\(point)")
            controller.dismiss(animated: false)
            try await eventually { controller.presentedViewController == nil }
        }
    }

    /// A double tap on an adjustment's thumbnail opens its editor, and so does one on its mask's, the red mark of a
    /// disabled mask included, as the Mac's opens its settings from either; neither renames it. Without a mask, its
    /// place is the name's, which renames from its first letter.
    @Test func aDoubleTapOnAnAdjustmentsThumbnailOrMaskOpensItsEditor() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        session.addAdjustment(.levels)
        session.adjustmentEditingID = nil
        let levels = try #require(session.activeLayerID)
        try #require(session.activeLayer?.adjustment?.kind == .levels)
        var cell = try cell(for: levels, in: controller)
        let name = try #require(views(UILabel.self, in: cell).first { $0.text == "Levels" })
        try doubleTap(at: name.convert(CGPoint(x: 2, y: name.bounds.midY), to: cell.contentView), in: cell)
        try await eventually { controller.presentedViewController is UIAlertController }
        #expect((controller.presentedViewController as? UIAlertController)?.title == "Rename Layer")
        #expect(session.adjustmentEditingID == nil)
        controller.dismiss(animated: false)
        try await eventually { controller.presentedViewController == nil }

        session.addMask()
        cell = try self.cell(for: levels, in: controller)
        let marks = [try view("Select image: Levels", in: cell), try view("Select mask: Levels", in: cell)].map { middle(of: $0, in: cell) }
        session.toggleLayerMask()
        try #require(session.activeLayer?.mask?.isEnabled == false)
        cell = try self.cell(for: levels, in: controller)
        let off = try #require(views(UILabel.self, in: cell).first { $0.text == "╱" && !$0.isHidden })
        for point in marks + [middle(of: off, in: cell)] {
            try doubleTap(at: point, in: cell)
            #expect(session.adjustmentEditingID == levels, "\(point)")
            try await eventually { controller.presentedViewController is AdjustmentEditorController }
            #expect(controller.presentedViewController is AdjustmentEditorController, "\(point)")
            #expect(try await !asksForAName(controller))
            session.cancelLevels()
            try await eventually { controller.presentedViewController == nil && session.adjustmentEditingID == nil }
        }
    }

    /// A double tap on a text layer's thumbnail opens its text for typing, as the Mac's does, rather than renaming it.
    @Test func aDoubleTapOnTextsThumbnailOpensIt() async throws {
        let (window, controller, session) = try await shownWindow()
        defer { window.isHidden = true }
        session.selectTool(.type)
        session.beginText(at: CGPoint(x: 20, y: 40), newLayer: true)
        session.textDraft?.style.content = "Hello"
        try #require(session.finishText())
        let text = try #require(session.activeLayer?.liveText != nil ? session.activeLayerID : nil)
        session.selectTool(.move)
        let cell = try cell(for: text, in: controller)
        let thumbnail = try view("Select text: Hello", in: cell)
        try doubleTap(at: middle(of: thumbnail, in: cell), in: cell)
        #expect(session.textDraft?.layerID == text)
        #expect(try await !asksForAName(controller))
        session.cancelText()
    }
}
