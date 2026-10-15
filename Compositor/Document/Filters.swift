import AppKit
import CoreImage
import Observation

/// Filters from the Filter menu. Each runs on the active image layer, inside the selection if
/// there is one, with a live preview and one undo step on OK.
nonisolated enum FilterKind: String, CaseIterable, Sendable {
    case gaussianBlur = "Gaussian Blur"
    case motionBlur = "Motion Blur"
    case progressiveBlur = "Progressive Blur"
    case addNoise = "Add Noise"
    case vignette = "Vignette"
    case bloomGlow = "Bloom / Glow"
    case dither = "Dither"
    case scanlines = "Scanlines"
    case tonalContrast = "Tonal Contrast"
    case lensCorrection = "Lens Correction"
    case cameraRaw = "Camera Raw Filter"
    case removeBackground = "Remove Background"
    case contentAwareFill = "Content-Aware Fill"
    case curves = "Curves"
    case exposure = "Exposure"
    case gradientMap = "Gradient Map"
    case grain = "Grain"
    case blackWhite = "Black & White"
    case colorBalance = "Color Balance"
    var isAutomatic: Bool { self == .contentAwareFill || self == .removeBackground }
    /// The Filter menu's own filters, which Last Filter can run again; not Content-Aware Fill or the Image menu's.
    var repeatsAsLastFilter: Bool { self != .contentAwareFill && !isImageAdjustment }
    /// Filters made wholly in Core Image, which works at 16 bits as readily as at 8: a 16-bit layer runs them once, on its
    /// 16-bit pixels, rather than three times through `DeepLayer.run`.
    var runsAtSixteenBits: Bool { self == .gaussianBlur || self == .motionBlur || self == .progressiveBlur || self == .bloomGlow }
    /// Filters whose output channels each depend on all three input channels (Camera Raw's color, and the ones that work
    /// from brightness), which a 16-bit layer runs the slower, channel-by-channel way (`DeepLayer.run`).
    var mixesChannels: Bool { self == .cameraRaw || self == .tonalContrast || self == .scanlines }
    /// For the color adjustments whose channels mix, their color lookup, to apply to a 16-bit layer
    /// (`LayerAdjustment.sixteenBitLookup`); nil for the rest.
    func sixteenBitLookup(_ settings: FilterSettings) -> (cube: Data, dimension: Int)? {
        var adjustment: LayerAdjustment
        switch self {
        case .blackWhite: adjustment = LayerAdjustment(kind: .blackWhite); adjustment.blackWhite = settings.blackWhite
        case .colorBalance: adjustment = LayerAdjustment(kind: .colorBalance); adjustment.colorBalance = settings.colorBalance
        case .gradientMap: adjustment = LayerAdjustment(kind: .gradientMap); adjustment.gradientMap = settings.gradientMap
        default: return nil
        }
        return adjustment.sixteenBitLookup
    }
    /// Color adjustments: in the Image menu (and editable as adjustment layers), not under Filter.
    var isImageAdjustment: Bool {
        self == .curves || self == .exposure || self == .gradientMap || self == .grain
            || self == .blackWhite || self == .colorBalance
    }
}

/// Remove Background's two ways of working: Apple's own subject mask on its own, or that mask refined against the
/// layer's detail, which recovers hair and fur but takes longer.
nonisolated enum BackgroundQuality: String, CaseIterable, Sendable {
    case basic = "Basic"
    case advanced = "Advanced"
}

