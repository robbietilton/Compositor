import Foundation

/// Copy/Paste/Clear Layer Style: Photoshop's name for a layer's `LayerEffects` (its stroke, shadow, glow…), taken
/// as one unit rather than the single-effect copy an Option-drag in the panel already does.
extension EditorSession {
    /// The style Copy Layer Style set aside: one for the whole app, as Photoshop's is, so it pastes into another
    /// document too. Not part of any document, so it isn't saved or covered by undo.
    @MainActor @Observable final class LayerStyleClipboard {
        static let shared = LayerStyleClipboard()
        var effects: LayerEffects?
    }
    var copiedLayerEffects: LayerEffects? { LayerStyleClipboard.shared.effects }
    /// Selected layers that can hold effects: groups and layers without pixels can't.
    private var styleTargets: [ImageLayer] {
        document?.layers.filter { selectedLayerIDs.contains($0.id) && !$0.isGroup && $0.asset != nil } ?? []
    }
    var canCopyLayerStyle: Bool { canEditLayers && activeLayer?.effects?.isEmpty == false }
    var canPasteLayerStyle: Bool { canEditLayers && copiedLayerEffects != nil && !styleTargets.isEmpty }
    var canClearLayerStyle: Bool { canEditLayers && styleTargets.contains { $0.effects?.isEmpty == false } }

    func copyLayerStyle() {
        guard canCopyLayerStyle else { return }
        LayerStyleClipboard.shared.effects = activeLayer?.effects
    }

    /// Applies the copied style to every selected layer that can hold effects, as one undo step.
    func pasteLayerStyle() {
        guard canPasteLayerStyle, let effects = copiedLayerEffects else { return }
        let targets = styleTargets
        finishOpacityEdit()
        beginEdit("Paste Layer Style")
        for target in targets { setEffects(effects, on: target.id, name: "Paste Layer Style") }
        endEdit()
    }

    /// Removes effects from every selected layer that has any, as one undo step.
    func clearLayerStyle() {
        guard canClearLayerStyle else { return }
        let targets = styleTargets.filter { $0.effects?.isEmpty == false }
        finishOpacityEdit()
        beginEdit("Clear Layer Style")
        for target in targets { setEffects(LayerEffects(), on: target.id, name: "Clear Layer Style") }
        endEdit()
    }
}
