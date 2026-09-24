import AppKit
import CoreImage

nonisolated enum AdjustmentKind: String, Codable, CaseIterable, Sendable {
    case hsv = "Hue/Saturation", levels = "Levels", curves = "Curves"
    case exposure = "Exposure", gradientMap = "Gradient Map", grain = "Grain", addNoise = "Add Noise"
    case gaussianBlur = "Gaussian Blur", motionBlur = "Motion Blur"
    case invert = "Invert"
    case blackWhite = "Black & White", colorBalance = "Color Balance"

    /// Localized menu/panel name; the English rawValue is the catalog key.
    var localizedName: String {
        String(localized: String.LocalizationValue(rawValue))
    }

    var symbol: String {
        switch self {
        case .curves: return "point.topleft.down.to.point.bottomright.curvepath"
        case .levels: return "slider.horizontal.3"
        case .hsv: return "circle.lefthalf.filled"
        case .exposure: return "plusminus.circle"
        case .gradientMap: return "paintpalette"
        case .grain: return "circle.grid.3x3"
        case .gaussianBlur: return "drop.fill"
        case .motionBlur: return "wind"
        case .addNoise: return "circle.dotted"
        case .invert: return "circle.righthalf.filled"
        case .blackWhite: return "circle.filled.pattern.diagonalline.rectangle"
        case .colorBalance: return "scale.3d"
        }
    }
    /// The filter panel that edits this kind; Levels and Hue/Saturation have panels of their own.
    /// Every kind but Invert opens an editor when its layer is double-clicked.
    var isEditable: Bool { self != .invert }
    var filterKind: FilterKind? {
        switch self {
        case .curves: return .curves
        case .blackWhite: return .blackWhite
        case .colorBalance: return .colorBalance
        case .exposure: return .exposure
        case .gradientMap: return .gradientMap
        case .grain: return .grain
        case .gaussianBlur: return .gaussianBlur
        case .motionBlur: return .motionBlur
        case .addNoise: return .addNoise
        // Hue/Saturation and Levels have panels of their own; Invert has nothing to set.
        case .hsv, .levels, .invert: return nil
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
    var blackWhiteSettings: BlackWhiteSettings?
    var colorBalanceSettings: ColorBalanceSettings?
    // Optional so projects created before blur adjustments continue to decode unchanged.
    var blurRadius: Double?
    var motionAngle: Double?
    var motionDistance: Double?
    var noiseAmount: Double?
    var noiseGaussian: Bool?
    var noiseMonochromatic: Bool?
    var noiseSeed: UInt32?
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
    var blackWhite: BlackWhiteSettings {
        get { blackWhiteSettings ?? BlackWhiteSettings() }
        set { blackWhiteSettings = newValue }
    }
    var colorBalance: ColorBalanceSettings {
        get { colorBalanceSettings ?? ColorBalanceSettings() }
        set { colorBalanceSettings = newValue }
    }
    var gaussianRadius: Double {
        get { blurRadius ?? 10 }
        set { blurRadius = newValue }
    }
    var resolvedMotionAngle: Double {
        get { motionAngle ?? 0 }
        set { motionAngle = newValue }
    }
    var resolvedMotionDistance: Double {
        get { motionDistance ?? 10 }
        set { motionDistance = newValue }
    }
    var resolvedNoiseAmount: Double {
        get { noiseAmount ?? 10 }
        set { noiseAmount = newValue }
    }
    var resolvedNoiseGaussian: Bool {
        get { noiseGaussian ?? false }
        set { noiseGaussian = newValue }
    }
    var resolvedNoiseMonochromatic: Bool {
        get { noiseMonochromatic ?? false }
        set { noiseMonochromatic = newValue }
    }
    var resolvedNoiseSeed: UInt32 {
        get { noiseSeed ?? 0 }
        set { noiseSeed = newValue }
    }
    /// Document-pixel halo needed so a partial canvas redraw can sample beyond its dirty rectangle.
    var samplingMargin: CGFloat {
        switch kind {
        case .gaussianBlur: return CGFloat(gaussianRadius * 3 + 2)
        case .motionBlur: return CGFloat(resolvedMotionDistance / 2 + 2)
        default: return 0
        }
    }
    var isValid: Bool {
        hue.isFinite && saturation.isFinite && lightness.isFinite && abs(hue) <= 360 && abs(saturation) <= 100 && abs(lightness) <= 100
        && resolvedHSV.adjustments.values.allSatisfy {
            $0.hue.isFinite && abs($0.hue) <= 360 && $0.saturation.isFinite && abs($0.saturation) <= 100
                && $0.lightness.isFinite && abs($0.lightness) <= 100
        }
        && resolvedHSV.bands.values.allSatisfy { $0.handles.allSatisfy { $0.isFinite } }
        && levels.ranges.count == 4 && levels.ranges.allSatisfy { $0 == $0.normalized } && curves.isValid
        && exposure.isValid && gradientMap.isValid && grain.isValid && blackWhite.isValid && colorBalance.isValid
        && gaussianRadius.isFinite && (0.1...250).contains(gaussianRadius)
        && resolvedMotionAngle.isFinite && (-90...90).contains(resolvedMotionAngle)
        && resolvedMotionDistance.isFinite && (1...2000).contains(resolvedMotionDistance)
        && resolvedNoiseAmount.isFinite && (0.1...400).contains(resolvedNoiseAmount)
    }
    /// `region` is the part of the document `image` covers (the whole image at one unit per pixel when
    /// omitted), so Grain's pattern stays fixed in the document however the canvas splits its drawing.
    func apply(_ image: CGImage, region: CGRect? = nil, scale: CGFloat = 1) throws -> CGImage {
        switch kind {
        case .hsv:
            return try HueSaturationFilter.run(HueSaturationJob(image: image,
                settings: resolvedHSV,
                selection: nil, pixelToDocument: .identity, thumbnail: false)).image
        case .levels: return try LevelsFilter.run(LevelsJob(image: image, settings: levels, selection: nil, mapping: .identity))
        case .curves: return try curves.apply(image)
        case .blackWhite: return try blackWhite.apply(image)
        case .colorBalance: return try colorBalance.apply(image)
        case .exposure: return try exposure.apply(image)
        case .gradientMap: return try gradientMap.apply(image)
        case .grain:
            let region = region ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)
            return try grain.apply(image, origin: region.origin, unitsPerPixel: region.width / CGFloat(max(1, image.width)))
        case .gaussianBlur, .motionBlur, .addNoise:
            var settings = FilterSettings()
            settings.radius = gaussianRadius
            settings.angle = resolvedMotionAngle
            settings.distance = resolvedMotionDistance
            settings.amount = resolvedNoiseAmount
            settings.gaussian = resolvedNoiseGaussian
            settings.monochromatic = resolvedNoiseMonochromatic
            let filterKind: FilterKind = switch kind {
            case .gaussianBlur: .gaussianBlur
            case .motionBlur: .motionBlur
            default: .addNoise
            }
            return try PixelFilter.run(FilterJob(kind: filterKind, image: image, settings: settings,
                                                  scale: scale, selection: nil, mapping: .identity,
                                                  seed: resolvedNoiseSeed,
                                                  noiseOrigin: region?.origin ?? .zero))
        case .invert:
            return try PixelInvert.run(PixelInvert.Job(image: image, isMask: false,
                                                       pixelToDocument: .identity, selection: nil))
        }
    }
}

extension EditorSession {
    func addAdjustment(_ kind: AdjustmentKind) {
        guard canEditLayers, let document, document.layers.count < 10_000 else { return }
        var layer = ImageLayer(name: kind.rawValue, blankSize: document.size)
        var adjustment = LayerAdjustment(kind: kind)
        // A new Gradient Map runs from the foreground to the background color, as in Photoshop;
        // each Grain layer gets a pattern of its own.
        if kind == .gradientMap {
            adjustment.gradientMap = GradientMapSettings(shadows: AdjustmentColor(foregroundColor), highlights: AdjustmentColor(backgroundColor))
        }
        if kind == .grain { adjustment.grain.seed = .random(in: .min ... .max) }
        if kind == .addNoise { adjustment.resolvedNoiseSeed = .random(in: .min ... .max) }
        layer.adjustment = adjustment
        layer.parentID = activeLayer?.isGroup == true ? activeLayerID : activeLayer?.parentID
        let index = document.layers.firstIndex { $0.id == activeLayerID }.map { $0 + 1 } ?? document.layers.count
        beginEdit("New \(kind.rawValue) Adjustment")
        self.document?.layers.insert(layer, at: index)
        if let parent = layer.parentID { collapsedGroupIDs.remove(parent) }
        activeLayerID = layer.id
        endEdit()
        // Invert has nothing to set, so the new layer just applies rather than opening an editor.
        if kind.isEditable { adjustmentEditingID = layer.id }
    }
    func updateAdjustment(_ id: UUID, value: LayerAdjustment) {
        guard let index = document?.layers.firstIndex(where: { $0.id == id }), value.isValid else { return }
        document?.layers[index].adjustment = value
        brushRevision += 1
    }
}
