import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// What a camera recorded, before anyone decided how it should look. The file holds one value per
/// photosite at 12–14 bits; every choice a JPEG has already baked in — exposure, white balance,
/// contrast — is still open. Compositor's layers are 8-bit, so that latitude has to be spent at
/// import: these are the controls for spending it deliberately rather than accepting a default.
nonisolated struct RawDevelopSettings: Codable, Equatable, Sendable {
    /// Stops of exposure, either side of what the camera recorded.
    var exposure: Float = 0
    /// White balance in Kelvin, starting from the camera's own reading.
    var temperature: Float = 5000
    /// Green–magenta balance, starting from the camera's own reading.
    var tint: Float = 0
    /// Apple's tone curve: 1 is its full interpretation, 0 leaves the image flat and neutral.
    var boost: Float = 1
    /// Selective tone controls, matching the familiar camera-RAW range.
    var highlights: Float = 0
    var shadows: Float = 0
    var whites: Float = 0
    var blacks: Float = 0
    /// Point curves are evaluated while the image is still in the linear working pipeline.
    var curves = CurvesSettings()
    /// What the camera itself chose, so Reset has somewhere to go back to.
    var asShotTemperature: Float = 5000
    var asShotTint: Float = 0

    init(exposure: Float = 0, temperature: Float = 5000, tint: Float = 0, boost: Float = 1,
         highlights: Float = 0, shadows: Float = 0, whites: Float = 0, blacks: Float = 0,
         curves: CurvesSettings = CurvesSettings(), asShotTemperature: Float = 5000, asShotTint: Float = 0) {
        self.exposure = exposure; self.temperature = temperature; self.tint = tint; self.boost = boost
        self.highlights = highlights; self.shadows = shadows; self.whites = whites; self.blacks = blacks
        self.curves = curves; self.asShotTemperature = asShotTemperature; self.asShotTint = asShotTint
    }

    /// Version 12 projects written before the expanded develop panel contain only the original six
    /// values. Missing tone controls decode as identities so those projects remain readable.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try values.decodeIfPresent(Float.self, forKey: .exposure) ?? 0
        temperature = try values.decodeIfPresent(Float.self, forKey: .temperature) ?? 5000
        tint = try values.decodeIfPresent(Float.self, forKey: .tint) ?? 0
        boost = try values.decodeIfPresent(Float.self, forKey: .boost) ?? 1
        highlights = try values.decodeIfPresent(Float.self, forKey: .highlights) ?? 0
        shadows = try values.decodeIfPresent(Float.self, forKey: .shadows) ?? 0
        whites = try values.decodeIfPresent(Float.self, forKey: .whites) ?? 0
        blacks = try values.decodeIfPresent(Float.self, forKey: .blacks) ?? 0
        curves = try values.decodeIfPresent(CurvesSettings.self, forKey: .curves) ?? CurvesSettings()
        asShotTemperature = try values.decodeIfPresent(Float.self, forKey: .asShotTemperature) ?? 5000
        asShotTint = try values.decodeIfPresent(Float.self, forKey: .asShotTint) ?? 0
    }

    var isAsShot: Bool {
        exposure == 0 && boost == 1 && temperature == asShotTemperature && tint == asShotTint
            && highlights == 0 && shadows == 0 && whites == 0 && blacks == 0
            && curves.channels == CurvesSettings().channels
    }
    var isValid: Bool {
        exposure.isFinite && (-20...20).contains(exposure)
            && temperature.isFinite && (1_000...50_000).contains(temperature)
            && tint.isFinite && (-1_000...1_000).contains(tint)
            && boost.isFinite && (0...1).contains(boost)
            && [highlights, shadows, whites, blacks].allSatisfy { $0.isFinite && (-100...100).contains($0) }
            && curves.isValid
            && asShotTemperature.isFinite && (1_000...50_000).contains(asShotTemperature)
            && asShotTint.isFinite && (-1_000...1_000).contains(asShotTint)
    }
    mutating func reset() {
        exposure = 0
        boost = 1
        highlights = 0
        shadows = 0
        whites = 0
        blacks = 0
        curves = CurvesSettings()
        temperature = asShotTemperature
        tint = asShotTint
    }
}

