import CoreGraphics
import Foundation
import Testing
@testable import Compositor

/// A layer effect's panel undoes a slider's drag, or a color picked for the effect, in one step, an edit made meanwhile
/// keeping its own, and nothing that ends the panel's editing leaves a drag holding Undo back.
@MainActor struct EffectUndoTests {
    /// A 200 × 100 document with one gray layer, active, in `session` or a new one.
    private func session(_ session: EditorSession? = nil) throws -> EditorSession {
        let session = session ?? EditorSession()
        session.createDocument(width: 200, height: 100)
        let context = try BrushRaster.context(width: 200, height: 100, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Gray"))
        session.backgroundColor = .white
        return session
    }
    private func stroke(_ session: EditorSession) -> StrokeEffect? { session.activeLayer?.effects?.stroke }
    /// Blues the picker moves through, in the 8-bit steps it works in.
    private let blues = (1...20).map { PaletteColor(red: 0, green: 0, blue: CGFloat($0 * 10) / 255) }
    private let reds = (1...20).map { PaletteColor(red: CGFloat($0 * 10) / 255, green: 0, blue: 0) }
    /// Moves the open picker through `colors`, dragging in it or clicking the canvas, the effect following each, as the
    /// panel's `onChange(of: colorPicker?.color)` has it.
    private func pick(_ session: EditorSession, _ colors: [PaletteColor]) {
        for color in colors {
            session.colorPicker?.hsb.setRGB(color)
            session.previewEffectColor()
        }
    }

    /// A drag of Inner Glow's Size slider sets the size many times a second; the drag is one step, and one Undo puts
    /// back the size it had before. While the slider is held, Undo waits, as it does for Layer Opacity's.
    @Test func aSliderDragIsOneStep() throws {
        let session = try session()
        session.addEffect(.innerGlow)
        let count = session.history.undoCount
        session.beginEffectsChange()
        for size in 11...40 { session.changeEffects { $0.innerGlow?.size = CGFloat(size) } }
        #expect(!session.canUndo)
        session.finishEffectsChange()
        #expect(session.history.undoCount == count + 1)
        #expect(session.history.undoName == "Edit Inner Glow")
        session.undo()
        #expect(session.activeLayer?.effects?.innerGlow?.size == 10)
        #expect(session.history.undoName == "Add Inner Glow")
        session.redo()
        #expect(session.activeLayer?.effects?.innerGlow?.size == 40)
    }

    /// A drag with more values than the history keeps steps, about a second of one, keeps the step that added the effect.
    @Test func aLongDragKeepsTheStepsBeforeIt() throws {
        let session = try session()
        session.addEffect(.innerGlow)
        session.beginEffectsChange()
        for size in 1...(session.history.entryLimit + 50) { session.changeEffects { $0.innerGlow?.size = CGFloat(size) } }
        session.finishEffectsChange()
        session.undo()
        #expect(session.activeLayer?.effects?.innerGlow?.size == 10)
        #expect(session.history.undoName == "Add Inner Glow")
        session.undo()
        #expect(session.activeLayer?.effects == nil)
    }

    /// Picking Stroke's color, the stroke following the picker as it moves, is one step on OK. Undo stays available
    /// while picking.
    @Test func aColorPickingIsOneStep() throws {
        let session = try session()
        session.addEffect(.stroke)
        let count = session.history.undoCount
        session.openEffectColorPicker(.stroke)
        pick(session, blues)
        #expect(session.canUndo)
        session.closeColorPicker(commit: true)
        #expect(stroke(session)?.color == blues.last)
        #expect(session.history.undoCount == count + 1)
        #expect(session.history.undoName == "Edit Stroke")
        session.undo()
        #expect(stroke(session)?.color == .white)
        #expect(session.history.undoName == "Add Stroke")
        session.redo()
        #expect(stroke(session)?.color == blues.last)
    }

    /// A picking canceled leaves no step, and the project saved before it unmodified.
    @Test func aCanceledPickingLeavesNoStep() throws {
        let session = try session()
        session.addEffect(.stroke)
        session.history.markSaved()
        let count = session.history.undoCount
        session.openEffectColorPicker(.stroke)
        pick(session, blues)
        #expect(session.isModified)
        session.closeColorPicker(commit: false)
        #expect(stroke(session)?.color == .white)
        #expect(session.history.undoCount == count)
        #expect(session.history.undoName == "Add Stroke")
        #expect(!session.isModified)
    }

    /// Saved partway through a picking, the project is modified by the rest of it, and still is once its Cancel has put
    /// back the color the saved file doesn't have.
    @Test func aPickingSavedPartwayLeavesTheProjectModified() throws {
        let session = try session()
        session.addEffect(.stroke)
        session.openEffectColorPicker(.stroke)
        pick(session, Array(blues[..<10]))
        session.history.markSaved(session.history.currentRevision)
        #expect(!session.isModified)
        pick(session, Array(blues[10...]))
        #expect(session.isModified)
        session.closeColorPicker(commit: false)
        #expect(stroke(session)?.color == .white)
        #expect(session.history.undoName == "Add Stroke")
        #expect(session.isModified)
    }

    /// An edit made beside the open picker isn't folded into the picking's step: the picking before it and the picking
    /// after it are a step each.
    @Test func anEditBesideThePickerKeepsItsOwnStep() throws {
        let session = try session()
        session.addEffect(.stroke)
        session.openEffectColorPicker(.stroke)
        pick(session, Array(blues[..<10]))
        session.setLayerOpacity(0.5)
        pick(session, Array(blues[10...]))
        session.closeColorPicker(commit: true)
        #expect(session.history.undoName == "Edit Stroke")
        session.undo()
        #expect(stroke(session)?.color == blues[9])
        #expect(session.activeLayer?.opacity == 0.5)
        #expect(session.history.undoName == "Layer Opacity")
        session.undo()
        #expect(session.activeLayer?.opacity == 1)
        #expect(session.history.undoName == "Edit Stroke")
        session.undo()
        #expect(stroke(session)?.color == .white)
        #expect(session.history.undoName == "Add Stroke")
    }

    /// An Undo while picking takes back the picking so far; the picker's OK doesn't put it back, nor clear Redo.
    @Test func anUndoWhilePickingOutlastsItsOK() throws {
        let session = try session()
        session.addEffect(.stroke)
        session.openEffectColorPicker(.stroke)
        pick(session, blues)
        session.undo()
        #expect(stroke(session)?.color == .white)
        #expect(session.colorPicker?.color == .white)
        session.closeColorPicker(commit: true)
        #expect(stroke(session)?.color == .white)
        #expect(session.history.undoName == "Add Stroke")
        #expect(session.canRedo)
        #expect(session.history.redoName == "Edit Stroke")
        session.redo()
        #expect(stroke(session)?.color == blues.last)
    }

    /// Cancel puts back the color the effect had before the picking, through an Undo that left that color alone; once
    /// Undo has taken the effect back to a color from before the picking, Cancel leaves it there and Redo stays.
    @Test func cancelAfterAnUndoPutsBackOnlyWhatThePickingDid() throws {
        let session = try session()
        session.addEffect(.stroke)
        session.openEffectColorPicker(.stroke)
        pick(session, blues)
        session.setLayerOpacity(0.5)
        session.undo()
        #expect(stroke(session)?.color == blues.last)
        session.closeColorPicker(commit: false)
        #expect(stroke(session)?.color == .white)

        session.openEffectColorPicker(.stroke)
        pick(session, blues)
        session.closeColorPicker(commit: true)
        session.openEffectColorPicker(.stroke)
        pick(session, reds)
        session.undo()
        session.undo()
        #expect(stroke(session)?.color == .white)
        session.closeColorPicker(commit: false)
        #expect(stroke(session)?.color == .white)
        #expect(session.canRedo)
        session.redo()
        #expect(stroke(session)?.color == blues.last)
        session.redo()
        #expect(stroke(session)?.color == reds.last)
    }

    /// An Undo of the picking's own step while the picker is open, and a Redo of it, move the picker's working color
    /// with the effect, but not what its Cancel puts back: the color from before the picking, so a picking canceled
    /// still leaves no step. OK keeps the color the effect has.
    @Test(arguments: [false, true], [false, true])
    func anUndoOrRedoOfThePickingItselfKeepsWhatCancelPutsBack(redo: Bool, commit: Bool) throws {
        let session = try session()
        session.addEffect(.stroke)
        session.history.markSaved()
        let count = session.history.undoCount
        session.openEffectColorPicker(.stroke)
        pick(session, blues)
        session.undo()
        #expect(stroke(session)?.color == .white)
        #expect(session.colorPicker?.color == .white)
        if redo {
            session.redo()
            #expect(stroke(session)?.color == blues.last)
            #expect(session.colorPicker?.color == blues.last)
        }
        session.closeColorPicker(commit: commit)
        let picked = redo && commit
        #expect(stroke(session)?.color == (picked ? blues.last : .white))
        #expect(session.history.undoCount == count + (picked ? 1 : 0))
        #expect(session.isModified == picked)
        // What's left to redo is what the Undo, or the Redo after it, left.
        #expect(session.canRedo == !redo)
    }

    /// So too with an edit made beside the picker in between, the picking a step before it and a step after it: an Undo
    /// of the step after it leaves Cancel putting back the color from before the whole picking.
    @Test func cancelAfterAnUndoOfThePickingsLaterStepPutsBackTheColorFromBeforeIt() throws {
        let session = try session()
        session.addEffect(.stroke)
        session.openEffectColorPicker(.stroke)
        pick(session, Array(blues[..<10]))
        session.setLayerOpacity(0.5)
        pick(session, Array(blues[10...]))
        session.undo()
        #expect(stroke(session)?.color == blues[9])
        #expect(session.colorPicker?.color == blues[9])
        session.closeColorPicker(commit: false)
        #expect(stroke(session)?.color == .white)
        #expect(session.activeLayer?.opacity == 0.5)
    }

    /// An effect's color can be finer than the picker's 8-bit steps, as in a project written by hand or by a script. The
    /// picker opening on it, as the panel follows the picker's color, or following an Undo back to it, leaves it as it
    /// is: no step is added and Redo stays.
    @Test func aColorFinerThanThePickersStepsIsLeftAsItIs() throws {
        let session = try session()
        session.addEffect(.stroke)
        session.changeEffects { $0.setColor(PaletteColor(red: 0.3, green: 0.3, blue: 0.3), for: .stroke) }
        let count = session.history.undoCount
        session.openEffectColorPicker(.stroke)
        session.previewEffectColor()
        #expect(session.history.undoCount == count)
        pick(session, blues)
        session.undo()
        session.previewEffectColor()
        #expect(stroke(session)?.color == PaletteColor(red: 0.3, green: 0.3, blue: 0.3))
        session.closeColorPicker(commit: true)
        #expect(stroke(session)?.color == PaletteColor(red: 0.3, green: 0.3, blue: 0.3))
        #expect(session.history.undoCount == count)
        #expect(session.canRedo)
    }

    /// Cancel puts such a color back exactly, even after a picking that ends on its 8-bit rounding, so the picking
    /// leaves no step and the project unmodified.
    @Test func cancelPutsBackAColorFinerThanThePickersStepsExactly() throws {
        let session = try session()
        session.addEffect(.stroke)
        let gray = PaletteColor(red: 0.3, green: 0.3, blue: 0.3)
        session.changeEffects { $0.setColor(gray, for: .stroke) }
        session.history.markSaved()
        let count = session.history.undoCount
        session.openEffectColorPicker(.stroke)
        pick(session, blues + [gray])
        #expect(stroke(session)?.color == gray.quantized)
        session.closeColorPicker(commit: false)
        #expect(stroke(session)?.color == gray)
        #expect(session.history.undoCount == count)
        #expect(!session.isModified)
    }

    /// What ends a drag in an effect's panel from outside the drag itself.
    enum WayOut: String, CaseIterable {
        case ok, cancel, effectRemoved, layerDeleted, anotherEffectAdded, anotherEffectOpened, settled, settledWhileBusy, saved
    }

    /// Everything that ends an effect's editing ends a drag still held in its panel, so Undo isn't left waiting for it:
    /// OK, Cancel (the drag a step of its own before Cancel's), the effect removed, or gone with its layer, another
    /// effect added or opened, settling the project for Quit or closing it, which cancels the panel, or leaves it open
    /// while the project is busy, and saving it.
    @Test(arguments: WayOut.allCases) func everyWayOutEndsADrag(_ wayOut: WayOut) async throws {
        let workspace = ProjectWorkspace()
        let session = try session(workspace.current.session)
        let id = try #require(session.activeLayerID)
        session.addEffect(.shadow)
        session.finishEffectsEditing(commit: true)
        session.addEffect(.stroke)
        session.finishEffectsEditing(commit: true)
        session.selectEffect(.stroke, on: id, editing: true)
        session.beginEffectsChange()
        session.changeEffects { $0.stroke?.size = 11 }
        session.changeEffects { $0.stroke?.size = 12 }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EffectUndoTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        switch wayOut {
        case .ok: session.finishEffectsEditing(commit: true)
        case .cancel: session.finishEffectsEditing(commit: false)
        case .effectRemoved: session.removeSelectedEffect()
        case .layerDeleted:
            session.deleteActiveLayer()
            session.endEffectsEditingIfGone()
        case .anotherEffectAdded: session.addEffect(.innerGlow)
        case .anotherEffectOpened: session.selectEffect(.shadow, on: id, editing: true)
        case .settled: await session.settlePendingEdits()
        case .settledWhileBusy:
            session.isProjectBusy = true
            await session.settlePendingEdits()
            session.isProjectBusy = false
        case .saved:
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            session.projectURL = folder.appendingPathComponent("Effects.comp")
            #expect(await workspace.current.controller.save())
            #expect(!session.isModified)
        }
        #expect(session.canUndo)
        switch wayOut {
        case .ok, .saved, .settledWhileBusy:
            // Saving, and settling while the project is busy, leave the panel open.
            #expect((session.effectsEditing != nil) == (wayOut != .ok))
            #expect(session.history.undoName == "Edit Stroke")
            session.undo()
            #expect(stroke(session)?.size == 4)
        case .cancel, .settled, .effectRemoved:
            #expect(session.history.undoName == (wayOut == .effectRemoved ? "Remove Stroke" : "Cancel Stroke"))
            session.undo()
            #expect(stroke(session)?.size == 12)
            #expect(session.history.undoName == "Edit Stroke")
            session.undo()
            #expect(stroke(session)?.size == 4)
        case .layerDeleted:
            // The deletion goes into the drag's step, as it does into Layer Opacity's: one Undo brings the layer back
            // as it was before the drag.
            #expect(session.effectsEditing == nil)
            #expect(session.history.undoName == "Edit Stroke")
            session.undo()
            #expect(session.activeLayerID == id)
            #expect(stroke(session)?.size == 4)
        case .anotherEffectAdded, .anotherEffectOpened:
            #expect(session.history.undoName == (wayOut == .anotherEffectAdded ? "Add Inner Glow" : "Cancel Stroke"))
            #expect(session.effectsEditing?.kind == (wayOut == .anotherEffectAdded ? .innerGlow : .shadow))
        }
    }

    /// A drag in an effect's panel and a drag of Layer Opacity are a step each, whichever starts while the other is held.
    @Test func effectAndOpacityDragsKeepTheirOwnSteps() throws {
        let session = try session()
        session.addEffect(.stroke)
        let count = session.history.undoCount
        session.beginOpacityEdit()
        session.setLayerOpacity(0.5)
        session.setLayerOpacity(0.4)
        session.beginEffectsChange()
        session.changeEffects { $0.stroke?.size = 12 }
        session.changeEffects { $0.stroke?.size = 13 }
        session.finishEffectsChange()
        session.finishOpacityEdit()
        session.beginEffectsChange()
        session.changeEffects { $0.stroke?.size = 14 }
        session.changeEffects { $0.stroke?.size = 15 }
        session.beginOpacityEdit()
        session.setLayerOpacity(0.3)
        session.setLayerOpacity(0.2)
        session.finishOpacityEdit()
        session.finishEffectsChange()
        #expect(session.history.undoCount == count + 4)
        for (name, size, opacity) in [("Layer Opacity", 15.0, 0.4), ("Edit Stroke", 13, 0.4), ("Edit Stroke", 4, 0.4),
                                      ("Layer Opacity", 4, 1)] {
            #expect(session.history.undoName == name)
            session.undo()
            #expect(stroke(session)?.size == CGFloat(size))
            #expect(session.activeLayer?.opacity == opacity)
        }
    }

    /// An edit made while a drag in an effect's panel is held, on the canvas beside the panel, from the keyboard or in
    /// the Layers panel, which the iPad's effect panel leaves free, and the step it makes.
    enum EditMeanwhile: String, CaseIterable {
        case brushStroke = "Brush Stroke", smudge = "Smudge", gradient = "Gradient", fill = "Fill"
        case blendMode = "Layer Blend Mode", hide = "Hide Stroke", copy = "Copy Stroke", add = "Add Inner Glow"
    }

    /// An edit made while a drag in an effect's panel is held ends the drag first, as it does Layer Opacity's, so it's
    /// a step of its own rather than going into the drag's.
    @Test(arguments: EditMeanwhile.allCases) func anEditMeanwhileKeepsItsOwnStep(_ edit: EditMeanwhile) async throws {
        let session = try session()
        let id = try #require(session.activeLayerID)
        // A second layer, to copy the Stroke to.
        session.insert(try #require(session.activeLayer?.asset))
        let other = try #require(session.activeLayerID)
        session.selectLayer(id)
        session.selectTool(edit == .smudge ? .blur : edit == .gradient ? .gradient : .brush)
        session.blurMode = .smudge
        session.addEffect(.stroke)
        let count = session.history.undoCount
        session.beginEffectsChange()
        session.changeEffects { $0.stroke?.size = 12 }
        switch edit {
        case .brushStroke, .smudge:
            session.beginBrush(at: CGPoint(x: 20, y: 40))
            session.continueBrush(at: CGPoint(x: 120, y: 40))
            #expect(session.finishBrushImmediately())
        case .gradient:
            session.beginGradient(at: CGPoint(x: 20, y: 40))
            session.moveGradient(end: CGPoint(x: 120, y: 40))
            session.endGradientDrag()
            await session.commitGradient()
        case .fill: await session.fillSelection(with: .foreground)
        case .blendMode: session.cycleBlendMode(forward: true)
        case .hide: session.toggleEffect(.stroke, on: id)
        case .copy: session.copyEffect(.stroke, from: id, to: other)
        case .add: session.addEffect(.innerGlow)
        }
        session.changeEffects { $0.stroke?.size = 13 }
        session.finishEffectsChange()
        #expect(session.history.undoCount == count + 3)
        // Another effect added cancels the panel, the drag a step of its own before Cancel's, which takes off the
        // Stroke added in it, so the rest of the drag sets nothing.
        let steps: [(String, CGFloat?)] = edit == .add
            ? [(edit.rawValue, nil), ("Cancel Stroke", 12), ("Edit Stroke", 4)]
            : [("Edit Stroke", 12), (edit.rawValue, 12), ("Edit Stroke", 4)]
        for (name, size) in steps {
            #expect(session.history.undoName == name)
            session.undo()
            #expect(session.document?.layers.first { $0.id == id }?.effects?.stroke?.size == size)
        }
    }

    /// A crop, a transform, text or a gradient waiting for Apply, which the effect's panel works beside, and the step it
    /// makes once it's applied.
    enum CanvasEdit: String, CaseIterable {
        case crop = "Crop", transform = "Transform Layer", text = "New Text Layer", gradient = "Gradient"
    }

    /// A drag in the effect's panel is one step beside a crop, a transform, text or a gradient waiting for Apply too,
    /// which the panel works beside; the canvas's edit applied while the drag is held ends the drag first, so each keeps
    /// a step of its own.
    @Test(arguments: CanvasEdit.allCases) func aCanvasEditAppliedMeanwhileKeepsItsOwnStep(_ edit: CanvasEdit) async throws {
        let session = try session()
        let id = try #require(session.activeLayerID)
        func size() -> CGFloat? { session.document?.layers.first { $0.id == id }?.effects?.stroke?.size }
        session.addEffect(.stroke)
        switch edit {
        case .crop:
            session.selectTool(.crop)
            session.cropRect = CGRect(x: 0, y: 0, width: 100, height: 50)
        case .transform: session.transformCommand()
        case .text:
            session.selectTool(.type)
            session.beginText(at: CGPoint(x: 10, y: 10), newLayer: true)
            session.textDraft?.style.content = "Text"
        case .gradient:
            session.selectTool(.gradient)
            session.beginGradient(at: CGPoint(x: 20, y: 40))
            session.moveGradient(end: CGPoint(x: 120, y: 40))
            session.endGradientDrag()
        }
        let count = session.history.undoCount
        session.beginEffectsChange()
        session.changeEffects { $0.stroke?.size = 12 }
        session.changeEffects { $0.stroke?.size = 13 }
        switch edit {
        case .crop: await session.commitCrop()
        case .transform:
            session.transformEdit?.draft.origin.x += 20
            session.commitTransform()
        case .text: #expect(session.finishText())
        case .gradient: await session.commitGradient()
        }
        session.changeEffects { $0.stroke?.size = 14 }
        session.finishEffectsChange()
        #expect(session.history.undoCount == count + 3)
        for (name, value) in [("Edit Stroke", 13.0), (edit.rawValue, 13), ("Edit Stroke", 4)] {
            #expect(session.history.undoName == name)
            session.undo()
            #expect(size() == CGFloat(value))
        }
    }

    /// Layer Opacity's drag is ended the same way: a brush stroke made while it's held is a step of its own.
    @Test func aBrushStrokeWhileOpacityIsDraggedKeepsItsOwnStep() throws {
        let session = try session()
        session.selectTool(.brush)
        let count = session.history.undoCount
        session.beginOpacityEdit()
        session.setLayerOpacity(0.5)
        session.beginBrush(at: CGPoint(x: 20, y: 40))
        session.continueBrush(at: CGPoint(x: 120, y: 40))
        #expect(session.finishBrushImmediately())
        session.setLayerOpacity(0.4)
        session.finishOpacityEdit()
        #expect(session.history.undoCount == count + 3)
        for (name, opacity) in [("Layer Opacity", 0.5), ("Brush Stroke", 0.5), ("Layer Opacity", 1)] {
            #expect(session.history.undoName == name)
            session.undo()
            #expect(session.activeLayer?.opacity == opacity)
        }
    }
}
