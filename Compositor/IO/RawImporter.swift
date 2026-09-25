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
    /// What the camera itself chose, so Reset has somewhere to go back to.
    var asShotTemperature: Float = 5000
    var asShotTint: Float = 0

    var isAsShot: Bool {
        exposure == 0 && boost == 1 && temperature == asShotTemperature && tint == asShotTint
    }
    mutating func reset() {
        exposure = 0
        boost = 1
        temperature = asShotTemperature
        tint = asShotTint
    }
}

nonisolated enum RawImporter {
    /// One context for every develop: building a CIContext allocates GPU resources, and the sheet
    /// develops again on each slider move.
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Developing a RAW is seconds of work, so only one runs at a time and the caller waits its
    /// turn. Without this a dragged slider starts a render per pixel moved and they all pile up.
    ///
    /// The preview keeps its filter between renders, which is what makes the sliders feel live:
    /// building a new CIRAWFilter decodes the file again (about 1.5s here), while changing exposure
    /// or white balance on one that already exists costs nothing measurable.
    actor Queue {
        static let shared = Queue()
        private var cached: (url: URL, limit: CGFloat, filter: CIRAWFilter)?

        func develop(_ url: URL, settings: RawDevelopSettings, limit: CGFloat?) -> CGImage? {
            guard let limit else { return try? RawImporter.develop(url, settings: settings, limit: nil) }
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

    /// The camera's own white balance, which is where the sliders start.
    static func asShot(_ url: URL) -> RawDevelopSettings? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        return RawDevelopSettings(temperature: filter.neutralTemperature, tint: filter.neutralTint,
                                  asShotTemperature: filter.neutralTemperature, asShotTint: filter.neutralTint)
    }

    /// The developed image. `limit` caps the long edge for the preview the sheet shows while the
    /// sliders move; the import itself passes nil and gets the full frame.
    static func develop(_ url: URL, settings: RawDevelopSettings, limit: CGFloat? = nil) throws -> CGImage {
        guard let filter = CIRAWFilter(imageURL: url) else { throw ImageImportError.unreadable }
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
        guard let output = filter.outputImage else { return nil }
        return context.createCGImage(output, from: output.extent, format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
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
