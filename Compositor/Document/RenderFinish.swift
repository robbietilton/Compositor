import AppKit

/// Independent implementations inspired by photographic finishing workflows, not Nik algorithms. The raw values
/// are the kinds FinishPixels.c takes; the photo realism group follows the original seven.
nonisolated enum FinishEffect: Int, CaseIterable, Sendable, Identifiable {
    case tonalContrast, ink, proContrast, detailExtractor, bloom, warmth, vignette
    case sensorGrain, microTexture, highlightRolloff, chromaticAberration, lensSoftness
    var id: Int { rawValue }
    /// Camera and lens character that makes a render read as a photograph.
    var isPhotoRealism: Bool { rawValue >= FinishEffect.sensorGrain.rawValue }
    var title: String {
        switch self {
        case .tonalContrast: "Tonal Contrast"
        case .ink: "Ink"
        case .proContrast: "Pro Contrast"
        case .detailExtractor: "Detail Extractor"
        case .bloom: "Bloom / Glow"
        case .warmth: "Brilliance / Warmth"
        case .vignette: "Vignette"
        case .sensorGrain: "Sensor Grain"
        case .microTexture: "Micro Texture"
        case .highlightRolloff: "Highlight Rolloff"
        case .chromaticAberration: "Chromatic Aberration"
        case .lensSoftness: "Lens Softness"
        }
    }
    var summary: String {
        switch self {
        case .tonalContrast: "Bring out texture separately in shadows, midtones and highlights."
        case .ink: "Photographic paper and ink tones for a stylized final image."
        case .proContrast: "Add a gentle S-curve for depth while keeping black and white endpoints."
        case .detailExtractor: "Reveal material detail and gently balance local lighting."
        case .bloom: "Diffuse bright areas for softer windows, lamps and reflections."
        case .warmth: "Balance cool and warm light, and refine color intensity."
        case .vignette: "Darken the edges softly to draw attention toward the center."
        case .sensorGrain: "Fine, film-like grain, strongest in the midtones, that breaks up the too-clean look of CG."
        case .microTexture: "Lift only the finest texture, such as fabric weave and rug fibres, leaving flat areas and noise alone."
        case .highlightRolloff: "Ease bright areas into white as a camera does, with a warm halation around windows and lamps."
        case .chromaticAberration: "Split red and blue slightly toward the corners, like a real lens."
        case .lensSoftness: "Soften the image gradually toward the corners, keeping the center sharp."
        }
    }
    /// A stable name for saved presets, independent of the order of the cases.
    var key: String {
        switch self {
        case .tonalContrast: "tonalContrast"
        case .ink: "ink"
        case .proContrast: "proContrast"
        case .detailExtractor: "detailExtractor"
        case .bloom: "bloom"
        case .warmth: "warmth"
        case .vignette: "vignette"
        case .sensorGrain: "sensorGrain"
        case .microTexture: "microTexture"
        case .highlightRolloff: "highlightRolloff"
        case .chromaticAberration: "chromaticAberration"
        case .lensSoftness: "lensSoftness"
        }
    }
    var usesRadius: Bool { radiusControl != nil }
    /// What Radius means for this effect, and its slider range, in layer pixels.
    var radiusControl: (title: String, range: ClosedRange<Double>)? {
        switch self {
        case .tonalContrast, .detailExtractor, .bloom: ("Detail radius", 1...100)
        case .sensorGrain: ("Grain size", 1...6)
        case .microTexture: ("Texture scale", 1...6)
        case .highlightRolloff: ("Halation radius", 1...100)
        case .chromaticAberration: ("Fringe at the corners", 1...12)
        case .lensSoftness: ("Softness radius", 1...40)
        case .ink, .proContrast, .warmth, .vignette: nil
        }
    }
    var defaults: FinishParameters {
        var value = FinishParameters()
        switch self {
        case .tonalContrast: value.enabled = true; value.amount = 50; value.radius = 16
        case .ink: value.amount = 60
        case .proContrast: value.amount = 40
        case .detailExtractor: value.amount = 30; value.radius = 5
        case .bloom: value.amount = 25; value.radius = 24
        case .warmth: value.amount = 50; value.shadows = 20; value.saturation = 8
        case .vignette: value.amount = 25
        case .sensorGrain: value.amount = 30; value.radius = 1.5
        case .microTexture: value.amount = 40; value.radius = 1
        case .highlightRolloff: value.amount = 40; value.highlights = 30; value.radius = 16
        case .chromaticAberration: value.amount = 100; value.radius = 2
        case .lensSoftness: value.amount = 40; value.radius = 4
        }
        return value
    }
}

