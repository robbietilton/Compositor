import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ExportError: LocalizedError {
    case tooLarge, render, encode
    var errorDescription: String? {
        switch self {
        case .tooLarge: String(localized: "Image export supports canvases up to \(DocumentLimits.maxSurfaceMegapixels) megapixels and \(DocumentLimits.maxSide.formatted()) pixels per side.")
        case .render: localized("The canvas could not be rendered. Try a smaller canvas.")
        case .encode: localized("The image could not be encoded.")
        }
    }
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

    func jpeg(_ raster: ExportRaster, options: JPEGOptions) throws -> JPEGResult {
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
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1000,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { throw ExportError.encode }
            return JPEGResult(data: data, preview: preview)
        }
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
nonisolated struct JPEGResult: @unchecked Sendable {
    let data: Data
    let preview: CGImage
}
