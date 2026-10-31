import CoreGraphics
import Foundation
import CoreImage
import Vision

/// Filter › Volumetric Light: a light placed on the image, its beams through the air, and the haze it lights. `center`
/// is where the light is, in document coordinates, set by clicking the canvas; the filter opens with it on the layer's
/// brightest spot. The rest are 0–100: how bright the beams are, how far from the light they reach, how thick the
/// haze is, how big the light is, and how much the beams break up into shafts.
nonisolated struct VolumetricLightSettings: Equatable, Sendable {
    var center: CGPoint?
    var color = AdjustmentColor(red: 1, green: 0.86, blue: 0.68)
    var intensity: Double = 30
    var length: Double = 0
    var haze: Double = 60
    var size: Double = 20
    var shafts: Double = 0
    /// How far into the scene the haze begins, 0–100, by the photo's own spread of depths: at 0 it reaches up to the
    /// camera; at 50 about the nearer half of the scene stays clear; at 100 only the farthest parts are hazy.
    var distance: Double = 30
    /// Depth Contrast, 0–100: how far the depth is spread out (`DepthMap.equalized`), so depths bunched together, like
    /// a distant city, get haze in steps rather than all alike. 0 keeps the model's own spacing.
    var depthContrast: Double = 0

    var isIdentity: Bool { intensity == 0 && haze == 0 }

    var normalized: Self {
        var result = self
        result.color = color.clamped
        result.intensity = ImageAdjustmentPixels.clamp(intensity, 0...100, 30)
        result.length = ImageAdjustmentPixels.clamp(length, 0...100, 0)
        result.haze = ImageAdjustmentPixels.clamp(haze, 0...100, 60)
        result.size = ImageAdjustmentPixels.clamp(size, 0...100, 20)
        result.shafts = ImageAdjustmentPixels.clamp(shafts, 0...100, 0)
        result.distance = ImageAdjustmentPixels.clamp(distance, 0...100, 30)
        result.depthContrast = ImageAdjustmentPixels.clamp(depthContrast, 0...100, 0)
        if let center, !(center.x.isFinite && center.y.isFinite) { result.center = nil }
        return result
    }
}

