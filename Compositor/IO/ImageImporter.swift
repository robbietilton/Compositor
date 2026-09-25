import AppKit
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

nonisolated struct ImportedImage: @unchecked Sendable {
    // Immutable CGImages can be shared with the main-thread renderer.
    let image: CGImage
    let thumbnail: CGImage
    let name: String
    var raster: RasterSnapshot? = nil
}

nonisolated enum ImageImportError: LocalizedError {
    case unreadable, unsupported, tooLarge
    var errorDescription: String? {
        switch self {
        case .unreadable: "The image could not be read. It may be damaged or unavailable."
        case .unsupported: "Choose a JPEG, PNG, HEIC, TIFF, or Photoshop (PSD) file."
        case .tooLarge: "This import exceeds the current \(DocumentLimits.documentBudgetMegapixels)-megapixel document budget or \(DocumentLimits.maxSide.formatted())-pixel side limit."
        }
    }
}

actor ImageImporter {
    static let shared = ImageImporter()
    // Created only on first import, never during empty-app launch.
    private lazy var context = CIContext(options: [.cacheIntermediates: false])
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// An SVG drawn once into pixels, by macOS's own SVG renderer: fitted to `fitting` (the canvas) when there is one,
    /// otherwise at the size the file declares. It comes in as an ordinary image layer, so it doesn't stay vector.
    func decodeSVG(_ url: URL, fitting: CGSize?, remainingPixels: Int = DocumentLimits.documentPixelBudget) throws -> ImportedImage {
        guard let svg = NSImage(contentsOf: url), svg.size.width > 0, svg.size.height > 0 else { throw ImageImportError.unreadable }
        let scale = fitting.map { min($0.width / svg.size.width, $0.height / svg.size.height) } ?? 1
        let width = max(1, Int((svg.size.width * scale).rounded())), height = max(1, Int((svg.size.height * scale).rounded()))
        guard width <= DocumentLimits.maxSide, height <= DocumentLimits.maxSide, width * height <= remainingPixels else {
            throw ImageImportError.tooLarge
        }
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        // Layer pixels are stored top row first; AppKit draws bottom-up, so the drawing is turned over to match.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        svg.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { throw ImageImportError.unreadable }
        return ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: url.deletingPathExtension().lastPathComponent)
    }

    /// `flattenedPhotoshop`: a PSD or PSB with no layer records (only a background), read as its merged image.
    func decode(_ url: URL, remainingPixels: Int = DocumentLimits.documentPixelBudget, flattenedPhotoshop: Bool = false) throws -> ImportedImage {
        try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let identifier = CGImageSourceGetType(source) as String?,
                  let type = UTType(identifier) else { throw ImageImportError.unreadable }
            let photoshop = flattenedPhotoshop ? [UTType.photoshopImage, .photoshopLargeImage] : []
            guard ([UTType.jpeg, .png, .heic, .tiff] + photoshop).contains(where: { type.conforms(to: $0) }) else {
                throw ImageImportError.unsupported
            }
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0 else { throw ImageImportError.unreadable }
            guard width <= DocumentLimits.maxSide, height <= DocumentLimits.maxSide, width * height <= remainingPixels else {
                throw ImageImportError.tooLarge
            }
            guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                throw ImageImportError.unreadable
            }
            let orientation = (properties[kCGImagePropertyOrientation] as? Int32) ?? 1
            let oriented = CIImage(cgImage: decoded).oriented(forExifOrientation: orientation)
            guard let image = context.createCGImage(oriented, from: oriented.extent, format: .RGBA8, colorSpace: sRGB) else {
                throw ImageImportError.unreadable
            }
            let scale = min(1, 96 / max(oriented.extent.width, oriented.extent.height))
            let preview = oriented.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let thumbnail = context.createCGImage(preview, from: preview.extent.integral, format: .RGBA8, colorSpace: sRGB) else {
                throw ImageImportError.unreadable
            }
            return ImportedImage(image: image, thumbnail: thumbnail, name: url.deletingPathExtension().lastPathComponent)
        }
    }

    func loadPhotoshop(_ url: URL, remainingPixels: Int = DocumentLimits.documentPixelBudget) throws -> PSDDocument {
        try PSDReader.read(from: url, remainingPixels: remainingPixels)
    }

    func photoshopAssets(_ document: PSDDocument) throws -> [UUID: ImportedImage] {
        try PSDDocumentBuilder.assets(from: document)
    }
}
