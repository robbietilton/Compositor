import Foundation
import CoreGraphics

actor CanvasResizer {
    static let shared = CanvasResizer()

    func resize(_ snapshot: ProjectSnapshot, to options: CanvasSizeOptions) throws -> ProjectSnapshot {
        guard (1...DocumentLimits.maxSide).contains(options.width), (1...DocumentLimits.maxSide).contains(options.height),
              (0...8).contains(options.anchor) else { throw ProjectError.tooLarge }
        let old = snapshot.manifest
        let offset = options.offset(fromWidth: old.width, height: old.height)
        guard offset.x.isFinite, offset.y.isFinite, abs(offset.x) <= 1_000_000, abs(offset.y) <= 1_000_000 else {
            throw ProjectError.invalid
        }
        guard options.width != old.width || options.height != old.height || offset != .zero else { return snapshot }
        var manifest = ProjectManifest(resolution: old.resolution, documentID: old.documentID,
            width: options.width, height: options.height, activeLayerID: old.activeLayerID, layers: [],
            guides: old.guides?.map { $0.offset(x: offset.x, y: offset.y) })
        for layer in old.layers {
            var transform = layer.transform
            transform.origin.x += offset.x
            transform.origin.y += offset.y
            guard transform.isValid else { throw ProjectError.tooLarge }
            manifest.layers.append(ProjectLayerRecord(id: layer.id, name: layer.name,
                isVisible: layer.isVisible, transform: transform, imageFile: layer.imageFile, parentID: layer.parentID, isGroup: layer.isGroup, opacity: layer.opacity, blendMode: layer.blendMode, maskFile: layer.maskFile, maskEnabled: layer.maskEnabled, maskSourceID: layer.maskSourceID, adjustment: layer.adjustment,
                maskPlacement: layer.maskPlacement.map { placement -> LayerTransform in
                    var moved = placement
                    moved.origin.x += offset.x
                    moved.origin.y += offset.y
                    return moved
                }, maskLinked: layer.maskLinked, shape: layer.shape, text: layer.text))
        }
        var images = snapshot.images
        // A colored extension is separate bottom-layer content. The old canvas
        // intersection remains transparent, including holes in the existing artwork.
        if let color = options.fill, options.width > old.width || options.height > old.height {
            let used = images.values.reduce(0) { $0 + $1.image.width * $1.image.height }
            guard options.width * options.height <= DocumentLimits.documentPixelBudget - used,
                  manifest.layers.count < 10_000 else { throw ProjectError.tooLarge }
            guard [color.red, color.green, color.blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                throw ProjectError.invalid
            }
            let asset = try autoreleasepool {
                let space = CGColorSpace(name: CGColorSpace.sRGB)!
                guard let context = CGContext(data: nil, width: options.width, height: options.height,
                    bitsPerComponent: 8, bytesPerRow: options.width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ExportError.render }
                context.translateBy(x: 0, y: CGFloat(options.height))
                context.scaleBy(x: 1, y: -1)
                context.setFillColor(CGColor(colorSpace: space, components: [color.red, color.green, color.blue, 1])!)
                context.fill(CGRect(x: 0, y: 0, width: options.width, height: options.height))
                context.clear(CGRect(origin: offset, size: CGSize(width: old.width, height: old.height)))
                guard let image = context.makeImage() else { throw ExportError.render }
                let factor = min(1, 96 / CGFloat(max(options.width, options.height)))
                let tw = max(1, Int(CGFloat(options.width) * factor)), th = max(1, Int(CGFloat(options.height) * factor))
                guard let thumb = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8,
                    bytesPerRow: tw * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    throw ExportError.render
                }
                thumb.interpolationQuality = .high
                thumb.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
                guard let thumbnail = thumb.makeImage() else { throw ExportError.render }
                return ImportedImage(image: image, thumbnail: thumbnail, name: "Canvas Extension")
            }
            let id = UUID()
            images[id] = asset
            manifest.layers.insert(ProjectLayerRecord(id: id, name: "Canvas Extension", isVisible: true,
                transform: LayerTransform(origin: .zero, size: CGSize(width: options.width, height: options.height)),
                imageFile: "\(id.uuidString).png"), at: 0)
        }
        return ProjectSnapshot(manifest: manifest, images: images, masks: snapshot.masks)
    }
}
