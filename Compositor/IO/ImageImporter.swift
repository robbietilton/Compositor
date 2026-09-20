import Foundation
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
        case .unsupported: "Choose a JPEG, PNG, HEIC, TIFF, or PSD image."
        case .tooLarge: "This import exceeds the current 100-megapixel document budget or 30,000-pixel side limit."
        }
    }
}

extension UTType {
    /// macOS ships no `.psd` constant; ImageIO registers the Photoshop type by identifier, so the lookup stays optional.
    static let psd = UTType("com.adobe.photoshop-image")
}

actor ImageImporter {
    static let shared = ImageImporter()
    // Created only on first import, never during empty-app launch.
    private lazy var context = CIContext(options: [.cacheIntermediates: false])
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    func decode(_ url: URL, remainingPixels: Int = 100_000_000) throws -> ImportedImage {
        try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let identifier = CGImageSourceGetType(source) as String?,
                  let type = UTType(identifier) else { throw ImageImportError.unreadable }
            let accepted: [UTType] = [.jpeg, .png, .heic, .tiff] + [UTType.psd].compactMap { $0 }
            guard accepted.contains(where: { type.conforms(to: $0) }) else {
                throw ImageImportError.unsupported
            }
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0 else { throw ImageImportError.unreadable }
            guard width <= 30_000, height <= 30_000, width * height <= remainingPixels else {
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
}
