#if os(macOS)
import AppKit
#endif
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
    /// A 16-bit layer's pixels at 16 bits a channel (`DeepLayer`); `image` is then its dithered 8-bit copy. Once the
    /// layer's painted, these are its `raster`'s base, with the strokes' 8-bit patches over them: read the whole layer
    /// at 16 bits with `DeepLayer.flattened`.
    var deep: CGImage? = nil
    /// An HDR layer: `deep` holds light brighter than white, as half floats (`DeepLayer.hdr`).
    var isHDR: Bool { deep.map(DeepLayer.isHDR) ?? false }
    /// Its file in a project: EXR for an HDR layer, which PNG can't hold, otherwise PNG.
    func file(for id: UUID) -> String { "\(id.uuidString).\(isHDR ? "exr" : "png")" }
}

/// A folder brought in as images: the ones directly inside it, not its subfolders'.
nonisolated enum ImageFolder {
    /// A plain folder: not a file, and not a package such as a Compositor project.
    static func matches(_ url: URL) -> Bool {
        guard url.isFileURL, url.pathExtension.lowercased() != "comp",
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else { return false }
        return values.isDirectory == true && values.isPackage != true
    }

    /// The importable images directly inside `folder`, in the Finder's name order ("2" before "10").
    static func images(in folder: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                                      options: [.skipsHiddenFiles])) ?? []
        return contents.filter { url in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return UTType.importableImages.contains { type.conforms(to: $0) }
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

nonisolated enum ImageImportError: LocalizedError {
    case unreadable, unsupported, tooLarge
    var errorDescription: String? {
        switch self {
        case .unreadable: "The image could not be read. It may be damaged or unavailable."
        case .unsupported: "Choose a JPEG, PNG, HEIC, HEIF, TIFF, WebP, or Photoshop (PSD) file."
        case .tooLarge: "This import exceeds the current \(DocumentLimits.documentBudgetMegapixels)-megapixel document budget or \(DocumentLimits.maxSide.formatted())-pixel side limit."
        }
    }
}

actor ImageImporter {
    static let shared = ImageImporter()
    // Created only on first import, never during empty-app launch.
    private lazy var context = CIContext(options: [.cacheIntermediates: false])
    /// For sources with more than 8 bits a channel: half-float in linear light throughout, so nothing is rounded
    /// before the final dithered 8 bits (as `RawImporter` develops).
    private lazy var wideContext = CIContext(options: [
        .cacheIntermediates: false,
        .workingFormat: CIFormat.RGBAh,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
    ])
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// An SVG drawn once into pixels, by macOS's own SVG renderer: fitted to `fitting` (the canvas) when there is one,
    /// otherwise at the size the file declares. It comes in as an ordinary image layer, so it doesn't stay vector.
    func decodeSVG(_ url: URL, fitting: CGSize?, remainingPixels: Int = DocumentLimits.documentPixelBudget) throws -> ImportedImage {
        #if os(macOS)
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
        #else
        // iPadOS has no SVG renderer to hand.
        throw ImageImportError.unsupported
        #endif
    }

    /// `flattenedPhotoshop`: a PSD or PSB with no layer records (only a background), read as its merged image.
    func decode(_ url: URL, remainingPixels: Int = DocumentLimits.documentPixelBudget, flattenedPhotoshop: Bool = false) throws -> ImportedImage {
        try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let identifier = CGImageSourceGetType(source) as String?,
                  let type = UTType(identifier) else { throw ImageImportError.unreadable }
            let photoshop = flattenedPhotoshop ? [UTType.photoshopImage, .photoshopLargeImage] : []
            guard ([UTType.jpeg, .png, .heic, .heif, .tiff, .webP, .openEXR, .radianceHDR] + photoshop).contains(where: { type.conforms(to: $0) }) else {
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
            // Floats (EXR, Radiance HDR, float TIFF): an HDR layer when they go brighter than white, kept so as half
            // floats in extended sRGB (`DeepLayer.wideAsset`); otherwise a 16-bit layer.
            if decoded.bitmapInfo.contains(.floatComponents) {
                guard let pixels = wideContext.createCGImage(oriented, from: oriented.extent, format: .RGBAh,
                                                             colorSpace: DeepLayer.hdrSpace) else { throw ImageImportError.unreadable }
                return try DeepLayer.wideAsset(pixels, name: url.deletingPathExtension().lastPathComponent)
            }
            // More than 8 bits a channel (16-bit PNG and TIFF, 10-bit HEIF): a 16-bit layer, which keeps them
            // (`DeepLayer`), shown and edited through a copy rounded to 8 with a fine noise, so gradients don't step.
            let wide = decoded.bitsPerComponent > 8
            if wide {
                guard let deep = wideContext.createCGImage(oriented, from: oriented.extent, format: .RGBA16, colorSpace: sRGB) else {
                    throw ImageImportError.unreadable
                }
                return try DeepLayer.asset(deep, name: url.deletingPathExtension().lastPathComponent)
            }
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
