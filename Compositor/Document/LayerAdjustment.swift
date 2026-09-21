import AppKit
import CoreImage

nonisolated enum AdjustmentKind: String, Codable, CaseIterable, Sendable {
    case hsv = "Hue/Saturation", levels = "Levels", curves = "Curves"
    case exposure = "Exposure", gradientMap = "Gradient Map", grain = "Grain"

    /// The localized menu/picker title. The raw value stays English (it doubles as a stable identifier).
    var displayName: String {
        switch self {
        case .hsv: String(localized: "Hue/Saturation")
        case .levels: String(localized: "Levels")
        case .curves: String(localized: "Curves")
        case .exposure: String(localized: "Exposure")
        case .gradientMap: String(localized: "Gradient Map")
        case .grain: String(localized: "Grain")
        }
    }
    var symbol: String {
        switch self {
        case .curves: return "point.topleft.down.to.point.bottomright.curvepath"
        case .levels: return "slider.horizontal.3"
        case .hsv: return "circle.lefthalf.filled"
        case .exposure: return "plusminus.circle"
        case .gradientMap: return "paintpalette"
        case .grain: return "circle.grid.3x3"
        }
    }
    /// The filter panel that edits this kind; Levels and Hue/Saturation have panels of their own.
    var filterKind: FilterKind? {
        switch self {
        case .curves: return .curves
        case .exposure: return .exposure
        case .gradientMap: return .gradientMap
        case .grain: return .grain
        case .hsv, .levels: return nil
        }
    }
}
nonisolated struct LayerAdjustment: Codable, Equatable, Sendable {
    var kind: AdjustmentKind
    var hue: Double = 0
    var saturation: Double = 0
    var lightness: Double = 0
    var colorize = false
    // Optional so projects saved before range-aware HSV adjustments still decode.
    var hsvSettings: HueSaturationSettings?
    var resolvedHSV: HueSaturationSettings {
        hsvSettings ?? HueSaturationSettings(hue: hue, saturation: saturation, lightness: lightness, colorize: colorize)
    }
    var levels = LevelsSettings()
    var curves = CurvesSettings()
    // Optional so projects saved before these adjustments existed decode, and save, exactly as before.
    var exposureSettings: ExposureSettings?
    var gradientMapSettings: GradientMapSettings?
    var grainSettings: GrainSettings?
    var exposure: ExposureSettings {
        get { exposureSettings ?? ExposureSettings() }
        set { exposureSettings = newValue }
    }
    var gradientMap: GradientMapSettings {
        get { gradientMapSettings ?? GradientMapSettings() }
        set { gradientMapSettings = newValue }
    }
    var grain: GrainSettings {
        get { grainSettings ?? GrainSettings() }
        set { grainSettings = newValue }
    }
    var isValid: Bool {
        hue.isFinite && saturation.isFinite && lightness.isFinite && abs(hue) <= 360 && abs(saturation) <= 100 && abs(lightness) <= 100
        && resolvedHSV.adjustments.values.allSatisfy {
            $0.hue.isFinite && abs($0.hue) <= 360 && $0.saturation.isFinite && abs($0.saturation) <= 100
                && $0.lightness.isFinite && abs($0.lightness) <= 100
        }
        && resolvedHSV.bands.values.allSatisfy { $0.handles.allSatisfy { $0.isFinite } }
        && levels.ranges.count == 4 && levels.ranges.allSatisfy { $0 == $0.normalized } && curves.isValid
        && exposure.isValid && gradientMap.isValid && grain.isValid
    }
    /// `region` is the part of the document `image` covers (the whole image at one unit per pixel when
    /// omitted), so Grain's pattern stays fixed in the document however the canvas splits its drawing.
    func apply(_ image: CGImage, region: CGRect? = nil) throws -> CGImage {
        switch kind {
        case .hsv:
            return try HueSaturationFilter.run(HueSaturationJob(image: image,
                settings: resolvedHSV,
                selection: nil, pixelToDocument: .identity, thumbnail: false)).image
        case .levels: return try LevelsFilter.run(LevelsJob(image: image, settings: levels, selection: nil, mapping: .identity))
        case .curves: return try curves.apply(image)
        case .exposure: return try exposure.apply(image)
        case .gradientMap: return try gradientMap.apply(image)
        case .grain:
            let region = region ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)
            return try grain.apply(image, origin: region.origin, unitsPerPixel: region.width / CGFloat(max(1, image.width)))
        }
    }
}

extension EditorSession {
    func addAdjustment(_ kind: AdjustmentKind) {
        guard canEditLayers, let document, document.layers.count < 10_000 else { return }
        var layer = ImageLayer(name: String(localized: String.LocalizationValue(kind.rawValue)), blankSize: document.size)
        var adjustment = LayerAdjustment(kind: kind)
        // A new Gradient Map runs from the foreground to the background color, as in Photoshop;
        // each Grain layer gets a pattern of its own.
        if kind == .gradientMap {
            adjustment.gradientMap = GradientMapSettings(shadows: AdjustmentColor(foregroundColor), highlights: AdjustmentColor(backgroundColor))
        }
        if kind == .grain { adjustment.grain.seed = .random(in: .min ... .max) }
        layer.adjustment = adjustment
        layer.parentID = activeLayer?.isGroup == true ? activeLayerID : activeLayer?.parentID
        let index = document.layers.firstIndex { $0.id == activeLayerID }.map { $0 + 1 } ?? document.layers.count
        beginEdit(String(format: String(localized: "New %@ Adjustment"), String(localized: String.LocalizationValue(kind.rawValue))))
        self.document?.layers.insert(layer, at: index)
        if let parent = layer.parentID { collapsedGroupIDs.remove(parent) }
        activeLayerID = layer.id
        endEdit()
        adjustmentEditingID = layer.id
    }
    func updateAdjustment(_ id: UUID, value: LayerAdjustment) {
        guard let index = document?.layers.firstIndex(where: { $0.id == id }), value.isValid else { return }
        document?.layers[index].adjustment = value
        brushRevision += 1
    }
}
