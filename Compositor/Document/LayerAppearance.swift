import Foundation
import CoreGraphics

nonisolated enum LayerBlendMode: String, Codable, CaseIterable, Sendable {
    case normal = "Normal"
    case darken = "Darken", multiply = "Multiply", colorBurn = "Color Burn"
    case linearBurn = "Linear Burn"
    case lighten = "Lighten", screen = "Screen", colorDodge = "Color Dodge"
    case linearDodge = "Linear Dodge (Add)"
    case overlay = "Overlay", softLight = "Soft Light", hardLight = "Hard Light"
    case vividLight = "Vivid Light", linearLight = "Linear Light", pinLight = "Pin Light", hardMix = "Hard Mix"
    case difference = "Difference", exclusion = "Exclusion", subtract = "Subtract", divide = "Divide"
    case hue = "Hue", saturation = "Saturation", color = "Color", luminosity = "Luminosity"

    /// Photoshop's grouping: darkening modes together, then lightening, then contrast, then the
    /// comparative ones, then the component modes. The menu draws a line between each group.
    static let groups: [[LayerBlendMode]] = [
        [.normal],
        [.darken, .multiply, .colorBurn, .linearBurn],
        [.lighten, .screen, .colorDodge, .linearDodge],
        [.overlay, .softLight, .hardLight, .vividLight, .linearLight, .pinLight, .hardMix],
        [.difference, .exclusion, .subtract, .divide],
        [.hue, .saturation, .color, .luminosity]
    ]

    /// What Core Graphics can draw directly. The rest are composited through Core Image or by hand,
    /// so this is only meaningful for the modes `SeparableBlend.needsSurface` leaves alone.
    var cgMode: CGBlendMode {
        switch self {
        case .normal: .normal
        case .multiply: .multiply
        case .screen: .screen
        case .overlay: .overlay
        case .softLight: .softLight
        case .hardLight: .hardLight
        case .darken: .darken
        case .lighten: .lighten
        case .difference: .difference
        case .exclusion: .exclusion
        case .colorDodge: .colorDodge
        case .colorBurn: .colorBurn
        case .hue: .hue
        case .saturation: .saturation
        case .color: .color
        case .luminosity: .luminosity
        // Drawn through Core Image or by hand; never reaches Core Graphics.
        case .linearBurn, .linearDodge, .vividLight, .linearLight, .pinLight, .hardMix, .subtract, .divide: .normal
        }
    }

    /// The Core Image filter that computes this mode, for the ones Core Graphics has no equivalent
    /// for — or computes wrongly, as it does for Color Burn and Color Dodge.
    var coreImageFilter: String? {
        switch self {
        case .colorBurn: "CIColorBurnBlendMode"
        case .colorDodge: "CIColorDodgeBlendMode"
        case .linearBurn: "CILinearBurnBlendMode"
        case .linearDodge: "CILinearDodgeBlendMode"
        case .vividLight: "CIVividLightBlendMode"
        case .linearLight: "CILinearLightBlendMode"
        case .pinLight: "CIPinLightBlendMode"
        case .hardMix: "CIHardMixBlendMode"
        case .subtract: "CISubtractBlendMode"
        case .divide: "CIDivideBlendMode"
        default: nil
        }
    }

    // Photoshop's Darker Color and Lighter Color are left out: they compare a pixel's whole
    // brightness rather than working a channel at a time, and neither framework implements them.
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
    /// A folder takes an opacity of its own, which dims everything inside it (see LayerOpacity);
    /// blending still belongs to each layer, so the rest of the appearance controls stay off for folders.
    var canEditOpacity: Bool { canEditLayers && selectedLayerIDs.count == 1 && activeLayer != nil }
    func beginOpacityEdit() {
        guard canEditOpacity, opacityEditLayerID == nil, let id = activeLayerID else { return }
        beginEdit("Layer Opacity")
        opacityEditLayerID = id
    }
    func finishOpacityEdit() {
        guard opacityEditLayerID != nil else { return }
        opacityEditLayerID = nil
        endEdit()
    }
    func setLayerOpacity(_ opacity: Double) {
        guard opacity.isFinite, canEditOpacity,
              let id = opacityEditLayerID ?? activeLayerID,
              let index = document?.layers.firstIndex(where: { $0.id == id }) else { return }
        let standalone = opacityEditLayerID == nil
        if standalone { beginEdit("Layer Opacity") }
        document?.layers[index].opacity = min(1, max(0, opacity))
        if standalone { endEdit() }
    }
    /// Sets every selected layer's opacity as one undo step. A selected folder takes the value too,
    /// dimming its contents on top of their own opacity.
    func setSelectedLayersOpacity(_ opacity: Double) {
        guard opacity.isFinite, canEditLayers, let document else { return }
        let value = min(1, max(0, opacity))
        let indices = document.layers.indices.filter {
            selectedLayerIDs.contains(document.layers[$0].id) && document.layers[$0].opacity != value
        }
        guard !indices.isEmpty else { return }
        finishOpacityEdit()
        beginEdit("Layer Opacity")
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
        beginEdit("Layer Blend Mode")
        document?.layers[index].blendMode = mode
        endEdit()
    }
}
