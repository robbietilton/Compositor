import CoreGraphics

/// Draws into a top-left coordinate system, shared by the canvas and export.
nonisolated enum LayerRenderer {
    static func draw(_ image: CGImage, transform: LayerTransform, center: CGPoint,
                     scale: CGFloat = 1, opacity: Double = 1, blendMode: LayerBlendMode = .normal, mask: CGImage? = nil, in context: CGContext) {
        let width = transform.size.width * scale
        let height = transform.size.height * scale
        // Large reductions draw from sharp halvings; Core Graphics then only does the last 2× or less.
        let device = deviceScale(of: context)
        let source = reduced(image, width: width, device: device, sampling: transform.sampling)
        let clip = mask.map { reduced($0, width: width, device: device, sampling: transform.sampling) }
        context.saveGState()
        context.setAlpha(opacity)
        context.setBlendMode(blendMode.cgMode)
        context.interpolationQuality = interpolation(transform.sampling,
            finalFactor: width * device / CGFloat(max(1, image.width)) * CGFloat(1 << source.level),
            upright: transform.radians == 0)
        context.setShouldAntialias(transform.sampling != .nearest)
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: transform.radians)
        context.scaleBy(x: transform.flipX ? -1 : 1, y: transform.flipY ? 1 : -1)
        let bounds = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
        if let clip { context.clip(to: coverage(of: clip, in: bounds), mask: clip.image) }
        context.draw(source.image, in: coverage(of: source, in: bounds))
        context.restoreGState()
    }

    /// An image ready to draw a layer `width` context units wide: sharp halvings for large reductions (never
    /// for Nearest), and how far past the layer's bounds the copy reaches — halvings round up, so it covers
    /// exactly `2^level` source pixels per pixel, a little beyond the right and bottom.
    struct Reduced {
        let image: CGImage
        let level: Int
        let widthScale: CGFloat
        let heightScale: CGFloat
    }

    /// Core Graphics's filter for the last resample, `finalFactor` device pixels per (reduced) image pixel.
    /// An `upright` layer drawn pixel for pixel copies its pixels straight across.
    /// Shrinking uses Low: Medium and High prefilter by the image's own size and position, so a piece of an
    /// image would come out different from the whole (painted layers draw in pieces), and the sharp halvings
    /// have already done the heavy reduction. Enlarging keeps the layer's own setting.
    static func interpolation(_ sampling: LayerSampling, finalFactor: CGFloat, upright: Bool = false) -> CGInterpolationQuality {
        if sampling == .nearest || (upright && abs(finalFactor - 1) < 0.001) { return .none }
        return finalFactor <= 1 ? .low : sampling.quality
    }
    static func reduced(_ image: CGImage, width: CGFloat, device: CGFloat, sampling: LayerSampling) -> Reduced {
        guard sampling != .nearest else { return Reduced(image: image, level: 0, widthScale: 1, heightScale: 1) }
        let level = DownsampleCache.level(for: width * device / CGFloat(max(1, image.width)))
        let result = DownsampleCache.shared.image(image, level: level)
        return Reduced(image: result.image, level: result.level,
                       widthScale: CGFloat(result.image.width << result.level) / CGFloat(max(1, image.width)),
                       heightScale: CGFloat(result.image.height << result.level) / CGFloat(max(1, image.height)))
    }
    /// Where a reduced image goes when its layer fills `bounds` (in the renderer's y-up drawing space).
    static func coverage(of reduced: Reduced, in bounds: CGRect) -> CGRect {
        let width = bounds.width * reduced.widthScale, height = bounds.height * reduced.heightScale
        return CGRect(x: bounds.minX, y: bounds.maxY - height, width: width, height: height)
    }

    /// Device pixels per unit along the context's x axis.
    static func deviceScale(of context: CGContext) -> CGFloat {
        let device = context.userSpaceToDeviceSpaceTransform
        return (device.a * device.a + device.b * device.b).squareRoot()
    }

    /// Resample coverage as coverage, bypassing grayscale color conversion.
    static func drawCoverage(_ image: CGImage, transform: LayerTransform, in context: CGContext) {
        context.saveGState()
        context.interpolationQuality = transform.sampling.quality
        context.setShouldAntialias(transform.sampling != .nearest)
        context.translateBy(x: transform.center.x, y: transform.center.y)
        context.rotate(by: transform.radians)
        context.scaleBy(x: transform.flipX ? -1 : 1, y: transform.flipY ? 1 : -1)
        let bounds = CGRect(x: -transform.size.width / 2, y: -transform.size.height / 2,
                            width: transform.size.width, height: transform.size.height)
        context.clip(to: bounds, mask: image)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(bounds)
        context.restoreGState()
    }

}

