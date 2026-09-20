import AppKit
import CoreImage

/// Free distortion (Cmd-drag a transform handle): the layer's four corners move independently.
/// Layer transforms are affine, so a distortion is previewed live and, on Apply, the pixels (and
/// mask) are resampled into the new shape — as Photoshop does for pixel layers — leaving an
/// ordinary axis-aligned layer over the shape's bounds.
nonisolated enum DistortWarp {
    /// The transform's corners in handle order: top-left, top-right, bottom-right, bottom-left.
    static func corners(of transform: LayerTransform) -> [CGPoint] {
        [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)].map(transform.point)
    }

    /// Four finite corners making a convex, non-degenerate shape; a twisted (bow-tie) or collapsed
    /// shape has no sensible warp and is refused.
    static func isUsable(_ corners: [CGPoint]) -> Bool {
        guard corners.count == 4,
              corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1_000_000 && abs($0.y) <= 1_000_000 }) else { return false }
        var sign: CGFloat = 0
        for index in 0..<4 {
            let a = corners[index], b = corners[(index + 1) % 4], c = corners[(index + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            guard abs(cross) > 0.01 else { return false }
            if sign == 0 { sign = cross < 0 ? -1 : 1 } else if (cross < 0) != (sign < 0) { return false }
        }
        return true
    }

    /// The perspective mapping of the unit square (corners in `corners(of:)` order) onto `c`.
    static func homography(_ c: [CGPoint]) -> (CGPoint) -> CGPoint {
        let sx = c[0].x - c[1].x + c[2].x - c[3].x, sy = c[0].y - c[1].y + c[2].y - c[3].y
        var g: CGFloat = 0, h: CGFloat = 0
        if abs(sx) > 1e-9 || abs(sy) > 1e-9 {
            let dx1 = c[1].x - c[2].x, dx2 = c[3].x - c[2].x, dy1 = c[1].y - c[2].y, dy2 = c[3].y - c[2].y
            let den = dx1 * dy2 - dx2 * dy1
            if abs(den) > 1e-12 {
                g = (sx * dy2 - dx2 * sy) / den
                h = (dx1 * sy - sx * dy1) / den
            }
        }
        let a = c[1].x - c[0].x + g * c[1].x, b = c[3].x - c[0].x + h * c[3].x, x0 = c[0].x
        let d = c[1].y - c[0].y + g * c[1].y, e = c[3].y - c[0].y + h * c[3].y, y0 = c[0].y
        return { p in
            let w = g * p.x + h * p.y + 1
            return CGPoint(x: (a * p.x + b * p.y + x0) / w, y: (d * p.x + e * p.y + y0) / w)
        }
    }

    /// Where each corner of the image's own pixels lands: a flipped layer shows its pixels
    /// mirrored, so they go to the opposite corners of the shape.
    private static func imageCorners(_ corners: [CGPoint], flipX: Bool, flipY: Bool)
        -> (topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        func corner(_ x: Int, _ y: Int) -> CGPoint {
            let u = flipX ? 1 - x : x, v = flipY ? 1 - y : y
            return corners[[0, 1, 3, 2][v * 2 + u]]
        }
        return (corner(0, 0), corner(1, 0), corner(1, 1), corner(0, 1))
    }

    /// `image`, shown through `transform`, resampled so its corners land on `corners`. Returns the
    /// warped pixels over the shape's whole-pixel bounds and the axis-aligned transform for them.
    /// `limit` caps the longest side for previews.
    static func warp(_ image: CGImage, transform: LayerTransform, corners: [CGPoint], isMask: Bool,
                     limit: CGFloat? = nil) throws -> (image: CGImage, transform: LayerTransform) {
        guard isUsable(corners) else { throw ProjectError.invalid }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let minX = floor(xs.min()!), minY = floor(ys.min()!)
        let bounds = CGRect(x: minX, y: minY, width: ceil(xs.max()!) - minX, height: ceil(ys.max()!) - minY)
        guard bounds.width >= 1, bounds.height >= 1, bounds.width <= 30_000, bounds.height <= 30_000,
              bounds.width * bounds.height <= 100_000_000 else { throw ProjectError.tooLarge }
        let placed = LayerTransform(origin: bounds.origin, size: bounds.size, sampling: transform.sampling)
        // A uniform 1 × 1 mask already covers any shape.
        if isMask, image.width == 1, image.height == 1 { return (image, placed) }
        let factor = limit.map { min(1, $0 / max(bounds.width, bounds.height)) } ?? 1
        let width = max(1, Int((bounds.width * factor).rounded(.up)))
        let height = max(1, Int((bounds.height * factor).rounded(.up)))
        let target = imageCorners(corners, flipX: transform.flipX, flipY: transform.flipY)
        // Core Image measures y upward from the bottom of the output.
        func vector(_ point: CGPoint) -> CIVector {
            CIVector(x: (point.x - bounds.minX) * factor, y: (bounds.maxY - point.y) * factor)
        }
        let warped = CIImage(cgImage: image).applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": vector(target.topLeft), "inputTopRight": vector(target.topRight),
            "inputBottomRight": vector(target.bottomRight), "inputBottomLeft": vector(target.bottomLeft),
        ])
        return (try PixelAdjust.render(warped, width: width, height: height, isMask: isMask), placed)
    }

    /// A full-resolution warp cropped to its visible pixels. A distorted shape rarely fills its
    /// bounding box — and a brush stroke never does — so the layer (and its transform handles)
    /// should hug what is actually there. `crop` is in the warp's pixels, for cropping a mask to match.
    static func warpTrimmed(_ image: CGImage, transform: LayerTransform, corners: [CGPoint])
        throws -> (image: CGImage, transform: LayerTransform, crop: CGRect) {
        let warped = try warp(image, transform: transform, corners: corners, isMask: false)
        let full = CGRect(x: 0, y: 0, width: warped.image.width, height: warped.image.height)
        let context = try BrushRaster.context(width: warped.image.width, height: warped.image.height, mask: false)
        BrushRaster.draw(warped.image, in: full, mask: false, context: context)
        guard let data = context.data else { throw ExportError.render }
        var edges = [Int](repeating: 0, count: 4)
        brush_alpha_bounds(data.assumingMemoryBound(to: UInt8.self), warped.image.width, warped.image.height, context.bytesPerRow, &edges)
        let crop = CGRect(x: edges[0], y: edges[1], width: edges[2] - edges[0], height: edges[3] - edges[1])
        // Nothing visible, or nothing to trim: keep the warp as it is.
        guard crop.width >= 1, crop.height >= 1, crop != full, let cropped = warped.image.cropping(to: crop) else {
            return (warped.image, warped.transform, full)
        }
        var placed = warped.transform
        placed.origin = CGPoint(x: placed.origin.x + crop.minX, y: placed.origin.y + crop.minY)
        placed.size = crop.size
        return (cropped, placed, crop)
    }

    /// Where `placement`'s corners (handle order) land when the perspective taking `transform`'s corners to `corners`
    /// is applied around it too — how a linked mask placed apart from its layer distorts with the layer.
    static func carried(_ placement: LayerTransform, by transform: LayerTransform, to corners: [CGPoint]) -> [CGPoint] {
        let toUnit = CGAffineTransform(translationX: -0.5, y: -0.5)
            .concatenating(CGAffineTransform(scaleX: transform.size.width, y: transform.size.height))
            .concatenating(CGAffineTransform(rotationAngle: transform.radians))
            .concatenating(CGAffineTransform(translationX: transform.center.x, y: transform.center.y)).inverted()
        let map = homography(corners)
        return self.corners(of: placement).map { map($0.applying(toUnit)) }
    }

    /// A mask warped like `warp`, but `background` (its tone past its pixels) outside the shape instead of black —
    /// for masks placed apart from their layers, which show beyond their own bounds.
    static func warpMask(_ image: CGImage, transform: LayerTransform, corners: [CGPoint], background: CGFloat,
                         limit: CGFloat? = nil) throws -> (image: CGImage, transform: LayerTransform) {
        let warped = try warp(image, transform: transform, corners: corners, isMask: true, limit: limit)
        guard background > 0, warped.image !== image else { return warped }
        let width = warped.image.width, height = warped.image.height
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        let context = try BrushRaster.context(width: width, height: height, mask: true)
        context.setFillColor(gray: background, alpha: 1)
        context.fill(full)
        let sx = CGFloat(width) / warped.transform.size.width, sy = CGFloat(height) / warped.transform.size.height
        let shape = CGMutablePath()
        shape.addLines(between: corners.map { CGPoint(x: ($0.x - warped.transform.origin.x) * sx, y: ($0.y - warped.transform.origin.y) * sy) })
        shape.closeSubpath()
        context.addPath(shape)
        context.clip()
        BrushRaster.draw(warped.image, in: full, mask: true, context: context)
        guard let result = context.makeImage() else { throw ExportError.render }
        return (result, warped.transform)
    }

    /// Carries an outline drawn over the original pixels (placed by `pixelToDocument`) into the
    /// distorted shape, so a transformed selection keeps matching its pixels.
    static func mapPath(_ path: CGPath, pixelToDocument: CGAffineTransform, pixelSize: CGSize,
                        transform: LayerTransform, corners: [CGPoint]) -> CGPath? {
        guard isUsable(corners), pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let toPixels = pixelToDocument.inverted()
        let map = homography(corners)
        func carry(_ point: CGPoint) -> CGPoint {
            let pixel = point.applying(toPixels)
            var u = pixel.x / pixelSize.width, v = pixel.y / pixelSize.height
            if transform.flipX { u = 1 - u }
            if transform.flipY { v = 1 - v }
            return map(CGPoint(x: u, y: v))
        }
        let result = CGMutablePath()
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint: result.move(to: carry(element.points[0]))
            case .addLineToPoint: result.addLine(to: carry(element.points[0]))
            case .addQuadCurveToPoint: result.addQuadCurve(to: carry(element.points[1]), control: carry(element.points[0]))
            case .addCurveToPoint:
                result.addCurve(to: carry(element.points[2]), control1: carry(element.points[0]), control2: carry(element.points[1]))
            case .closeSubpath: result.closeSubpath()
            @unknown default: break
            }
        }
        return result
    }
}