/// Every filter's settings; each filter reads only its own.
nonisolated struct FilterSettings: Equatable, Sendable {
    /// Gaussian Blur radius in layer pixels (the blur's standard deviation), 0.1–250.
    var radius: Double = 5
    /// Gaussian Blur keeps every pixel's transparency: only the colors blur, from the layer's own pixels, so its
    /// outline stays where it is instead of softening and spreading.
    var preserveTransparency = false
    /// Motion Blur direction in degrees, counterclockwise from horizontal as in Photoshop, −90–90.
    var angle: Double = 0
    /// Motion Blur streak length in layer pixels, 1–2000.
    var distance: Double = 10
    /// Progressive Blur: the blur at the start of its line and at its end, in layer pixels (a Gaussian blur's radius),
    /// 0–250, changing evenly between them.
    var progressiveFrom: Double = 0
    var progressiveTo: Double = 20
    /// Where it runs, in document coordinates, set by dragging on the canvas: `progressiveFrom` at `progressiveStart`,
    /// `progressiveTo` at `progressiveEnd` and past it. Nil until the filter places it on the layer.
    var progressiveStart: CGPoint?
    var progressiveEnd: CGPoint?
    /// Radial: from the start outwards to the circle through the end, rather than along the line.
    var progressiveRadial = false
    /// From and To the other way round.
    var progressiveInverted = false
    /// Add Noise strength as Photoshop's percentage, 0.1–400.
    var amount: Double = 10
    /// Add Noise distribution: Gaussian (more speckled) instead of Uniform.
    var gaussian = false
    /// Add Noise changes brightness only, the same amount on every channel.
    var monochromatic = false
    /// Standalone vignette: edge color, strength, and shape of its falloff.
    var vignetteAmount: Double = 35
    var vignetteColor = AdjustmentColor(red: 0, green: 0, blue: 0)
    var vignetteMidpoint: Double = 50
    var vignetteRoundness: Double = 100
    var vignetteFeather: Double = 60
    var vignetteHighlights: Double = 25
    /// Bloom / Glow: strength and blur radius in layer pixels.
    var bloomAmount: Double = 40
    var bloomRadius: Double = 24
    /// Tonal Contrast: one local-detail radius and separate tonal strengths.
    var tonalAmount: Double = 50
    var tonalRadius: Double = 16
    var tonalShadows: Double = 40
    var tonalMidtones: Double = 60
    var tonalHighlights: Double = 30
    /// Lens Correction's Remove Distortion, −100–100: positive straightens barrel distortion
    /// (lines bowing outward), negative straightens pincushion (lines bowing inward).
    var distortion: Double = 0
    var curves = CurvesSettings()
    var exposure = ExposureSettings()
    var gradientMap = GradientMapSettings()
    var grain = GrainSettings()
    var blackWhite = BlackWhiteSettings()
    var colorBalance = ColorBalanceSettings()
    var dither = DitherSettings()
    var scanlines = ScanlinesSettings()
    var cameraRaw = CameraRawSettings()
    /// Remove Background: Basic is the quick subject mask; Advanced refines it (see the three settings below).
    var backgroundQuality: BackgroundQuality = .basic
    /// Remove Background: how far the mask is pulled onto the image's own edges (0 off, in layer pixels).
    var refineEdges: Double = 12
    /// Remove Background: pushes the mask's grays toward black and white, 0–100, clearing haze in thin areas.
    var matteContrast: Double = 25
    /// Remove Background: contracts (negative) or expands (positive) the mask edge, in layer pixels.
    var shiftEdge: Double = 0
    var normalized: Self {
        func clamp(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        var result = self
        result.radius = clamp(radius, 0.1...250, 5)
        result.angle = clamp(angle, -90...90, 0)
        result.distance = clamp(distance, 1...2000, 10)
        result.progressiveFrom = clamp(progressiveFrom, 0...250, 0)
        result.progressiveTo = clamp(progressiveTo, 0...250, 20)
        result.amount = clamp(amount, 0.1...400, 10)
        result.vignetteAmount = clamp(vignetteAmount, 0...100, 35)
        result.vignetteColor = vignetteColor.clamped
        result.vignetteMidpoint = clamp(vignetteMidpoint, 0...100, 50)
        result.vignetteRoundness = clamp(vignetteRoundness, -100...100, 100)
        result.vignetteFeather = clamp(vignetteFeather, 0...100, 60)
        result.vignetteHighlights = clamp(vignetteHighlights, 0...100, 25)
        result.bloomAmount = clamp(bloomAmount, 0...100, 40)
        result.bloomRadius = clamp(bloomRadius, 1...150, 24)
        result.tonalAmount = clamp(tonalAmount, 0...100, 50)
        result.tonalRadius = clamp(tonalRadius, 1...100, 16)
        result.tonalShadows = clamp(tonalShadows, -100...100, 40)
        result.tonalMidtones = clamp(tonalMidtones, -100...100, 60)
        result.tonalHighlights = clamp(tonalHighlights, -100...100, 30)
        result.distortion = clamp(distortion, -100...100, 0)
        result.refineEdges = clamp(refineEdges, 0...40, 12)
        result.matteContrast = clamp(matteContrast, 0...100, 25)
        result.shiftEdge = clamp(shiftEdge, -10...10, 0)
        result.exposure = exposure.normalized
        result.gradientMap = gradientMap.normalized
        result.grain = grain.normalized
        result.dither = dither.normalized
        result.scanlines = scanlines.normalized
        result.cameraRaw = cameraRaw.normalized
        return result
    }
}

/// Sides of a layer, in its own pixels (top is row 0).
nonisolated struct LayerSides: OptionSet, Sendable {
    let rawValue: Int
    static let left = Self(rawValue: 1), right = Self(rawValue: 2), top = Self(rawValue: 4), bottom = Self(rawValue: 8)
}

nonisolated struct FilterJob: @unchecked Sendable {
    let kind: FilterKind
    var image: CGImage
    let settings: FilterSettings
    /// Pixels in `image` per original layer pixel, so a downscaled preview blurs proportionally less.
    let scale: CGFloat
    let selection: SelectionClip?
    let mapping: CGAffineTransform
    /// Add Noise's random pattern: the same seed gives the same grain.
    var seed: UInt32 = 0
    /// Vignette on an empty layer: the canvas, in the document, which it frames and fills. Otherwise the vignette
    /// frames the layer's own pixels and recolors only those.
    var canvas: CGRect? = nil
    /// The image's sides at the canvas's edge, which Gaussian and Motion Blur carry on past instead of fading.
    var canvasSides: LayerSides = []
    /// Canvas-space origin used by live adjustment layers so partial redraws keep one noise field.
    var noiseOrigin: CGPoint = .zero
    /// A 16-bit layer's pixels, for a filter that works in Core Image (`FilterKind.runsAtSixteenBits`): rendered at 16 bits.
    var sixteenBit = false
    /// Camera Raw's Option-drag clipping view. Preview only; committing leaves this nil.
    var cameraRawClipping: CameraRawClipping? = nil
    /// Persistent histogram clipping indicators. Preview only; committing leaves these off.
    var showsShadowClipping = false
    var showsHighlightClipping = false
    /// What Camera Raw's adaptive sliders read from `image`, when known already: measured once for a session's previews.
    var cameraRawBrightness: CameraRawTables.Brightness? = nil
    /// Preview only: the CPU remains the reference for OK, export, and unsupported GPU paths.
    var cameraRawUsesGPU = false
    /// Point-color range preview. −1 leaves the grade alone.
    var visualizesPointColor = -1
    /// Option-drag on Sharpening Masking. Preview only.
    var showsSharpenMask = false
}

nonisolated enum PixelFilter {
    /// `image` cropped to the pixels that are actually there, with the transform that keeps them in place: a blur
    /// is given generous room to spread, and whatever it leaves empty is cut away again.
    static func trimmed(_ image: CGImage, placed: LayerTransform) throws -> (image: CGImage, transform: LayerTransform) {
        guard let crop = try trimCrop(image), let cropped = image.cropping(to: crop) else { return (image, placed) }
        return (cropped, trimmedTransform(placed, crop: crop, width: image.width, height: image.height))
    }
    /// The part of `image` with anything in it, or nil when that's all of it (or nothing).
    static func trimCrop(_ image: CGImage) throws -> CGRect? {
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: full, mask: false, context: context)
        guard let data = context.data else { throw ExportError.render }
        var edges = [Int](repeating: 0, count: 4)
        brush_alpha_bounds(data.assumingMemoryBound(to: UInt8.self), image.width, image.height, context.bytesPerRow, &edges)
        let crop = CGRect(x: edges[0], y: edges[1], width: edges[2] - edges[0], height: edges[3] - edges[1])
        return crop.width >= 1 && crop.height >= 1 && crop != full ? crop : nil
    }
    /// The transform placing `crop` of an image `width` × `height` that was placed by `placed`.
    static func trimmedTransform(_ placed: LayerTransform, crop: CGRect, width: Int, height: Int) -> LayerTransform {
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        var result = placed
        result.size = CGSize(width: crop.width * placed.size.width / full.width,
                             height: crop.height * placed.size.height / full.height)
        let toDocument = BrushRaster.pixelToDocument(placed, width: width, height: height)
        let middle = CGPoint(x: crop.midX, y: crop.midY).applying(toDocument)
        result.origin = CGPoint(x: middle.x - result.size.width / 2, y: middle.y - result.size.height / 2)
        return result
    }

    /// `CIMotionBlur`'s radius per pixel of streak length. Photoshop smears evenly along the whole
    /// distance; Core Image tapers like a Gaussian whose spread is about its radius (measured on a
    /// single dot). An even streak of length d spreads d / √12, so this radius matches its spread.
    static let motionRadiusPerPixel = 1 / 12.0.squareRoot()
    /// Remove Distortion at ±100 moves the image's corners by this share of their distance from the center.
    static let lensStrength = 0.35

    /// The image with its edge pixels carried on past `sides`, as Photoshop's blurs do at the canvas's edge: there
    /// is nothing clear beyond it to blur into, so a picture filling the canvas keeps solid edges. Past its other
    /// sides it stays clear, and a blur spreads into that.
    static func extending(_ image: CIImage, past sides: LayerSides, of extent: CGRect) -> CIImage {
        guard !sides.isEmpty else { return image }
        // Far enough for any blur; Core Image's y axis points up, so the layer's top is the extent's maxY.
        let far: CGFloat = 100_000
        var region = extent
        if sides.contains(.left) { region.origin.x -= far; region.size.width += far }
        if sides.contains(.right) { region.size.width += far }
        if sides.contains(.bottom) { region.origin.y -= far; region.size.height += far }
        if sides.contains(.top) { region.size.height += far }
        return image.clampedToExtent().cropped(to: region)
    }

    static func run(_ job: FilterJob) throws -> CGImage {
        let settings = job.settings.normalized
        let width = job.image.width, height = job.image.height
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        // Not clamped: a blur softens the layer's edges and spreads into the room made for it, rather than
        // smearing the border outwards and stopping at it.
        let edges = CIImage(cgImage: job.image)
        let image: CGImage
        switch job.kind {
        case .curves: image = try settings.curves.apply(job.image)
        case .exposure: image = try settings.exposure.apply(job.image)
        case .gradientMap: image = try settings.gradientMap.apply(job.image)
        case .blackWhite: image = try settings.blackWhite.apply(job.image)
        case .colorBalance: image = try settings.colorBalance.apply(job.image)
        case .cameraRaw: image = try settings.cameraRaw.apply(job.image, clipping: job.cameraRawClipping, scale: job.scale, seed: job.seed,
                                                                visualizePointColor: job.visualizesPointColor, sharpenMask: job.showsSharpenMask,
                                                                brightness: job.cameraRawBrightness, usesGPU: job.cameraRawUsesGPU)
        // Grain sits in layer pixels; the job's seed gives each application its own pattern.
        case .grain: image = try settings.grain.apply(job.image, unitsPerPixel: 1 / job.scale, seed: job.seed)
        case .dither: image = try settings.dither.apply(job.image)
        case .scanlines: image = try settings.scanlines.apply(job.image)
        case .removeBackground:
            image = try SubjectRemoval.run(job.image, settings: settings)
        case .contentAwareFill:
            image = try ContentFill.run(job)
        case .gaussianBlur:
            let source = settings.preserveTransparency ? edges : extending(edges, past: job.canvasSides, of: extent)
            var blurred = source.applyingGaussianBlur(sigma: settings.radius * job.scale)
            if settings.preserveTransparency {
                // Each color from the layer's own pixels: dividing by the blurred alpha takes out the pull of the
                // clear ones around them, which would otherwise darken and thin the colors near the outline. Then
                // the original alpha, so the outline doesn't move.
                blurred = blurred.unpremultiplyingAlpha().settingAlphaOne(in: extent)
                    .applyingFilter("CIBlendWithAlphaMask", parameters: [
                        kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: edges,
                    ])
            }
            image = try render(blurred.cropped(to: extent), job: job)
        case .progressiveBlur:
            image = try render(progressivelyBlurred(edges, job: job, settings: settings, extent: extent).cropped(to: extent), job: job)
        case .motionBlur:
            // Core Image's y axis points up, so its counterclockwise angle matches Photoshop's.
            let streaked = extending(edges, past: job.canvasSides, of: extent).applyingFilter("CIMotionBlur", parameters: [
                kCIInputRadiusKey: settings.distance * job.scale * motionRadiusPerPixel,
                kCIInputAngleKey: settings.angle * .pi / 180,
            ])
            image = try render(streaked.cropped(to: extent), job: job)
        case .addNoise:
            // C, not Core Image: its random generator is uniform only, and Gaussian noise is needed too.
            let context = try BrushRaster.context(width: width, height: height, mask: false)
            BrushRaster.draw(job.image, in: extent, mask: false, context: context)
            guard let data = context.data else { throw ExportError.render }
            noise_add_at(data.assumingMemoryBound(to: UInt8.self), width, height, context.bytesPerRow,
                         Float(settings.amount), settings.gaussian ? 1 : 0, settings.monochromatic ? 1 : 0, job.seed,
                         Int64(job.noiseOrigin.x.rounded(.down)), Int64(job.noiseOrigin.y.rounded(.down)))
            guard let noisy = context.makeImage() else { throw ExportError.render }
            image = noisy
        case .vignette:
            let context = try BrushRaster.context(width: width, height: height, mask: false)
            BrushRaster.draw(job.image, in: extent, mask: false, context: context)
            guard let data = context.data else { throw ExportError.render }
            // The canvas in this image's pixels; bottom-up, as the context's rows are.
            let frame = job.canvas.map { $0.applying(job.mapping.inverted()) } ?? extent
            adjust_colored_vignette(data.assumingMemoryBound(to: UInt8.self), width, height, context.bytesPerRow,
                                    frame.minX, CGFloat(height) - frame.maxY, frame.width, frame.height, job.canvas == nil ? 0 : 1,
                                    settings.vignetteAmount, settings.vignetteMidpoint, settings.vignetteRoundness,
                                    settings.vignetteFeather, settings.vignetteHighlights,
                                    settings.vignetteColor.red, settings.vignetteColor.green, settings.vignetteColor.blue)
            guard let result = context.makeImage() else { throw ExportError.render }
            image = result
        case .bloomGlow:
            let bloomed = edges.applyingFilter("CIBloom", parameters: [
                kCIInputRadiusKey: settings.bloomRadius * job.scale,
                kCIInputIntensityKey: settings.bloomAmount / 50,
            ])
            image = try render(bloomed.cropped(to: extent), job: job)
        case .tonalContrast:
            let blurred = edges.applyingGaussianBlur(sigma: settings.tonalRadius * job.scale)
            let base = try PixelAdjust.render(blurred.cropped(to: extent), width: width, height: height, isMask: false)
            let context = try BrushRaster.context(width: width, height: height, mask: false)
            let baseContext = try BrushRaster.context(width: width, height: height, mask: false)
            BrushRaster.draw(job.image, in: extent, mask: false, context: context)
            BrushRaster.draw(base, in: extent, mask: false, context: baseContext)
            guard let data = context.data, let baseData = baseContext.data else { throw ExportError.render }
            adjust_tonal_contrast(data.assumingMemoryBound(to: UInt8.self),
                                  baseData.assumingMemoryBound(to: UInt8.self),
                                  width, height, context.bytesPerRow, baseContext.bytesPerRow,
                                  settings.tonalAmount, settings.tonalShadows,
                                  settings.tonalMidtones, settings.tonalHighlights)
            guard let result = context.makeImage() else { throw ExportError.render }
            image = result
        case .lensCorrection:
            // The warp is relative to the image's own size, so a downscaled preview bends the same way.
            let source = try BrushRaster.context(width: width, height: height, mask: false)
            BrushRaster.draw(job.image, in: extent, mask: false, context: source)
            let destination = try BrushRaster.context(width: width, height: height, mask: false)
            guard let from = source.data, let into = destination.data else { throw ExportError.render }
            lens_distort(from.assumingMemoryBound(to: UInt8.self), into.assumingMemoryBound(to: UInt8.self),
                         width, height, source.bytesPerRow, settings.distortion / 100 * lensStrength)
            guard let corrected = destination.makeImage() else { throw ExportError.render }
            image = corrected
        }
        guard let selection = job.selection else { return image }
        return try PixelAdjust.blend(image, over: job.image, through: selection, pixelToDocument: job.mapping, isMask: false,
                                     sixteenBit: job.sixteenBit)
    }

    /// A filter's preview on an HDR layer's pixels (`hdr`, at the preview's size), made the way OK makes the result: the
    /// Core Image filters on them as they are, Exposure exactly, the rest with highlights divided down to within white
    /// and multiplied back (`DeepLayer.normalizing`) — run once here, where OK runs them several times and reads
    /// between, too slow for every slider move and too fine to see.
    static func previewHDR(_ job: FilterJob, from hdr: CGImage) throws -> CGImage {
        var run = job
        run.image = hdr
        if job.kind.runsAtSixteenBits {
            run.sixteenBit = true
            return try PixelFilter.run(run)
        }
        if job.kind == .exposure {
            let result = try DeepLayer.exposure(hdr, job.settings.exposure)
            guard let selection = job.selection else { return result }
            return try PixelAdjust.blend(result, over: hdr, through: selection, pixelToDocument: job.mapping, isMask: false, sixteenBit: true)
        }
        return try DeepLayer.normalizing(hdr) { normal in
            run.image = normal
            return try PixelFilter.run(run)
        }
    }

    /// Progressive Blur: sharp at the start of its line, blurring to the full amount at the end (or, radial, outwards from
    /// the start to the circle through the end), by a mask Core Image blurs through. Past the canvas's edge the layer's
    /// edge pixels carry on, as Gaussian Blur's do.
    static func progressivelyBlurred(_ edges: CIImage, job: FilterJob, settings: FilterSettings, extent: CGRect) -> CIImage {
        // The line in the image's pixels, then in Core Image's, whose y axis points up.
        let toPixels = job.mapping.inverted()
        func point(_ document: CGPoint) -> CGPoint {
            let pixel = document.applying(toPixels)
            return CGPoint(x: pixel.x, y: extent.height - pixel.y)
        }
        let start = point(settings.progressiveStart ?? CGPoint(x: extent.midX, y: extent.minY).applying(job.mapping))
        var end = point(settings.progressiveEnd ?? CGPoint(x: extent.midX, y: extent.maxY).applying(job.mapping))
        if hypot(end.x - start.x, end.y - start.y) < 1 { end = CGPoint(x: start.x, y: start.y - 1) }
        // The mask gives each place its share of the strongest blur: From's at the start, To's at the end.
        var from = settings.progressiveFrom, to = settings.progressiveTo
        if settings.progressiveInverted { swap(&from, &to) }
        let strongest = max(from, to)
        guard strongest > 0 else { return edges }
        func share(_ radius: Double) -> CIColor { CIColor(red: radius / strongest, green: radius / strongest, blue: radius / strongest) }
        let mask = settings.progressiveRadial
            ? CIFilter(name: "CIRadialGradient", parameters: [
                kCIInputCenterKey: CIVector(cgPoint: start), "inputRadius0": 0,
                "inputRadius1": hypot(end.x - start.x, end.y - start.y), "inputColor0": share(from), "inputColor1": share(to)])!.outputImage!
            : CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(cgPoint: start), "inputPoint1": CIVector(cgPoint: end),
                "inputColor0": share(from), "inputColor1": share(to)])!.outputImage!
        return extending(edges, past: job.canvasSides, of: extent).applyingFilter("CIMaskedVariableBlur", parameters: [
            "inputMask": mask, kCIInputRadiusKey: strongest * job.scale,
        ])
    }

    /// A Core Image filter's result, at 16 bits for a 16-bit layer's pixels.
    private static func render(_ image: CIImage, job: FilterJob) throws -> CGImage {
        let width = job.image.width, height = job.image.height
        if job.sixteenBit { return try DeepLayer.render(image, width: width, height: height, hdr: DeepLayer.isHDR(job.image)) }
        return try PixelAdjust.render(image, width: width, height: height, isMask: false)
    }
}

