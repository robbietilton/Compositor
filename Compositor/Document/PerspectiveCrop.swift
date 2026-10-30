import CoreGraphics
import CoreImage

/// Perspective Crop (the Crop tool's Perspective switch): four corners placed freely, and Apply takes what lies
/// inside them to an upright rectangle, so a document, sign or painting photographed at an angle comes out square.
/// Every layer is resampled through the same perspective, as Image Size resamples them: live text and shapes become
/// plain pixels, and layers without pixels (folders, adjustments) cover the new canvas.
nonisolated enum PerspectiveCrop {
    enum Failure: LocalizedError {
        case animation
        var errorDescription: String? { "Perspective Crop can’t resample an animated GIF layer. Crop it with the frame instead." }
    }

    /// Corners (handle order: top-left, top-right, bottom-right, bottom-left) a perspective can take upright: convex,
    /// and wound the way they are listed, so the result isn't mirrored.
    static func isUpright(_ corners: [CGPoint]) -> Bool {
        guard DistortWarp.isConvex(corners) else { return false }
        let a = corners[0], b = corners[1], c = corners[2]
        return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x) > 0
    }

    /// The upright size: the mean of each pair of opposite sides, in whole pixels.
    static func size(of corners: [CGPoint]) -> CGSize? {
        guard isUpright(corners) else { return nil }
        func length(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(b.x - a.x, b.y - a.y) }
        let width = ((length(corners[0], corners[1]) + length(corners[3], corners[2])) / 2).rounded()
        let height = ((length(corners[0], corners[3]) + length(corners[1], corners[2])) / 2).rounded()
        guard width >= 1, height >= 1, width <= DocumentLimits.maxSideExtent, height <= DocumentLimits.maxSideExtent,
              width * height <= DocumentLimits.maxSurfaceExtent else { return nil }
        return CGSize(width: width, height: height)
    }

    static func crop(_ snapshot: ProjectSnapshot, corners: [CGPoint]) throws -> ProjectSnapshot {
        guard let size = size(of: corners) else { throw ProjectError.invalid }
        let old = snapshot.manifest
        guard !old.layers.contains(where: { $0.gif != nil }) else { throw Failure.animation }
        // Only what lies inside the corners survives, so each layer is drawn over their bounds and no further.
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let minX = floor(xs.min()!), minY = floor(ys.min()!)
        let bounds = CGRect(x: minX, y: minY, width: ceil(xs.max()!) - minX, height: ceil(ys.max()!) - minY)
        guard bounds.width <= DocumentLimits.maxSideExtent, bounds.height <= DocumentLimits.maxSideExtent,
              bounds.width * bounds.height <= DocumentLimits.maxSurfaceExtent else { throw ProjectError.tooLarge }
        let width = Int(size.width), height = Int(size.height)
        let canvas = LayerTransform(origin: .zero, size: size)
        var manifest = ProjectManifest(resolution: old.resolution, documentID: old.documentID, width: width, height: height,
                                       activeLayerID: old.activeLayerID, layers: [])
        var images: [UUID: ImportedImage] = [:]
        var masks: [UUID: ImportedImage] = [:]
        var usedPixels = 0, usedMaskPixels = 0
        for layer in old.layers {
            try Task.checkCancellation()
            var transform = LayerTransform(origin: .zero, size: size, sampling: layer.transform.sampling)
            // The part of the upright image a linked mask is cropped to along with its layer.
            var crop = CGRect(origin: .zero, size: size)
            if layer.imageFile != nil {
                guard let source = snapshot.images[layer.id] else { throw ProjectError.missingImage }
                let upright = try uprightImage(source, transform: layer.transform, bounds: bounds, corners: corners, size: size)
                crop = upright.crop
                guard Int(crop.width) * Int(crop.height) <= DocumentLimits.documentPixelBudget - usedPixels else { throw ProjectError.tooLarge }
                usedPixels += Int(crop.width) * Int(crop.height)
                images[layer.id] = upright.asset
                transform.origin = crop.origin
                transform.size = crop.size
            }
            var placement: LayerTransform?
            if layer.maskFile != nil {
                guard let source = snapshot.masks[layer.id] else { throw ProjectError.missingImage }
                // A uniform mask looks the same wherever it sits.
                if source.image.width == 1, source.image.height == 1 {
                    masks[layer.id] = source
                } else {
                    guard width * height <= DocumentLimits.documentPixelBudget - usedMaskPixels else { throw ProjectError.tooLarge }
                    usedMaskPixels += width * height
                    let mask = try uprightMask(source, placement: layer.maskPlacement ?? layer.transform,
                        background: layer.maskPlacement == nil ? 0 : LayerMask.background(of: source.thumbnail),
                        bounds: bounds, corners: corners, size: size)
                    // A linked mask covering its layer is cropped with it; any other covers the new canvas.
                    if layer.maskPlacement == nil, layer.maskLinked != false {
                        guard let cropped = mask.cropping(to: crop) else { throw ExportError.render }
                        masks[layer.id] = try LayerMask.asset(from: cropped)
                    } else {
                        masks[layer.id] = try LayerMask.asset(from: mask)
                        placement = canvas
                    }
                }
            }
            manifest.layers.append(ProjectLayerRecord(id: layer.id, name: layer.name, isVisible: layer.isVisible,
                transform: transform, imageFile: layer.imageFile, parentID: layer.parentID, isGroup: layer.isGroup, opacity: layer.opacity, blendMode: layer.blendMode, maskFile: layer.maskFile, maskEnabled: layer.maskEnabled, maskSourceID: layer.maskSourceID, adjustment: layer.adjustment,
                maskPlacement: placement, maskLinked: layer.maskLinked, effects: layer.effects))
        }
        return ProjectSnapshot(manifest: manifest, images: images, masks: masks, animations: snapshot.animations)
    }

    /// What lies inside `corners` of a raster drawn over `bounds` (document points, top-left origin), taken upright
    /// to `size`. Core Image samples back from each output pixel into the shape, so it holds even when the shape's
    /// vanishing point falls inside the picture, where warping the layer's own corners forward would not.
    private static func upright(_ raster: CGImage, bounds: CGRect, corners: [CGPoint], size: CGSize) -> CIImage {
        // Core Image measures y upward from the bottom of the raster.
        func vector(_ point: CGPoint) -> CIVector { CIVector(x: point.x - bounds.minX, y: bounds.maxY - point.y) }
        let corrected = CIImage(cgImage: raster).applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": vector(corners[0]), "inputTopRight": vector(corners[1]),
            "inputBottomRight": vector(corners[2]), "inputBottomLeft": vector(corners[3]), "inputCrop": true,
        ])
        // Its own size estimate isn't the one asked for (a trapezoid comes out much taller), so it's scaled to it.
        let extent = corrected.extent
        return corrected.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            .concatenating(CGAffineTransform(scaleX: size.width / extent.width, y: size.height / extent.height)))
    }

    /// A layer's pixels taken upright and trimmed to what's visible, with where the trim sits in the upright image.
    /// A 16-bit layer stays 16-bit (`DeepLayer`).
    private static func uprightImage(_ source: ImportedImage, transform: LayerTransform, bounds: CGRect, corners: [CGPoint],
                                     size: CGSize) throws -> (asset: ImportedImage, crop: CGRect) {
        try autoreleasepool {
            let deep = try DeepLayer.flattened(source)
            let hdr = deep.map(DeepLayer.isHDR) ?? false
            let context = try deep.map { _ in try DeepLayer.context(width: Int(bounds.width), height: Int(bounds.height), hdr: hdr) }
                ?? BrushRaster.context(width: Int(bounds.width), height: Int(bounds.height), mask: false)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            LayerRenderer.draw(deep ?? source.image, transform: transform, center: transform.center, in: context)
            guard let raster = context.makeImage() else { throw ExportError.render }
            let image = upright(raster, bounds: bounds, corners: corners, size: size)
            let width = Int(size.width), height = Int(size.height)
            let full = deep == nil ? try PixelAdjust.render(image, width: width, height: height, isMask: false)
                                   : try DeepLayer.render(image, width: width, height: height, hdr: hdr)
            let crop = try visibleBounds(of: full) ?? CGRect(x: 0, y: 0, width: width, height: height)
            guard let cropped = full.cropping(to: crop) else { throw ExportError.render }
            let asset = deep == nil ? ImportedImage(image: cropped, thumbnail: try PixelAdjust.thumbnail(of: cropped), name: source.name)
                                    : try DeepLayer.asset(cropped, name: source.name)
            return (asset, crop)
        }
    }

    /// A mask taken upright over the whole new canvas. Beyond its own pixels it shows `background`, as a mask placed
    /// apart from its layer does.
    private static func uprightMask(_ source: ImportedImage, placement: LayerTransform, background: CGFloat,
                                    bounds: CGRect, corners: [CGPoint], size: CGSize) throws -> CGImage {
        try autoreleasepool {
            let context = try BrushRaster.context(width: Int(bounds.width), height: Int(bounds.height), mask: true)
            context.setFillColor(gray: background, alpha: 1)
            context.fill(CGRect(origin: .zero, size: bounds.size))
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            // Its own rectangle starts black, so the background shows only beyond it.
            let shape = CGMutablePath()
            shape.addLines(between: DistortWarp.corners(of: placement))
            shape.closeSubpath()
            context.addPath(shape)
            context.setFillColor(gray: 0, alpha: 1)
            context.fillPath()
            LayerRenderer.drawCoverage(source.image, transform: placement, in: context)
            guard let raster = context.makeImage() else { throw ExportError.render }
            return try PixelAdjust.render(upright(raster, bounds: bounds, corners: corners, size: size),
                                          width: Int(size.width), height: Int(size.height), isMask: true)
        }
    }

    /// The bounds of `image`'s pixels that aren't fully transparent; nil when none are.
    private static func visibleBounds(of image: CGImage) throws -> CGRect? {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        guard let data = context.data else { throw ExportError.render }
        var edges = [Int](repeating: 0, count: 4)
        brush_alpha_bounds(data.assumingMemoryBound(to: UInt8.self), image.width, image.height, context.bytesPerRow, &edges)
        let rect = CGRect(x: edges[0], y: edges[1], width: edges[2] - edges[0], height: edges[3] - edges[1])
        return rect.width >= 1 && rect.height >= 1 ? rect : nil
    }
}

