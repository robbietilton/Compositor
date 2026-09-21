import AppKit
import CoreImage

/// The six color ranges plus Master, as in Photoshop's Cmd+U.
nonisolated enum ColorRange: String, CaseIterable, Sendable, Hashable, Codable {
    case master = "Master", reds = "Reds", yellows = "Yellows", greens = "Greens"
    case cyans = "Cyans", blues = "Blues", magentas = "Magentas"

    /// Photoshop's starting hue band: falloff start, range start, range end, falloff end.
    var defaultBand: HueBand {
        switch self {
        case .master: HueBand(falloffStart: 0, rangeStart: 0, rangeEnd: 360, falloffEnd: 360)
        case .reds: HueBand(falloffStart: 315, rangeStart: 345, rangeEnd: 15, falloffEnd: 45)
        case .yellows: HueBand(falloffStart: 15, rangeStart: 45, rangeEnd: 75, falloffEnd: 105)
        case .greens: HueBand(falloffStart: 75, rangeStart: 105, rangeEnd: 135, falloffEnd: 165)
        case .cyans: HueBand(falloffStart: 135, rangeStart: 165, rangeEnd: 195, falloffEnd: 225)
        case .blues: HueBand(falloffStart: 195, rangeStart: 225, rangeEnd: 255, falloffEnd: 285)
        case .magentas: HueBand(falloffStart: 255, rangeStart: 285, rangeEnd: 315, falloffEnd: 345)
        }
    }
    static let colorRanges = ColorRange.allCases.filter { $0 != .master }
}

/// A hue band in degrees, wrapping at 360: full strength between `rangeStart` and
/// `rangeEnd`, fading to nothing at `falloffStart` and `falloffEnd`.
nonisolated struct HueBand: Equatable, Sendable, Codable {
    var falloffStart: Double
    var rangeStart: Double
    var rangeEnd: Double
    var falloffEnd: Double

    /// Degrees from `from` forward to `to`, always 0…360.
    static func forward(_ from: Double, _ to: Double) -> Double {
        let delta = (to - from).truncatingRemainder(dividingBy: 360)
        return delta < 0 ? delta + 360 : delta
    }

    /// How strongly this band claims a hue: 1 inside the range, ramping linearly through
    /// each falloff shoulder, 0 outside. Wraparound is handled by measuring forward.
    func weight(of hue: Double) -> Double {
        let span = Self.forward(falloffStart, falloffEnd)
        guard span > 0 else { return 1 } // Master covers everything.
        let position = Self.forward(falloffStart, hue)
        guard position <= span else { return 0 }
        let rampIn = Self.forward(falloffStart, rangeStart)
        let plateauEnd = Self.forward(falloffStart, rangeEnd)
        if position < rampIn { return rampIn > 0 ? position / rampIn : 1 }
        if position <= plateauEnd { return 1 }
        let rampOut = span - plateauEnd
        return rampOut > 0 ? (span - position) / rampOut : 1
    }

    var handles: [Double] { [falloffStart, rangeStart, rangeEnd, falloffEnd] }

    /// A band centered on one hue, keeping this band's core and shoulder widths.
    func centered(on hue: Double) -> HueBand {
        let core = Self.forward(rangeStart, rangeEnd)
        let leading = Self.forward(falloffStart, rangeStart)
        let trailing = Self.forward(rangeEnd, falloffEnd)
        func wrap(_ value: Double) -> Double {
            let remainder = value.truncatingRemainder(dividingBy: 360)
            return remainder < 0 ? remainder + 360 : remainder
        }
        let start = wrap(hue - core / 2)
        return HueBand(falloffStart: wrap(start - leading), rangeStart: start,
                       rangeEnd: wrap(start + core), falloffEnd: wrap(start + core + trailing))
    }

    /// Widens the band so this hue is fully inside it, moving whichever edge is nearer.
    mutating func include(_ hue: Double) {
        guard weight(of: hue) < 1 else { return }
        let shoulderIn = Self.forward(falloffStart, rangeStart)
        let shoulderOut = Self.forward(rangeEnd, falloffEnd)
        let beforeStart = Self.forward(hue, rangeStart)
        let afterEnd = Self.forward(rangeEnd, hue)
        if beforeStart <= afterEnd {
            rangeStart = hue
            falloffStart = hue - shoulderIn
        } else {
            rangeEnd = hue
            falloffEnd = hue + shoulderOut
        }
        normalize()
    }

    /// Narrows the band so this hue falls outside it entirely, shoulder included.
    mutating func exclude(_ hue: Double) {
        guard weight(of: hue) > 0 else { return }
        let shoulderIn = Self.forward(falloffStart, rangeStart)
        let shoulderOut = Self.forward(rangeEnd, falloffEnd)
        let fromStart = Self.forward(falloffStart, hue)
        let toEnd = Self.forward(hue, falloffEnd)
        if fromStart <= toEnd {
            falloffStart = hue + 1
            rangeStart = hue + 1 + shoulderIn
        } else {
            falloffEnd = hue - 1
            rangeEnd = hue - 1 - shoulderOut
        }
        normalize()
    }

    /// Keeps all four handles in 0…360 and the band under a full circle.
    private mutating func normalize() {
        func wrap(_ value: Double) -> Double {
            let remainder = value.truncatingRemainder(dividingBy: 360)
            return remainder < 0 ? remainder + 360 : remainder
        }
        falloffStart = wrap(falloffStart); rangeStart = wrap(rangeStart)
        rangeEnd = wrap(rangeEnd); falloffEnd = wrap(falloffEnd)
        if Self.forward(falloffStart, falloffEnd) > 350 {
            falloffEnd = wrap(falloffStart + 350)
        }
    }

    /// Moves one handle, keeping the four in order and the band under a full circle.
    mutating func setHandle(_ index: Int, to degrees: Double) {
        var updated = self
        let value = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        switch index {
        case 0: updated.falloffStart = value
        case 1: updated.rangeStart = value
        case 2: updated.rangeEnd = value
        default: updated.falloffEnd = value
        }
        let span = Self.forward(updated.falloffStart, updated.falloffEnd)
        let toStart = Self.forward(updated.falloffStart, updated.rangeStart)
        let toEnd = Self.forward(updated.falloffStart, updated.rangeEnd)
        guard span > 1, span <= 350, toStart <= toEnd, toEnd <= span else { return }
        self = updated
    }
}