@Observable
final class FilterEdit {
    let kind: FilterKind
    /// Filter › Last Filter, applied straight away with the settings it had.
    var repeating = false
    let layerID: UUID
    let original: ImportedImage
    let transform: LayerTransform
    let selection: SelectionClip?
    var mapping: CGAffineTransform
    var previewSource: CGImage
    /// An HDR layer's pixels at the preview's size and grid, which its preview is made from, as OK makes the result from
    /// the layer's own: from `previewSource`, clipped to white, a blur or Exposure would preview something else.
    var hdrPreviewSource: CGImage?
    var previewScale: CGFloat
    var previewMapping: CGAffineTransform
    /// A filter reaching past the layer's edge — Content-Aware Fill over a selection, a blur spreading outwards —
    /// works on the layer's pixels padded out, and on the transform placing that larger grid.
    var grownImage: CGImage? = nil
    var grownTransform: LayerTransform? = nil
    /// Where the layer's own pixels sit within `grownImage`, so a 16-bit layer's pixels can be padded the same way.
    var grownInside: CGRect? = nil
    /// How far the padding reaches beyond the layer on every side, in layer pixels.
    var grownMargin: CGFloat = 0
    /// The layer's sides at or past the canvas's edge, where Gaussian and Motion Blur carry its edge pixels on rather
    /// than spreading into clear ones: they're given no padding.
    private(set) var canvasSides: LayerSides = []
    var settings: FilterSettings
    var preview = true
    var committing = false
    var previewError: String?
    var preparing = false
    /// Add Noise's grain, fixed while the panel is open so changing Amount doesn't reshuffle it.
    let seed = UInt32.random(in: .min ... .max)
    /// Camera Raw panel eyes. Off drops that group's amounts from the preview and from OK, without clearing the sliders.
    var showsCameraRawLight = true
    var showsCameraRawColor = true
    var showsCameraRawEffects = true
    var showsCameraRawCurve = true
    var showsCameraRawMixer = true
    var showsCameraRawGrading = true
    var showsCameraRawDetail = true
    var showsCameraRawOptics = true
    var showsCameraRawGeometry = true
    var showsCameraRawCalibration = true
    var cameraRawCurvePage: CameraRawCurvePage = .parametric
    var cameraRawPointChannel: CameraRawPointChannel = .rgb
    var cameraRawMixerPage: CameraRawMixerPage = .hsl
    var cameraRawMixerTab: CameraRawMixerTab = .hue
    var cameraRawMixerSwatch = 0
    var cameraRawPointIndex = 0
    var cameraRawGradePage: CameraRawGradePage = .threeWay
    var targetsCameraRawCurve = false
    var targetsCameraRawMixer = false
    var samplesPointColor = false
    var cameraRawDrag: CameraRawDrag?
    var pointColorVisualizeIndex: Int {
        let points = settings.cameraRaw.mixer.points
        guard points.indices.contains(cameraRawPointIndex), points[cameraRawPointIndex].visualize else { return -1 }
        return cameraRawPointIndex
    }
    /// White-balance eyedropper, armed from the Color section.
    var samplesWhiteBalance = false
    /// Defringe eyedropper, armed from Optics. Sets purple or green hue range from the clicked fringe.
    var samplesDefringe = false
    /// Guided Upright: drag lines on the preview.
    var drawingCameraRawGeometryGuide = false
    var cameraRawGuideDraft: (start: CGPoint, end: CGPoint)?
    /// Set while Option is held on Exposure, Highlights, Shadows, Whites, or Blacks.
    var cameraRawClipping: CameraRawClipping?
    /// Set while Option is held on Sharpening Masking.
    var cameraRawSharpenMask = false
    /// Histogram clipping indicators. They paint the preview and are not baked in on OK.
    var showsShadowClipping = false
    var showsHighlightClipping = false
    /// Histogram, or the vectorscope chosen from its context menu.
    var cameraRawScopeMode: CameraRawScopeMode = .histogram
    var cameraRawScope: CameraRawScope?
    /// RGB of the pixel under the pointer, in the adjusted preview.
    var cameraRawReadout: (red: Int, green: Int, blue: Int)?
    /// Vignette on an empty layer: the canvas it frames and fills.
    @ObservationIgnored var canvas: CGRect?
    /// The layer had no pixels yet (an empty layer); the filter started it from clear ones.
    @ObservationIgnored var startedEmpty = false
    @ObservationIgnored var preparedPreview: CGImage?
    /// Where `preparedPreview` goes: the grown layer it was made from, or nil for the layer's own place. A blur grows
    /// the layer as it gets bigger; the last preview stays up where it belongs until the next one replaces it.
    @ObservationIgnored var preparedTransform: LayerTransform?
    /// The grown layer `pending` is made from.
    @ObservationIgnored var pendingTransform: LayerTransform?
    /// Reject a render started before the blur's padded pixel grid changed.
    @ObservationIgnored var previewSourceVersion: UInt64 = 0
    /// Camera Raw's adaptive sliders read the picture before any change, which stays the same while the panel is open:
    /// measured once from the preview's source, again only when that changes.
    @ObservationIgnored private var cameraRawBrightness: (version: UInt64, value: CameraRawTables.Brightness)?
    var previewBrightness: CameraRawTables.Brightness? {
        guard let cached = cameraRawBrightness, cached.version == previewSourceVersion else { return nil }
        return cached.value
    }
    func cachePreviewBrightness(_ value: CameraRawTables.Brightness) {
        cameraRawBrightness = (previewSourceVersion, value)
    }
    /// The settings `preparedPreview` was made with, for the automatic filters that have settings of their own.
    @ObservationIgnored var preparedSettings: FilterSettings?
    @ObservationIgnored var pending: FilterJob?
    @ObservationIgnored var previewTask: Task<Void, Never>?
    /// Previews render from a copy no larger than this on its longest side.
    static let previewLimit: CGFloat = 2048

