import AppKit

/// Pixel conversion shared by image-selection tools.
///
/// This intentionally contains only the RGBA raster bridge needed by Quick Selection. The
/// Vision/Core ML foreground-segmentation backends from the compatibility fork are not part of
/// the upstream port and remain out of this branch.
nonisolated enum ForegroundMaskUtilities {
    static func rgbaBytes(from image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        guard width > 0, height > 0 else { throw ExportError.render }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                       bitsPerComponent: 8, bytesPerRow: width * 4,
                                       space: colorSpace,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                           | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else { throw ExportError.render }

        context.interpolationQuality = .none
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var result = [UInt8](repeating: 0, count: width * height * 4)
        result.withUnsafeMutableBufferPointer { output in
            wand_copy_flipped_rgba(data.assumingMemoryBound(to: UInt8.self), context.bytesPerRow,
                                   output.baseAddress, width, height)
        }
        return result
    }
}
