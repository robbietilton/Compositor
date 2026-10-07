import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ExportError: LocalizedError {
    case tooLarge, render, encode
    var errorDescription: String? {
        switch self {
        case .tooLarge: "Image export supports canvases up to \(DocumentLimits.maxSurfaceMegapixels) megapixels and \(DocumentLimits.maxSide.formatted()) pixels per side."
        case .render: "The canvas could not be rendered. Try a smaller canvas."
        case .encode: "The image could not be encoded."
        }
    }
}

actor ImageExporter {
    static let shared = ImageExporter()

    /// How far an export has come, said on the exporter's thread for whoever shows it.
    nonisolated enum Progress: Sendable, Equatable {
        /// The image is about to be composed of `total` layers: those drawn, visible and not folders.
        case composing(total: Int)
        /// The first `done` of them are composed, in order.
        case composed(done: Int)
        /// The image is composed, and is being encoded.
        case encoding
    }

    /// `snapshot` flattened, at its own size or, for a preview, `scale` of it: drawn at that size, not shrunk from the
    /// whole. `progress` is told how far it has come as it goes.
    func render(_ snapshot: ProjectSnapshot, scale: CGFloat = 1, progress: (@Sendable (Progress) -> Void)? = nil) throws -> ExportRaster {
        let width = snapshot.manifest.width, height = snapshot.manifest.height
        guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height),
              width * height <= DocumentLimits.maxSurfacePixels else { throw ExportError.tooLarge }
        let scale = min(1, scale)
        let pixelWidth = max(1, Int((CGFloat(width) * scale).rounded())), pixelHeight = max(1, Int((CGFloat(height) * scale).rounded()))
        let rendering = Timing.begin("Render")
        let raster = try autoreleasepool {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                                          bitsPerComponent: 8, bytesPerRow: pixelWidth * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw ExportError.render
            }
            context.clear(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            context.translateBy(x: 0, y: CGFloat(pixelHeight))
            context.scaleBy(x: CGFloat(pixelWidth) / CGFloat(width), y: -CGFloat(pixelHeight) / CGFloat(height))
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
            // The surfaces made along the way are as sharp as the image they go into.
            live.resolution = CGFloat(pixelWidth) / CGFloat(width)
            live.adjustmentScale = live.resolution
            live.adjustment = { records[$0]?.adjustment }
            live.adjustmentOpacity = { records[$0]?.effectiveOpacity(in: records) ?? 1 }
            live.adjustmentClip = { id, ctx in
                if let layer = records[id], let image = snapshot.mask(for: layer)?.enabledImage {
                    FolderMaskClip(image: image, transform: layer.transform).apply(center: layer.transform.center, in: ctx)
                }
            }
            let visible = LayerHierarchy.visibleLayers(snapshot.manifest.layers).map(\.id)
            live.prepareStacks(visible, parent: { records[$0]?.parentID }, blend: { records[$0]?.blendMode ?? .normal })
            progress?(.composing(total: visible.count))
            var composed = 0
            FolderMaskClip.draw(visible, parent: { records[$0]?.parentID }, clip: { id in
                guard let folder = records[id], let image = snapshot.mask(for: folder)?.enabledImage else { return nil }
                let clip = FolderMaskClip(image: image, transform: folder.transform)
                return { clip.apply(center: folder.transform.center, in: $0) }
            }, in: context) { id in
                live.drawComposite(id, in: context)
                composed += 1
                progress?(.composed(done: composed))
            }
            guard let image = context.makeImage() else { throw ExportError.render }
            return ExportRaster(image: image, resolution: snapshot.manifest.resolution ?? 72)
        }
        Timing.end(rendering, "\(pixelWidth)×\(pixelHeight)")
        return raster
    }

    /// The Space-bar preview, saved in the project's QuickLook folder: the flattened image on white, a JPEG up to
    /// 1,024 px on the long side, about 100–200 KB. Nil for canvases too large to flatten on every save.
    func quickLookImages(_ snapshot: ProjectSnapshot) -> QuickLookImages? {
        let making = Timing.begin("QuickLook preview")
        let longSide = max(snapshot.manifest.width, snapshot.manifest.height)
        // Drawn no smaller than half size, where a layer at its own size draws straight, then shrunk; the reductions a
        // smaller one needs aren't kept, as nothing draws this again.
        guard snapshot.manifest.width * snapshot.manifest.height <= 50_000_000,
              let raster = try? DownsampleCache.$keeps.withValue(false, operation: {
                  try render(snapshot, scale: max(0.5, 1024 / CGFloat(longSide)))
              }),
              let preview = try? scaledJPEG(raster.image, longSide: 1024) else { return nil }
        Timing.end(making)
        return QuickLookImages(preview: preview)
    }

    private func scaledJPEG(_ image: CGImage, longSide: CGFloat) throws -> Data {
        let scale = min(1, longSide / CGFloat(max(image.width, image.height)))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded())), height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        return try autoreleasepool {
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { throw ExportError.render }
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(bounds)
            context.interpolationQuality = .high
            context.draw(image, in: bounds)
            guard let flattened = context.makeImage() else { throw ExportError.render }
            return try encode(flattened, type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        }
    }

    /// `snapshot` flattened and encoded as PNG. `progress` is told how far it has come as it goes.
    func pngData(_ snapshot: ProjectSnapshot, progress: (@Sendable (Progress) -> Void)? = nil) throws -> Data {
        let raster = try render(snapshot, progress: progress)
        progress?(.encoding)
        let encoding = Timing.begin("Encode PNG")
        let data = try encode(raster.image, type: .png, properties: [
            kCGImagePropertyDPIWidth: raster.resolution, kCGImagePropertyDPIHeight: raster.resolution
        ] as CFDictionary)
        Timing.end(encoding, Timing.bytes(data.count))
        return data
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

    /// `raster` over the options' color and encoded as JPEG at their quality, with a preview of it decoded. `progress` is
    /// told as it encodes.
    func jpeg(_ raster: ExportRaster, options: JPEGOptions, progress: (@Sendable (Progress) -> Void)? = nil) throws -> JPEGResult {
        try Task.checkCancellation()
        progress?(.encoding)
        let encoding = Timing.begin("Encode JPEG")
        let result = try autoreleasepool {
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
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    // Full size, so the dialog's 100% view shows the real artifacts; capped to keep memory in bounds.
                    kCGImageSourceThumbnailMaxPixelSize: min(max(image.width, image.height), 8192),
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { throw ExportError.encode }
            return JPEGResult(data: data, preview: preview)
        }
        Timing.end(encoding, "quality \(Int((options.quality * 100).rounded()))%, \(Timing.bytes(result.data.count))")
        return result
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

nonisolated struct QuickLookImages: Sendable {
    let preview: Data
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
nonisolated struct JPEGResult: @unchecked Sendable {
    let data: Data
    let preview: CGImage
}