    /// `growingTo`: a document area the layer's grid should cover (Content-Aware Fill's selection on the canvas).
    /// A blur grows the grid by its own reach instead, and again if its amount is raised.
    init(kind: FilterKind, layer: ImageLayer, selection: SelectionClip?, settings: FilterSettings, growingTo area: CGRect? = nil,
         canvas: CGSize? = nil) throws {
        guard let asset = layer.asset else { throw ProjectError.invalid }
        self.kind = kind
        self.settings = settings.normalized
        layerID = layer.id; original = asset; transform = layer.transform; self.selection = selection
        let ready = try Self.prepared(kind: kind, from: asset.image, placed: layer.transform)
        mapping = ready.mapping
        previewSource = ready.previewSource
        previewScale = ready.previewScale
        previewMapping = ready.previewMapping
        hdrPreviewSource = try Self.hdrPreview(of: asset, inside: nil, grid: nil, size: ready.previewSource)
        // A rotated layer's sides don't run along the canvas's, so it has none at its edge.
        if let canvas, kind == .gaussianBlur || kind == .motionBlur || kind == .progressiveBlur, layer.transform.rotation == 0 {
            let inPixels = CGRect(origin: .zero, size: canvas).applying(ready.mapping.inverted())
            let width = CGFloat(asset.image.width), height = CGFloat(asset.image.height)
            if inPixels.minX >= -0.5 { canvasSides.insert(.left) }
            if inPixels.maxX <= width + 0.5 { canvasSides.insert(.right) }
            if inPixels.minY >= -0.5 { canvasSides.insert(.top) }
            if inPixels.maxY <= height + 0.5 { canvasSides.insert(.bottom) }
        }
        if let area {
            let toPixels = BrushRaster.pixelToDocument(layer.transform, width: asset.image.width, height: asset.image.height).inverted()
            try grow(to: area.applying(toPixels).integral)
        }
        try growForBlur()
    }

