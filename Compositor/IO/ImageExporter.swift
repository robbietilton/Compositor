import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ExportError: LocalizedError {
    case tooLarge, render, encode, bitDepth
    var errorDescription: String? {
        switch self {
        case .tooLarge: "Image export supports canvases up to \(DocumentLimits.maxSurfaceMegapixels) megapixels and \(DocumentLimits.maxSide.formatted()) pixels per side."
        case .render: "The canvas could not be rendered. Try a smaller canvas."
        case .encode: "The image could not be encoded."
        case .bitDepth: "The encoder could not produce the selected bit depth. Try 8 bits per channel."
        }
    }
}

nonisolated enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case png, jpeg, tiff, avif, heic

    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var type: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .tiff: .tiff
        case .avif: UTType("public.avif")!
        case .heic: .heic
        }
    }
    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .tiff: "tif"
        default: rawValue
        }
    }
    var bitDepths: [Int] {
        switch self {
        case .png, .tiff: [8, 16]
        case .avif, .heic: [8, 10]
        case .jpeg: [8]
        }
    }
    var supportsQuality: Bool { self == .jpeg || self == .avif || self == .heic }
    var supportsTransparency: Bool { self != .jpeg }
    static var available: [Self] {
        let identifiers = CGImageDestinationCopyTypeIdentifiers() as! [String]
        return allCases.filter { identifiers.contains($0.type.identifier) }
    }
}

nonisolated enum TIFFCompression: Int, CaseIterable, Identifiable, Sendable {
    case none = 1, lzw = 5, zip = 8
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .none: "None"
        case .lzw: "LZW (lossless)"
        case .zip: "ZIP (lossless)"
        }
    }
}

nonisolated struct ExportOptions: Equatable, Sendable {
    var format: ExportFormat = .png
    var compression = JPEGOptions()
    var bitDepth = 8
    var preserveTransparency = true
    var tiffCompression: TIFFCompression = .lzw

    var effectiveBitDepth: Int { format.bitDepths.contains(bitDepth) ? bitDepth : 8 }
    var includesAlpha: Bool { format.supportsTransparency && preserveTransparency }

}

