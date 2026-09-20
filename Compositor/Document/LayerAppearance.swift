import Foundation
import CoreGraphics

nonisolated enum LayerBlendMode: String, Codable, CaseIterable, Sendable {
    case normal = "Normal", multiply = "Multiply", screen = "Screen", overlay = "Overlay"
    case darken = "Darken", lighten = "Lighten", difference = "Difference"
    case colorDodge = "Color Dodge", colorBurn = "Color Burn"
    case hue = "Hue", saturation = "Saturation", color = "Color", luminosity = "Luminosity"
    var cgMode: CGBlendMode {
        switch self {
        case .normal: .normal
        case .multiply: .multiply
        case .screen: .screen
        case .overlay: .overlay
        case .darken: .darken
        case .lighten: .lighten
        case .difference: .difference
        case .colorDodge: .colorDodge
        case .colorBurn: .colorBurn
        case .hue: .hue
        case .saturation: .saturation
        case .color: .color
        case .luminosity: .luminosity
        }
    }
}

extension EditorSession {
    func displayedBlendMode(for layer: ImageLayer) -> LayerBlendMode {
        if let blendPreview, blendPreview.layerID == layer.id, activeLayerID == layer.id { return blendPreview.mode }
        return layer.blendMode
    }
    func previewBlendMode(_ mode: LayerBlendMode?, for id: UUID?) {
        if let mode, let id, id == activeLayerID, canEditAppearance { blendPreview = (id, mode) }
        else { blendPreview = nil }
        refreshCanvasPreview?()
    }
    var canEditAppearance: Bool { canEditLayers && selectedLayerIDs.count == 1 && activeLayer?.isGroup == false }
    func beginOpacityEdit() {
        guard canEditAppearance, opacityEditLayerID == nil, let id = activeLayerID else { return }
        beginEdit(L10n.string("Layer Opacity"))
        opacityEditLayerID = id
    }
    func finishOpacityEdit() {
        guard opacityEditLayerID != nil else { return }
        opacityEditLayerID = nil
        endEdit()
    }
    func setLayerOpacity(_ opacity: Double) {
        guard opacity.isFinite, canEditAppearance,
              let id = opacityEditLayerID ?? activeLayerID,
              let index = document?.layers.firstIndex(where: { $0.id == id }) else { return }
        let standalone = opacityEditLayerID == nil
        if standalone { beginEdit(L10n.string("Layer Opacity")) }
        document?.layers[index].opacity = min(1, max(0, opacity))
        if standalone { endEdit() }
    }
    /// Sets every selected image layer's opacity as one undo step. Folders have no
    /// opacity of their own yet, so they are skipped.
    func setSelectedLayersOpacity(_ opacity: Double) {
        guard opacity.isFinite, canEditLayers, let document else { return }
        let value = min(1, max(0, opacity))
        let indices = document.layers.indices.filter {
            selectedLayerIDs.contains(document.layers[$0].id) && !document.layers[$0].isGroup && document.layers[$0].opacity != value
        }
        guard !indices.isEmpty else { return }
        finishOpacityEdit()
        beginEdit(L10n.string("Layer Opacity"))
        for index in indices { self.document?.layers[index].opacity = value }
        endEdit()
    }
    /// Shift-+ / Shift-−: the active layer's blend mode steps to the next or previous one in the
    /// blend menu's order, wrapping around, as one undo step.
    func cycleBlendMode(forward: Bool) {
        guard canEditAppearance, let layer = activeLayer else { return }
        let modes = LayerBlendMode.allCases
        let index = modes.firstIndex(of: layer.blendMode) ?? 0
        setLayerBlendMode(modes[(index + (forward ? 1 : modes.count - 1)) % modes.count])
    }
    func setLayerBlendMode(_ mode: LayerBlendMode) {
        blendPreview = nil
        guard canEditAppearance, let index = document?.layers.firstIndex(where: { $0.id == activeLayerID }) else { return }
        finishOpacityEdit()
        beginEdit(L10n.string("Layer Blend Mode"))
        document?.layers[index].blendMode = mode
        endEdit()
    }
}
