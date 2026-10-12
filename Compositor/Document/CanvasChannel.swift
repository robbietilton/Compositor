import CoreGraphics
import CoreImage

/// Which part of the composited image the canvas is showing. This is a view setting only: it never changes layer
/// pixels, saved projects or exports.
nonisolated enum CanvasChannel: String, CaseIterable, Sendable {
    case rgb, red, green, blue

    var titleKey: String {
        switch self {
        case .rgb: "RGB"
        case .red: "Red"
        case .green: "Green"
        case .blue: "Blue"
        }
    }

    var shortcut: Character {
        switch self {
        case .rgb: "2"
        case .red: "3"
        case .green: "4"
        case .blue: "5"
        }
    }

    private var byte: Int? {
        switch self {
        case .rgb: nil
        case .red: 0
        case .green: 1
        case .blue: 2
        }
    }

    /// Turns the selected channel of a top-left RGBA8 `BrushRaster` context into the gray shown by image editors.
    func isolate(in context: CGContext) {
        guard let byte, context.bitsPerComponent == 8, context.bitsPerPixel == 32, let raw = context.data else { return }
        let width = context.width, height = context.height, stride = context.bytesPerRow
        BrushRaster.inBands(count: height) { firstRow, rowCount in
            let pixels = raw.assumingMemoryBound(to: UInt8.self)
            for y in firstRow..<(firstRow + rowCount) {
                let row = pixels + y * stride
                for x in 0..<width {
                    let pixel = row + x * 4
                    let value = pixel[byte]
                    pixel[0] = value
                    pixel[1] = value
                    pixel[2] = value
                }
            }
        }
    }

    /// The same isolation for the Metal/Core Image canvas, without another texture or raster pass.
    func isolate(_ image: CIImage) -> CIImage {
        guard let byte else { return image }
        let component = byte == 0 ? CIVector(x: 1, y: 0, z: 0, w: 0)
            : byte == 1 ? CIVector(x: 0, y: 1, z: 0, w: 0)
                        : CIVector(x: 0, y: 0, z: 1, w: 0)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": component,
            "inputGVector": component,
            "inputBVector": component,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    /// A channel-panel thumbnail from a small composited image.
    func thumbnail(from image: CGImage) -> CGImage? {
        guard self != .rgb else { return image }
        guard let context = try? BrushRaster.copy(image) else { return nil }
        isolate(in: context)
        return context.makeImage()
    }
}
