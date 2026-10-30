import CoreGraphics

nonisolated enum AdjustmentSurface {
    static func draw(in context: CGContext, padding: CGFloat = 0, within: CGRect? = nil, sixteenBit: Bool = false, hdr: Bool = false,
                     body: (CGContext) -> Void) {
        // Spatial adjustments need pixels outside AppKit's dirty rectangle. Render that halo
        // offscreen; the destination context still clips the final draw to the requested region.
        let output = context.boundingBoxOfClipPath.integral
        // No farther than `within` reaches (the document, when an adjustment's reach is the whole of it), and no bigger
        // than a surface can be: a reach past that is cut back rather than drawing nothing.
        var reach = padding
        if let within { reach = min(reach, max(within.maxX - output.minX, output.maxX - within.minX, within.maxY - output.minY,
                                               output.maxY - within.minY, 0)) }
        let room = (((output.width + output.height) * (output.width + output.height) / 4
            + max(0, DocumentLimits.maxSurfaceExtent - output.width * output.height)).squareRoot() - (output.width + output.height) / 2) / 2
        let bounds = output.insetBy(dx: -max(0, min(reach, room.rounded(.down))), dy: -max(0, min(reach, room.rounded(.down)))).integral
        guard bounds.width > 0, bounds.height > 0 else { return }
        // One surface pixel per screen pixel: a surface in points would be half the display's resolution on Retina,
        // stretched back up and soft. Too big for that, it falls back to points.
        let device = LayerRenderer.deviceScale(of: context)
        let scale = bounds.width * bounds.height * device * device <= DocumentLimits.maxSurfaceExtent ? device : 1
        guard bounds.width * bounds.height <= DocumentLimits.maxSurfaceExtent,
              let surface = try? surface(sixteenBit: sixteenBit, hdr: hdr, width: Int((bounds.width * scale).rounded()),
                                         height: Int((bounds.height * scale).rounded())) else { return }
        surface.scaleBy(x: scale, y: scale)
        surface.translateBy(x: -bounds.minX, y: -bounds.minY)
        body(surface)
        guard let image = surface.makeImage() else { return }
        context.saveGState()
        context.interpolationQuality = scale == device ? .none : .high
        context.translateBy(x: bounds.minX, y: bounds.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: bounds.size))
        context.restoreGState()
    }

    /// A 16-bit render (`sixteenBit`) keeps 16 bits through the surface.
    private static func surface(sixteenBit: Bool, hdr: Bool, width: Int, height: Int) throws -> CGContext {
        sixteenBit ? try DeepLayer.context(width: width, height: height, hdr: hdr)
                                       : try BrushRaster.context(width: width, height: height, mask: false)
    }
}
