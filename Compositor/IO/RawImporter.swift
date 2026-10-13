import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// What a camera recorded, before anyone decided how it should look. The file holds one value per
/// photosite at 12–14 bits; every choice a JPEG has already baked in — exposure, white balance,
/// contrast — is still open. Compositor's layers are 8-bit, so that latitude has to be spent at
/// import: these are the controls for spending it deliberately rather than accepting a default.
nonisolated struct RawDevelopSettings: Equatable, Sendable {
    /// Stops of exposure, either side of what the camera recorded.
    var exposure: Float = 0
    /// White balance in Kelvin, starting from the camera's own reading.
    var temperature: Float = 5000
    /// Green–magenta balance, starting from the camera's own reading.
    var tint: Float = 0
    /// Apple's tone curve: 1 is its full interpretation, 0 leaves the image flat and neutral.
    var boost: Float = 1
    /// Luminance noise reduction, 0–1, starting where the system's RAW engine starts for this camera.
    var noiseReduction: Float = 0
    /// The lens's distortion and vignetting taken out, from the profile in the file, where it has one.
    var lensCorrection = false
    /// Detail brought back in highlights the camera only partly clipped (one or two channels blown).
    var highlightRecovery = false
    /// What the camera itself chose, so Reset has somewhere to go back to.
    var asShotTemperature: Float = 5000
    var asShotTint: Float = 0
    var asShotNoiseReduction: Float = 0
    var asShotLensCorrection = false
    var asShotHighlightRecovery = false
    /// Which of those this file's camera allows; the others stay as they are.
    var supportsNoiseReduction = false
    var supportsLensCorrection = false
    var supportsHighlightRecovery = false

    var isAsShot: Bool {
        exposure == 0 && boost == 1 && temperature == asShotTemperature && tint == asShotTint
            && noiseReduction == asShotNoiseReduction && lensCorrection == asShotLensCorrection
            && highlightRecovery == asShotHighlightRecovery
    }
    mutating func reset() {
        exposure = 0
        boost = 1
        temperature = asShotTemperature
        tint = asShotTint
        noiseReduction = asShotNoiseReduction
        lensCorrection = asShotLensCorrection
        highlightRecovery = asShotHighlightRecovery
    }
}

