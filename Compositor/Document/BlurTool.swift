import CoreGraphics
import Foundation
import CoreImage

extension EditorSession {

    /// What a Blur stroke paints: the layer's own pixels (or, painting the mask, its mask), softened by the Radius set
    /// in the options bar, measured on the canvas, at the layer's own resolution. It is taken when the stroke starts,
    /// so going over an area again in a new stroke softens it further, as in Photoshop. `render` makes any part of the
    /// softened sample, so only what the brush reaches is ever blurred; `image` is the sharp sample, the same size.
    /// `deepRender`, for a 16-bit layer: the same, softened from its 16-bit pixels and made at 16 bits (`DeepLayer`).
    func blurSample(for stroke: BrushStroke) -> (sample: (image: CGImage, placed: CGRect, inGrid: Bool), render: (CGRect) -> CGImage?,
                                                 deepRender: ((CGRect) -> CGImage?)?)? {
        let layer = stroke.layer
        guard let image = stroke.isMask ? layer.mask?.asset.image : layer.asset?.image else { return nil }
        // The canvas's softening, carried into the layer's pixels: wider there when the layer is scaled down.
        let map = stroke.pixelToDocument
        let perPixel = max(1e-6, abs(map.a * map.d - map.b * map.c).squareRoot())
        let sidePixels = max(stroke.sourceRect.width, stroke.sourceRect.height)
        let sigma = min(Double(min(50, max(0.5, brushSettings.blurRadius))) / perPixel, sidePixels / 2)
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
        let isMask = stroke.isMask
        let render: (CGRect) -> CGImage? = { part in
            // `part` counts rows from the top; Core Image counts them from the bottom.
            PixelAdjust.ciContext.createCGImage(soft, from: CGRect(x: part.minX, y: CGFloat(height) - part.maxY,
                                                                   width: part.width, height: part.height),
                format: isMask ? .L8 : .RGBA8,
                colorSpace: isMask ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        var deepRender: ((CGRect) -> CGImage?)?
        if !isMask, let asset = layer.asset, asset.deep != nil {
            // Made once, when the brush first reaches the layer.
            var deepSoft: CIImage?
            deepRender = { part in
                if deepSoft == nil {
                    guard let deep = try? DeepLayer.flattened(asset),
                          let wide = try? DeepLayer.context(width: width, height: height, hdr: DeepLayer.isHDR(deep)) else { return nil }
                    BrushRaster.draw(deep, in: placed, mask: false, context: wide)
                    guard let sharp = wide.makeImage() else { return nil }
                    deepSoft = CIImage(cgImage: sharp).applyingGaussianBlur(sigma: sigma * fit).cropped(to: extent)
                }
                guard let deepSoft else { return nil }
                return DeepLayer.ciContext.createCGImage(deepSoft, from: CGRect(x: part.minX, y: CGFloat(height) - part.maxY,
                                                                                  width: part.width, height: part.height),
                    format: asset.isHDR ? .RGBAh : .RGBA16, colorSpace: asset.isHDR ? DeepLayer.hdrSpace : CGColorSpace(name: CGColorSpace.sRGB)!)
            }
        }
        if let deepRender {
            // While painting, the 16-bit sample dithered down: rounded straight to 8 bits, a smooth 16-bit layer's
            // softened copy came out in bands until the stroke ended.
            return ((sharp, region, true), { part in deepRender(part).flatMap { try? DeepLayer.dithered($0) } ?? render(part) }, deepRender)
        }
        return ((sharp, region, true), render, deepRender)
    }
}