    /// The room a blur needs around the layer: about three standard deviations, or half a streak.
    static func blurMargin(_ kind: FilterKind, _ settings: FilterSettings) -> CGFloat {
        switch kind {
        case .gaussianBlur: return settings.preserveTransparency ? 0 : CGFloat(settings.radius * 3 + 2)
        case .motionBlur: return CGFloat(settings.distance / 2 + 2)
        case .progressiveBlur: return CGFloat(max(settings.progressiveFrom, settings.progressiveTo) * 3 + 2)
        case .bloomGlow: return CGFloat(settings.bloomRadius * 3 + 2)
        default: return 0
        }
    }

    /// Pads the layer out so the blur has somewhere to spread; only ever grows, so easing the amount back off
    /// doesn't rebuild anything.
    func growForBlur() throws {
        let margin = Self.blurMargin(kind, settings)
        guard margin > grownMargin else { return }
        let bounds = CGRect(x: 0, y: 0, width: original.image.width, height: original.image.height)
        let room = margin.rounded(.up)
        var target = bounds
        if !canvasSides.contains(.left) { target.origin.x -= room; target.size.width += room }
        if !canvasSides.contains(.right) { target.size.width += room }
        if !canvasSides.contains(.top) { target.origin.y -= room; target.size.height += room }
        if !canvasSides.contains(.bottom) { target.size.height += room }
        try grow(to: target)
        // Measured over the padded sides only, or a side left unpadded would have every change pad it again.
        grownMargin = room
    }

    /// The layer's pixels drawn into a grid covering `extent` (layer pixels), with the transform that places it.
    private func grow(to extent: CGRect) throws {
        let bounds = CGRect(x: 0, y: 0, width: original.image.width, height: original.image.height)
        let target = bounds.union(extent).integral
        guard target != bounds else { return }
        guard target.width <= DocumentLimits.maxSideExtent, target.height <= DocumentLimits.maxSideExtent, target.width * target.height <= DocumentLimits.maxSurfaceExtent else { throw ProjectError.tooLarge }
        let context = try BrushRaster.context(width: Int(target.width), height: Int(target.height), mask: false)
        let inside = bounds.offsetBy(dx: -target.minX, dy: -target.minY)
        if let raster = original.raster { raster.draw(in: inside, context: context) }
        else { BrushRaster.draw(original.image, in: inside, mask: false, context: context) }
        guard let image = context.makeImage() else { throw ExportError.render }
        let toDocument = BrushRaster.pixelToDocument(transform, width: original.image.width, height: original.image.height)
        var expanded = transform
        expanded.size = CGSize(width: target.width * transform.size.width / bounds.width,
                               height: target.height * transform.size.height / bounds.height)
        let middle = CGPoint(x: target.midX, y: target.midY).applying(toDocument)
        expanded.origin = CGPoint(x: middle.x - expanded.size.width / 2, y: middle.y - expanded.size.height / 2)
        grownImage = image
        grownTransform = expanded
        grownInside = inside
        grownMargin = min(bounds.minX - target.minX, bounds.minY - target.minY,
                          target.maxX - bounds.maxX, target.maxY - bounds.maxY)
        try prepare(from: image, placed: expanded)
    }