nonisolated enum TonalContrastType: Int, CaseIterable, Sendable, Identifiable {
    case standard, highPass, fine, balanced, strong
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .standard: "Standard"
        case .highPass: "High Pass"
        case .fine: "Fine"
        case .balanced: "Balanced"
        case .strong: "Strong"
        }
    }
    /// The texture scale relative to Radius; matches `radii` in FinishPixels.c.
    var radiusScale: Double {
        switch self {
        case .standard: 1
        case .highPass: 0.5
        case .fine: 0.25
        case .balanced: 1.5
        case .strong: 2
        }
    }
}

nonisolated struct FinishParameters: Equatable, Sendable {
    var enabled = false
    var amount: Double = 50
    var shadows: Double = 40
    var midtones: Double = 60
    var highlights: Double = 30
    var radius: Double = 16
    var saturation: Double = 0
    var palette = 0
    var contrastType: TonalContrastType = .standard
    var protectShadows: Double = 0
    var protectHighlights: Double = 0

    func normalized(for effect: FinishEffect) -> Self {
        let fallback = effect.defaults
        func finite(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        var result = self
        result.amount = finite(amount, 0...100, fallback.amount)
        result.shadows = finite(shadows, effect == .warmth || effect == .tonalContrast ? -100...100 : 0...100, fallback.shadows)
        result.midtones = finite(midtones, -100...100, fallback.midtones)
        result.highlights = finite(highlights, -100...100, fallback.highlights)
        result.radius = finite(radius, effect.radiusControl?.range ?? 1...100, fallback.radius)
        result.saturation = finite(saturation, -100...100, fallback.saturation)
        result.protectShadows = finite(protectShadows, 0...100, 0)
        result.protectHighlights = finite(protectHighlights, 0...100, 0)
        result.palette = min(5, max(0, palette))
        return result
    }

    /// These settings as the pixel processor takes them; `scale` is pixels of the processed image per layer pixel.
    func pixelSettings(for effect: FinishEffect, scale: CGFloat, seed: UInt32 = 0) -> FinishEffectSettings {
        FinishEffectSettings(kind: Int32(effect.rawValue), amount: Float(amount / 100), shadows: Float(shadows / 100),
                             midtones: Float(midtones / 100), highlights: Float(highlights / 100),
                             radius: Float(radius * scale), saturation: Float(saturation / 100), palette: Int32(palette),
                             contrast_type: Int32(contrastType.rawValue), protect_shadows: Float(protectShadows / 100),
                             protect_highlights: Float(protectHighlights / 100), seed: seed)
    }

    /// Whether these settings leave every pixel of `effect` unchanged, so it can be skipped.
    func isNeutral(for effect: FinishEffect) -> Bool {
        guard enabled, amount > 0 else { return true }
        switch effect {
        case .tonalContrast:
            return shadows == 0 && midtones == 0 && highlights == 0 && saturation == 0
                && protectShadows == 0 && protectHighlights == 0
        case .warmth: return shadows == 0 && saturation == 0
        default: return false
        }
    }
}

/// Missing keys keep their defaults, so presets saved by older versions still load.
nonisolated extension FinishParameters: Codable {
    private enum CodingKeys: String, CodingKey {
        case enabled, amount, shadows, midtones, highlights, radius, saturation, palette, contrastType
        case protectShadows, protectHighlights
    }
    init(from decoder: any Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        amount = try values.decodeIfPresent(Double.self, forKey: .amount) ?? amount
        shadows = try values.decodeIfPresent(Double.self, forKey: .shadows) ?? shadows
        midtones = try values.decodeIfPresent(Double.self, forKey: .midtones) ?? midtones
        highlights = try values.decodeIfPresent(Double.self, forKey: .highlights) ?? highlights
        radius = try values.decodeIfPresent(Double.self, forKey: .radius) ?? radius
        saturation = try values.decodeIfPresent(Double.self, forKey: .saturation) ?? saturation
        palette = try values.decodeIfPresent(Int.self, forKey: .palette) ?? palette
        contrastType = try values.decodeIfPresent(Int.self, forKey: .contrastType)
            .flatMap(TonalContrastType.init(rawValue:)) ?? contrastType
        protectShadows = try values.decodeIfPresent(Double.self, forKey: .protectShadows) ?? protectShadows
        protectHighlights = try values.decodeIfPresent(Double.self, forKey: .protectHighlights) ?? protectHighlights
    }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(enabled, forKey: .enabled)
        try values.encode(amount, forKey: .amount)
        try values.encode(shadows, forKey: .shadows)
        try values.encode(midtones, forKey: .midtones)
        try values.encode(highlights, forKey: .highlights)
        try values.encode(radius, forKey: .radius)
        try values.encode(saturation, forKey: .saturation)
        try values.encode(palette, forKey: .palette)
        try values.encode(contrastType.rawValue, forKey: .contrastType)
        try values.encode(protectShadows, forKey: .protectShadows)
        try values.encode(protectHighlights, forKey: .protectHighlights)
    }
}