extension EditorSession {
    /// The Perspective switch's corners while the Crop tool is out: the frame's own corners until one is dragged.
    var visibleCropCorners: [CGPoint]? {
        guard cropPerspective, let rect = visibleCropRect else { return nil }
        return cropCorners ?? [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                               CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    /// Moves the corners; a shape no perspective can take upright (folded, mirrored, or too large) is ignored.
    /// The frame follows their bounds, so everything that waits on a crop in progress still sees one.
    func setCropCorners(_ corners: [CGPoint]) {
        guard PerspectiveCrop.size(of: corners) != nil else { return }
        cropCorners = corners
        let xs = corners.map(\.x), ys = corners.map(\.y)
        cropRect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// Turning Perspective off keeps the corners' bounds as an ordinary frame.
    func setCropPerspective(_ isOn: Bool) {
        if !isOn, cropCorners != nil, let rect = cropRect {
            let snapped = CropGeometry.snapped(rect)
            cropRect = CropGeometry.valid(snapped) ? snapped : nil
        }
        cropCorners = nil
        cropPerspective = isOn
    }

    func commitPerspectiveCrop(_ corners: [CGPoint]) async {
        guard canStartProjectOperation, let snapshot = projectSnapshot() else { return }
        isProjectBusy = true
        defer { isProjectBusy = false }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try PerspectiveCrop.crop(snapshot, corners: corners)
            }.value
            cropRect = nil
            cropCorners = nil
            applyDocumentSize(result, actionName: "Perspective Crop")
        } catch { cropError = error.localizedDescription }
    }
}