    /// What the filter and its preview read: the full-size grid, and a copy no larger than `previewLimit` for
    /// everything but the filters that must be made at full size.
    private static func prepared(kind: FilterKind, from source: CGImage, placed: LayerTransform) throws
        -> (mapping: CGAffineTransform, previewSource: CGImage, previewScale: CGFloat, previewMapping: CGAffineTransform) {
        let mapping = BrushRaster.pixelToDocument(placed, width: source.width, height: source.height)
        // Camera Raw keeps native detail throughout slider drags. Noise, grain, dither and scanlines also need
        // full-size pixels: made on a smaller copy they would look coarser once enlarged.
        let factor = [.cameraRaw, .addNoise, .grain, .dither, .scanlines, .contentAwareFill, .removeBackground].contains(kind)
            ? 1 : min(1, previewLimit / CGFloat(max(source.width, source.height)))
        guard factor < 1 else { return (mapping, source, 1, mapping) }
        let w = max(1, Int(CGFloat(source.width) * factor)), h = max(1, Int(CGFloat(source.height) * factor))
        let context = try BrushRaster.context(width: w, height: h, mask: false)
        BrushRaster.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h), mask: false, context: context)
        guard let small = context.makeImage() else { throw ExportError.render }
        return (mapping, small, CGFloat(w) / CGFloat(source.width),
                BrushRaster.pixelToDocument(placed, width: w, height: h))
    }
    private func prepare(from source: CGImage, placed: LayerTransform) throws {
        let ready = try Self.prepared(kind: kind, from: source, placed: placed)
        mapping = ready.mapping
        previewSource = ready.previewSource
        previewScale = ready.previewScale
        previewMapping = ready.previewMapping
        hdrPreviewSource = try Self.hdrPreview(of: original, inside: grownInside,
                                               grid: CGSize(width: source.width, height: source.height), size: ready.previewSource)
        previewSourceVersion &+= 1
    }

    /// An HDR layer's pixels laid out as `size` (the preview's source) is: padded onto `grid` at `inside` when the layer
    /// has grown, then scaled to its size. Nil for any other layer.
    private static func hdrPreview(of asset: ImportedImage, inside: CGRect?, grid: CGSize?, size: CGImage) throws -> CGImage? {
        guard asset.isHDR, let deep = try DeepLayer.flattened(asset) else { return nil }
        guard let grid, let inside else { return try DeepLayer.hdrPreview(of: asset, matching: size) }
        let whole = try DeepLayer.padded(deep, to: grid, inside: inside)
        guard whole.width != size.width || whole.height != size.height else { return whole }
        let context = try DeepLayer.context(width: size.width, height: size.height, hdr: true)
        context.interpolationQuality = .high
        BrushRaster.draw(whole, in: CGRect(x: 0, y: 0, width: size.width, height: size.height), mask: false, context: context)
        return context.makeImage()
    }

    func previewImage(for id: UUID) -> CGImage? { preview && id == layerID ? preparedPreview : nil }
    /// Sliders as they will be rendered: a hidden Camera Raw group contributes nothing.
    func renderSettings() -> FilterSettings {
        var value = settings
        if kind == .cameraRaw {
            value.cameraRaw = value.cameraRaw.applying(showsLight: showsCameraRawLight, showsColor: showsCameraRawColor,
                                                        showsEffects: showsCameraRawEffects, showsCurve: showsCameraRawCurve,
                                                        showsMixer: showsCameraRawMixer, showsGrading: showsCameraRawGrading,
                                                        showsDetail: showsCameraRawDetail, showsOptics: showsCameraRawOptics,
                                                        showsGeometry: showsCameraRawGeometry, showsCalibration: showsCameraRawCalibration)
        }
        return value
    }
    var previewJob: FilterJob {
        var job = FilterJob(kind: kind, image: previewSource, settings: renderSettings(), scale: previewScale, selection: selection,
                            mapping: previewMapping, seed: seed)
        job.canvas = canvas
        job.canvasSides = canvasSides
        job.cameraRawClipping = cameraRawClipping
        job.showsShadowClipping = showsShadowClipping
        job.showsHighlightClipping = showsHighlightClipping
        job.visualizesPointColor = pointColorVisualizeIndex
        job.showsSharpenMask = cameraRawSharpenMask
        if kind == .cameraRaw {
            job.cameraRawBrightness = previewBrightness
            job.cameraRawUsesGPU = previewSource.width * previewSource.height >= MetalCameraRawLookup.minimumPixels
        }
        return job
    }
}

extension EditorSession {
    var canContentAwareFill: Bool {
        canAdjustColors && !isMaskSelected && selection?.isEmpty == false && filterEdit == nil && hueSaturation == nil
    }
    /// `repeating` is Last Filter: the settings go on as they are, without a preview or the panel.
    func beginFilter(_ kind: FilterKind, repeating: Bool = false) {
        if kind == .contentAwareFill && !canContentAwareFill { return }
        guard filterEdit == nil, hueSaturation == nil, kind == .vignette ? canVignette : canAdjustColors else { NSSound.beep(); return }
        if gradientEdit != nil {
            Task { await commitGradient(); beginFilter(kind) }
            return
        }
        commitTransform(); cancelCrop(); cancelLasso()
        guard var layer = activeLayer, let document else { return }
        pauseGIFForEditing(for: layer.id)
        layer = pixelEditingLayer(for: layer)
        do {
            // An empty layer has no pixels until something is put on it; Vignette starts it with clear ones.
            let startedEmpty = layer.asset == nil
            if startedEmpty {
                let width = max(1, Int(layer.transform.size.width.rounded())), height = max(1, Int(layer.transform.size.height.rounded()))
                guard let clear = try BrushRaster.context(width: width, height: height, mask: false).makeImage() else { throw ExportError.render }
                layer.asset = ImportedImage(image: clear, thumbnail: try PixelAdjust.thumbnail(of: clear), name: layer.name)
            }
            var settings = filterSettings
            // Progressive Blur starts sharp at the top of the layer's visible part, blurring to its foot; Last Filter
            // keeps the line it had.
            if kind == .progressiveBlur, !repeating {
                let shown = CGRect(origin: layer.transform.origin, size: layer.transform.size)
                    .intersection(CGRect(origin: .zero, size: document.size))
                let area = shown.isNull || shown.isEmpty ? CGRect(origin: .zero, size: document.size) : shown
                settings.progressiveStart = CGPoint(x: area.midX, y: area.minY + area.height * 0.35)
                settings.progressiveEnd = CGPoint(x: area.midX, y: area.maxY)
            }
            // Gradient Map starts from the foreground and background colors, as in Photoshop.
            if kind == .gradientMap {
                settings.gradientMap = GradientMapSettings(shadows: AdjustmentColor(foregroundColor), highlights: AdjustmentColor(backgroundColor))
            }
            // Content-Aware Fill extends the layer over any of the selection on the canvas past its edge; Vignette on
            // an empty layer covers the whole canvas, which it frames and fills.
            let canvas = CGRect(origin: .zero, size: document.size)
            let fillsCanvas = kind == .vignette && startedEmpty
            let area = kind == .contentAwareFill
                ? selection.map { $0.path.boundingBoxOfPath.intersection(canvas) }.flatMap { $0.isNull || $0.isEmpty ? nil : $0 }
                : fillsCanvas ? canvas : nil
            let edit = try FilterEdit(kind: kind, layer: layer, selection: selection?.clip(canvas: document.size), settings: settings,
                                      growingTo: area, canvas: document.size)
            if fillsCanvas { edit.canvas = canvas }
            edit.startedEmpty = startedEmpty
            edit.repeating = repeating
            filterEdit = edit
            if kind == .cameraRaw, edit.previewSource.width * edit.previewSource.height >= MetalCameraRawLookup.minimumPixels {
                Task.detached(priority: .utility) { _ = MetalCameraRawLookup.shared }
            }
            // An automatic filter commits what its preview made, so it still needs one.
            updateFilter(edit.settings, preview: !repeating || kind.isAutomatic)
        } catch { brushError = error.localizedDescription }
    }

    /// Filter › Last Filter (⌘F): the last filter applied, again, with the same settings and no panel, as in Photoshop.
    var canRepeatLastFilter: Bool {
        guard let lastFilter, filterEdit == nil, hueSaturation == nil else { return false }
        return lastFilter == .vignette ? canVignette : canAdjustColors
    }
    func repeatLastFilter() async {
        guard let kind = lastFilter, canRepeatLastFilter else { NSSound.beep(); return }
        if gradientEdit != nil { await commitGradient() }
        beginFilter(kind, repeating: true)
        guard let edit = filterEdit, edit.repeating else { return }
        await commitFilter()
        // Nothing to apply (a zero amount), or it couldn't be: don't leave it open with no panel to close it.
        if filterEdit === edit { cancelFilter() }
    }