/// The canvas's last warped preview, reused while the distortion and layer are unchanged.
struct DistortPreviewCache {
    let corners: [CGPoint]
    let draft: LayerTransform
    let image: CGImage
    let mask: CGImage?
    let result: (image: CGImage, mask: CGImage?, transform: LayerTransform)?
}

extension EditorSession {
    /// Cmd-drag on a transform handle: the corners start moving freely. Each distortion resamples
    /// the pixels, so the edit then waits for Apply rather than applying on mouse-up.
    func beginDistort() {
        guard let edit = transformEdit, edit.corners == nil, edit.draft.isValid else { return }
        transformEdit = TransformEdit(layerID: edit.layerID, draft: edit.draft, persistent: true, floating: edit.floating,
                                      corners: DistortWarp.corners(of: edit.draft), mask: edit.mask, group: edit.group)
    }

    /// Moves the distortion's corners; a twisted or collapsed shape is ignored.
    func previewCorners(_ corners: [CGPoint]) {
        guard transformEdit?.corners != nil, DistortWarp.isUsable(corners) else { return }
        transformEdit?.corners = corners
    }

    /// Where a distortion takes `layer`: its transform under the edit and the corners that transform moves to —
    /// for a group, each layer by the same perspective as the box.
    private func distortTarget(for layer: ImageLayer, edit: TransformEdit, shape: [CGPoint]) -> (transform: LayerTransform, corners: [CGPoint])? {
        guard let group = edit.group else { return edit.layerID == layer.id ? (edit.draft, shape) : nil }
        guard let original = group.originals[layer.id] else { return nil }
        let transform = original.following(from: group.box, to: edit.draft)
        let corners = DistortWarp.carried(transform, by: edit.draft, to: shape)
        return DistortWarp.isUsable(corners) ? (transform, corners) : nil
    }

