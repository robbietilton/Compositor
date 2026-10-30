import CoreGraphics
import CoreImage

/// Filter › Lens Effects: what light does inside a camera's lens and the filters in front of it. Each effect is made from
/// the picture's own light, in linear light as optics work, so only real light sources flare and nothing is pasted on.
nonisolated enum LensEffect: String, CaseIterable, Codable, Sendable {
    case anamorphicFlare = "Anamorphic Flare"
    case starburst = "Starburst"
    case mist = "Mist"
    case prism = "Prism"
    case bokeh = "Bokeh"
}

/// The shape a lens draws its out-of-focus lights in.
nonisolated enum BokehShape: String, CaseIterable, Codable, Sendable {
    /// Wide open.
    case round = "Round"
    /// Stopped down, its aperture's blades showing as straight sides.
    case hexagon = "Hexagon"
    /// An anamorphic lens's tall ovals.
    case oval = "Oval"
    /// Clipped into a lemon shape toward the frame's edges, as fast and vintage lenses draw them.
    case catsEye = "Cat's Eye"

    var index: UInt32 { UInt32(Self.allCases.firstIndex(of: self) ?? 0) }
}

nonisolated struct LensEffectSettings: Codable, Equatable, Sendable {
    static let starPointChoices = [4, 6, 8, 12, 14]
    static let bokehSizes: ClosedRange<Double> = 0.5...6

    var effect: LensEffect = .anamorphicFlare
    /// Anamorphic Flare and Starburst: how bright a light has to be to flare, 50–100%; past 95, how big and solid too
    /// (see `LensOptics.sources`).
    var threshold: Double = 90
    /// Anamorphic Flare: strength 0–100, and the streak's reach as a percentage of the layer's longer side.
    var flareAmount: Double = 50
    var flareLength: Double = 60
    /// How much the lens's coatings turn the streak blue along its length, 0–100: none keeps every streak the color of
    /// its light all the way.
    var flareBlue: Double = 80
    /// Starburst: strength, the spikes' reach (percent of the longer side), how many, and their angle in degrees.
    var starAmount: Double = 50
    var starLength: Double = 12
    var starPoints = 6
    var starAngle: Double = 15
    /// Mist: how much light scatters, and how far, 0–100.
    var mistStrength: Double = 50
    var mistSize: Double = 30
    /// Prism: how strong the ghosted copies are, how many, how far apart (percent of the longer side), which way in
    /// degrees (counterclockwise from right), how much they're softened, 0–100, and how far the glass splits each copy's
    /// red and blue apart, 0–100 (0 keeps them crisp; 30, the default, splits them 0.3% of the longer side).
    var prismAmount: Double = 80
    var prismCopies: Double = 5
    var prismOffset: Double = 6
    var prismAngle: Double = 180
    /// Copies on both sides of the picture rather than one, Copies of them each side.
    var prismBothWays = false
    var prismBlur: Double = 0
    var prismFringe: Double = 30
    /// Bokeh, always a full lens blur: the discs' size (percent of the longer side), how brightly lights open into
    /// them, how much of a disc's light gathers at its rim, as many lenses draw it, and the aperture's shape.
    var bokehRadius: Double = 2
    var bokehBrightness: Double = 50
    var bokehRing: Double = 100
    var bokehShape: BokehShape = .round

    init() {}

    /// Each setting read if it's there, its default if not, so settings added later don't make older files unreadable.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T { try values.decodeIfPresent(T.self, forKey: key) ?? fallback }
        let base = Self()
        effect = try read(.effect, base.effect); threshold = try read(.threshold, base.threshold)
        flareAmount = try read(.flareAmount, base.flareAmount); flareLength = try read(.flareLength, base.flareLength)
        flareBlue = try read(.flareBlue, base.flareBlue)
        starAmount = try read(.starAmount, base.starAmount); starLength = try read(.starLength, base.starLength)
        starPoints = try read(.starPoints, base.starPoints); starAngle = try read(.starAngle, base.starAngle)
        mistStrength = try read(.mistStrength, base.mistStrength); mistSize = try read(.mistSize, base.mistSize)
        prismAmount = try read(.prismAmount, base.prismAmount); prismCopies = try read(.prismCopies, base.prismCopies)
        prismOffset = try read(.prismOffset, base.prismOffset); prismAngle = try read(.prismAngle, base.prismAngle)
        prismBothWays = try read(.prismBothWays, base.prismBothWays); prismBlur = try read(.prismBlur, base.prismBlur)
        prismFringe = try read(.prismFringe, base.prismFringe)
        bokehRadius = try read(.bokehRadius, base.bokehRadius); bokehBrightness = try read(.bokehBrightness, base.bokehBrightness)
        bokehRing = try read(.bokehRing, base.bokehRing); bokehShape = try read(.bokehShape, base.bokehShape)
    }

    /// Nothing to do: OK closes as Cancel does.
    var isIdentity: Bool {
        switch effect {
        case .anamorphicFlare: flareAmount == 0
        case .starburst: starAmount == 0
        case .mist: mistStrength == 0
        case .prism: prismAmount == 0
        case .bokeh: false
        }
    }

    var normalized: Self {
        var result = self
        result.threshold = ImageAdjustmentPixels.clamp(threshold, 50...100, 90)
        result.flareAmount = ImageAdjustmentPixels.clamp(flareAmount, 0...100, 50)
        result.flareLength = ImageAdjustmentPixels.clamp(flareLength, 1...100, 60)
        result.flareBlue = ImageAdjustmentPixels.clamp(flareBlue, 0...100, 80)
        result.starAmount = ImageAdjustmentPixels.clamp(starAmount, 0...100, 50)
        result.starLength = ImageAdjustmentPixels.clamp(starLength, 2...40, 12)
        result.starPoints = Self.starPointChoices.contains(starPoints) ? starPoints : 6
        result.starAngle = ImageAdjustmentPixels.clamp(starAngle, -180...180, 15)
        result.mistStrength = ImageAdjustmentPixels.clamp(mistStrength, 0...100, 50)
        result.mistSize = ImageAdjustmentPixels.clamp(mistSize, 0...100, 30)
        result.prismAmount = ImageAdjustmentPixels.clamp(prismAmount, 0...100, 80)
        result.prismCopies = ImageAdjustmentPixels.clamp(prismCopies, 1...8, 5).rounded()
        result.prismOffset = ImageAdjustmentPixels.clamp(prismOffset, 0...50, 6)
        result.prismAngle = ImageAdjustmentPixels.clamp(prismAngle, -180...180, 180)
        result.prismBlur = ImageAdjustmentPixels.clamp(prismBlur, 0...100, 0)
        result.prismFringe = ImageAdjustmentPixels.clamp(prismFringe, 0...100, 30)
        result.bokehRadius = ImageAdjustmentPixels.clamp(bokehRadius, Self.bokehSizes.lowerBound...Self.bokehSizes.upperBound, 2)
        result.bokehBrightness = ImageAdjustmentPixels.clamp(bokehBrightness, 0...100, 50)
        result.bokehRing = ImageAdjustmentPixels.clamp(bokehRing, 0...100, 100)
        return result
    }

    /// The effect on `pixels`, an 8- or 16-bit layer's sRGB pixels. Sizes are proportions of the image, so a preview at
    /// a smaller size looks as the result will.
    func apply(to pixels: CGImage) throws -> CIImage {
        try apply(to: CIImage(cgImage: pixels), side: CGFloat(max(pixels.width, pixels.height)))
    }

    /// The effect on `original`, its sizes proportions of `side` pixels: the longer side of the whole picture, which an
    /// adjustment layer drawn a part at a time is only a piece of.
    func apply(to original: CIImage, side: CGFloat) throws -> CIImage {
        let settings = normalized
        let extent = original.extent
        // The light arithmetic runs on opaque colors, and the layer's own transparency goes back on at the end: Core
        // Image's blends weigh light by its alpha, which a thin streak hardly has.
        let image = original.unpremultiplyingAlpha().settingAlphaOne(in: extent)
        let result: CIImage
        switch settings.effect {
        case .anamorphicFlare: result = LensOptics.anamorphic(image, settings, side: side)
        case .starburst: result = LensOptics.starburst(image, settings, side: side)
        case .mist: result = LensOptics.mist(image, settings, side: side)
        case .prism: result = LensOptics.prism(image, settings, side: side)
        case .bokeh: result = try LensOptics.bokeh(image, settings, side: side)
        }
        return result.cropped(to: extent).applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: original])
    }
}