/// Which eyedropper is armed while the Hue/Saturation panel is open.
nonisolated enum HueSampleMode: String, CaseIterable, Sendable {
    case replace = "Sample", add = "Add", remove = "Remove"
    /// All three are eyedroppers; Add and Remove carry a small badge.
    var symbol: String { "eyedropper" }
    var badge: String? {
        switch self {
        case .replace: nil
        case .add: "plus.circle.fill"
        case .remove: "minus.circle.fill"
        }
    }
    var help: String {
        switch self {
        case .replace: "Click the image to center this range on that color"
        case .add: "Click the image to widen this range to include that color"
        case .remove: "Click the image to narrow this range to exclude that color"
        }
    }
}

/// A targeted-adjustment drag in progress.
struct HueTargetDrag {
    let range: ColorRange
    let hue: Double
    let saturation: Double
}

nonisolated struct RangeAdjustment: Equatable, Sendable, Codable {
    var hue: Double = 0
    var saturation: Double = 0
    var lightness: Double = 0
}

/// Hue is −180…180 (0…360 when colorizing), Saturation −100…100 (0…100 colorizing),
/// Lightness −100…100. Each color range keeps its own values; Master applies everywhere.
nonisolated struct HueSaturationSettings: Equatable, Sendable, Codable {
    /// Which range the sliders and spectrum edit.
    var range: ColorRange = .master
    var colorize = false
    /// Applies the selected range to everything *outside* its band instead.
    var invertRange = false
    var adjustments: [ColorRange: RangeAdjustment] = [:]
    var bands: [ColorRange: HueBand] = Dictionary(uniqueKeysWithValues: ColorRange.allCases.map { ($0, $0.defaultBand) })

    init(hue: Double = 0, saturation: Double = 0, lightness: Double = 0, colorize: Bool = false,
         range: ColorRange = .master) {
        self.range = range
        self.colorize = colorize
        adjustments[range] = RangeAdjustment(hue: hue, saturation: saturation, lightness: lightness)
    }

    /// The sliders read and write the selected range.
    var hue: Double {
        get { adjustments[range]?.hue ?? 0 }
        set { adjustments[range, default: RangeAdjustment()].hue = newValue }
    }
    var saturation: Double {
        get { adjustments[range]?.saturation ?? 0 }
        set { adjustments[range, default: RangeAdjustment()].saturation = newValue }
    }
    var lightness: Double {
        get { adjustments[range]?.lightness ?? 0 }
        set { adjustments[range, default: RangeAdjustment()].lightness = newValue }
    }
    var band: HueBand {
        get { bands[range] ?? range.defaultBand }
        set { bands[range] = newValue }
    }

    /// Photoshop's starting point when Colorize is switched on.
    static let colorizeStart = HueSaturationSettings(hue: 0, saturation: 25, lightness: 0, colorize: true)
    var isIdentity: Bool { !colorize && adjustments.values.allSatisfy { $0 == RangeAdjustment() } }

    /// How much a range applies to one hue: Master everywhere, others through their band.
    func weight(of colorRange: ColorRange, hue: Double) -> Double {
        guard colorRange != .master else { return 1 }
        let weight = (bands[colorRange] ?? colorRange.defaultBand).weight(of: hue)
        return invertRange && colorRange == range ? 1 - weight : weight
    }
}