extension LayerRenderer {
    /// Preview replacement tiles without building a full-size raster. Disjoint
    /// clips ensure opacity and blend modes are applied exactly once per pixel.
    static func drawBrushPreview(_ image: CGImage?, transform: LayerTransform, center: CGPoint,
        scale: CGFloat, opacity: Double, blendMode: LayerBlendMode, mask: CGImage?,
        patches: [BrushPatch], pixelWidth: Int, pixelHeight: Int, paintingMask: Bool, sourceRect: CGRect? = nil, raster: RasterSnapshot? = nil, rasterBase: CGImage? = nil, in context: CGContext) {
        let width = transform.size.width * scale, height = transform.size.height * scale
        let bounds = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
        func mapped(_ source: CGRect) -> CGRect {
            CGRect(x: bounds.minX + source.minX / CGFloat(pixelWidth) * width,
                y: bounds.maxY - source.maxY / CGFloat(pixelHeight) * height,
                width: source.width / CGFloat(pixelWidth) * width,
                height: source.height / CGFloat(pixelHeight) * height)
        }
        func rect(_ patch: BrushPatch) -> CGRect { mapped(patch.rect) }
        let originalBounds = sourceRect.map(mapped) ?? bounds
        func drawSource() {
            guard let raster else {
                if let image { context.draw(image, in: originalBounds) }
                return
            }
            func sourceMapped(_ r: CGRect) -> CGRect {
                CGRect(x: originalBounds.minX + r.minX / CGFloat(raster.width) * originalBounds.width,
                    y: originalBounds.maxY - r.maxY / CGFloat(raster.height) * originalBounds.height,
                    width: r.width / CGFloat(raster.width) * originalBounds.width,
                    height: r.height / CGFloat(raster.height) * originalBounds.height)
            }
            if let base = rasterBase ?? raster.base {
                context.saveGState()
                context.addRect(originalBounds)
                for patch in raster.patches { context.addRect(sourceMapped(patch.rect)) }
                context.clip(using: .evenOdd)
                context.draw(base, in: sourceMapped(raster.baseRect))
                context.restoreGState()
            }
            let visible = context.boundingBoxOfClipPath
            for patch in raster.patches {
                let target = sourceMapped(patch.rect)
                guard target.intersects(visible) else { continue }
                context.saveGState()
                context.clip(to: target)
                context.draw(patch.image, in: target)
                context.restoreGState()
            }
        }
        context.saveGState()
        context.setAlpha(opacity)
        context.setBlendMode(blendMode.cgMode)
        context.interpolationQuality = transform.sampling.quality
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: transform.radians)
        context.scaleBy(x: transform.flipX ? -1 : 1, y: transform.flipY ? 1 : -1)
        // Tile boundaries must not acquire overlapping antialias coverage.
        context.setShouldAntialias(false)
        if image != nil {
            context.saveGState()
            context.addRect(bounds)
            for patch in patches { context.addRect(rect(patch)) }
            context.clip(using: .evenOdd)
            if let mask { context.clip(to: originalBounds, mask: mask) }
            drawSource()
            context.restoreGState()
        }
        for patch in patches {
            let tileBounds = rect(patch)
            context.saveGState()
            context.clip(to: tileBounds)
            if paintingMask {
                if image != nil {
                    context.clip(to: tileBounds, mask: patch.image)
                    drawSource()
                }
            } else {
                if let mask {
                    // Paint outside the old raster is revealed; retain the old mask inside it.
                    context.saveGState()
                    context.clip(to: originalBounds, mask: mask)
                    context.draw(patch.image, in: tileBounds)
                    context.restoreGState()
                    context.addRect(tileBounds)
                    let overlap = tileBounds.intersection(originalBounds)
                    if !overlap.isNull, !overlap.isEmpty { context.addRect(overlap) }
                    context.clip(using: .evenOdd)
                }
                context.draw(patch.image, in: tileBounds)
            }
            context.restoreGState()
        }
        context.restoreGState()
    }
}
