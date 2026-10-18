import CoreGraphics
import Foundation
import Accelerate
import CoreImage

/// Whole-image invert in one vectorized pass (vImage), optionally limited to a selection.
/// Inverting never changes a layer's size, so no tiles, bounds scans, or re-cropping.
nonisolated enum PixelInvert {
    struct Job: @unchecked Sendable {
        let image: CGImage
        let isMask: Bool
        /// Maps the image's top-left pixel grid to document pixels.
        let pixelToDocument: CGAffineTransform
        let selection: SelectionClip?
    }

    static func run(_ job: Job) throws -> CGImage {
        let width = job.image.width, height = job.image.height
        let original = try PixelAdjust.bitmap(width: width, height: height, mask: job.isMask)
        original.draw(job.image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let inverted = try PixelAdjust.bitmap(width: width, height: height, mask: job.isMask)
        guard let sourceData = original.data, let targetData = inverted.data else { throw ExportError.render }
        var source = vImage_Buffer(data: sourceData, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: original.bytesPerRow)
        var target = vImage_Buffer(data: targetData, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: inverted.bytesPerRow)
        let error: vImage_Error
        if job.isMask {
            let table = (0...255).map { Pixel_8(255 - $0) }
            error = vImageTableLookUp_Planar8(&source, &target, table, vImage_Flags(kvImageNoFlags))
        } else {
            // Premultiplied RGBA: each color becomes alpha − color, so transparency is kept.
            // Row-major 4×4 matrix applied as pixel × matrix, channels in R, G, B, A order.
            // Fixed-point ×256 with divisor 256: a divisor of 1 rounds every value down a level.
            let matrix: [Int16] = [-256,    0,    0,   0,
                                      0, -256,    0,   0,
                                      0,    0, -256,   0,
                                    256,  256,  256, 256]
            error = vImageMatrixMultiply_ARGB8888(&source, &target, matrix, 256, nil, nil, vImage_Flags(kvImageNoFlags))
        }
        guard error == kvImageNoError, let invertedImage = inverted.makeImage() else { throw ExportError.render }
        guard let selection = job.selection, let originalImage = original.makeImage() else { return invertedImage }
        return try PixelAdjust.blend(invertedImage, over: originalImage, through: selection,
                                     pixelToDocument: job.pixelToDocument, isMask: job.isMask)
    }

    /// Kept for existing call sites; thumbnails live in `PixelAdjust`.
    static func thumbnail(of image: CGImage) throws -> CGImage { try PixelAdjust.thumbnail(of: image) }
}