    /// Progressive Blur's line, dragged on the canvas: either end moved (document coordinates).
    func moveProgressiveBlur(start: CGPoint? = nil, end: CGPoint? = nil) {
        guard let edit = filterEdit, edit.kind == .progressiveBlur, !edit.committing else { return }
        var settings = edit.settings
        if let start { settings.progressiveStart = start }
        if let end { settings.progressiveEnd = end }
        updateFilter(settings, preview: edit.preview)
    }

    func updateFilter(_ settings: FilterSettings, preview: Bool) {
        guard let edit = filterEdit, !edit.committing else { return }
        edit.settings = settings.normalized
        edit.preview = preview
        // A bigger blur needs more room around the layer than it was given.
        if FilterEdit.blurMargin(edit.kind, edit.settings) > edit.grownMargin {
            do { try edit.growForBlur() }
            catch { brushError = error.localizedDescription }
        }
        if previewAdjustmentEditing(preview: preview) { return }
        if edit.kind.isAutomatic, edit.preparedPreview != nil, edit.preparedSettings == edit.settings { brushRevision += 1; return }
        guard preview else {
            edit.pending = nil; edit.preparedPreview = nil; brushRevision += 1
            return
        }
        edit.pending = edit.previewJob
        edit.pendingTransform = edit.grownTransform
        renderFilterPreview(edit)
    }

    /// Renders the newest settings; changes that arrive mid-render wait for it rather than
    /// cancelling it, so dragging a slider keeps the canvas updating.
    private func renderFilterPreview(_ edit: FilterEdit) {
        guard filterEdit === edit, edit.previewTask == nil, var job = edit.pending else { return }
        if job.kind == .cameraRaw { job.cameraRawBrightness = edit.previewBrightness }
        edit.pending = nil
        let placement = edit.pendingTransform
        let sourceVersion = edit.previewSourceVersion
        let hdrSource = edit.kind.isAutomatic ? nil : edit.hdrPreviewSource
        edit.preparing = true
        edit.previewError = nil
        edit.previewTask = Task { @MainActor [weak self, weak edit] in
            let result = await Task.detached(priority: .userInitiated) { () -> (CGImage?, CameraRawScope?, String?, CameraRawTables.Brightness?) in
                var run = job
                // Measure once on the worker, then reuse it for every slider update in this session.
                if run.kind == .cameraRaw, run.cameraRawBrightness == nil {
                    run.cameraRawBrightness = CameraRawTables.brightness(of: run.image)
                }
                do {
                    // An HDR layer previews from its HDR pixels, as OK makes it, shown clipped to white.
                    if let hdrSource {
                        let made = try PixelFilter.previewHDR(run, from: hdrSource)
                        let scope = run.kind == .cameraRaw ? try CameraRawScope.preview(run).scope : nil
                        return (try DeepLayer.dithered(made), scope, nil, run.cameraRawBrightness)
                    }
                    if run.kind == .cameraRaw {
                        let made = try CameraRawScope.preview(run)
                        return (made.image, made.scope, nil, run.cameraRawBrightness)
                    }
                    return (try PixelFilter.run(run), nil, nil, run.cameraRawBrightness)
                } catch {
                    return (nil, nil, error.localizedDescription, run.cameraRawBrightness)
                }
            }.value
            guard let self, let edit, self.filterEdit === edit, !Task.isCancelled else {
                if job.cameraRawUsesGPU { Task.detached(priority: .utility) { MetalCameraRawLookup.shared?.discardBuffers() } }
                return
            }
            edit.previewTask = nil
            edit.preparing = false
            // Made before the layer grew for a bigger blur: it still shows, in the place it was made for, until the
            // render from the grown layer replaces it.
            let current = sourceVersion == edit.previewSourceVersion
            if current, let brightness = result.3 { edit.cachePreviewBrightness(brightness) }
            edit.previewError = result.2
            if let scope = result.1 { edit.cameraRawScope = scope }
            if (edit.preview || edit.kind.isAutomatic), current || !edit.kind.isAutomatic {
                edit.preparedPreview = result.0
                edit.preparedTransform = placement
                edit.preparedSettings = current ? job.settings : nil
                self.brushRevision += 1
            }
            self.renderFilterPreview(edit)
        }
    }

    func cancelFilter() {
        // A filter color still being picked goes with the panel.
        if case .gradientMap = colorPicker?.target { closeColorPicker(commit: false) }
        if case .vignette = colorPicker?.target { closeColorPicker(commit: false) }
        if case .dither = colorPicker?.target { closeColorPicker(commit: false) }
        if finishAdjustmentEditing(commit: false) { return }
        guard let edit = filterEdit, !edit.committing else { return }
        edit.previewTask?.cancel()
        if edit.kind == .cameraRaw, edit.previewJob.cameraRawUsesGPU {
            Task.detached(priority: .utility) { MetalCameraRawLookup.shared?.discardBuffers() }
        }
        filterEdit = nil
        brushRevision += 1
    }

