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
        guard (1...DocumentLimits.maxSide).contains(options.width), (1...DocumentLimits.maxSide).contains(options.height),
              options.resolution.isFinite, (1...9600).contains(options.resolution) else { throw ProjectError.tooLarge }
        let old = snapshot.manifest
        var manifest = ProjectManifest(resolution: options.resolution, documentID: old.documentID,
            width: options.width, height: options.height, activeLayerID: old.activeLayerID, layers: [],
            guides: old.guides)
        if old.width == options.width && old.height == options.height {
            manifest.layers = old.layers
            return ProjectSnapshot(manifest: manifest, images: snapshot.images, masks: snapshot.masks,
                                   animations: snapshot.animations)
        }
        guard options.width * options.height <= DocumentLimits.maxSurfacePixels else { throw ProjectError.tooLarge }
        let sx = CGFloat(options.width) / CGFloat(old.width)
        let sy = CGFloat(options.height) / CGFloat(old.height)
        // Effects are sized in pixels, so they scale with the pixels, as Photoshop's Scale Styles does: by the mean of
        // the two factors when the image is stretched. Live text and shapes are resampled into plain pixels.
        let effectScale = (sx * sy).squareRoot()
        manifest.guides = old.guides?.map { $0.scaled(x: sx, y: sy) }
        var images: [UUID: ImportedImage] = [:]
        var masks: [UUID: ImportedImage] = [:]
        var animations = snapshot.animations
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
                guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height),
                      width * height <= DocumentLimits.documentPixelBudget - usedPixels else { throw ProjectError.tooLarge }
                usedPixels += width * height
                guard let source = snapshot.images[layer.id] else { throw ProjectError.missingImage }
                images[layer.id] = try resizedImage(source, from: layer.transform, to: transform, scaleX: sx, scaleY: sy)
            }
            if layer.maskFile != nil {
                guard let source = snapshot.masks[layer.id] else { throw ProjectError.missingImage }
                masks[layer.id] = try resizedMask(source, placement: layer.maskPlacement, from: layer.transform,
                    to: transform, scaleX: sx, scaleY: sy, usedPixels: &usedMaskPixels)
            }
            var gif = layer.gif
            if let animation = snapshot.animations[layer.id] {
                var resized = animation.resizing(from: layer.transform, to: transform, scaleX: sx, scaleY: sy)
                for (index, source) in animation.framePixels {
                    guard width * height <= DocumentLimits.documentPixelBudget - usedPixels else { throw ProjectError.tooLarge }
                    usedPixels += width * height
                    resized.framePixels[index] = try resizedImage(source, from: layer.transform, to: transform, scaleX: sx, scaleY: sy)
                }
                guard resized.geometry?.isValid == true else { throw ProjectError.tooLarge }
                animations[layer.id] = resized
                gif?.geometry = resized.geometry
            }
            manifest.layers.append(ProjectLayerRecord(id: layer.id, name: layer.name, isVisible: layer.isVisible,
                transform: transform, imageFile: layer.imageFile, parentID: layer.parentID, isGroup: layer.isGroup, opacity: layer.opacity, blendMode: layer.blendMode, maskFile: layer.maskFile, maskEnabled: layer.maskEnabled, maskSourceID: layer.maskSourceID, adjustment: layer.adjustment,
                maskPlacement: layer.maskPlacement.map { $0.placing($0.unitToDocument.concatenating(CGAffineTransform(scaleX: sx, y: sy))) },
                maskLinked: layer.maskLinked, effects: layer.effects?.scaled(by: effectScale), gif: gif))
        }
        return ProjectSnapshot(manifest: manifest, images: images, masks: masks, animations: animations)
    }

    private func resizedImage(_ source: ImportedImage, from original: LayerTransform, to transform: LayerTransform,
                              scaleX: CGFloat, scaleY: CGFloat) throws -> ImportedImage {
        try autoreleasepool {
            let width = Int(transform.size.width), height = Int(transform.size.height)
            let deep = try DeepLayer.flattened(source)
            let context = try deep.map { try DeepLayer.context(width: width, height: height, hdr: DeepLayer.isHDR($0)) }
                ?? BrushRaster.context(width: width, height: height, mask: false)
            context.translateBy(x: -transform.origin.x, y: -transform.origin.y)
            context.scaleBy(x: scaleX, y: scaleY)
            var sourceTransform = original
            sourceTransform.sampling = transform.sampling
            LayerRenderer.draw(deep ?? source.image, transform: sourceTransform, center: sourceTransform.center, in: context)
            guard let image = context.makeImage() else { throw ExportError.render }
            if deep != nil { return try DeepLayer.asset(image, name: source.name) }
            return ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: source.name)
        }
    }

    private func resizedMask(_ source: ImportedImage, placement: LayerTransform?, from original: LayerTransform,
                             to transform: LayerTransform, scaleX: CGFloat, scaleY: CGFloat,
                             usedPixels: inout Int) throws -> ImportedImage {
        // Uniform masks are resolution independent. Placed masks keep their pixels while their placement scales.
        let keepsPixels = (source.image.width == 1 && source.image.height == 1) || placement != nil
        let width = keepsPixels ? source.image.width : Int(transform.size.width)
        let height = keepsPixels ? source.image.height : Int(transform.size.height)
        guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height),
              width * height <= DocumentLimits.documentPixelBudget - usedPixels else { throw ProjectError.tooLarge }
        usedPixels += width * height
        if keepsPixels { return source }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw ExportError.render }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -transform.origin.x, y: -transform.origin.y)
        context.scaleBy(x: scaleX, y: scaleY)
        var sourceTransform = original
        sourceTransform.sampling = transform.sampling
        LayerRenderer.drawCoverage(source.image, transform: sourceTransform, in: context)
        guard let image = context.makeImage() else { throw ExportError.render }
        return try LayerMask.asset(from: image)
    }
}

extension EditorSession {
    /// Keeps the zoom, so the image visibly grows or shrinks on screen; fitting it to the window again made a resize
    /// look like nothing had happened. Canvas Size keeps it too, for the same reason.
    func applyImageSize(_ snapshot: ProjectSnapshot) {
        applyDocumentSize(snapshot, actionName: "Image Size", keepingZoom: true)
    }

    func applyDocumentSize(_ snapshot: ProjectSnapshot, actionName: String, keepingZoom: Bool = false) {
        guard document?.id == snapshot.manifest.documentID else { return }
        beginEdit(actionName)
        let m = snapshot.manifest
        document = CanvasDocument(id: m.documentID, width: m.width, height: m.height,
            layers: snapshot.documentLayers, resolution: m.resolution ?? 72, guides: m.guides ?? [])
        endEdit()
        if keepingZoom { viewport.recenter() } else { viewport.fit(documentSize: document!.size) }
    }
}