/// The light arithmetic behind the lens effects, in Core Image.
private nonisolated enum LensOptics {
    static func linear(_ image: CIImage) -> CIImage { image.applyingFilter("CISRGBToneCurveToLinear") }
    static func gamma(_ image: CIImage) -> CIImage { image.applyingFilter("CILinearToSRGBToneCurve") }

    /// Red, green and blue scaled, alpha left as it is.
    static func scaled(_ image: CIImage, _ red: Double, _ green: Double, _ blue: Double) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: red, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: green, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: blue, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
    }

    static func scaled(_ image: CIImage, _ amount: Double) -> CIImage { scaled(image, amount, amount, amount) }

    /// Light added to light, both laid over black first: the blend weighs light by its alpha, which a thin streak
    /// hardly has. Not `CIAdditionCompositing`, which adds the alphas too, past one.
    static func add(_ light: CIImage, to image: CIImage) -> CIImage {
        let black = CIImage(color: .black)
        return light.composited(over: black).applyingFilter("CILinearDodgeBlendMode", parameters: [
            kCIInputBackgroundImageKey: image.composited(over: black)])
    }

    /// The light brighter than `threshold` (0–1, on the picture's own tones), in linear light, fading in above it.
    static func highlights(_ image: CIImage, threshold: Double) -> CIImage {
        // Over black, not clear: a tone curve or blend reads a dim light divided by its alpha.
        linear(image).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .black), kCIInputMaskImageKey: brightness(image, above: threshold),
        ]).cropped(to: image.extent)
    }

    /// How far each pixel is above `threshold` in brightness, 0–1, as a gray mask.
    static func brightness(_ image: CIImage, above threshold: Double) -> CIImage {
        let t = min(0.95, max(0, threshold)), k = 1 - t
        let luminance = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        let gray = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": luminance, "inputGVector": luminance, "inputBVector": luminance,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        return gray.applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: t, y: 0),
            "inputPoint2": CIVector(x: t + k * 0.4, y: 0.25), "inputPoint3": CIVector(x: t + k * 0.75, y: 0.7),
            "inputPoint4": CIVector(x: 1, y: 1)])
    }

    /// The lights a flare or starburst is made from, by Threshold (0.5–1). Up to 0.95 it's how bright a light is. Past
    /// that, a photo's brightest lights are all clipped to white, so it's how big and solid a bright spot is: a pixel
    /// stays only where its surroundings are lit too, over a wider area the higher Threshold goes, until only the
    /// strongest one or two sources are left.
    static func sources(_ image: CIImage, threshold: Double, side: CGFloat) -> CIImage {
        guard threshold > 0.95 else { return highlights(image, threshold: threshold) }
        let extent = image.extent
        let density = min(1, (threshold - 0.95) / 0.05)
        let lit = brightness(image, above: 0.95)
        let around = lit.clampedToExtent().applyingGaussianBlur(sigma: side * 0.03 * density).cropped(to: extent)
        // Measured against the photo's own strongest source, so the top of the range always leaves it.
        var peak: Float = 0
        PixelAdjust.ciContext.render(around.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: extent)]),
                                     toBitmap: &peak, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .Rf, colorSpace: nil)
        guard peak > 0.001 else { return highlights(image, threshold: 0.95) }
        // Scaled so the strongest is 1 first: a tone curve works at 8-bit steps, too coarse for these small values.
        let cut = 0.25 + 0.6 * density, soft = 0.05
        let solid = scaled(around, 1 / Double(peak)).applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: max(0, cut - soft), y: 0),
            "inputPoint2": CIVector(x: cut, y: 0.5), "inputPoint3": CIVector(x: cut + soft, y: 1),
            "inputPoint4": CIVector(x: max(1, cut + soft * 2), y: 1)])
        // A light that qualifies keeps all of itself, not just its middle.
        let whole = solid.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: side * 0.03 * density]).cropped(to: extent)
        let mask = lit.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: whole])
        return linear(image).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .black), kCIInputMaskImageKey: mask]).cropped(to: extent)
    }

    /// Only the lights shorter than `height` pixels: the light less its vertical opening, so a wide bright area drops
    /// out and a lamp or a glint stays.
    static func compact(_ light: CIImage, height: CGFloat) -> CIImage {
        let size = max(3, Int(height) | 1)
        let opened = light.applyingFilter("CIMorphologyRectangleMinimum", parameters: ["inputWidth": 1, "inputHeight": size])
            .applyingFilter("CIMorphologyRectangleMaximum", parameters: ["inputWidth": 1, "inputHeight": size])
        return light.applyingFilter("CISubtractBlendMode", parameters: [kCIInputBackgroundImageKey: light, kCIInputImageKey: opened])
    }

    /// `image` blurred along `angle` (radians) with a standard deviation of `along` pixels and `across` pixels across
    /// it: squeezed along the line, blurred evenly and stretched back, so a long streak costs no more than a short one.
    /// `spread` first draws each light out along the line, which lifts a small light far more than a wide bright area.
    static func streak(_ image: CIImage, angle: CGFloat, along: CGFloat, across: CGFloat, spread: CGFloat = 0) -> CIImage {
        let across = max(0.5, across)
        let squeeze = max(1, along / across)
        var turned = angle == 0 ? image : image.transformed(by: CGAffineTransform(rotationAngle: -angle))
        if spread >= 3 {
            turned = turned.applyingFilter("CIMorphologyRectangleMaximum", parameters: [
                "inputWidth": min(301, Int(spread) | 1), "inputHeight": 1])
        }
        let origin = turned.extent.origin
        let small = turned.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 1, kCIInputAspectRatioKey: 1 / squeeze])
        let back = small.applyingGaussianBlur(sigma: across)
            .transformed(by: CGAffineTransform(scaleX: squeeze, y: 1))
            .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
        return angle == 0 ? back : back.transformed(by: CGAffineTransform(rotationAngle: angle))
    }

    /// Horizontal streaks as an anamorphic lens's cylindrical glass draws them, made from the picture's own light.
    /// Lights brighter than Threshold flare, the more the brighter they are, and concentrated ones — a lamp, the sun,
    /// daylight through an opening — count for far more than the same light scattered in glints. Each throws a thin line across the frame inside a softer band, a white core and a veil.
    /// Near the light a streak keeps the light's own color; along it the coatings turn it blue, reaching farthest in
    /// blue and least in red, as much as Blue asks. Each color is eased off before it's tinted, so a strong streak stays
    /// saturated rather than whitening.
    static func anamorphic(_ image: CIImage, _ settings: LensEffectSettings, side: CGFloat) -> CIImage {
        let extent = image.extent
        let reach = side * settings.flareLength / 100, thin = max(0.5, side * 0.0008)
        let amount = settings.flareAmount / 50, blue = settings.flareBlue / 100
        let spread = sources(image, threshold: settings.threshold / 100, side: side).clampedToExtent()
            .applyingGaussianBlur(sigma: side * 0.004).cropped(to: extent)
        let lifted = add(spread, to: CIImage(color: CIColor(red: 0.12, green: 0.12, blue: 0.12)).cropped(to: extent))
        let sources = scaled(spread.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: lifted]), 1.6)
            .cropped(to: extent)
        // The thin line comes from compact lights only: drawn from a big one it would be as tall as the light.
        let lineSources = compact(sources, height: side * 0.012)
        let lengths = [1 - 0.7 * blue, 1 - 0.4 * blue, 1.0], coat = [1 - blue * 0.9, 1 - blue * 0.62, 1.0]
        func only(_ light: CIImage, _ channel: Int, _ gain: Double) -> CIImage {
            scaled(light, channel == 0 ? gain : 0, channel == 1 ? gain : 0, channel == 2 ? gain : 0)
        }
        var flare = CIImage.empty()
        for channel in 0..<3 {
            let line = streak(lineSources, angle: 0, along: reach * lengths[channel], across: thin)
            flare = add(only(softClip(scaled(line, 4 * amount), limit: 0.6), channel, coat[channel]), to: flare)
            // The band: brightest near the light, fading toward the frame's edges.
            var band = CIImage.empty()
            for (fraction, weight) in [(0.08, 0.8), (0.3, 0.35), (0.9, 0.15)] {
                let along = reach * fraction * lengths[channel]
                let gain = weight * pow(along / (side * 0.08), 0.5) * amount
                band = add(scaled(streak(sources, angle: 0, along: along, across: side * 0.006), gain), to: band)
            }
            flare = add(only(softClip(band, limit: 0.7), channel, coat[channel]), to: flare)
        }
        let core = streak(sources, angle: 0, along: side * 0.015, across: thin * 3)
        let veil = sources.clampedToExtent().applyingGaussianBlur(sigma: side * 0.04).cropped(to: extent)
        flare = add(scaled(core, 1.2 * amount), to: flare)
        flare = add(scaled(veil, 0.5 * amount * coat[0], 0.5 * amount * coat[1], 0.5 * amount), to: flare)
        return gamma(add(flare, to: linear(image)))
    }

    /// Thin spikes from each light, as an aperture's blades diffract it: fading quickly from the light, and a little
    /// longer in red than in blue, as diffraction spreads longer waves farther. Each direction's work is shared: the
    /// picture turned once, each length's lights spread once for all three colors, and the spikes summed before
    /// turning back once.
    static func starburst(_ image: CIImage, _ settings: LensEffectSettings, side: CGFloat) -> CIImage {
        let light = sources(image, threshold: settings.threshold / 100, side: side)
        let reach = side * settings.starLength / 100, thin = max(0.5, side * 0.0006)
        let spokes = max(1, settings.starPoints / 2)
        var rays = CIImage.empty()
        for spoke in 0..<spokes {
            let theta = settings.starAngle * .pi / 180 + Double(spoke) * .pi / Double(spokes)
            let turned = light.transformed(by: CGAffineTransform(rotationAngle: -theta))
            var spikes = CIImage.empty()
            for (fraction, weight) in [(0.04, 1.8), (0.12, 0.9), (0.35, 0.35), (1.0, 0.1)] {
                // Each light drawn out along the spike first, so a small light spikes as a big one does.
                let width = max(thin * 2, reach * fraction) * 0.8
                let spread = width >= 3 ? turned.applyingFilter("CIMorphologyRectangleMaximum", parameters: [
                    "inputWidth": min(301, Int(width) | 1), "inputHeight": 1]) : turned
                let gain = weight * settings.starAmount / 50
                for (channel, stretch) in [(0, 1.0), (1, 0.9), (2, 0.8)] {
                    let along = max(thin * 2, reach * fraction * stretch)
                    let blurred = streak(spread, angle: 0, along: along, across: thin)
                    spikes = add(scaled(blurred, channel == 0 ? gain : 0, channel == 1 ? gain : 0, channel == 2 ? gain : 0), to: spikes)
                }
            }
            rays = add(spikes.transformed(by: CGAffineTransform(rotationAngle: theta)), to: rays)
        }
        return gamma(add(rays, to: linear(image)))
    }

    /// A diffusion filter, as a black mist one: a share of every pixel's light scatters into a near halo and a wide
    /// veil rather than being added, so bright areas soften and spill and the shadows lift a little, without the whole
    /// picture brightening. The brightest lights scatter a little extra.
    static func mist(_ image: CIImage, _ settings: LensEffectSettings, side: CGFloat) -> CIImage {
        let extent = image.extent
        let light = linear(image)
        let scale = side * (0.2 + settings.mistSize / 100 * 1.8) / 100
        let near = light.clampedToExtent().applyingGaussianBlur(sigma: scale * 0.6).cropped(to: extent)
        let far = light.clampedToExtent().applyingGaussianBlur(sigma: scale * 4).cropped(to: extent)
        let glow = highlights(image, threshold: 0.75).clampedToExtent().applyingGaussianBlur(sigma: scale * 1.5).cropped(to: extent)
        let strength = settings.mistStrength / 100, scatter = strength * 0.4
        let scattered = add(scaled(glow, strength * 0.35), to: add(scaled(far, scatter * 0.4), to: scaled(near, scatter * 0.6)))
        return gamma(add(scattered, to: scaled(light, 1 - scatter)))
    }

    /// The blur of a lens focused elsewhere: every point spreads into a disc of the aperture's shape, not the soft
    /// smear of a Gaussian blur (see `MetalBokeh`). In a real photo a light is far brighter than white, so its disc
    /// stays bright: the lights are boosted, blurred on their own and eased back, so a wide bright area doesn't blow out.
    static func bokeh(_ image: CIImage, _ settings: LensEffectSettings, side: CGFloat) throws -> CIImage {
        let extent = image.extent
        let radius = side * settings.bokehRadius / 100
        guard let gpu = MetalBokeh.shared else { throw ExportError.render }
        func disc(_ light: CIImage) throws -> CIImage {
            try gpu.blur(light, extent: extent, radius: radius, shape: settings.bokehShape, ring: settings.bokehRing / 100)
        }
        // Even at its least, lights open into clear discs: Brightness says how much they glow, not whether.
        let lights = scaled(highlights(image, threshold: 0.8), 12 + settings.bokehBrightness * 0.7)
        return gamma(add(softClip(try disc(lights), limit: 0.8), to: try disc(linear(image))))
    }

    /// Light compressed smoothly toward `limit`: nearly unchanged when dim, never past it.
    static func softClip(_ light: CIImage, limit: Double) -> CIImage {
        let curved = scaled(light.composited(over: CIImage(color: .black)), 1 / (4 * limit)).applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0.0625, y: 0.224), "inputPoint2": CIVector(x: 0.125, y: 0.398),
            "inputPoint3": CIVector(x: 0.25, y: 0.638), "inputPoint4": CIVector(x: 1, y: 1)])
        return scaled(curved, limit)
    }

    /// A prism held before the lens: copies of the picture stepped along a line, one way or both, each fainter than the
    /// last, with a color fringe from the glass as wide as Fringe asks. A copy shows where it's brighter than what's behind it, so lit
    /// shapes echo into the shadows and nothing darkens. Blur softens the copies, more the farther they're pushed.
    static func prism(_ image: CIImage, _ settings: LensEffectSettings, side: CGFloat) -> CIImage {
        let extent = image.extent
        let light = linear(image)
        let theta = settings.prismAngle * .pi / 180
        let direction = CGVector(dx: cos(theta), dy: sin(theta))
        let shift = side * settings.prismOffset / 100
        var result = light
        // Farthest first, so each nearer copy shows over it.
        let sides: [CGFloat] = settings.prismBothWays ? [1, -1] : [1]
        for copy in stride(from: Int(settings.prismCopies), through: 1, by: -1) {
            var ghost = CIImage.empty()
            for way in sides {
                func moved(_ along: CGFloat) -> CIImage {
                    light.transformed(by: CGAffineTransform(translationX: direction.dx * along * way, y: direction.dy * along * way))
                }
                let step = shift * CGFloat(copy)
                guard settings.prismFringe > 0 else {
                    ghost = lighten(moved(step), ghost)
                    continue
                }
                let fringe = side * settings.prismFringe / 10_000
                for (channel, along) in [(0, step + fringe), (1, step), (2, step - fringe)] {
                    ghost = lighten(scaled(moved(along), channel == 0 ? 1 : 0, channel == 1 ? 1 : 0, channel == 2 ? 1 : 0), ghost)
                }
            }
            if settings.prismBlur > 0 {
                ghost = ghost.clampedToExtent().applyingGaussianBlur(sigma: side * settings.prismBlur / 10_000 * Double(copy))
            }
            let fade = pow(0.78, Double(copy - 1)) * settings.prismAmount / 100
            result = lighten(scaled(ghost.cropped(to: extent), fade), result)
        }
        return gamma(result)
    }

    static func lighten(_ image: CIImage, _ background: CIImage) -> CIImage {
        image.applyingFilter("CILightenBlendMode", parameters: [kCIInputBackgroundImageKey: background])
    }

}