actor ImageExporter {
    static let shared = ImageExporter()

    func render(_ snapshot: ProjectSnapshot) throws -> ExportRaster {
        let width = snapshot.manifest.width, height = snapshot.manifest.height
        guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height),
              width * height <= DocumentLimits.maxSurfacePixels else { throw ExportError.tooLarge }
        return try autoreleasepool {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw ExportError.render
            }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            let records = Dictionary(uniqueKeysWithValues: snapshot.manifest.layers.map { ($0.id, $0) })
            for layer in snapshot.manifest.layers {
                guard layer.imageFile == nil || snapshot.images[layer.id] != nil,
                      layer.maskFile == nil || snapshot.masks[layer.id] != nil else { throw ProjectError.missingImage }
            }
            try LiveMaskGraph.validate(snapshot.manifest.layers)
            let live = LiveMaskRenderer(bounds: CGRect(x: 0, y: 0, width: width, height: height), source: { records[$0]?.maskSourceID }) { id, target in
                guard let layer = records[id], let image = snapshot.images[id]?.image else { return }
                let opacity = layer.effectiveOpacity(in: records)
                let mask = snapshot.mask(for: layer).flatMap { $0.clipImage(placement: $0.placement, over: layer.transform, width: image.width, height: image.height) }
                let effects = LayerEffectsRenderer.cached(image, mask: mask, effects: layer.effects)
                func drawLayer(_ mode: LayerBlendMode, _ into: CGContext) {
                    if let effects {
                        let grown = LayerEffectsRenderer.placed(layer.transform, image: effects.image, inset: effects.inset)
                        LayerRenderer.draw(effects.image, transform: grown, center: grown.center,
                            opacity: opacity, blendMode: mode, mask: nil, in: into)
                        return
                    }
                    LayerRenderer.draw(image, transform: layer.transform, center: layer.transform.center,
                        opacity: opacity, blendMode: mode, mask: mask, in: into)
                }
                let mode = layer.blendMode ?? .normal
                // Core Graphics blends these two wrong; see SeparableBlend.
                if SeparableBlend.needsSurface(mode), SeparableBlend.draw(mode, in: target, body: { drawLayer(.normal, $0) }) { return }
                drawLayer(mode, target)
            }
            live.adjustment = { records[$0]?.adjustment }
            live.adjustmentOpacity = { records[$0]?.effectiveOpacity(in: records) ?? 1 }
            live.adjustmentClip = { id, ctx in
                if let layer = records[id], let image = snapshot.mask(for: layer)?.enabledImage {
                    FolderMaskClip(image: image, transform: layer.transform).apply(center: layer.transform.center, in: ctx)
                }
            }
            live.prepareStacks(LayerHierarchy.visibleLayers(snapshot.manifest.layers).map(\.id), parent: { records[$0]?.parentID }, blend: { records[$0]?.blendMode ?? .normal })
            FolderMaskClip.draw(LayerHierarchy.visibleLayers(snapshot.manifest.layers).map(\.id), parent: { records[$0]?.parentID }, clip: { id in
                guard let folder = records[id], let image = snapshot.mask(for: folder)?.enabledImage else { return nil }
                let clip = FolderMaskClip(image: image, transform: folder.transform)
                return { clip.apply(center: folder.transform.center, in: $0) }
            }, in: context) { live.drawComposite($0, in: context) }
            guard let image = context.makeImage() else { throw ExportError.render }
            return ExportRaster(image: image, resolution: snapshot.manifest.resolution ?? 72)
        }
    }

    func pngData(_ snapshot: ProjectSnapshot) throws -> Data {
        let raster = try render(snapshot)
        return try encode(raster.image, type: .png, properties: [
            kCGImagePropertyDPIWidth: raster.resolution, kCGImagePropertyDPIHeight: raster.resolution
        ] as CFDictionary)
    }

    private func encode(_ image: CGImage, type: UTType, properties: CFDictionary? = nil) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw ExportError.encode
        }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encode }
        return data as Data
    }

    func jpeg(_ raster: ExportRaster, options: JPEGOptions) throws -> ExportResult {
        try Task.checkCancellation()
        return try autoreleasepool {
            let image = raster.image
            guard let context = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ExportError.render }
            context.setFillColor(CGColor(colorSpace: context.colorSpace!,
                components: [options.red, options.green, options.blue, 1])!)
            let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.fill(bounds)
            context.draw(image, in: bounds)
            guard let flattened = context.makeImage() else { throw ExportError.render }
            try Task.checkCancellation()
            let data = try encode(flattened, type: .jpeg,
                properties: [kCGImageDestinationLossyCompressionQuality: min(1, max(0, options.quality)),
                             kCGImagePropertyDPIWidth: raster.resolution,
                             kCGImagePropertyDPIHeight: raster.resolution] as CFDictionary)
            try Task.checkCancellation()
            return try preview(data)
        }
    }

    func encode(_ raster: ExportRaster, options: ExportOptions) throws -> ExportResult {
        try Task.checkCancellation()
        guard ExportFormat.available.contains(options.format) else { throw ExportError.encode }
        if options.format == .jpeg { return try jpeg(raster, options: options.compression) }
        return try autoreleasepool {
            var properties: [CFString: Any] = [
                kCGImagePropertyDPIWidth: raster.resolution,
                kCGImagePropertyDPIHeight: raster.resolution
            ]
            if options.format.supportsQuality {
                properties[kCGImageDestinationLossyCompressionQuality] = min(1, max(0, options.compression.quality))
            }
            if options.format == .tiff {
                properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: options.tiffCompression.rawValue]
            }
            let image = try prepare(raster.image, options: options)
            let data = try encode(image, type: options.format.type, properties: properties as CFDictionary)
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  metadata[kCGImagePropertyDepth] as? Int == options.effectiveBitDepth else { throw ExportError.bitDepth }
            return try preview(data)
        }
    }

    private func prepare(_ image: CGImage, options: ExportOptions) throws -> CGImage {
        if options.effectiveBitDepth == 8 && options.includesAlpha { return image }
        // ImageIO encodes 16-bit integer input to 10-bit AVIF/HEIC.
        let bits = options.effectiveBitDepth > 8 ? 16 : 8
        let alpha = options.includesAlpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
        let byteOrder = bits == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: bits, bytesPerRow: image.width * 4 * (bits / 8),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: alpha.rawValue | byteOrder) else { throw ExportError.render }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        if !options.includesAlpha {
            context.setFillColor(CGColor(colorSpace: context.colorSpace!,
                components: [options.compression.red, options.compression.green, options.compression.blue, 1])!)
            context.fill(bounds)
        }
        context.draw(image, in: bounds)
        guard let result = context.makeImage() else { throw ExportError.render }
        return result
    }

    private func preview(_ data: Data) throws -> ExportResult {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let preview = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCache: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw ExportError.encode }
        return ExportResult(data: data, preview: preview)
    }

    func exportPNG(_ snapshot: ProjectSnapshot, to url: URL) throws {
        let data = try pngData(snapshot)
        try write(data, to: url)
    }

    func write(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do { try data.write(to: target, options: .atomic) }
            catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    }
}

nonisolated struct ExportRaster: @unchecked Sendable {
    let image: CGImage
    var resolution: Double = 72
}
nonisolated struct JPEGOptions: Equatable, Sendable {
    var quality: Double = 0.85
    var red: CGFloat = 1
    var green: CGFloat = 1
    var blue: CGFloat = 1
}
nonisolated struct ExportResult: @unchecked Sendable {
    let data: Data
    let preview: CGImage
}
