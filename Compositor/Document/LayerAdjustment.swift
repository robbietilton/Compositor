import AppKit
import CoreImage

nonisolated enum AdjustmentKind: String, Codable, CaseIterable, Sendable {
    case hsv = "Hue/Saturation", levels = "Levels", curves = "Curves"
    case exposure = "Exposure", gradientMap = "Gradient Map", grain = "Grain", addNoise = "Add Noise"
    case gaussianBlur = "Gaussian Blur", motionBlur = "Motion Blur"
    case structure = "Structure"
    case invert = "Invert"
    case blackWhite = "Black & White", colorBalance = "Color Balance"
    case progressiveBlur = "Progressive Blur", bloomGlow = "Bloom / Glow", rgbSplit = "RGB Split"
    /// The menus' two groups, each in the order of the menu it comes from: the Image menu's color adjustments, then
    /// the Filter menu's filters.
    static let imageAdjustments: [Self] = [.curves, .levels, .hsv, .blackWhite, .colorBalance, .exposure, .gradientMap, .grain, .invert]
    static let filters: [Self] = [.gaussianBlur, .motionBlur, .progressiveBlur, .addNoise, .bloomGlow, .rgbSplit, .structure]
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
        case .structure: return "circle.grid.2x2"
        case .invert: return "circle.righthalf.filled"
        case .blackWhite: return "circle.filled.pattern.diagonalline.rectangle"
        case .colorBalance: return "scale.3d"
        case .progressiveBlur: return "aqi.medium"
        case .bloomGlow: return "sun.max"
        case .rgbSplit: return "rainbow"
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
        case .progressiveBlur: return .progressiveBlur
        case .bloomGlow: return .bloomGlow
        case .rgbSplit: return .rgbSplit
        case .structure: return .structure
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
    // Optional so projects from before these filter layers (version 16) decode and save unchanged.
    var filterLayerSettings: FilterLayerSettings?
    /// Progressive Blur, Bloom / Glow and RGB Split's settings.
    var filterLayer: FilterLayerSettings {
        get { filterLayerSettings ?? FilterLayerSettings() }
        set { filterLayerSettings = newValue }
    }
    // Optional so projects saved before Structure adjustments continue to decode unchanged.
    var structureAmount: Double?
    var structureRadius: Double?
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
    /// Local-detail strength, −100…100. Zero leaves the image unchanged.
    var resolvedStructureAmount: Double {
        get { structureAmount ?? 0 }
        set { structureAmount = newValue }
    }
    /// Local-detail radius in document pixels, 1–100.
    var resolvedStructureRadius: Double {
        get { structureRadius ?? 16 }
        set { structureRadius = newValue }
    }
    /// Document-pixel halo needed so a partial canvas redraw can sample beyond its dirty rectangle.
    var samplingMargin: CGFloat {
        switch kind {
        case .gaussianBlur: return CGFloat(gaussianRadius * 3 + 2)
        case .motionBlur: return CGFloat(resolvedMotionDistance / 2 + 2)
        case .progressiveBlur, .bloomGlow, .rgbSplit:
            return FilterEdit.blurMargin(kind.filterKind ?? .bloomGlow, filterLayer.applied(to: FilterSettings()))
        case .structure:
            return resolvedStructureAmount == 0 ? 0 : CGFloat(resolvedStructureRadius * 3 + 2)
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
        && filterLayer.isValid
        && resolvedStructureAmount.isFinite && (-100...100).contains(resolvedStructureAmount)
        && resolvedStructureRadius.isFinite && (1...100).contains(resolvedStructureRadius)
    }
    /// `region` is the part of the document `image` covers (the whole image at one unit per pixel when
    /// omitted), so Grain's pattern stays fixed in the document however the canvas splits its drawing.
    /// Its color lookup, for those whose channels mix, to apply at 16 bits (`DeepLayer.lookup`); nil for the rest.
    var sixteenBitLookup: (cube: Data, dimension: Int)? {
        switch kind {
        case .hsv: (HueSaturationFilter.cube(resolvedHSV), HueSaturationFilter.dimension)
        case .blackWhite, .colorBalance, .gradientMap: GPUAdjustment.cube(for: self).map { ($0, GPUAdjustment.dimension) }
        default: nil
        }
    }

    /// `apply` on 16-bit or HDR pixels (`DeepLayer`): the blurs once in Core Image, which keeps them as they are;
    /// Exposure exactly on HDR ones; through its color lookup when its channels mix; otherwise run several times and
    /// read between (`DeepLayer.run`).
    func applySixteenBit(_ image: CGImage, region: CGRect? = nil, scale: CGFloat = 1) throws -> CGImage {
        if [.gaussianBlur, .motionBlur, .progressiveBlur, .bloomGlow].contains(kind) {
            return try apply(image, region: region, scale: scale, sixteenBit: true)
        }
        if kind == .exposure, DeepLayer.isHDR(image) { return try DeepLayer.exposure(image, exposure) }
        if let lookup = sixteenBitLookup { return try DeepLayer.lookup(image, cube: lookup.cube, dimension: lookup.dimension) }
        return try DeepLayer.run(image) { try apply($0, region: region, scale: scale) }
    }

    /// `sixteenBit`: the blurs render at the image's own depth (`FilterJob.sixteenBit`).
    func apply(_ image: CGImage, region: CGRect? = nil, scale: CGFloat = 1, sixteenBit: Bool = false) throws -> CGImage {
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
            var job = FilterJob(kind: filterKind, image: image, settings: settings,
                                scale: scale, selection: nil, mapping: .identity,
                                seed: resolvedNoiseSeed,
                                // The region's origin in the image's own pixels.
                                noiseOrigin: region.map { CGPoint(x: $0.minX * CGFloat(image.width) / max(1, $0.width),
                                                                  y: $0.minY * CGFloat(image.height) / max(1, $0.height)) } ?? .zero)
            job.sixteenBit = sixteenBit && filterKind != .addNoise
            return try PixelFilter.run(job)
        case .progressiveBlur, .bloomGlow, .rgbSplit:
            // The positions are the document's: `region` places this image in it.
            let region = region ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let mapping = CGAffineTransform(a: region.width / CGFloat(max(1, image.width)), b: 0, c: 0,
                                            d: region.height / CGFloat(max(1, image.height)), tx: region.minX, ty: region.minY)
            var job = FilterJob(kind: kind.filterKind ?? .bloomGlow, image: image, settings: filterLayer.applied(to: FilterSettings()),
                                scale: scale, selection: nil, mapping: mapping)
            job.sixteenBit = sixteenBit && kind != .rgbSplit
            return try PixelFilter.run(job)
        case .structure:
            guard resolvedStructureAmount != 0 else { return image }
            var settings = FilterSettings()
            settings.tonalAmount = resolvedStructureAmount
            settings.tonalRadius = resolvedStructureRadius
            return try PixelFilter.run(FilterJob(kind: .structure, image: image, settings: settings,
                                                  scale: scale, selection: nil, mapping: .identity))
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
        // Progressive Blur's line and RGB Split's center start on the canvas, as the filters' do on a layer.
        let canvas = CGRect(origin: .zero, size: document.size)
        if kind == .progressiveBlur {
            adjustment.filterLayer.progressiveStart = CGPoint(x: canvas.midX, y: canvas.height * 0.35)
            adjustment.filterLayer.progressiveEnd = CGPoint(x: canvas.midX, y: canvas.maxY)
        }
        if kind == .rgbSplit {
            adjustment.filterLayer.rgbSplitCenter = CGPoint(x: canvas.midX, y: canvas.midY)
            adjustment.filterLayer.rgbSplitReach = max(1, hypot(canvas.width, canvas.height) / 2)
        }
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

/// The settings a Progressive Blur, Bloom / Glow or RGB Split adjustment layer keeps: those of its filter (see
/// `FilterSettings`), positions in the document's pixels.
nonisolated struct FilterLayerSettings: Codable, Equatable, Sendable {
    var progressiveFrom: Double = 0
    var progressiveTo: Double = 20
    var progressiveStart: CGPoint?
    var progressiveEnd: CGPoint?
    var progressiveRadial = false
    var progressiveInverted = false
    var bloomAmount: Double = 40
    var bloomRadius: Double = 24
    var rgbSplitDistance: Double = 10
    var rgbSplitBlur: Double = 0
    var rgbSplitAngle: Double = 0
    var rgbSplitRadial = false
    var rgbSplitCenter: CGPoint?
    var rgbSplitReach: Double = 1000

    init() {}
    init(_ settings: FilterSettings) {
        let settings = settings.normalized
        progressiveFrom = settings.progressiveFrom; progressiveTo = settings.progressiveTo
        progressiveStart = settings.progressiveStart; progressiveEnd = settings.progressiveEnd
        progressiveRadial = settings.progressiveRadial; progressiveInverted = settings.progressiveInverted
        bloomAmount = settings.bloomAmount; bloomRadius = settings.bloomRadius
        rgbSplitDistance = settings.rgbSplitDistance; rgbSplitBlur = settings.rgbSplitBlur; rgbSplitAngle = settings.rgbSplitAngle
        rgbSplitRadial = settings.rgbSplitRadial; rgbSplitCenter = settings.rgbSplitCenter; rgbSplitReach = settings.rgbSplitReach
    }

    /// `settings` with these in place of its own.
    func applied(to settings: FilterSettings) -> FilterSettings {
        var settings = settings
        settings.progressiveFrom = progressiveFrom; settings.progressiveTo = progressiveTo
        settings.progressiveStart = progressiveStart; settings.progressiveEnd = progressiveEnd
        settings.progressiveRadial = progressiveRadial; settings.progressiveInverted = progressiveInverted
        settings.bloomAmount = bloomAmount; settings.bloomRadius = bloomRadius
        settings.rgbSplitDistance = rgbSplitDistance; settings.rgbSplitBlur = rgbSplitBlur; settings.rgbSplitAngle = rgbSplitAngle
        settings.rgbSplitRadial = rgbSplitRadial; settings.rgbSplitCenter = rgbSplitCenter; settings.rgbSplitReach = rgbSplitReach
        return settings
    }

    /// Within the ranges the filters take, every number finite.
    var isValid: Bool {
        let points = [progressiveStart, progressiveEnd, rgbSplitCenter].compactMap { $0 }
        return self == Self(applied(to: FilterSettings())) && points.allSatisfy { $0.x.isFinite && $0.y.isFinite }
    }
}
