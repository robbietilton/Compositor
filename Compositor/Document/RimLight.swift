import CoreGraphics
import CoreImage

/// One of Rim Light's lights: where it comes from, in degrees counterclockwise from the right, its color, how strong
/// it is, how far it wraps around the edges, and how hard its inner edge is rather than feathered, each 0–100.
nonisolated struct RimLight: Equatable, Sendable, Identifiable {
    var id = UUID()
    var angle: Double = 135
    var color = AdjustmentColor(red: 1, green: 0.86, blue: 0.7)
    var strength: Double = 50
    var width: Double = 30
    var choke: Double = 0
}

/// Filter › Rim Light: up to `maximumLights` lights behind the subject that catch its edges, and how much of their
/// light glows in the air around it, 0–100.
nonisolated struct RimLightSettings: Equatable, Sendable {
    static let maximumLights = 3
    var lights = [RimLight()]
    var glow: Double = 10

    /// The light with `id`, for the panel's controls: one just removed reads as a default and takes no changes, so a
    /// control still drawn for it can't reach past the list.
    subscript(light id: UUID) -> RimLight {
        get { lights.first { $0.id == id } ?? RimLight(id: id) }
        set { if let index = lights.firstIndex(where: { $0.id == id }) { lights[index] = newValue } }
    }

    /// What the next added light starts as: from the side across from the ones there, in a color that sets them off.
    var nextLight: RimLight {
        let angle = lights.last.map { $0.angle > 0 ? $0.angle - 180 : $0.angle + 180 } ?? 135
        // A cool one across from the first, then white.
        let colors = [AdjustmentColor(red: 0.7, green: 0.84, blue: 1), AdjustmentColor(red: 1, green: 1, blue: 1)]
        return RimLight(angle: angle, color: colors[min(max(lights.count - 1, 0), 1)], strength: 50, width: lights.last?.width ?? 30,
                        choke: lights.last?.choke ?? 0)
    }

    var isIdentity: Bool { lights.allSatisfy { $0.strength == 0 } }

    var normalized: Self {
        var result = self
        result.glow = ImageAdjustmentPixels.clamp(glow, 0...100, 10)
        result.lights = Array(lights.prefix(Self.maximumLights)).map {
            RimLight(id: $0.id, angle: ImageAdjustmentPixels.clamp($0.angle, -180...180, 135), color: $0.color.clamped,
                     strength: ImageAdjustmentPixels.clamp($0.strength, 0...100, 50),
                     width: ImageAdjustmentPixels.clamp($0.width, 0...100, 30),
                     choke: ImageAdjustmentPixels.clamp($0.choke, 0...100, 0))
        }
        return result
    }
}