/// Volumetric Light worked out the way games draw light shafts after the fact: what gives off light is the light itself
/// and the photo's bright openings near it, with the subject (Vision's mask, as Rim Light finds it) and the photo's dark
/// shapes blocking it; each pixel then gathers that light along the line back toward the light, so whatever blocks it
/// casts shafts of shadow through the beams. The haze is thickest near the light and thinner in front of the subject,
/// which stands nearer than what's behind it, so the subject sits in the air rather than under a veil.
nonisolated enum VolumetricLighting {
    /// How bright the beams are at Intensity 100, over the photo.
    static let fullIntensity: Double = 5
    /// How thick the haze is at Haze 100.
    static let fullHaze: Double = 1

    /// `image` (the pixels of `source`) with the light at `light`, in `image`'s own coordinates (Core Image's, y up).
    /// What doesn't change as the sliders move is worked out once and kept (`Prepared`): the scene's glows, air and
    /// subject for the image, its depth for Depth Contrast, and the beams for the light's place, Size, Length and
    /// Shafts. So moving Haze, Distance, Intensity or the color only lays them over the photo again.
    static func apply(to image: CIImage, source: CGImage, settings: VolumetricLightSettings, light: CGPoint) throws -> CIImage {
        let settings = settings.normalized
        guard !settings.isIdentity else { return image }
        let extent = image.extent
        let side = max(extent.width, extent.height)
        // Kept only at the preview's size: the full-size pass on OK runs once, and its pieces would take a lot of memory.
        let keeps = extent.width * extent.height <= FilterEdit.previewLimit * FilterEdit.previewLimit
        let scene = try prepared.scene(source: source, extent: extent, keeps: keeps) {
            try Self.scene(image, source: source, extent: extent, keeps: keeps)
        }
        let depth = prepared.depth(source: source, extent: extent, contrast: settings.depthContrast, keeps: keeps) {
            // How far away each part is, once the depth model is here (`DepthModel`), the subject's edge taken from its
            // outline (`outline`).
            (DepthModel.depth(for: source)?.equalized(Float(settings.depthContrast / 100))).map {
                (image: composedDepth($0, subject: outline(source).map {
                    CIImage(cgImage: $0, options: [.colorSpace: NSNull()])
                        .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(source.width), y: extent.height / CGFloat(source.height)))
                        .cropped(to: extent)
                }, extent: extent), distances: $0.values.map { 1 - $0 }.sorted())
            }
        }
        let beams = try prepared.beams(source: source, extent: extent, key: BeamsKey(light: light, settings: settings), keeps: keeps) {
            try Self.beams(image, subject: scene.subject, light: light, side: side, extent: extent, settings: settings, keeps: keeps)
        }
        return try MetalVolumetricLight.combined(image, beams: beams, near: scene.near, glows: scene.glows, ambient: scene.ambient,
                                                 depth: depth?.image, ramp: ramp(settings.distance, distances: depth?.distances),
                                                 light: light, side: side, settings: settings).cropped(to: extent)
    }

    /// What the haze is laid over the photo with that's the same whatever the sliders say.
    private struct Scene {
        /// The subject's mask, if there is a subject; `subject` is black without one.
        let mask: CIImage?
        let subject: CIImage
        /// How near the subject a pixel is, for the haze and beams in front of it.
        let near: CIImage
        let glows: CIImage
        let ambient: CIImage
    }

    private static func scene(_ image: CIImage, source: CGImage, extent: CGRect, keeps: Bool) throws -> Scene {
        func kept(_ image: CIImage) throws -> CIImage { keeps ? try Self.kept(image) : image }
        let side = max(extent.width, extent.height)
        let raw: [CIImageOption: Any] = [.colorSpace: NSNull()]
        let toImage = CGAffineTransform(scaleX: extent.width / CGFloat(source.width), y: extent.height / CGFloat(source.height))
        // With no subject found, nothing stands in front of the light.
        let mask = Self.subject(source).map { CIImage(cgImage: $0, options: raw).transformed(by: toImage).cropped(to: extent) }
        let subject = mask ?? CIImage.black.cropped(to: extent)
        func blurred(_ image: CIImage, _ sigma: CGFloat) -> CIImage {
            image.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
        }
        // The photo's own lights (headlights, windows, signs), each glowing into the haze in its own color: a halo and a
        // wider bloom. A light is what's brighter than half white and than half again the light around it, so in a dark
        // scene every lamp counts, while in a bright one (ice, a daylight street) only what stands out from the bright
        // surfaces around it does, rather than the whole scene glowing.
        let cutoff = blurred(image, side * 0.04).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1.5, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1.5, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1.5, w: 0)])
            .applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0.5, y: 0.5, z: 0.5, w: 0),
                                                         "inputMaxComponents": CIVector(x: 100, y: 100, z: 100, w: 1)])
        let lights = image.applyingFilter("CISubtractBlendMode", parameters: [kCIInputBackgroundImageKey: image, kCIInputImageKey: cutoff])
            .applyingFilter("CIColorClamp", parameters: ["inputMaxComponents": CIVector(x: 100, y: 100, z: 100, w: 1)])
        let glows = blurred(lights, side * 0.012).applyingFilter("CIAdditionCompositing", parameters: [
            kCIInputBackgroundImageKey: blurred(lights, side * 0.05).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 2, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 2, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 2, w: 0)])])
        // The air lit by the scene itself: its light spread wide, which the haze takes its color and brightness from.
        let ambient = blurred(image, side * 0.12)
        let near = blurred(subject, max(1, side * 0.003))
        return Scene(mask: try mask.map { try kept($0) }, subject: try kept(subject), near: try kept(near),
                     glows: try kept(glows), ambient: try kept(ambient))
    }

    /// The beams for the light where it is, at full size. They're soft, so they're worked out at half size, which also
    /// halves the distance each one gathers over.
    private static func beams(_ image: CIImage, subject: CIImage, light: CGPoint, side: CGFloat, extent: CGRect,
                              settings: VolumetricLightSettings, keeps: Bool) throws -> CIImage {
        func kept(_ image: CIImage) throws -> CIImage { keeps ? try Self.kept(image) : image }
        let half = CGAffineTransform(scaleX: 0.5, y: 0.5)
        let halfExtent = extent.applying(half).integral
        let small = image.samplingLinear().transformed(by: half).cropped(to: halfExtent)
        let smallSubject = subject.samplingLinear().transformed(by: half).cropped(to: halfExtent)
        // The photo's brightest, lightly blurred so one hot pixel doesn't set it, to tell its openings by.
        let peak = image.clampedToExtent().applyingGaussianBlur(sigma: 2).cropped(to: extent)
            .applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: extent)])
        let beams = try MetalVolumetricLight.beams(small, subject: smallSubject, peak: peak, light: light.applying(half),
                                                   side: side / 2, settings: settings)
        return try kept(beams.clampedToExtent().applyingGaussianBlur(sigma: 1).samplingLinear()
            .transformed(by: half.inverted()).cropped(to: extent))
    }

    /// The settings the beams depend on: they don't change as Haze, Distance, Intensity or the color move.
    private struct BeamsKey: Equatable {
        let light: CGPoint, size: Double, length: Double, shafts: Double
        init(light: CGPoint, settings: VolumetricLightSettings) {
            self.light = light; size = settings.size; length = settings.length; shafts = settings.shafts
        }
    }

    /// `image` worked out now and held, in half floats and with no color conversion either way, as the filter itself
    /// renders (`PixelAdjust.ciContext`), so it comes back exactly as it was, to build on without working it out again.
    private static func kept(_ image: CIImage) throws -> CIImage {
        guard let made = keeping.createCGImage(image, from: image.extent, format: .RGBAh,
                                               colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)) else { throw ExportError.render }
        return CIImage(cgImage: made, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(translationX: image.extent.minX, y: image.extent.minY))
    }
    private static let keeping = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])

    /// The last image's scene, depth and beams, so a slider moving on the same image reuses them. Each is kept for the
    /// image itself (held, so another can't take its place in memory and be mistaken for it) and its size.
    private static let prepared = Prepared()
    private final class Prepared: @unchecked Sendable {
        private let lock = NSLock()
        private var image: CGImage?
        private var extent = CGRect.null
        private var scene: Scene?
        private var depth: (contrast: Double, value: (image: CIImage, distances: [Float])?)?
        private var beams: (key: BeamsKey, image: CIImage)?

        /// Starts over when the image changes.
        private func forImage(_ source: CGImage, _ extent: CGRect) {
            guard image !== source || self.extent != extent else { return }
            image = source; self.extent = extent; scene = nil; depth = nil; beams = nil
        }
        func scene(source: CGImage, extent: CGRect, keeps: Bool, make: () throws -> Scene) rethrows -> Scene {
            guard keeps else { return try make() }
            lock.lock(); forImage(source, extent); let hit = scene; lock.unlock()
            if let hit { return hit }
            let made = try make()
            lock.lock(); if image === source { scene = made }; lock.unlock()
            return made
        }
        func depth(source: CGImage, extent: CGRect, contrast: Double, keeps: Bool,
                   make: () -> (image: CIImage, distances: [Float])?) -> (image: CIImage, distances: [Float])? {
            guard keeps else { return make() }
            lock.lock(); forImage(source, extent); let hit = depth; lock.unlock()
            if let hit, hit.contrast == contrast, hit.value != nil || !DepthModel.isReady { return hit.value }
            let made = make()
            // Without the model yet, nothing's kept, so its depth is picked up once it's here.
            lock.lock(); if image === source, made != nil { depth = (contrast, made) }; lock.unlock()
            return made
        }
        func beams(source: CGImage, extent: CGRect, key: BeamsKey, keeps: Bool, make: () throws -> CIImage) rethrows -> CIImage {
            guard keeps else { return try make() }
            lock.lock(); forImage(source, extent); let hit = beams; lock.unlock()
            if let hit, hit.key == key { return hit.image }
            let made = try make()
            lock.lock(); if image === source { beams = (key, made) }; lock.unlock()
            return made
        }
    }

    /// Where the haze begins and where it's full, as distance (0 nearest, 1 farthest), for Distance: with depth, read
    /// off the photo's own spread of depths, so the same Distance clears the same share of any scene; without it, as
    /// the guess runs (`distances`: the photo's distances, sorted). The haze always builds over a gentle stretch from the
    /// one to the other, so it can't turn hard or inside out.
    static func ramp(_ distance: Double, distances: [Float]?) -> (start: Float, end: Float) {
        let share = Float(distance / 100)
        guard let distances, !distances.isEmpty else { return (share * 0.6, share * 0.6 + 0.5) }
        func at(_ share: Float) -> Float { distances[min(distances.count - 1, Int(max(0, share) * Float(distances.count - 1)))] }
        // A wide stretch however close the scene's depths lie, so a soft edge in the depth stays a soft edge in the haze.
        let start = min(at(share), 0.9)
        return (start, max(at(min(1, share + 0.45)), start + 0.45))
    }

    /// The depth the haze goes by, over `extent`: 1 near, 0 far. The model's map is soft at the subject's edge, where
    /// its nearness bleeds out into a band around it, so there the subject's mask decides instead: inside the mask the
    /// subject is near, and the band around it takes the depth of the backdrop just beyond it, worked out from around it
    /// (as Rim Light finds the backdrop); the two meet through the mask's own soft edge, hair and all. Further off, the
    /// model's map as it is.
    static func composedDepth(_ predicted: DepthMap, subject: CIImage?, extent: CGRect) -> CIImage {
        let side = max(extent.width, extent.height)
        func blurred(_ image: CIImage, _ sigma: CGFloat) -> CIImage {
            image.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
        }
        let depth = blurred(DepthModel.image(predicted, over: extent), side * 0.0015)
        guard let soft = subject else { return depth }
        let reach = side * 0.02
        func scaled(_ image: CIImage, _ gain: CGFloat, bias: CGFloat = 0) -> CIImage {
            image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0), "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)])
            .applyingFilter("CIColorClamp")
        }
        // The outline comes crisp, and soft only through hair (`outline`).
        let subject = soft
        // The backdrop is read from beyond the band the model's nearness bleeds into (the mask grown past it), then
        // spread back in under the subject and the band, each place an average of the backdrop near it.
        let beyond = scaled(blurred(subject, reach), -6, bias: 1)
        let weighted = blurred(depth.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: beyond]), reach * 2.5)
        let behind = scaled(blurred(beyond, reach * 2.5), 1, bias: 0.001)
            .applyingFilter("CIDivideBlendMode", parameters: [kCIInputBackgroundImageKey: weighted])
        // Near the subject, the backdrop's depth; further out, the model's.
        let closeness = scaled(blurred(subject, reach * 1.5), 4)
        let around = behind.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: depth, kCIInputMaskImageKey: closeness])
        let near = depth.applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0.9, y: 0.9, z: 0.9, w: 0)])
        return near.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: around, kCIInputMaskImageKey: subject])
            .cropped(to: extent)
    }

    /// The depth the haze goes by, as a picture the size of `source`: white near, black far (`composedDepth`). Nil
    /// without the model.
    static func depthMap(for source: CGImage, settings: VolumetricLightSettings) -> CGImage? {
        guard let depth = DepthModel.depth(for: source)?.equalized(Float(settings.normalized.depthContrast / 100)) else { return nil }
        let extent = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let subject = outline(source).map { CIImage(cgImage: $0, options: [.colorSpace: NSNull()]) }
        let map = composedDepth(depth, subject: subject, extent: extent)
        let opaque = map.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                                                                      "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        return context.createCGImage(opaque, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// The subject in `image`, as Rim Light finds it, or nil when there's none; that's remembered too, so a photo without
    /// one isn't searched again at every slider step.
    static func subject(_ image: CGImage) -> CGImage? {
        if noSubject.contains(image) { return nil }
        do { return try RimLighting.subject(image) } catch {
            noSubject.remember(image)
            return nil
        }
    }
    /// The subject's outline for the depth. People take Vision's person segmentation at its most accurate, which
    /// follows shoulders and hair truly, where the general subject mask bulges past them; anything else (an object, or
    /// what a person holds) takes the general mask as it comes, smooth and true to its shape. Not the mask pulled onto
    /// the photo's edges (`subject`): that catches hair for the light, but along a busy backdrop (ice, rocks) it's pulled
    /// in and out by the texture, and the depth's edge would follow it, wavy where it's straight. Worked out once an
    /// image.
    static func outline(_ image: CGImage) -> CGImage? {
        if noSubject.contains(image) { return nil }
        return outlines.outline(for: image) {
            guard let general = try? SubjectRemoval.subjectMask(image) else { return nil }
            let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let raw: [CIImageOption: Any] = [.colorSpace: NSNull()]
            let side = CGFloat(max(image.width, image.height))
            let generalImage = CIImage(cgImage: general, options: raw)
            // The person's own mask, if Vision found the person the general mask did; on a small or dim figure it can
            // come back faint or only in part, and then the general mask is the better outline throughout.
            let person = personMask(image).flatMap { agrees($0, with: generalImage, extent: extent) ? $0 : nil }
            var composed = generalImage
            if let person {
                // Where a person is (and a little around, for their outline), their own mask; elsewhere the general one.
                let personImage = CIImage(cgImage: person, options: raw)
                let near = personImage.clampedToExtent().applyingGaussianBlur(sigma: side * 0.01).cropped(to: extent)
                    .applyingFilter("CIColorMatrix", parameters: [
                        "inputRVector": CIVector(x: 20, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 20, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: 20, w: 0)]).applyingFilter("CIColorClamp")
                composed = personImage.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: generalImage, kCIInputMaskImageKey: near])
            }
            // Heads take the person's mask (or the general one) pulled onto the photo's own edges over a wide 30 px (as Remove Background's
            // Refine does), which finds the strands of hair and clears the backdrop between them, kept within the
            // general mask; its grays kept so the haze shows through. The rest of the person keeps the crisp outline.
            if let heads = headsMask(image),
               let strands = try? GuidedMatte.refine(mask: person ?? general, guide: image, radius: 30, limit: .greatestFiniteMagnitude) {
                // Its faintest grays dropped: they're the haze of a halo around the hair, not strands.
                let hair = CIImage(cgImage: strands, options: raw).applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1.4, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1.4, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 1.4, w: 0), "inputBiasVector": CIVector(x: -0.25, y: -0.25, z: -0.25, w: 0)])
                    .applyingFilter("CIColorClamp")
                    // Multiplied by the general mask, which stops cleanly just past the hair: the strands inside it stay,
                    // and what the wide refine pulled onto the backdrop beyond it goes.
                    .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: generalImage])
                composed = hair.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: firmed(composed, side: side, extent: extent),
                                                                               kCIInputMaskImageKey: CIImage(cgImage: heads, options: raw)])
            } else {
                composed = firmed(composed, side: side, extent: extent)
            }
            return try? PixelAdjust.render(composed.cropped(to: extent), width: image.width, height: image.height, isMask: true)
        }
    }

    /// Whether the person's mask covers most of what the general mask found: at least 60% of it.
    private static func agrees(_ person: CGImage, with general: CIImage, extent: CGRect) -> Bool {
        let both = CIImage(cgImage: person, options: [.colorSpace: NSNull()])
            .applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: general])
        func mean(_ image: CIImage) -> Float {
            var pixel = [Float](repeating: 0, count: 4)
            PixelAdjust.ciContext.render(image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: extent)]),
                                         toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                         format: .RGBAf, colorSpace: nil)
            return pixel[0]
        }
        let found = mean(general)
        return found > 0 && mean(both) / found >= 0.6
    }

    /// An outline made crisp, so the haze meets the subject cleanly rather than creeping onto it. Smoothed a touch first,
    /// so the small steps in Vision's masks (they're worked out small and enlarged) round off into the straight or
    /// curved edge they stand for.
    private static func firmed(_ mask: CIImage, side: CGFloat, extent: CGRect) -> CIImage {
        mask.clampedToExtent().applyingGaussianBlur(sigma: max(1, side * 0.0015)).cropped(to: extent)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 2.5, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 2.5, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 2.5, w: 0), "inputBiasVector": CIVector(x: -1.1, y: -1.1, z: -1.1, w: 0)])
            .applyingFilter("CIColorClamp")
    }

    /// Where the people's heads are in `image`, white, soft-edged: from their bodies' poses (eyes, ears, nose, or failing
    /// those the neck and shoulders, so a head seen from behind counts too), an oval over each head sized by the
    /// shoulders. Nil when no head is found.
    private static func headsMask(_ image: CGImage) -> CGImage? {
        let request = VNDetectHumanBodyPoseRequest()
        guard (try? VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])) != nil,
              let people = request.results, !people.isEmpty else { return nil }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var found = false
        for person in people {
            // Vision's points are 0–1 with y up, as this context's are.
            func point(_ name: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
                guard let joint = try? person.recognizedPoint(name), joint.confidence > 0.2 else { return nil }
                return CGPoint(x: joint.location.x * width, y: joint.location.y * height)
            }
            let face = [VNHumanBodyPoseObservation.JointName.nose, .leftEye, .rightEye, .leftEar, .rightEar].compactMap(point)
            let neck = point(.neck)
            let shoulders = [point(.leftShoulder), point(.rightShoulder)].compactMap { $0 }
            let span = shoulders.count == 2 ? hypot(shoulders[0].x - shoulders[1].x, shoulders[0].y - shoulders[1].y) : nil
            var center: CGPoint
            if !face.isEmpty {
                center = CGPoint(x: face.map(\.x).reduce(0, +) / CGFloat(face.count), y: face.map(\.y).reduce(0, +) / CGFloat(face.count))
            } else if let neck, let span {
                center = CGPoint(x: neck.x, y: neck.y + span * 0.55)
            } else { continue }
            let size = max(span ?? 0, neck.map { hypot($0.x - center.x, $0.y - center.y) * 2.2 } ?? 0, max(width, height) * 0.03)
            // The oval reaches up and out for hair, and stops above the shoulders.
            let oval = CGRect(x: center.x - size * 0.75, y: center.y - size * 0.45, width: size * 1.5, height: size * 1.4)
            context.setFillColor(gray: 1, alpha: 1)
            context.fillEllipse(in: oval)
            found = true
        }
        guard found, let ovals = context.makeImage() else { return nil }
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let soft = CIImage(cgImage: ovals, options: [.colorSpace: NSNull()]).clampedToExtent()
            .applyingGaussianBlur(sigma: max(width, height) * 0.02).cropped(to: extent)
        return try? PixelAdjust.render(soft, width: image.width, height: image.height, isMask: true)
    }

    /// The people in `image`, white, at its size; nil when there are none.
    private static func personMask(_ image: CGImage) -> CGImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        guard (try? VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])) != nil,
              let buffer = request.results?.first?.pixelBuffer else { return nil }
        let mask = CIImage(cvPixelBuffer: buffer)
        let scaled = mask.samplingLinear().transformed(by: CGAffineTransform(scaleX: CGFloat(image.width) / mask.extent.width,
                                                                              y: CGFloat(image.height) / mask.extent.height))
        guard let rendered = try? PixelAdjust.render(scaled, width: image.width, height: image.height, isMask: true) else { return nil }
        // An empty mask means no one's there.
        let peak = scaled.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: CGRect(x: 0, y: 0, width: image.width, height: image.height))])
        var pixel = [UInt8](repeating: 0, count: 4)
        PixelAdjust.ciContext.render(peak, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return pixel[0] > 128 ? rendered : nil
    }

    /// The last image's outline, held with the image so another can't take its place in memory and be mistaken for it.
    private static let outlines = Outlines()
    private final class Outlines: @unchecked Sendable {
        private let lock = NSLock()
        private var image: CGImage?
        private var value: CGImage??
        func outline(for image: CGImage, make: () -> CGImage?) -> CGImage? {
            lock.lock()
            let hit = self.image === image ? value : nil
            lock.unlock()
            if let hit { return hit }
            let made = make()
            lock.lock(); self.image = image; value = .some(made); lock.unlock()
            return made
        }
    }
    /// Whether the subject in `image` has been looked for already, so lighting it is quick.
    static func hasLooked(for image: CGImage) -> Bool { noSubject.contains(image) || RimLighting.hasSubject(for: image) }
    private static let noSubject = Remembered()
    private final class Remembered: @unchecked Sendable {
        private let lock = NSLock()
        /// Held, so another image can't take its place in memory and be mistaken for it.
        private var image: CGImage?
        func contains(_ image: CGImage) -> Bool { lock.lock(); defer { lock.unlock() }; return self.image === image }
        func remember(_ image: CGImage) { lock.lock(); self.image = image; lock.unlock() }
    }

    /// Where the light starts: in the biggest bright area of `image` (a window, the sky, a beam), at its brightest, in its
    /// pixels (rows top-down). Areas are the connected parts of a small copy near its top brightness, each weighed by its
    /// size and how bright it is, so a wide opening wins over a smaller patch of light on the rocks, even a hotter one.
    static func brightestPoint(in image: CGImage) -> CGPoint {
        let side = 64
        let width = max(1, image.width >= image.height ? side : side * image.width / max(1, image.height))
        let height = max(1, image.height >= image.width ? side : side * image.height / max(1, image.width))
        let center = CGPoint(x: Double(image.width) / 2, y: Double(image.height) / 2)
        guard let context = try? BrushRaster.context(width: width, height: height, mask: false), let data = context.data else { return center }
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        let pixels = data.assumingMemoryBound(to: UInt8.self), stride = context.bytesPerRow
        var gray = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let p = pixels + y * stride + x * 4
                gray[y * width + x] = 0.2126 * Double(p[0]) + 0.7152 * Double(p[1]) + 0.0722 * Double(p[2])
            }
        }
        // Lightly smoothed, so a speck doesn't count as an area.
        var bright = gray
        for y in 0..<height {
            for x in 0..<width {
                var sum = 0.0, count = 0.0
                for dy in -1...1 {
                    for dx in -1...1 {
                        let sx = x + dx, sy = y + dy
                        guard sx >= 0, sy >= 0, sx < width, sy < height else { continue }
                        sum += gray[sy * width + sx]; count += 1
                    }
                }
                bright[y * width + x] = sum / count
            }
        }
        guard let peak = bright.max(), peak > 0 else { return center }
        let threshold = peak * 0.75
        var area = [Int](repeating: -1, count: width * height)
        var best = (score: -1.0, at: 0)
        for start in bright.indices where bright[start] >= threshold && area[start] < 0 {
            // One bright area, flooded from here.
            var stack = [start], score = 0.0, brightest = start
            area[start] = start
            while let index = stack.popLast() {
                score += bright[index]
                if bright[index] > bright[brightest] { brightest = index }
                let x = index % width, y = index / width
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < width && ny < height {
                    let next = ny * width + nx
                    if area[next] < 0, bright[next] >= threshold { area[next] = start; stack.append(next) }
                }
            }
            if score > best.score { best = (score, brightest) }
        }
        return CGPoint(x: (Double(best.at % width) + 0.5) * Double(image.width) / Double(width),
                       y: (Double(best.at / width) + 0.5) * Double(image.height) / Double(height))
    }
}

