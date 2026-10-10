import CoreGraphics

nonisolated enum AdjustmentSurface {
    static func draw(in context: CGContext, padding: CGFloat = 0, body: (CGContext) -> Void) {
        // Spatial adjustments need pixels outside AppKit's dirty rectangle. Render that halo
        // offscreen; the destination context still clips the final draw to the requested region.
        let output = context.boundingBoxOfClipPath.integral
        let bounds = output.insetBy(dx: -padding, dy: -padding).integral
        guard bounds.width > 0, bounds.height > 0 else { return }
        // One surface pixel per screen pixel: a surface in points would be half the display's resolution on Retina,
        // stretched back up and soft. Too big for that, it falls back to points.
        let device = LayerRenderer.deviceScale(of: context)
        let scale = bounds.width * bounds.height * device * device <= DocumentLimits.maxSurfaceExtent ? device : 1
        let width = Int((bounds.width * scale).rounded()), height = Int((bounds.height * scale).rounded())
        // Same pixel size as the last frame: reuse that bitmap instead of allocating another full surface.
        guard bounds.width * bounds.height <= DocumentLimits.maxSurfaceExtent, width > 0, height > 0,
              let image = try? ImageAdjustmentPixels.withContext(width: width, height: height, clear: true, { surface -> CGImage in
                  surface.scaleBy(x: scale, y: scale)
                  surface.translateBy(x: -bounds.minX, y: -bounds.minY)
                  body(surface)
                  guard let image = surface.makeImage() else { throw ExportError.render }
                  return image
              }) else { return }
        context.saveGState()
        context.interpolationQuality = scale == device ? .none : .high
        context.translateBy(x: bounds.minX, y: bounds.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: bounds.size))
        context.restoreGState()
    }
}
