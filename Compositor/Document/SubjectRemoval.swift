import Vision
import CoreImage

nonisolated enum SubjectRemoval {
    enum Failure: LocalizedError {
        case noSubject
        var errorDescription: String? { L10n.string("No foreground subject was detected in this layer. Try an image with a more distinct subject.") }
    }
    /// Vision's own mask for an image, kept while the panel is open so moving a slider only redoes the refining.
    private static let cache = MaskCache()
    private final class MaskCache: @unchecked Sendable {
        private let lock = NSLock()
        private var key: ObjectIdentifier?
        private var value: CGImage?
        func mask(for image: CGImage, make: () throws -> CGImage) throws -> CGImage {
            lock.lock()
            let hit = key == ObjectIdentifier(image) ? value : nil
            lock.unlock()
            if let hit { return hit }
            let made = try make()
            lock.lock(); key = ObjectIdentifier(image); value = made; lock.unlock()
            return made
        }
    }

    /// Vision's raw subject mask, white over the subject: the model has no settings of its own, so everything the
    /// panel offers is done to this afterwards by `refined`.
    private static func vision(_ image: CGImage) throws -> CGImage {
        try cache.mask(for: image) {
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
            let request = VNGenerateForegroundInstanceMaskRequest()
            try handler.perform([request])
            guard let result = request.results?.first, !result.allInstances.isEmpty else { throw Failure.noSubject }
            let buffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
            return try PixelAdjust.render(CIImage(cvPixelBuffer: buffer), width: image.width, height: image.height, isMask: true)
        }
    }

    /// The panel's three controls, in the order they help:
    /// - Refine pulls the mask onto the image's own edges (a guided filter with the layer as its guide), which is
    ///   what recovers hair and fur the model cuts straight through.
    /// - Contrast pushes the mask's grays apart, clearing the haze that leaves background showing through.
    /// - Shift Edge grows or shrinks the mask, usually inwards, to drop the rim of background color around a cutout.
    private static func refined(_ mask: CGImage, guide: CGImage, settings: FilterSettings, limit: CGFloat) throws -> CGImage {
        // Basic is Apple's mask as it comes, which is quick; everything below is Advanced.
        guard settings.backgroundQuality == .advanced else { return mask }
        var image = CIImage(cgImage: mask)
        let extent = CGRect(x: 0, y: 0, width: mask.width, height: mask.height)
        if settings.refineEdges > 0 {
            image = CIImage(cgImage: try GuidedMatte.refine(mask: mask, guide: guide,
                                                            radius: settings.refineEdges, limit: limit))
        }
        if settings.shiftEdge != 0 {
            // A blur then a hard threshold at the matching level moves the edge by the blur's reach.
            let reach = abs(settings.shiftEdge)
            image = image.clampedToExtent().applyingGaussianBlur(sigma: reach / 2).cropped(to: extent)
            let level = settings.shiftEdge < 0 ? 0.75 : 0.25
            image = image.applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: level, y: level, z: level, w: 0),
                "inputMaxComponents": CIVector(x: level + 0.001, y: level + 0.001, z: level + 0.001, w: 1),
            ])
            let scale = 1 / 0.001
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
                "inputBiasVector": CIVector(x: -level * scale, y: -level * scale, z: -level * scale, w: 0),
            ])
        }
        if settings.matteContrast > 0 {
            // 0 leaves the mask as it is; 100 is a hard cut at the middle.
            let strength = settings.matteContrast / 100
            let slope = 1 / max(0.02, 1 - strength * 0.98)
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: slope, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: slope, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: slope, w: 0),
                "inputBiasVector": CIVector(x: (1 - slope) / 2, y: (1 - slope) / 2, z: (1 - slope) / 2, w: 0),
            ])
        }
        return try PixelAdjust.render(image.cropped(to: extent), width: mask.width, height: mask.height, isMask: true)
    }

    /// Where the subject is: white over it, black over the background, the size of the layer's own pixels — a layer
    /// mask that hides the background instead of erasing it. `under` is the layer's existing mask, kept as well.
    static func subjectMask(_ image: CGImage, under existing: CGImage?, settings: FilterSettings) throws -> CGImage {
        let subject = try refined(vision(image), guide: image, settings: settings, limit: .greatestFiniteMagnitude)
        guard let existing else { return subject }
        // Both masks hide: what either one hides stays hidden.
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: true)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        BrushRaster.draw(existing, in: bounds, mask: true, context: context)
        context.setBlendMode(.multiply)
        context.draw(subject, in: bounds)
        guard let combined = context.makeImage() else { throw ExportError.render }
        return combined
    }

    /// The preview: the layer with its background made transparent by the same mask the commit lays down.
    static func run(_ image: CGImage, settings: FilterSettings) throws -> CGImage {
        let source = CIImage(cgImage: image)
        // The preview refines on a copy at most this big, so dragging a slider stays responsive.
        let mask = CIImage(cgImage: try refined(vision(image), guide: image, settings: settings, limit: 1400))
        let output = source.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: source.extent),
            kCIInputMaskImageKey: mask
        ])
        return try PixelAdjust.render(output, width: image.width, height: image.height, isMask: false)
    }
}
