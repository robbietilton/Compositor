import AppKit
import CoreImage

/// Shared plumbing for whole-image adjustments: unmanaged Core Image rendering, selection
/// coverage on an image's own pixel grid, and blending a result back through a selection.
nonisolated enum PixelAdjust {
    /// No color management: pixel values pass through unchanged.

    /// An 8-bit bitmap with standard (bottom-left) coordinates and top-down memory rows.
    static func bitmap(width: Int, height: Int, mask: Bool) throws -> CGContext {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: mask ? width : width * 4,
            space: mask ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: mask ? CGImageAlphaInfo.none.rawValue
                             : CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { throw ExportError.render }
        context.interpolationQuality = .none
        return context
    }

    /// Selection coverage rasterized on the image's pixel grid (a fill, which is exact).
    static func coverage(_ selection: SelectionClip, width: Int, height: Int,
                         pixelToDocument: CGAffineTransform) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: true)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.concatenate(pixelToDocument.inverted())
        selection.apply(to: context)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(selection.rect)
        guard let image = context.makeImage() else { throw ExportError.render }
        return image
    }

    /// coverage × adjusted + (1 − coverage) × original, in float without color conversion,
    /// so fully selected pixels stay exact and soft edges blend.
    static func blend(_ adjusted: CGImage, over original: CGImage, through selection: SelectionClip,
                      pixelToDocument: CGAffineTransform, isMask: Bool) throws -> CGImage {
        let width = adjusted.width, height = adjusted.height
        let mask = try coverage(selection, width: width, height: height, pixelToDocument: pixelToDocument)
        let blended = CIImage(cgImage: adjusted).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(cgImage: original),
            kCIInputMaskImageKey: CIImage(cgImage: mask)])
        return try render(blended, width: width, height: height, isMask: isMask)
    }

    static func render(_ image: CIImage, width: Int, height: Int, isMask: Bool) throws -> CGImage {
        // A render can run concurrently with another detached filter job. Keep the context local so
        // an in-flight Core Image render cannot reuse another job's intermediate state.
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        guard let result = context.createCGImage(image, from: CGRect(x: 0, y: 0, width: width, height: height),
                format: isMask ? .L8 : .RGBA8,
                colorSpace: isMask ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!)
        else { throw ExportError.render }
        return result
    }

    /// A small preview for the Layers panel, matching imported thumbnails.
    static func thumbnail(of image: CGImage) throws -> CGImage {
        let factor = min(1, 96 / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * factor)), height = max(1, Int(CGFloat(image.height) * factor))
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        guard let thumbnail = context.makeImage() else { throw ExportError.render }
        return thumbnail
    }
}