nonisolated struct HueSaturationJob: @unchecked Sendable {
    let image: CGImage
    let settings: HueSaturationSettings
    let selection: SelectionClip?
    let pixelToDocument: CGAffineTransform
    /// Previews skip the layer-panel thumbnail.
    var thumbnail = true
}

nonisolated struct AdjustedPixels: @unchecked Sendable {
    let image: CGImage
    let thumbnail: CGImage?
}

/// Builds a color cube from the settings and applies it on the GPU. Working through a cube
/// keeps slider dragging fast on large images; identity settings never reach here.
nonisolated enum HueSaturationFilter {
    /// 33 points per axis, the usual size for this kind of lookup: fast to build, smooth enough.
    static let dimension = 33

    static func run(_ job: HueSaturationJob) throws -> AdjustedPixels {
        let width = job.image.width, height = job.image.height
        // CIColorCube unpremultiplies and premultiplies around its lookup itself. Doing it again here darkened
        // every translucent pixel (half-transparent blue came out at 94 of 128), which turned soft edges black.
        let adjusted = CIImage(cgImage: job.image)
            .applyingFilter("CIColorCube", parameters: ["inputCubeDimension": dimension,
                                                        "inputCubeData": cube(job.settings)])
        var result = try PixelAdjust.render(adjusted, width: width, height: height, isMask: false)
        if let selection = job.selection {
            let original = try PixelAdjust.bitmap(width: width, height: height, mask: false)
            original.draw(job.image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let originalImage = original.makeImage() else { throw ExportError.render }
            result = try PixelAdjust.blend(result, over: originalImage, through: selection,
                                           pixelToDocument: job.pixelToDocument, isMask: false)
        }
        return AdjustedPixels(image: result, thumbnail: job.thumbnail ? try PixelAdjust.thumbnail(of: result) : nil)
    }

    /// How much every range shifts a given hue, sampled once per degree. Building this
    /// once per settings keeps the cube cheap: without it each of ~36k cube entries would
    /// re-evaluate all seven ranges.
    typealias HueResponse = (shift: Double, saturation: Double, lightness: Double)

    static func hueResponse(_ settings: HueSaturationSettings) -> [HueResponse] {
        (0...360).map { degree in
            var response: HueResponse = (0, 0, 0)
            for (colorRange, adjustment) in settings.adjustments where adjustment != RangeAdjustment() {
                let weight = settings.weight(of: colorRange, hue: Double(degree))
                guard weight > 0 else { continue }
                response.shift += adjustment.hue * weight
                response.saturation += adjustment.saturation * weight
                response.lightness += adjustment.lightness * weight
            }
            return response
        }
    }

    /// The lookup table: every cube corner converted to HSL, adjusted, and back.
    static func cube(_ settings: HueSaturationSettings) -> Data {
        let response = hueResponse(settings)
        var values = [Float](repeating: 0, count: dimension * dimension * dimension * 4)
        var index = 0
        let step = Double(dimension - 1)
        for blue in 0..<dimension {
            for green in 0..<dimension {
                for red in 0..<dimension {
                    let color = adjust(red: Double(red) / step, green: Double(green) / step, blue: Double(blue) / step,
                                       settings: settings, response: response)
                    values[index] = Float(color.red)
                    values[index + 1] = Float(color.green)
                    values[index + 2] = Float(color.blue)
                    values[index + 3] = 1
                    index += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func adjust(red: Double, green: Double, blue: Double, settings: HueSaturationSettings,
                       response: [HueResponse]? = nil) -> (red: Double, green: Double, blue: Double) {
        var (hue, saturation, lightness) = toHSL(red: red, green: green, blue: blue)
        var lightnessAmount = 0.0
        if settings.colorize {
            hue = settings.hue.truncatingRemainder(dividingBy: 360)
            saturation = min(1, max(0, settings.saturation / 100))
            lightnessAmount = settings.lightness / 100
        } else {
            // Every range contributes, weighted by how strongly it claims the original hue.
            let table = response ?? hueResponse(settings)
            let sampled = table[min(table.count - 1, max(0, Int(hue.rounded())))]
            lightnessAmount = sampled.lightness / 100
            hue = (hue + sampled.shift).truncatingRemainder(dividingBy: 360)
            if hue < 0 { hue += 360 }
            // Multiplicative, so neutral grays stay neutral.
            saturation = min(1, max(0, saturation * (1 + sampled.saturation / 100)))
        }
        // Lightness pulls toward white above 0 and toward black below, reaching either at ±100.
        let amount = min(1, max(-1, lightnessAmount))
        lightness = amount >= 0 ? lightness + (1 - lightness) * amount : lightness * (1 + amount)
        return toRGB(hue: hue, saturation: saturation, lightness: min(1, max(0, lightness)))
    }

    /// The hue a spectrum swatch becomes, for the "after" bar.
    static func shiftedHue(_ hue: Double, settings: HueSaturationSettings) -> Double {
        var shift = 0.0
        for (colorRange, adjustment) in settings.adjustments where adjustment.hue != 0 {
            shift += adjustment.hue * settings.weight(of: colorRange, hue: hue)
        }
        let shifted = (hue + shift).truncatingRemainder(dividingBy: 360)
        return shifted < 0 ? shifted + 360 : shifted
    }

    private static func toHSL(red: Double, green: Double, blue: Double) -> (Double, Double, Double) {
        let high = max(red, green, blue), low = min(red, green, blue)
        let lightness = (high + low) / 2
        let delta = high - low
        guard delta > 0 else { return (0, 0, lightness) }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        var hue: Double
        if high == red { hue = (green - blue) / delta }
        else if high == green { hue = (blue - red) / delta + 2 }
        else { hue = (red - green) / delta + 4 }
        hue *= 60
        if hue < 0 { hue += 360 }
        return (hue, min(1, saturation), lightness)
    }

    private static func toRGB(hue: Double, saturation: Double, lightness: Double)
        -> (red: Double, green: Double, blue: Double) {
        guard saturation > 0 else { return (lightness, lightness, lightness) }
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let sector = hue / 60
        let second = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let base = lightness - chroma / 2
        let (red, green, blue): (Double, Double, Double)
        switch Int(sector) {
        case 0: (red, green, blue) = (chroma, second, 0)
        case 1: (red, green, blue) = (second, chroma, 0)
        case 2: (red, green, blue) = (0, chroma, second)
        case 3: (red, green, blue) = (0, second, chroma)
        case 4: (red, green, blue) = (second, 0, chroma)
        default: (red, green, blue) = (chroma, 0, second)
        }
        return (min(1, max(0, red + base)), min(1, max(0, green + base)), min(1, max(0, blue + base)))
    }
}

/// One open Hue/Saturation dialog. Previews render from a downscaled copy of the original
/// and are drawn straight on the canvas, so dragging stays responsive and the document is
/// untouched until OK.
@Observable
final class HueSaturationEdit {
    let layerID: UUID
    let original: ImportedImage
    let selection: SelectionClip?
    let pixelToDocument: CGAffineTransform
    /// Downscaled original used for previews, with the mapping for its own pixel grid.
    @ObservationIgnored let previewSource: CGImage
    @ObservationIgnored let previewPixelToDocument: CGAffineTransform
    var settings = HueSaturationSettings()
    var preview = true
    /// What the canvas shows while the dialog is open; nil means the layer's own pixels.
    /// Not observed: canvas redraws are driven by `brushRevision`.
    @ObservationIgnored private(set) var preparedPreview: CGImage?

    /// Previews render at most this many pixels on the longest side: full size for anything ordinary, so the canvas
    /// shows the real thing rather than a coarse copy stretched to fit, as a Hue/Saturation layer already does.
    static let previewLimit = 8000

    init(layerID: UUID, original: ImportedImage, selection: SelectionClip?, transform: LayerTransform) throws {
        self.layerID = layerID
        self.original = original
        self.selection = selection
        let width = original.image.width, height = original.image.height
        pixelToDocument = BrushRaster.pixelToDocument(transform, width: width, height: height)
        let factor = min(1, Double(Self.previewLimit) / Double(max(width, height)))
        if factor < 1 {
            let small = max(1, Int(Double(width) * factor)), tall = max(1, Int(Double(height) * factor))
            let context = try BrushRaster.context(width: small, height: tall, mask: false)
            context.interpolationQuality = .medium
            BrushRaster.draw(original.image, in: CGRect(x: 0, y: 0, width: small, height: tall), mask: false, context: context)
            guard let scaled = context.makeImage() else { throw ExportError.render }
            previewSource = scaled
            previewPixelToDocument = BrushRaster.pixelToDocument(transform, width: small, height: tall)
        } else {
            previewSource = original.image
            previewPixelToDocument = pixelToDocument
        }
    }

    func previewImage(for layer: UUID) -> CGImage? { layer == layerID ? preparedPreview : nil }
    func setPreview(_ image: CGImage?) { preparedPreview = image }
}

extension EditorSession {
    /// Color adjustments need a visible image layer (not a mask) and a non-empty selection
    /// if there is one; a pending gradient or transform is applied first.
    var canAdjustColors: Bool {
        _ = showsBusy
        guard levels == nil, filterEdit == nil, generativeEdit == nil, document != nil, let layer = activeLayer, !isProjectBusy, !isImporting, brushStroke == nil,
              pixelMove == nil, renamingLayerID == nil, !showsNewDocument, !showsImporter,
              selectedLayerIDs.count == 1, !layer.isGroup, !isMaskSelected, layer.asset != nil,
              document?.effectiveVisibleIDs.contains(layer.id) == true, selection?.isEmpty != true else { return false }
        return true
    }

    func beginHueSaturation() {
        guard hueSaturation == nil, canAdjustColors else { NSSound.beep(); return }
        commitTransform()
        if gradientEdit != nil { resolveGradient() }
        guard let document, let layer = activeLayer, let asset = layer.asset else { return }
        do {
            hueSaturation = try HueSaturationEdit(layerID: layer.id, original: asset,
                selection: try selection?.clip(canvas: document.size), transform: layer.transform)
        } catch { brushError = error.localizedDescription }
    }

    /// Live preview from the downscaled original. Requests coalesce rather than cancel:
    /// a render that is already running finishes and is shown, then the newest request
    /// renders. Cancelling instead starved the preview during a drag, because slider
    /// changes arrive faster than a render completes.
    func updateHueSaturation(_ settings: HueSaturationSettings, preview: Bool) {
        guard let edit = hueSaturation else { return }
        edit.settings = settings
        edit.preview = preview
        if previewAdjustmentEditing(preview: preview) { return }
        guard preview, !settings.isIdentity else {
            hueSaturationTask?.cancel()
            hueSaturationPending = nil
            edit.setPreview(nil)
            brushRevision += 1
            return
        }
        hueSaturationPending = HueSaturationJob(image: edit.previewSource, settings: settings,
                                                selection: edit.selection, pixelToDocument: edit.previewPixelToDocument,
                                                thumbnail: false)
        renderPendingPreview(edit)
    }

    private func renderPendingPreview(_ edit: HueSaturationEdit) {
        guard hueSaturation === edit, let job = hueSaturationPending, hueSaturationTask == nil else { return }
        hueSaturationPending = nil
        hueSaturationTask = Task { @MainActor [weak self] in
            let adjusted = await self?.adjustedPixels(job)
            guard let self else { return }
            self.hueSaturationTask = nil
            guard self.hueSaturation === edit else { return }
            if let adjusted {
                edit.setPreview(adjusted.image)
                self.brushRevision += 1
            }
            self.renderPendingPreview(edit)
        }
    }

    /// OK: renders at full quality and records one "Hue/Saturation" undo step. Identity
    /// settings change nothing at all.
    func commitHueSaturation() async {
        if finishAdjustmentEditing(commit: true) { return }
        guard let edit = hueSaturation else { return }
        hueSampleMode = nil
        hueTargeting = false
        hueTargetDrag = nil
        hueSaturationPending = nil
        hueSaturationTask?.cancel()
        let settings = edit.settings
        // The preview stays on screen until the committed pixels are in the document:
        // clearing it first leaves the canvas showing the original for a frame.
        defer {
            hueSaturation = nil
            brushRevision += 1
        }
        guard !settings.isIdentity else { return }
        isProjectBusy = true
        defer { isProjectBusy = false }
        let job = HueSaturationJob(image: edit.original.image, settings: settings,
                                   selection: edit.selection, pixelToDocument: edit.pixelToDocument, thumbnail: true)
        guard let adjusted = await adjustedPixels(job),
              let index = document?.layers.firstIndex(where: { $0.id == edit.layerID }),
              let current = document?.layers[index], current.asset?.image === edit.original.image else { return }
        beginEdit("Hue/Saturation")
        document?.layers[index] = ImageLayer(id: current.id,
            asset: ImportedImage(image: adjusted.image, thumbnail: adjusted.thumbnail ?? adjusted.image, name: current.name),
            name: current.name, isVisible: current.isVisible, transform: current.transform, parentID: current.parentID,
            isGroup: false, opacity: current.opacity, blendMode: current.blendMode, mask: current.mask, maskSourceID: current.maskSourceID)
        endEdit()
    }

    /// The hue under a document point, from the visible composite. Near-neutral pixels
    /// have no meaningful hue.
    func sampledHue(at point: CGPoint) -> Double? {
        guard let color = sampleCompositeColor(at: point) else { return nil }
        let hsb = PickerHSB(color)
        return hsb.saturation > 0.02 ? hsb.hue : nil
    }

    /// The eyedroppers: re-center, widen, or narrow the selected range's band.
    func sampleHueRange(at point: CGPoint) {
        guard let edit = hueSaturation, let mode = hueSampleMode else { return }
        var settings = edit.settings
        guard settings.range != .master, !settings.colorize, let hue = sampledHue(at: point) else { NSSound.beep(); return }
        switch mode {
        case .replace: settings.band = settings.band.centered(on: hue)
        case .add: settings.band.include(hue)
        case .remove: settings.band.exclude(hue)
        }
        updateHueSaturation(settings, preview: edit.preview)
    }

    /// Targeted adjustment: picks the range owning the sampled color and drags its
    /// saturation (or hue with Command held).
    func beginHueTargeting(at point: CGPoint) -> Bool {
        guard let edit = hueSaturation, hueTargeting, !edit.settings.colorize,
              let hue = sampledHue(at: point) else { NSSound.beep(); return false }
        var settings = edit.settings
        let range = ColorRange.colorRanges.max {
            settings.weight(of: $0, hue: hue) < settings.weight(of: $1, hue: hue)
        } ?? .reds
        settings.range = range
        let adjustment = settings.adjustments[range] ?? RangeAdjustment()
        hueTargetDrag = HueTargetDrag(range: range, hue: adjustment.hue, saturation: adjustment.saturation)
        updateHueSaturation(settings, preview: edit.preview)
        return true
    }

    /// Dragging right raises the value, left lowers it; one unit per view point.
    func dragHueTargeting(byViewDelta delta: CGFloat, adjustsHue: Bool) {
        guard let edit = hueSaturation, let drag = hueTargetDrag else { return }
        var settings = edit.settings
        if adjustsHue {
            settings.adjustments[drag.range, default: RangeAdjustment()].hue =
                min(180, max(-180, drag.hue + Double(delta) / 2))
        } else {
            settings.adjustments[drag.range, default: RangeAdjustment()].saturation =
                min(100, max(-100, drag.saturation + Double(delta) / 2))
        }
        updateHueSaturation(settings, preview: edit.preview)
    }

    func endHueTargeting() { hueTargetDrag = nil }

    func cancelHueSaturation() {
        if finishAdjustmentEditing(commit: false) { return }
        hueSampleMode = nil
        hueTargeting = false
        hueTargetDrag = nil
        guard hueSaturation != nil else { return }
        hueSaturationPending = nil
        hueSaturationTask?.cancel()
        hueSaturation = nil
        brushRevision += 1
    }

    private func adjustedPixels(_ job: HueSaturationJob) async -> AdjustedPixels? {
        do { return try await Task.detached(priority: .userInitiated) { try HueSaturationFilter.run(job) }.value }
        catch { brushError = error.localizedDescription; return nil }
    }
}