/// The original camera file and the choices used to develop it. Keeping the source rather than a
/// demosaiced intermediate lets the develop sheet start from the camera data again after reopening
/// a project. `Data` is copy-on-write, so duplicating a RAW-backed layer does not duplicate its bytes.
nonisolated struct RawBacking: Equatable, Sendable {
    let id: UUID
    let data: Data
    let name: String
    let typeIdentifier: String?
    var settings: RawDevelopSettings

    init(data: Data, name: String, typeIdentifier: String?, settings: RawDevelopSettings = RawDevelopSettings(), id: UUID = UUID()) {
        self.id = id
        self.data = data
        self.name = name
        self.typeIdentifier = typeIdentifier
        self.settings = settings
    }

    init(contentsOf url: URL) throws {
        // Own the bytes. A security-scoped import may disappear after this call, and a project
        // save later atomically replaces its package files.
        self.init(data: try Data(contentsOf: url), name: url.lastPathComponent,
                  typeIdentifier: UTType(filenameExtension: url.pathExtension)?.identifier)
    }
}

/// Display-only statistics for the developed RAW preview. RGB bins describe the individual output
/// channels; luminance uses Rec. 709 weights in the same display-referred sRGB values. Large
/// previews are sampled on a regular grid so moving a develop slider does not turn histogram work
/// into another full-frame render.
nonisolated struct RawDevelopHistogram: Equatable, Sendable {
    static let binCount = 256
    var red: [Double]
    var green: [Double]
    var blue: [Double]
    var luminance: [Double]

    var rgbPeak: Double {
        max(LevelsHistogramDisplay.scale(for: red),
            LevelsHistogramDisplay.scale(for: green),
            LevelsHistogramDisplay.scale(for: blue))
    }
    var luminancePeak: Double { LevelsHistogramDisplay.scale(for: luminance) }

    static func make(_ image: CGImage) -> Self? {
        guard image.width > 0, image.height > 0,
              let context = try? BrushRaster.context(width: image.width, height: image.height, mask: false) else { return nil }
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                         mask: false, context: context)
        guard let data = context.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var bins = Array(repeating: 0.0, count: binCount * 4)
        levels_histogram(bytes, nil, image.width * image.height, &bins)

        var luminance = Array(repeating: 0.0, count: binCount)
        let pixelCount = image.width * image.height
        let sampleStep = max(1, Int(sqrt(Double(pixelCount) / 500_000).rounded(.up)))
        for y in stride(from: 0, to: image.height, by: sampleStep) {
            let row = y * context.bytesPerRow
            for x in stride(from: 0, to: image.width, by: sampleStep) {
                let pixel = row + x * 4
                let alpha = Double(bytes[pixel + 3])
                if alpha == 0 { continue }
                let red = min(1, Double(bytes[pixel]) / alpha)
                let green = min(1, Double(bytes[pixel + 1]) / alpha)
                let blue = min(1, Double(bytes[pixel + 2]) / alpha)
                let value = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                luminance[min(255, max(0, Int((value * 255).rounded())))] += alpha / 255
            }
        }
        return Self(red: Array(bins[256..<512]), green: Array(bins[512..<768]),
                    blue: Array(bins[768..<1024]), luminance: luminance)
    }
}