    func commitFilter() async {
        if case .gradientMap = colorPicker?.target { closeColorPicker(commit: true) }
        if case .vignette = colorPicker?.target { closeColorPicker(commit: true) }
        if case .dither = colorPicker?.target { closeColorPicker(commit: true) }
        if finishAdjustmentEditing(commit: true) { return }
        guard let edit = filterEdit, !edit.committing else { return }
        if edit.kind.isAutomatic {
            await edit.previewTask?.value
            guard filterEdit === edit, !edit.committing, edit.preparedPreview != nil, edit.previewError == nil else { return }
            // Remove Background masks from the full-size image, so a preview made at preview size is fine to discard.
        }
        // A hidden Camera Raw group is absent from the layer. Remember that rendered grade, including
        // when every remaining amount is zero, so the next open does not put the hidden sliders back.
        let rendered = edit.renderSettings()
        if edit.kind == .cameraRaw { filterSettings = rendered }
        // No distortion to remove: close as Cancel does, without an undo step.
        if (edit.kind == .lensCorrection && edit.settings.distortion == 0)
            || (edit.kind == .vignette && edit.settings.vignetteAmount == 0)
            || (edit.kind == .bloomGlow && edit.settings.bloomAmount == 0)
            || (edit.kind == .tonalContrast && (edit.settings.tonalAmount == 0 ||
                (edit.settings.tonalShadows == 0 && edit.settings.tonalMidtones == 0 && edit.settings.tonalHighlights == 0)))
            || (edit.kind == .exposure && edit.settings.exposure == ExposureSettings())
            || (edit.kind == .grain && edit.settings.grain.amount == 0)
            || (edit.kind == .cameraRaw && rendered.cameraRaw.isIdentity) { cancelFilter(); return }
        edit.committing = true
        edit.previewTask?.cancel()
        if edit.kind != .cameraRaw { filterSettings = edit.settings }
        if edit.kind.repeatsAsLastFilter { lastFilter = edit.kind }
        isProjectBusy = true
        // The preview stays up until the result is on the layer, so the canvas never flashes the original.
        defer {
            filterEdit = nil; isProjectBusy = false; brushRevision += 1
            if edit.kind == .cameraRaw, edit.previewJob.cameraRawUsesGPU {
                Task.detached(priority: .utility) { MetalCameraRawLookup.shared?.discardBuffers() }
            }
        }
        // Remove Background masks the background out rather than erasing it, so it can be brought back at any time
        // by painting the mask, disabling it, or deleting it.
        if edit.kind == .removeBackground { await commitBackgroundMask(edit); return }
        // A blur that keeps the layer's transparency has no use for room around it (opening the panel may have made
        // some for the blur it started with): it's applied to the layer as it was, which leaves its size alone.
        let keepsOutline = edit.kind == .gaussianBlur && edit.settings.preserveTransparency
        let mapping = keepsOutline
            ? BrushRaster.pixelToDocument(edit.transform, width: edit.original.image.width, height: edit.original.image.height)
            : edit.mapping
        var job = FilterJob(kind: edit.kind, image: keepsOutline ? edit.original.image : edit.grownImage ?? edit.original.image,
                            settings: edit.renderSettings(), scale: 1, selection: edit.selection, mapping: mapping, seed: edit.seed)
        job.canvas = edit.canvas
        job.canvasSides = edit.canvasSides
        let cached = edit.kind.isAutomatic && edit.preparedSettings == edit.settings ? edit.preparedPreview : nil
        do {
            let grown = keepsOutline ? nil : edit.grownTransform
            let spreads = edit.kind == .gaussianBlur || edit.kind == .motionBlur || edit.kind == .progressiveBlur || edit.kind == .bloomGlow
            // A 16-bit layer runs the filter on its 16-bit pixels, padded as the 8-bit ones were (`DeepLayer.run`).
            // These rasterize the layer to 8-bit instead: Content-Aware Fill makes new pixels from scratch; Dither's
            // result is a few levels by design (three runs read between would mix its patterns into colors); Remove
            // Background would find the subject three times over.
            let rasterizes = edit.kind == .contentAwareFill || edit.kind == .dither || edit.kind == .removeBackground
            let deep = rasterizes ? nil : try DeepLayer.flattened(edit.original)
            let deepGrid = keepsOutline ? nil : edit.grownImage.flatMap { grownImage in
                edit.grownInside.map { (size: CGSize(width: grownImage.width, height: grownImage.height), inside: $0) }
            }
            let made = try await Task.detached(priority: .userInitiated) { () -> (asset: ImportedImage, transform: LayerTransform?) in
                // Exposure on an HDR layer, exactly: turned down, it brings highlights into view.
                if let deep, DeepLayer.isHDR(deep), job.kind == .exposure {
                    var result = try DeepLayer.exposure(deep, job.settings.exposure)
                    if let selection = job.selection {
                        result = try PixelAdjust.blend(result, over: deep, through: selection, pixelToDocument: job.mapping,
                                                       isMask: false, sixteenBit: true)
                    }
                    return (try DeepLayer.asset(result, name: job.kind.rawValue), grown)
                }
                if let deep, let lookup = job.kind.sixteenBitLookup(job.settings) {
                    // Channels that mix go through the adjustment's color lookup at 16 bits.
                    var result = try DeepLayer.lookup(deep, cube: lookup.cube, dimension: lookup.dimension)
                    if let selection = job.selection {
                        result = try PixelAdjust.blend(result, over: deep, through: selection, pixelToDocument: job.mapping,
                                                       isMask: false, sixteenBit: true)
                    }
                    return (try DeepLayer.asset(result, name: job.kind.rawValue), grown)
                }
                if let deep {
                    let input = try deepGrid.map { try DeepLayer.padded(deep, to: $0.size, inside: $0.inside) } ?? deep
                    var result: CGImage
                    if job.kind.runsAtSixteenBits {
                        var run = job
                        run.image = input
                        run.sixteenBit = true
                        result = try PixelFilter.run(run)
                    } else {
                        result = try DeepLayer.run(input, mixesChannels: job.kind.mixesChannels) { half in
                            var run = job
                            run.image = half
                            return try PixelFilter.run(run)
                        }
                    }
                    var placed = grown
                    if spreads, let grown, let crop = try PixelFilter.trimCrop(try DeepLayer.dithered(result)),
                       let cropped = result.cropping(to: crop) {
                        placed = PixelFilter.trimmedTransform(grown, crop: crop, width: result.width, height: result.height)
                        result = cropped
                    }
                    return (try DeepLayer.asset(result, name: job.kind.rawValue), placed)
                }
                var image = try cached ?? PixelFilter.run(job)
                var placed = grown
                if spreads, let grown {
                    let trimmed = try PixelFilter.trimmed(image, placed: grown)
                    image = trimmed.image
                    placed = trimmed.transform
                }
                return (ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: job.kind.rawValue), placed)
            }.value
            let asset = made.asset
            guard let index = document?.layers.firstIndex(where: { $0.id == edit.layerID }),
                  let current = document?.layers[index],
                  displayedAsset(for: current)?.image === edit.original.image || (edit.startedEmpty && current.asset == nil),
                  pixelEditTransformMatches(current, transform: edit.transform) else { return }
            // A grown layer's mask (covering the old grid) is carried onto the new one, its edge tone past the old edge.
            var mask = current.mask
            if current.gifAnimation == nil, let grown, let owned = current.mask, owned.placement == nil,
               owned.asset.image.width > 1 || owned.asset.image.height > 1 {
                var enabled = owned
                enabled.isEnabled = true
                guard let carried = enabled.clipImage(placement: current.transform, over: grown,
                                                      width: asset.image.width, height: asset.image.height) else { throw ExportError.render }
                mask = owned.replacing(try LayerMask.asset(from: carried))
            }
            let edited = try layerByEditingPixels(current, asset: asset, transform: made.transform ?? current.transform, mask: mask)
            beginEdit(edit.kind.rawValue)
            document?.layers[index] = edited
            endEdit()
        } catch { brushError = error.localizedDescription }
    }

    /// Remove Background as a layer mask: the subject stays white, the background black. A mask already on the layer
    /// (in the layer's own grid) is kept, hiding whatever either one hides; with a selection, only the selected part
    /// of the mask changes.
    private func commitBackgroundMask(_ edit: FilterEdit) async {
        let source = edit.original.image
        let current = document?.layers.first(where: { $0.id == edit.layerID })
        let existing = current?.mask.flatMap { owned in
            owned.placement == nil && owned.asset.image.width == source.width && owned.asset.image.height == source.height
                ? owned.asset.image : nil
        }
        let selection = edit.selection, mapping = edit.mapping, settings = edit.settings.normalized
        do {
            let made = try await Task.detached(priority: .userInitiated) { () -> CGImage in
                var mask = try SubjectRemoval.subjectMask(source, under: existing, settings: settings)
                if let selection, let base = existing {
                    mask = try PixelAdjust.blend(mask, over: base, through: selection, pixelToDocument: mapping, isMask: true)
                } else if let selection {
                    let white = try BrushRaster.context(width: source.width, height: source.height, mask: true)
                    white.setFillColor(gray: 1, alpha: 1)
                    white.fill(CGRect(x: 0, y: 0, width: source.width, height: source.height))
                    guard let opaque = white.makeImage() else { throw ExportError.render }
                    mask = try PixelAdjust.blend(mask, over: opaque, through: selection, pixelToDocument: mapping, isMask: true)
                }
                return mask
            }.value
            guard let index = document?.layers.firstIndex(where: { $0.id == edit.layerID }),
                  let layer = document?.layers[index], displayedAsset(for: layer)?.image === edit.original.image,
                  pixelEditTransformMatches(layer, transform: edit.transform) else { return }
            let asset = try LayerMask.asset(from: made)
            beginEdit(edit.kind.rawValue)
            document?.layers[index].mask = layer.mask.map { $0.replacing(asset) } ?? LayerMask(asset: asset)
            document?.layers[index].mask?.isEnabled = true
            isMaskSelected = true
            endEdit()
        } catch { brushError = error.localizedDescription }
    }
}