    /// The layer warped into the pending distortion, at preview size, for the canvas to draw.
    func distortPreview(for layer: ImageLayer) -> (image: CGImage, mask: CGImage?, transform: LayerTransform)? {
        guard let edit = transformEdit, !edit.mask, let shape = edit.corners, let image = layer.asset?.image,
              let target = distortTarget(for: layer, edit: edit, shape: shape) else { return nil }
        let transform = target.transform, corners = target.corners
        let mask = layer.mask?.enabledImage
        if let cache = distortPreviewCache[layer.id], cache.corners == corners, cache.draft == transform,
           cache.image === image, cache.mask === mask { return cache.result }
        var result: (image: CGImage, mask: CGImage?, transform: LayerTransform)?
        if let warped = try? DistortWarp.warp(image, transform: transform, corners: corners, isMask: false, limit: 2048) {
            let owned = layer.mask
            let warpedMask: CGImage?
            if owned?.placement == nil && owned?.isLinked != false {
                warpedMask = mask.flatMap { try? DistortWarp.warp($0, transform: transform, corners: corners, isMask: true, limit: 2048).image }
            } else if let owned, owned.isLinked, let placed = owned.placement,
                      case let placement = placed.following(from: layer.transform, to: transform),
                      case let carried = DistortWarp.carried(placement, by: transform, to: corners), DistortWarp.isUsable(carried),
                      let moved = try? DistortWarp.warpMask(owned.asset.image, transform: placement, corners: carried,
                                                            background: LayerMask.background(of: owned.asset.thumbnail), limit: 2048) {
                // A linked mask placed apart takes the same perspective over its own bounds.
                warpedMask = LayerMask(asset: ImportedImage(image: moved.image, thumbnail: owned.asset.thumbnail, name: owned.asset.name),
                                       isEnabled: owned.isEnabled)
                    .clipImage(placement: moved.transform, over: warped.transform, width: warped.image.width, height: warped.image.height, limit: 2048)
            } else {
                // An unlinked mask stays where it is on the document.
                warpedMask = owned?.clipImage(placement: owned?.placement ?? layer.transform, over: warped.transform,
                                              width: warped.image.width, height: warped.image.height, limit: 2048)
            }
            result = (warped.image, warpedMask, warped.transform)
        }
        distortPreviewCache[layer.id] = DistortPreviewCache(corners: corners, draft: transform, image: image, mask: mask, result: result)
        return result
    }