extension EditorSession {
    /// Volumetric Light's Extract Depth: closes the filter and adds the depth its haze goes by as a layer of its own,
    /// above the layer, white near and black far, to look at or use. Fetches the depth model first if it isn't here.
    func extractDepth() async {
        guard let edit = filterEdit, edit.kind == .volumetricLight, !edit.committing,
              let source = document?.layers.first(where: { $0.id == edit.layerID }), let image = source.asset?.image else { return }
        let settings = edit.settings.volumetric
        cancelFilter()
        preparingDepth = true
        let ready = await DepthModel.prepare()
        preparingDepth = false
        let map = ready ? await Task.detached(priority: .userInitiated) { VolumetricLighting.depthMap(for: image, settings: settings) }.value : nil
        guard let map, let thumbnail = try? PixelAdjust.thumbnail(of: map), canEditLayers,
              let index = document?.layers.firstIndex(where: { $0.id == source.id }) else { Platform.beep(); return }
        var layer = ImageLayer(asset: ImportedImage(image: map, thumbnail: thumbnail, name: "Depth"), origin: source.origin)
        layer.transform = source.transform
        layer.name = "Depth"
        layer.parentID = source.parentID
        beginEdit("Extract Depth")
        document?.layers.insert(layer, at: index + 1)
        activeLayerID = layer.id
        endEdit()
    }
}