/// Rim Light worked out the way games light flat sprites: the subject's outline (Vision's mask, pulled onto the
/// photo's edges) is rounded into a surface that faces sideways at the edge and turns to face the camera a light's
/// Width in, the photo's fine detail is pressed into it as bumps, and each light, from a little behind the subject,
/// brightens what faces it. So the rim starts right at the subject's edge and fades inwards, as a light from behind
/// reaches only what turns away from the camera; strands and edges brighter than their surroundings catch more.
nonisolated enum RimLighting {
    /// The rim's width as a share of the image's longer side, from Width 0 to 100.
    static func widthShare(_ width: Double) -> Double { 0.002 + width / 100 * 0.03 }
    /// How bright a light at Strength 100 is, over the surface's own color.
    static let fullStrength: Double = 10
    /// How much of the rims' light glows around the subject at Glow 100.
    static let fullGlow: Double = 4

    /// The subject's mask for `image`, refined, kept while the panel is open so a slider only relights.
    private static let cache = MaskCache()
    private final class MaskCache: @unchecked Sendable {
        private let lock = NSLock()
        /// The image the mask is for, held so another can't take its place in memory and be mistaken for it.
        private var key: CGImage?
        private var value: CGImage?
        func contains(_ image: CGImage) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return key === image && value != nil
        }
        func mask(for image: CGImage, make: () throws -> CGImage) throws -> CGImage {
            lock.lock()
            let hit = key === image ? value : nil
            lock.unlock()
            if let hit { return hit }
            let made = try make()
            lock.lock(); key = image; value = made; lock.unlock()
            return made
        }
    }

    /// Whether the subject in `image` has been found already, so lighting it is quick.
    static func hasSubject(for image: CGImage) -> Bool { cache.contains(image) }

    /// The subject, white: Vision's mask pulled onto the photo's own edges, as Remove Background's Advanced does, so
    /// hair and fine edges are lit rather than the blur around them.
    static func subject(_ image: CGImage) throws -> CGImage {
        try cache.mask(for: image) {
            let side = CGFloat(max(image.width, image.height))
            return try GuidedMatte.refine(mask: try SubjectRemoval.subjectMask(image), guide: image,
                                          radius: max(2, side * 0.008), limit: 2048)
        }
    }

    /// `image` (the pixels of `source`) with its rim lights added.
    static func apply(to image: CIImage, source: CGImage, settings: RimLightSettings) throws -> CIImage {
        let settings = settings.normalized
        guard !settings.isIdentity else { return image }
        let extent = image.extent
        let side = max(extent.width, extent.height)
        // As they are, not converted: the mask's levels, and the photo's gray as it's seen, for its detail.
        let raw: [CIImageOption: Any] = [.colorSpace: NSNull()]
        let toImage = CGAffineTransform(scaleX: extent.width / CGFloat(source.width), y: extent.height / CGFloat(source.height))
        // Where the light lands: the mask as refined, its soft grays kept, so thin strands of hair catch their share.
        let coverage = CIImage(cgImage: try subject(source), options: raw).transformed(by: toImage).cropped(to: extent)
        // The outline the form is rounded from: those grays pushed apart, so its edge is where the subject's is.
        let outline = coverage.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1.6, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1.6, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1.6, w: 0), "inputBiasVector": CIVector(x: -0.3, y: -0.3, z: -0.3, w: 0)])
            .applyingFilter("CIColorClamp")
        let gray = CIImage(cgImage: source, options: raw).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0), "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
            .transformed(by: toImage)
        func blurred(_ image: CIImage, _ sigma: CGFloat) -> CIImage {
            image.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
        }
        let fine = blurred(gray, 1), coarse = blurred(gray, max(2, side / 400))
        func scaled(_ image: CIImage, _ gain: Double, bias: Double = 0) -> CIImage {
            image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0), "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)])
        }
        // The backdrop behind the subject, worked out from around it: the photo outside the outline spread in under it,
        // each place an average of the backdrop near it. How far a pixel differs from that picks out loose strands.
        let open = scaled(outline, -1, bias: 1)
        let spread = side * 0.01
        let weighted = blurred(image.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: open]), spread)
        let behind = scaled(blurred(open, spread), 1, bias: 0.001)
            .applyingFilter("CIDivideBlendMode", parameters: [kCIInputBackgroundImageKey: weighted])
        let backdrop = image.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: behind])
        // How busy that backdrop is there, its colors' spread around their average: on rocks or a crowd everything
        // differs from the average, so a strand has to stand out further than that to count.
        let squares = image.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: image])
        let meanSquares = scaled(blurred(open, spread), 1, bias: 0.001).applyingFilter("CIDivideBlendMode", parameters: [
            kCIInputBackgroundImageKey: blurred(squares.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: open]), spread)])
        let busy = meanSquares.applyingFilter("CIDifferenceBlendMode", parameters: [
            kCIInputBackgroundImageKey: behind.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: behind])])
        let near = blurred(outline, side * 0.015)
        // Each light on its own, reaching in as far as its Width, and added up.
        var rims: CIImage?
        for light in settings.lights where light.strength > 0 {
            let width = side * widthShare(light.width)
            // The outline blurred far enough to tell, at each pixel, how far in from the edge it is, to twice Width.
            let reach = max(1, width / 1.5)
            let rim = try MetalRimLight.light(image, coverage: coverage, outline: blurred(outline, reach), fine: fine, coarse: coarse,
                                              backdrop: backdrop, busy: busy, near: near, width: width, reach: reach, side: side, light: light)
            rims = rims.map { rim.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? rim
        }
        guard var light = rims else { return image }
        if settings.glow > 0 {
            // Glow: the rims' light in the air behind the subject, each light's on its own side in its own color, a
            // halo and a wider haze. It wraps a little way in across the subject's edge, as light from behind does,
            // so the subject sits in it rather than being cut out against it; further in, the subject keeps its rims.
            let amount = settings.glow / 100 * Self.fullGlow
            let haze = scaled(blurred(light, side * 0.012), amount * 0.6)
                .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: scaled(blurred(light, side * 0.035), amount)])
            let around = scaled(blurred(outline, side * 0.008), -2, bias: 2).applyingFilter("CIColorClamp")
            let glow = haze.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty().cropped(to: extent), kCIInputMaskImageKey: around])
            light = light.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: glow])
        }
        return try MetalRimLight.combined(image, light: light.cropped(to: extent)).cropped(to: extent)
    }
}