nonisolated enum RawImporter {
    /// One context for every develop: building a CIContext allocates GPU resources, and the sheet
    /// develops again on each slider move.
    private static let outputSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    /// RAW decoding and every filter inserted before output stay half-float and scene-linear. The
    /// only 8-bit conversion is the final handoff to today's 8-bit document renderer.
    private static let context = CIContext(options: [
        .useSoftwareRenderer: false,
        .workingFormat: CIFormat.RGBAh,
        .workingColorSpace: workingSpace,
        .outputColorSpace: outputSpace
    ])

    /// Developing a RAW is seconds of work, so only one runs at a time and the caller waits its
    /// turn. Without this a dragged slider starts a render per pixel moved and they all pile up.
    ///
    /// The preview keeps its filter between renders, which is what makes the sliders feel live:
    /// building a new CIRAWFilter decodes the file again (about 1.5s here), while changing exposure
    /// or white balance on one that already exists costs nothing measurable.
    actor Queue {
        static let shared = Queue()
        private var cached: (id: UUID, limit: CGFloat, filter: CIRAWFilter)?

        func develop(_ source: RawBacking, settings: RawDevelopSettings, limit: CGFloat?) -> CGImage? {
            guard let limit else { return try? RawImporter.develop(source, settings: settings, limit: nil) }
            let filter: CIRAWFilter
            if let cached, cached.id == source.id, cached.limit == limit {
                filter = cached.filter
            } else {
                guard let made = makeFilter(source) else { return nil }
                let longest = max(made.nativeSize.width, made.nativeSize.height)
                if longest > limit {
                    made.scaleFactor = Float(limit / longest)
                    made.isDraftModeEnabled = true
                }
                cached = (source.id, limit, made)
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

    private static func makeFilter(_ source: RawBacking) -> CIRAWFilter? {
        CIRAWFilter(imageData: source.data, identifierHint: source.typeIdentifier)
    }

    /// The camera's own white balance, which is where the sliders start.
    static func asShot(_ source: RawBacking) -> RawDevelopSettings? {
        guard let filter = makeFilter(source) else { return nil }
        return RawDevelopSettings(temperature: filter.neutralTemperature, tint: filter.neutralTint,
                                  asShotTemperature: filter.neutralTemperature, asShotTint: filter.neutralTint)
    }

    /// The developed image. `limit` caps the long edge for the preview the sheet shows while the
    /// sliders move; the import itself passes nil and gets the full frame.
    static func develop(_ source: RawBacking, settings: RawDevelopSettings, limit: CGFloat? = nil) throws -> CGImage {
        guard let filter = makeFilter(source) else { throw ImageImportError.unreadable }
        filter.exposure = settings.exposure
        filter.neutralTemperature = settings.temperature
        filter.neutralTint = settings.tint
        filter.boostAmount = settings.boost
        if let limit {
            let size = filter.nativeSize
            let longest = max(size.width, size.height)
            if longest > limit {
                filter.scaleFactor = Float(limit / longest)
                filter.isDraftModeEnabled = true
            }
        }
        guard let image = render(filter, settings: settings) else { throw ImageImportError.unreadable }
        return image
    }

    /// Applies the settings to a filter that already holds the decoded frame, and reads the pixels out.
    fileprivate static func render(_ filter: CIRAWFilter, settings: RawDevelopSettings) -> CGImage? {
        filter.exposure = settings.exposure
        filter.neutralTemperature = settings.temperature
        filter.neutralTint = settings.tint
        filter.boostAmount = settings.boost
        guard var output = filter.outputImage else { return nil }
        if let adjusted = toneAdjusted(output, settings: settings) { output = adjusted }
        return context.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: outputSpace)
    }

    /// A dense one-dimensional float lookup keeps selective tones and point curves on the GPU and
    /// in the half-float, extended-linear working space. The controls operate on perceptual tones;
    /// lookup values return to linear light before the final render. It is cheap enough to rebuild
    /// continuously while a slider or curve point is dragged.
    static func toneAdjusted(_ image: CIImage, settings: RawDevelopSettings) -> CIImage? {
        guard settings.highlights != 0 || settings.shadows != 0 || settings.whites != 0 || settings.blacks != 0
                || settings.curves.channels != CurvesSettings().channels else { return image }
        let count = 2049, step = Double(count - 1)
        var values = [Float]()
        values.reserveCapacity(count * 3)
        for index in 0..<count {
            let tone = applyTone(linearToSRGB(Double(index) / step), settings: settings)
            for channel in 1...3 {
                let curved = settings.curves.value(settings.curves.value(tone * 255, channel: channel), channel: 0) / 255
                values.append(Float(sRGBToLinear(curved)))
            }
        }
        return image.applyingFilter("CIColorCurves", parameters: [
            "inputCurvesData": values.withUnsafeBufferPointer { Data(buffer: $0) },
            "inputCurvesDomain": CIVector(x: 0, y: 1),
            "inputColorSpace": workingSpace,
        ])
    }

    private static func applyTone(_ input: Double, settings: RawDevelopSettings) -> Double {
        func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
        let highlights = Double(settings.highlights) / 100
        let shadows = Double(settings.shadows) / 100
        let whites = Double(settings.whites) / 100
        let blacks = Double(settings.blacks) / 100
        var value = input, t = clamp((value - 0.5) / 0.5), weight = t * t
        value = clamp(value + highlights * weight * (highlights >= 0 ? 1 - value : value - 0.5))
        t = clamp((0.5 - value) / 0.5); weight = t * t
        value = clamp(value + shadows * weight * (shadows >= 0 ? 0.5 - value : value))
        if value > 0.75 { value = clamp(0.75 + (value - 0.75) * (1 + whites)) }
        if value < 0.25 { value = clamp(0.25 + (value - 0.25) * (1 - blacks)) }
        return value
    }

    private static func linearToSRGB(_ value: Double) -> Double {
        value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }

    private static func sRGBToLinear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
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
