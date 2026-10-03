import CoreGraphics
import Testing
@testable import Compositor

/// A layer's effects added, edited, copied and removed, and their editing ending when the effect goes.
@MainActor struct LayerEffectEditingTests {
    /// A 200 × 100 document with `layers` gray layers, the top one active.
    private func session(layers: Int = 1) throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 200, height: 100)
        let context = try BrushRaster.context(width: 200, height: 100, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let image = try #require(context.makeImage())
        for index in 0..<layers { session.insert(ImportedImage(image: image, thumbnail: image, name: "Gray \(index)")) }
        return session
    }

    /// A new Stroke takes the background color, as one step; Cancel takes it away again.
    @Test func aNewStrokeTakesTheBackgroundColorAndCancelTakesItAway() throws {
        let session = try session()
        let id = try #require(session.activeLayerID)
        session.backgroundColor = PaletteColor(red: 0, green: 0, blue: 1)
        session.addEffect(.stroke)
        #expect(session.history.undoName == "Add Stroke")
        #expect(session.activeLayer?.effects?.stroke?.blue == 1)
        #expect(session.effectsEditing == LayerEffectSelection(layerID: id, kind: .stroke))
        session.finishEffectsEditing(commit: false)
        #expect(session.history.undoName == "Cancel Stroke")
        #expect(session.activeLayer?.effects?.stroke == nil && session.effectsEditing == nil)
    }

    /// An effect copied to another layer is selected there.
    @Test func aCopiedEffectIsSelectedOnItsLayer() throws {
        let session = try session(layers: 2)
        let layers = try #require(session.document?.layers.map(\.id))
        let source = layers[1], target = layers[0]
        session.addEffect(.shadow)
        session.finishEffectsEditing(commit: true)
        session.copyEffect(.shadow, from: source, to: target)
        #expect(session.history.undoName == "Copy Drop Shadow")
        #expect(session.selectedEffect == LayerEffectSelection(layerID: target, kind: .shadow))
        #expect(session.document?.layers.first { $0.id == target }?.effects?.shadow == session.document?.layers.first { $0.id == source }?.effects?.shadow)
    }

    /// The selected effect removed is one step.
    @Test func theSelectedEffectIsRemoved() throws {
        let session = try session()
        session.addEffect(.stroke)
        session.finishEffectsEditing(commit: true)
        let id = try #require(session.activeLayerID)
        session.selectEffect(.stroke, on: id)
        session.removeSelectedEffect()
        #expect(session.history.undoName == "Remove Stroke")
        #expect(session.activeLayer?.effects?.stroke == nil)
    }

    /// An effect's editing ends when the effect goes, undone, with its color picker; it stays while the effect does, and
    /// ends when the layer goes too.
    @Test func editingEndsWhenItsEffectGoes() throws {
        let session = try session()
        session.addEffect(.stroke)
        session.endEffectsEditingIfGone()
        #expect(session.effectsEditing != nil)
        session.openEffectColorPicker(.stroke)
        try #require(session.colorPicker != nil)
        session.undo()
        try #require(session.activeLayer?.effects?.stroke == nil)
        session.endEffectsEditingIfGone()
        #expect(session.effectsEditing == nil && session.effectsEditingOriginal == nil && session.colorPicker == nil)

        session.addEffect(.shadow)
        session.deleteActiveLayer()
        try #require(session.document?.layers.isEmpty == true)
        session.endEffectsEditingIfGone()
        #expect(session.effectsEditing == nil)
    }
}
