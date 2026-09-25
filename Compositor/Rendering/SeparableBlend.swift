import CoreGraphics
import CoreImage

/// The blend modes Core Graphics can't draw, computed by Core Image instead.
///
/// Two kinds end up here. Core Graphics gets Color Burn and Color Dodge wrong: its versions ignore how transparent
/// the source is, so a soft brush comes out with a hard edge. And it has no equivalent at all for Linear Burn,
/// Linear Dodge, Vivid Light, Linear Light, Pin Light, Hard Mix, Subtract or Divide. Either way the layer is drawn
/// into a copy of the canvas, blended there, and the result put back.
nonisolated enum SeparableBlend {
    /// Whether this mode has to be composited through a surface rather than drawn straight on.
    static func needsSurface(_ mode: LayerBlendMode) -> Bool { mode.coreImageFilter != nil }
    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // Core Image works in a linear space unless told otherwise, and these two modes are not separable from
    // the gamma they are computed in: over 40% grey, an 80% grey layer dodges to 62% instead of Photoshop's
    // 100%, and burns to 0% instead of 25%. The blend has to happen in the same sRGB the canvas is in.
    private static let ciContext = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: space])

    /// Draws one layer into `context` in `mode`. `body` draws it as it would be drawn normally, into a context laid
    /// out exactly like `context`. Only a bitmap-backed context can be read back, so anywhere else this reports
    /// false and the caller draws with Core Graphics as before.
    static func draw(_ mode: LayerBlendMode, in context: CGContext, body: (CGContext) -> Void) -> Bool {
        guard let name = mode.coreImageFilter, context.data != nil, context.width > 0, context.height > 0,
              let filter = CIFilter(name: name),
              let backdrop = context.makeImage(),
              let surface = CGContext(data: nil, width: context.width, height: context.height, bitsPerComponent: 8,
                                      bytesPerRow: context.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return false }
        // The same placement as the canvas it will be blended into.
        surface.concatenate(context.ctm)
        body(surface)
        guard let source = surface.makeImage() else { return false }
        filter.setValue(CIImage(cgImage: source), forKey: kCIInputImageKey)
        filter.setValue(CIImage(cgImage: backdrop), forKey: kCIInputBackgroundImageKey)
        let frame = CGRect(x: 0, y: 0, width: context.width, height: context.height)
        guard let output = filter.outputImage,
              let blended = ciContext.createCGImage(output, from: frame, format: .RGBA8, colorSpace: space) else { return false }
        context.saveGState()
        context.concatenate(context.ctm.inverted())
        context.setBlendMode(.copy)
        context.setAlpha(1)
        context.draw(blended, in: frame)
        context.restoreGState()
        return true
    }
}
