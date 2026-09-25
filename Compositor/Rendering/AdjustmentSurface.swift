import CoreGraphics

nonisolated enum AdjustmentSurface {
    static func draw(in context: CGContext, padding: CGFloat = 0, body: (CGContext) -> Void) {
        // Spatial adjustments need pixels outside AppKit's dirty rectangle. Render that halo
        // offscreen; the destination context still clips the final draw to the requested region.
        let output = context.boundingBoxOfClipPath.integral
        let bounds = output.insetBy(dx: -padding, dy: -padding).integral
        guard bounds.width > 0, bounds.height > 0, bounds.width*bounds.height <= DocumentLimits.maxSurfaceExtent,
              let surface = try? BrushRaster.context(width: Int(bounds.width), height: Int(bounds.height), mask: false) else { return }
        surface.translateBy(x: -bounds.minX, y: -bounds.minY)
        body(surface)
        guard let image = surface.makeImage() else { return }
        context.saveGState()
        context.translateBy(x: bounds.minX, y: bounds.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: bounds.size))
        context.restoreGState()
    }
}
