import Foundation
import CoreGraphics

nonisolated struct ImageSizeOptions: Sendable {
    var width: Int
    var height: Int
    var resolution: Double
    var sampling: LayerSampling = .high
}

actor ImageResizer {
    static let shared = ImageResizer()

    func resize(_ snapshot: ProjectSnapshot, to options: ImageSizeOptions) throws -> ProjectSnapshot {
        guard (1...30_000).contains(options.width), (1...30_000).contains(options.height),
              options.resolution.isFinite, (1...9600).contains(options.resolution) else { throw ProjectError.tooLarge }
        let old = snapshot.manifest
        var manifest = ProjectManifest(resolution: options.resolution, documentID: old.documentID,
            width: options.width, height: options.height, activeLayerID: old.activeLayerID, layers: [])
        if old.width == options.width && old.height == options.height {
            manifest.layers = old.layers
            return ProjectSnapshot(manifest: manifest, images: snapshot.images, masks: snapshot.masks)
        }
        guard options.width * options.height <= 100_000_000 else { throw ProjectError.tooLarge }
        let sx = CGFloat(options.width) / CGFloat(old.width)
        let sy = CGFloat(options.height) / CGFloat(old.height)
        var images: [UUID: ImportedImage] = [:]
        var masks: [UUID: ImportedImage] = [:]
        var usedPixels = 0, usedMaskPixels = 0
        for layer in old.layers {
            try Task.checkCancellation()
            // Rasterize each transformed layer independently. Nonuniform scaling of a
            // rotated rectangle can introduce shear, which width/height/angle cannot represent.
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
                .map { layer.transform.point($0) }.map { CGPoint(x: $0.x * sx, y: $0.y * sy) }
            let left = floor(corners.map(\.x).min()!), top = floor(corners.map(\.y).min()!)
            let width = Int(ceil(corners.map(\.x).max()!) - left)
            let height = Int(ceil(corners.map(\.y).max()!) - top)
            let transform = LayerTransform(origin: CGPoint(x: left, y: top),
                size: CGSize(width: width, height: height), sampling: options.sampling)
            guard transform.isValid else { throw ProjectError.tooLarge }
            if layer.imageFile != nil {
                guard (1...30_000).contains(width), (1...30_000).contains(height),
                      width * height <= 100_000_000 - usedPixels else { throw ProjectError.tooLarge }
                usedPixels += width * height
                guard let source = snapshot.images[layer.id] else { throw ProjectError.missingImage }
                let asset = try autoreleasepool {
                    guard let context = CGContext(data: nil, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ExportError.render }
                    context.translateBy(x: 0, y: CGFloat(height))
                    context.scaleBy(x: 1, y: -1)
                    context.translateBy(x: -left, y: -top)
                    context.scaleBy(x: sx, y: sy)
                    var sourceTransform = layer.transform
                    sourceTransform.sampling = options.sampling
                    LayerRenderer.draw(source.image, transform: sourceTransform, center: sourceTransform.center, in: context)
                    guard let image = context.makeImage() else { throw ExportError.render }
                    let factor = min(1, 96 / CGFloat(max(width, height)))
                    let tw = max(1, Int(CGFloat(width) * factor)), th = max(1, Int(CGFloat(height) * factor))
                    guard let thumb = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8,
                        bytesPerRow: tw * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ExportError.render }
                    thumb.interpolationQuality = .high
                    thumb.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
                    guard let thumbnail = thumb.makeImage() else { throw ExportError.render }
                    return ImportedImage(image: image, thumbnail: thumbnail, name: source.name)
                }
                images[layer.id] = asset
            }
            if layer.maskFile != nil {
                guard let source = snapshot.masks[layer.id] else { throw ProjectError.missingImage }
                // Uniform masks are resolution independent; avoid allocating a full canvas for reveal/hide-all.
                // A mask on its own placement keeps its pixels; the placement scales with the canvas.
                if (source.image.width == 1 && source.image.height == 1) || layer.maskPlacement != nil { masks[layer.id] = source }
                else {
                    guard (1...30_000).contains(width), (1...30_000).contains(height),
                          width * height <= 100_000_000 - usedMaskPixels else { throw ProjectError.tooLarge }
                    usedMaskPixels += width * height
                    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw ExportError.render }
                    context.translateBy(x: 0, y: CGFloat(height))
                    context.scaleBy(x: 1, y: -1)
                    context.translateBy(x: -left, y: -top)
                    context.scaleBy(x: sx, y: sy)
                    var sourceTransform = layer.transform
                    sourceTransform.sampling = options.sampling
                    LayerRenderer.drawCoverage(source.image, transform: sourceTransform, in: context)
                    guard let image = context.makeImage() else { throw ExportError.render }
                    masks[layer.id] = try LayerMask.asset(from: image)
                }
            }
            manifest.layers.append(ProjectLayerRecord(id: layer.id, name: layer.name, isVisible: layer.isVisible,
                transform: transform, imageFile: layer.imageFile, parentID: layer.parentID, isGroup: layer.isGroup, opacity: layer.opacity, blendMode: layer.blendMode, maskFile: layer.maskFile, maskEnabled: layer.maskEnabled, maskSourceID: layer.maskSourceID, adjustment: layer.adjustment,
                maskPlacement: layer.maskPlacement.map { $0.placing($0.unitToDocument.concatenating(CGAffineTransform(scaleX: sx, y: sy))) },
                maskLinked: layer.maskLinked, shape: layer.shape, text: layer.text))
        }
        return ProjectSnapshot(manifest: manifest, images: images, masks: masks)
    }
}

extension EditorSession {
    func applyImageSize(_ snapshot: ProjectSnapshot) {
        applyDocumentSize(snapshot, actionName: "Image Size")
    }

    func applyDocumentSize(_ snapshot: ProjectSnapshot, actionName: String) {
        guard document?.id == snapshot.manifest.documentID else { return }
        beginEdit(actionName)
        let m = snapshot.manifest
        document = CanvasDocument(id: m.documentID, width: m.width, height: m.height,
            layers: m.layers.map { ImageLayer(id: $0.id, asset: snapshot.images[$0.id], name: $0.name,
                isVisible: $0.isVisible, transform: $0.transform, parentID: $0.parentID, isGroup: $0.isGroup == true, opacity: $0.opacity ?? 1, blendMode: $0.blendMode ?? .normal, mask: snapshot.mask(for: $0), maskSourceID: $0.maskSourceID, adjustment: $0.adjustment,
                shape: LayerShape.loaded($0.shape, image: snapshot.images[$0.id]?.image),
                text: LayerText.loaded($0.text, image: snapshot.images[$0.id]?.image)) }, resolution: m.resolution ?? 72)
        endEdit()
        viewport.fit(documentSize: document!.size)
    }
}