    /// Apply for a distortion: each distorted layer's pixels and mask are resampled into its shape, as one undo step.
    func commitDistort(_ edit: TransformEdit, corners shape: [CGPoint]) {
        distortPreviewCache = [:]
        let ids = edit.group.map { Array($0.originals.keys) } ?? [edit.layerID]
        beginEdit(edit.group == nil ? L10n.string("Distort") : L10n.string("Distort Layers"))
        for id in ids {
            guard let index = document?.layers.firstIndex(where: { $0.id == id }), let layer = document?.layers[index],
                  let target = distortTarget(for: layer, edit: edit, shape: shape) else { continue }
            do { try distort(at: index, transform: target.transform, corners: target.corners) }
            catch { brushError = error.localizedDescription }
        }
        endEdit()
    }

    /// The layer at `index`, shown by `transform`, resampled so its corners land on `corners`.
    private func distort(at index: Int, transform: LayerTransform, corners: [CGPoint]) throws {
        guard let layer = document?.layers[index], let image = layer.asset?.image else { return }
        let warped = try DistortWarp.warpTrimmed(image, transform: transform, corners: corners)
        let asset = ImportedImage(image: warped.image, thumbnail: try PixelAdjust.thumbnail(of: warped.image), name: layer.name)
        var mask = layer.mask
        if let original = layer.mask, original.placement == nil, original.isLinked {
            let warpedMask = try DistortWarp.warp(original.asset.image, transform: transform, corners: corners, isMask: true)
            // A uniform mask passes through; any other is cropped with the pixels.
            let maskAsset: ImportedImage
            if warpedMask.image === original.asset.image {
                maskAsset = original.asset
            } else {
                guard let cropped = warpedMask.image.cropping(to: warped.crop) else { throw ExportError.render }
                maskAsset = try LayerMask.asset(from: cropped)
            }
            mask = original.replacing(maskAsset)
        } else if let original = layer.mask, original.isLinked, let placed = original.placement,
                  case let placement = placed.following(from: layer.transform, to: transform),
                  case let carried = DistortWarp.carried(placement, by: transform, to: corners), DistortWarp.isUsable(carried) {
            // A linked mask placed apart takes the same perspective over its own bounds.
            let moved = try DistortWarp.warpMask(original.asset.image, transform: placement, corners: carried,
                                                 background: LayerMask.background(of: original.asset.thumbnail))
            mask = LayerMask(asset: moved.image === original.asset.image ? original.asset : try LayerMask.asset(from: moved.image),
                             isEnabled: original.isEnabled, placement: moved.transform, isLinked: true)
        } else if let original = layer.mask {
            // An unlinked mask keeps its place on the document.
            mask?.placement = original.placement ?? layer.transform
        }
        document?.layers[index].asset = asset
        document?.layers[index].transform = warped.transform
        document?.layers[index].mask = mask
    }
}