nonisolated enum RawImporter {
    /// One context for every develop: building a CIContext allocates GPU resources, and the sheet
    /// develops again on each slider move. Half-float in linear light throughout, named rather than left to
    /// Core Image's defaults, so nothing is rounded before the final 8-bit pixels.
    private static let context = CIContext(options: [
        .useSoftwareRenderer: false,
        .workingFormat: CIFormat.RGBAh,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
    ])

    /// Developing a RAW is seconds of work, so only one runs at a time and the caller waits its
    /// turn. Without this a dragged slider starts a render per pixel moved and they all pile up.
    ///
    /// The preview keeps its filter between renders, which is what makes the sliders feel live:
    /// building a new CIRAWFilter decodes the file again (about 1.5s here), while changing exposure
    /// or white balance on one that already exists costs nothing measurable.
    actor Queue {
        static let shared = Queue()
        private var cached: (url: URL, limit: CGFloat, filter: CIRAWFilter)?

        /// `sixteenBit`: the full frame at 16 bits a channel, for a 16-bit layer (`DeepLayer`); otherwise dithered to 8.
        func develop(_ url: URL, settings: RawDevelopSettings, limit: CGFloat?, sixteenBit: Bool = false) -> CGImage? {
            guard let limit else { return try? RawImporter.develop(url, settings: settings, limit: nil, sixteenBit: sixteenBit) }
            let filter: CIRAWFilter
            if let cached, cached.url == url, cached.limit == limit {
                filter = cached.filter
            } else {
                guard let made = CIRAWFilter(imageURL: url) else { return nil }
                let longest = max(made.nativeSize.width, made.nativeSize.height)
                if longest > limit {
                    made.scaleFactor = Float(limit / longest)
                    made.isDraftModeEnabled = true
                }
                cached = (url, limit, made)
                filter = made
            }
            return RawImporter.render(filter, settings: settings)
        }

        /// Lets go of the decoded frame when the sheet closes.
        func release() { cached = nil }
    }

    /// Every camera RAW the system can develop — 30 formats, from Canon and Nikon to DNG — rather
    /// than a list of vendors that would need extending with each new camera.
    static func matches(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .rawImage)
    }

    /// The camera's own white balance and the engine's own starting points for this camera, which is where the
    /// controls start.
    static func asShot(_ url: URL) -> RawDevelopSettings? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        var settings = RawDevelopSettings(temperature: filter.neutralTemperature, tint: filter.neutralTint)
        settings.noiseReduction = filter.isLuminanceNoiseReductionSupported ? filter.luminanceNoiseReductionAmount : 0
        settings.lensCorrection = filter.isLensCorrectionSupported && filter.isLensCorrectionEnabled
        if #available(macOS 26.0, *) {
            settings.highlightRecovery = filter.isHighlightRecoverySupported && filter.isHighlightRecoveryEnabled
            settings.supportsHighlightRecovery = filter.isHighlightRecoverySupported
        }
        settings.asShotTemperature = settings.temperature
        settings.asShotTint = settings.tint
        settings.asShotNoiseReduction = settings.noiseReduction
        settings.asShotLensCorrection = settings.lensCorrection
        settings.asShotHighlightRecovery = settings.highlightRecovery
        settings.supportsNoiseReduction = filter.isLuminanceNoiseReductionSupported
        settings.supportsLensCorrection = filter.isLensCorrectionSupported
        return settings
    }

    /// The developed image. `limit` caps the long edge for the preview the sheet shows while the
    /// sliders move; the import itself passes nil and gets the full frame.
    static func develop(_ url: URL, settings: RawDevelopSettings, limit: CGFloat? = nil, sixteenBit: Bool = false) throws -> CGImage {
        guard let filter = CIRAWFilter(imageURL: url) else { throw ImageImportError.unreadable }
        if let limit {
            let size = filter.nativeSize
            let longest = max(size.width, size.height)
            if longest > limit {
                filter.scaleFactor = Float(limit / longest)
                filter.isDraftModeEnabled = true
            }
        }
        guard let image = render(filter, settings: settings, sixteenBit: sixteenBit) else { throw ImageImportError.unreadable }
        return image
    }

    /// Applies the settings to a filter that already holds the decoded frame, and reads the pixels out.
    fileprivate static func render(_ filter: CIRAWFilter, settings: RawDevelopSettings, sixteenBit: Bool = false) -> CGImage? {
        filter.exposure = settings.exposure
        filter.neutralTemperature = settings.temperature
        filter.neutralTint = settings.tint
        filter.boostAmount = settings.boost
        if settings.supportsNoiseReduction { filter.luminanceNoiseReductionAmount = settings.noiseReduction }
        if settings.supportsLensCorrection { filter.isLensCorrectionEnabled = settings.lensCorrection }
        if #available(macOS 26.0, *), settings.supportsHighlightRecovery {
            filter.isHighlightRecoveryEnabled = settings.highlightRecovery
        }
        guard let output = filter.outputImage else { return nil }
        if sixteenBit {
            return context.createCGImage(output, from: output.extent.integral, format: .RGBA16,
                                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        return dithered(output, context: context)
    }

    /// The image as 8-bit sRGB pixels, rounded with a little noise rather than straight down. A RAW holds 12–14 bits;
    /// rounded plainly to 8, a smooth sky came out in visible steps, which curves and levels then pulled further apart.
    /// Noise of about one 8-bit step, too fine to see, breaks the steps up, as Lightroom does on export. The frame is
    /// rendered once at 16 bits, then rounded on every core in C: a few tens of milliseconds on a 20-megapixel photo.
    static func dithered(_ image: CIImage, context: CIContext) -> CGImage? {
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0, let target = try? BrushRaster.context(width: width, height: height, mask: false),
              let data = target.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var wide = [UInt16](repeating: 0, count: width * height * 4)
        wide.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 8, bounds: extent, format: .RGBA16,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        // In C, where the per-pixel work is quick in any build.
        wide.withUnsafeBufferPointer { dither_quantize16($0.baseAddress!, data, width, height, target.bytesPerRow) }
        return target.makeImage()
    }


    /// The frame's size without developing it, so an oversized file is refused before the work.
    static func pixelSize(_ url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }
}
