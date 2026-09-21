import CoreGraphics
import CoreImage

/// Color Burn and Color Dodge, blended the way the PDF spec (and Photoshop) define them.
///
/// Core Graphics gets these two wrong: its `.colorBurn` and `.colorDodge` ignore how transparent the source is, so
/// a soft brush comes out with a hard edge. Every other mode it has is right, so these two are evaluated explicitly
/// in a copy of the canvas and the result is put back.
nonisolated enum SeparableBlend {
    static func isCoreGraphicsWrong(_ mode: LayerBlendMode) -> Bool { mode == .colorBurn || mode == .colorDodge }
    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // Core Image works in a linear space unless told otherwise, and these two modes are not separable from
    // the gamma they are computed in: over 40% grey, an 80% grey layer dodges to 62% instead of Photoshop's
    // 100%, and burns to 0% instead of 25%. The blend has to happen in the same sRGB the canvas is in.
    private static let ciContext = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: space])

    /// Draws one layer into `context` in `mode`. `body` draws it as it would be drawn normally, into a context laid
    /// out exactly like `context`. Only a bitmap-backed context can be read back, so anywhere else this reports
    /// false and the caller draws with Core Graphics as before.
    static func draw(_ mode: LayerBlendMode, in context: CGContext, body: (CGContext) -> Void) -> Bool {
        guard isCoreGraphicsWrong(mode), context.data != nil, context.width > 0, context.height > 0,
              let backdrop = context.makeImage(),
              let surface = CGContext(data: nil, width: context.width, height: context.height, bitsPerComponent: 8,
                                      bytesPerRow: context.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return false }
        // The same placement as the canvas it will be blended into.
        surface.concatenate(context.ctm)
        body(surface)
        guard let source = surface.makeImage() else { return false }
        let frame = CGRect(x: 0, y: 0, width: context.width, height: context.height)
        // Use the explicit equations for both opaque and translucent pixels. Core Image's blend
        // filters vary with the active color-management context on macOS 12, while these modes must
        // produce the same result in export, canvas preview, and Universal builds.
        guard let blended = cpuBlend(mode, source: source, backdrop: backdrop, frame: frame) else { return false }
        context.saveGState()
        context.concatenate(context.ctm.inverted())
        context.setBlendMode(.copy)
        context.setAlpha(1)
        context.draw(blended, in: frame)
        context.restoreGState()
        return true
    }

    /// Core Image can refuse a blend filter while another detached render is being torn down. Keep
    /// the export deterministic with the PDF blend equations as a small bitmap fallback.
    private static func cpuBlend(_ mode: LayerBlendMode, source: CGImage, backdrop: CGImage, frame: CGRect) -> CGImage? {
        guard let foreground = try? BrushRaster.context(width: source.width, height: source.height, mask: false),
              let background = try? BrushRaster.context(width: backdrop.width, height: backdrop.height, mask: false) else { return nil }
        BrushRaster.draw(source, in: frame, mask: false, context: foreground)
        BrushRaster.draw(backdrop, in: frame, mask: false, context: background)
        guard let srcData = foreground.data, let backData = background.data else { return nil }
        let src = srcData.assumingMemoryBound(to: UInt8.self), back = backData.assumingMemoryBound(to: UInt8.self)
        let count = source.width * source.height
        for index in 0..<count {
            let offset = index * 4
            let sourceAlpha = CGFloat(src[offset + 3]) / 255
            let backgroundAlpha = CGFloat(back[offset + 3]) / 255
            func color(_ data: UnsafeMutablePointer<UInt8>) -> (CGFloat, CGFloat, CGFloat) {
                guard data[offset + 3] > 0 else { return (0, 0, 0) }
                let alpha = CGFloat(data[offset + 3]) / 255
                return (CGFloat(data[offset]) / 255 / alpha, CGFloat(data[offset + 1]) / 255 / alpha,
                        CGFloat(data[offset + 2]) / 255 / alpha)
            }
            let sourceColor = color(src), backgroundColor = color(back)
            func blend(_ base: CGFloat, _ top: CGFloat) -> CGFloat {
                switch mode {
                case .colorDodge: return top >= 1 ? 1 : min(1, base / max(1 - top, 1 / 255))
                case .colorBurn: return top <= 0 ? 0 : 1 - min(1, (1 - base) / top)
                default: return base
                }
            }
            let resultAlpha = sourceAlpha + backgroundAlpha * (1 - sourceAlpha)
            guard resultAlpha > 0 else {
                src[offset] = 0; src[offset + 1] = 0; src[offset + 2] = 0; src[offset + 3] = 0
                continue
            }
            let red = sourceAlpha * ((1 - backgroundAlpha) * sourceColor.0 + backgroundAlpha * blend(backgroundColor.0, sourceColor.0))
                + (1 - sourceAlpha) * backgroundAlpha * backgroundColor.0
            let green = sourceAlpha * ((1 - backgroundAlpha) * sourceColor.1 + backgroundAlpha * blend(backgroundColor.1, sourceColor.1))
                + (1 - sourceAlpha) * backgroundAlpha * backgroundColor.1
            let blue = sourceAlpha * ((1 - backgroundAlpha) * sourceColor.2 + backgroundAlpha * blend(backgroundColor.2, sourceColor.2))
                + (1 - sourceAlpha) * backgroundAlpha * backgroundColor.2
            src[offset] = UInt8(min(255, max(0, (red * 255).rounded())))
            src[offset + 1] = UInt8(min(255, max(0, (green * 255).rounded())))
            src[offset + 2] = UInt8(min(255, max(0, (blue * 255).rounded())))
            src[offset + 3] = UInt8(min(255, max(0, (resultAlpha * 255).rounded())))
        }
        return foreground.makeImage()
    }
}
