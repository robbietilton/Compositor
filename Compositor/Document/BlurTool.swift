import AppKit
import CoreImage

extension EditorSession {
    /// What a Blur stroke paints: the layer's own pixels (or, painting the mask, its mask), softened by an amount
    /// that follows the brush size on the canvas, at the layer's own resolution. It is taken when the stroke starts,
    /// so going over an area again in a new stroke softens it further, as in Photoshop.
    func blurSample(for stroke: BrushStroke) -> (image: CGImage, placed: CGRect, inGrid: Bool)? {
        let layer = stroke.layer
        guard let image = stroke.isMask ? layer.mask?.asset.image : layer.asset?.image else { return nil }
        // The canvas's softening, carried into the layer's pixels: wider there when the layer is scaled down.
        let map = stroke.pixelToDocument
        let perPixel = max(1e-6, abs(map.a * map.d - map.b * map.c).squareRoot())
        let sidePixels = max(stroke.sourceRect.width, stroke.sourceRect.height)
        let sigma = min(min(30, max(1.5, Double(brushSettings.diameter) / 10)) / perPixel, sidePixels / 2)
        // Room for the blur to spread past the pixels' edges, as it does on the canvas.
        let margin = ceil(3 * sigma)
        let region = stroke.sourceRect.insetBy(dx: -margin, dy: -margin)
        // At the layer's own resolution up to a budget of several canvases; a huge layer's sample is made coarser
        // instead (the stroke scales it back over the layer), rather than a surface too large to make at every stroke.
        let canvas = (document?.width ?? 0) * (document?.height ?? 0)
        let budget = Double(min(DocumentLimits.maxSurfacePixels, max(16_000_000, 4 * canvas)))
        let fit = min(1, (budget / Double(region.width * region.height)).squareRoot())
        let width = max(1, Int((region.width * fit).rounded(.up))), height = max(1, Int((region.height * fit).rounded(.up)))
        guard let context = try? BrushRaster.context(width: width, height: height, mask: stroke.isMask) else { return nil }
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let placed = CGRect(x: margin * fit, y: margin * fit, width: stroke.sourceRect.width * fit, height: stroke.sourceRect.height * fit)
        if stroke.isMask, let owned = layer.mask {
            // Past its pixels a mask keeps its edge tone, so blurring near its edge doesn't pull in the wrong one.
            context.setFillColor(gray: LayerMask.background(of: owned.asset.thumbnail), alpha: 1)
            context.fill(extent)
        }
        BrushRaster.draw(image, in: placed, mask: stroke.isMask, context: context)
        guard let sharp = context.makeImage() else { return nil }
        let source = CIImage(cgImage: sharp)
        let soft = (stroke.isMask ? source.clampedToExtent() : source).applyingGaussianBlur(sigma: sigma * fit).cropped(to: extent)
        guard let result = try? PixelAdjust.render(soft, width: width, height: height, isMask: stroke.isMask) else { return nil }
        return (result, region, true)
    }
}