/// Where a crop lies within the whole layer, in its pixels, when only part of the layer is processed.
nonisolated struct FinishRegion: Equatable, Sendable {
    var x: Int
    var y: Int
    var fullWidth: Int
    var fullHeight: Int
}

nonisolated struct RenderFinishSettings: Equatable, Sendable {
    private var effects = FinishEffect.allCases.map(\.defaults)
    static let palettes = ["Carbon", "Sepia", "Cyanotype", "Warm Violet", "Teal", "Copper"]
    // Tone/detail first, then color, glow, lens and final framing; grain sits on top of everything, as a sensor's
    // would. UI order emphasizes the two main filters.
    static let processingOrder: [FinishEffect] = [.tonalContrast, .detailExtractor, .microTexture, .proContrast, .ink, .warmth,
                                                  .highlightRolloff, .bloom, .lensSoftness, .chromaticAberration, .vignette, .sensorGrain]
    subscript(_ effect: FinishEffect) -> FinishParameters {
        get { effects[effect.rawValue] }
        set { effects[effect.rawValue] = newValue }
    }
    var normalized: Self {
        var result = self
        for effect in FinishEffect.allCases { result[effect] = self[effect].normalized(for: effect) }
        return result
    }
    /// Every effect that changes pixels, in library order.
    var activeEffects: [FinishEffect] { FinishEffect.allCases.filter { !self[$0].isNeutral(for: $0) } }
    var isIdentity: Bool { activeEffects.isEmpty }

    /// How far, in pixels at `scale`, the active spatial effects reach: in a processed crop, pixels closer than this
    /// to a cut edge differ from the whole layer's result. Three box passes reach three radii; chained effects add up.
    func reach(scale: CGFloat = 1) -> Int {
        let settings = normalized
        var total = 0
        for effect in FinishEffect.allCases where !settings[effect].isNeutral(for: effect) {
            let p = settings[effect]
            switch effect {
            case .tonalContrast, .detailExtractor, .bloom, .microTexture, .highlightRolloff, .lensSoftness:
                if effect == .tonalContrast && p.shadows == 0 && p.midtones == 0 && p.highlights == 0 { continue }
                if effect == .highlightRolloff && p.highlights <= 0 { continue }
                let radius = p.radius * Double(scale) * (effect == .tonalContrast ? p.contrastType.radiusScale : 1)
                total += 3 * Int(max(1, min(500, radius.rounded())))
            case .chromaticAberration:
                total += Int((p.radius * Double(scale) * p.amount / 100).rounded(.up)) + 2
            case .ink, .proContrast, .warmth, .vignette, .sensorGrain: break
            }
        }
        return total + 2
    }

    /// `region`: `image` is a crop of a larger layer (the zoomed-in preview), so Vignette is placed on the whole layer.
    /// `cache`: an open edit's preview, which keeps each effect's output so a later effect's change starts from there.
    /// `seed`: the grain pattern, fixed for an open edit so its preview, zoomed-in detail and result agree.
    func apply(_ image: CGImage, scale: CGFloat, region: FinishRegion? = nil, cache: FinishStageCache? = nil,
               seed: UInt32 = 0) throws -> CGImage {
        let settings = normalized
        let stages = Self.processingOrder.filter { !settings[$0].isNeutral(for: $0) }
            .map { FinishStageCache.Stage(effect: $0, parameters: settings[$0]) }
        guard !stages.isEmpty else { return image }
        let reused = cache?.prefix(of: stages, from: image, scale: scale, region: region, seed: seed) ?? []
        if reused.count == stages.count, let finished = reused.last?.image { return finished }
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(reused.last?.image ?? image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { throw ExportError.render }
        let place = region ?? FinishRegion(x: 0, y: 0, fullWidth: image.width, fullHeight: image.height)
        func process(_ run: some Collection<FinishStageCache.Stage>) throws {
            let effects = run.map { $0.parameters.pixelSettings(for: $0.effect, scale: scale, seed: seed) }
            let done = effects.withUnsafeBufferPointer {
                finish_apply_stack(bytes, image.width, image.height, context.bytesPerRow, place.fullWidth, place.fullHeight,
                                   place.x, place.y, $0.baseAddress, $0.count)
            }
            guard done != 0 else { throw ExportError.render }
        }
        let remaining = stages[reused.count...]
        guard let cache else {
            // One call for the whole stack, so its working planes are allocated once.
            try process(remaining)
            guard let output = context.makeImage() else { throw ExportError.render }
            return output
        }
        var outputs: [(stage: FinishStageCache.Stage, image: CGImage)] = []
        for stage in remaining {
            try process(CollectionOfOne(stage))
            guard let output = context.makeImage() else { throw ExportError.render }
            outputs.append((stage, output))
        }
        cache.store(reused + outputs, from: image, scale: scale, region: region, seed: seed)
        return outputs[outputs.count - 1].image
    }
}

/// Render Finish previews keep each effect's output, so changing a later effect starts from the one before it
/// instead of redoing the whole stack. Holds one image at one scale: the preview of an open edit.
nonisolated final class FinishStageCache: @unchecked Sendable {
    struct Stage: Equatable {
        let effect: FinishEffect
        let parameters: FinishParameters
    }
    private let lock = NSLock()
    private var source: CGImage?
    private var scale: CGFloat = 0
    private var region: FinishRegion?
    private var seed: UInt32 = 0
    private var stages: [(stage: Stage, image: CGImage)] = []

    /// A snapshot of the matching prefix. A concurrent render may replace this cache while a caller works;
    /// keeping its own prefix prevents combining new outputs with another render's incompatible stages.
    func prefix(of wanted: [Stage], from image: CGImage, scale: CGFloat, region: FinishRegion?, seed: UInt32)
        -> [(stage: Stage, image: CGImage)] {
        lock.lock(); defer { lock.unlock() }
        guard source === image, self.scale == scale, self.region == region, self.seed == seed else { return [] }
        var count = 0
        while count < min(wanted.count, stages.count), stages[count].stage == wanted[count] { count += 1 }
        return Array(stages.prefix(count))
    }

    /// Publishes a complete, internally consistent render, including the caller's reused prefix.
    func store(_ outputs: [(stage: Stage, image: CGImage)], from image: CGImage, scale: CGFloat, region: FinishRegion?, seed: UInt32) {
        lock.lock(); defer { lock.unlock() }
        source = image
        self.scale = scale
        self.region = region
        self.seed = seed
        stages = outputs
    }
}

/// Saved per effect under stable names; effects missing from an older preset load disabled.
nonisolated extension RenderFinishSettings: Codable {
    init(from decoder: any Decoder) throws {
        self.init()
        let saved = try decoder.singleValueContainer().decode([String: FinishParameters].self)
        for effect in FinishEffect.allCases {
            if let parameters = saved[effect.key] { self[effect] = parameters }
            else { self[effect].enabled = false }
        }
        self = normalized
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Dictionary(uniqueKeysWithValues: FinishEffect.allCases.map { ($0.key, self[$0]) }))
    }
}
