import AppKit
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

    var componentByte: Int? {
        switch self {
        case .rgb: nil
        case .red: 0
        case .green: 1
        case .blue: 2
        }
    }

    /// Turns the selected channel of a top-left RGBA8 `BrushRaster` context into the gray shown by image editors.
    func isolate(in context: CGContext) {
        guard let byte = componentByte, context.bitsPerComponent == 8, context.bitsPerPixel == 32,
              let raw = context.data else { return }
        let width = context.width, height = context.height, stride = context.bytesPerRow
        let pixels = raw.assumingMemoryBound(to: UInt8.self)
        if stride == width * 4 {
            BrushRaster.inBands(count: width * height) { firstPixel, pixelCount in
                for index in firstPixel..<(firstPixel + pixelCount) {
                    let pixel = pixels + index * 4
                    let value = pixel[byte]
                    pixel[0] = value
                    pixel[1] = value
                    pixel[2] = value
                }
            }
        } else {
            for y in 0..<height {
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
        guard let byte = componentByte else { return image }
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

extension EditorSession {
    /// Cmd-click in the Channels panel loads the composite channel's pixels at 50% or brighter as a selection.
    /// The composite is rendered in tiles into a one-byte mask, so a very large canvas does not require another
    /// canvas-sized RGBA allocation just to inspect one component.
    @discardableResult
    func loadChannelSelection(_ channel: CanvasChannel, mode: SelectionMode = .replace) -> Bool {
        guard let byte = channel.componentByte, canEditSelection, let document else { return false }
        do {
            let mask = try BrushRaster.context(width: document.width, height: document.height, mask: true)
            guard let maskData = mask.data else { throw ExportError.render }
            let destination = maskData.assumingMemoryBound(to: UInt8.self)
            let tileSide = 4096
            for y in stride(from: 0, to: document.height, by: tileSide) {
                let height = min(tileSide, document.height - y)
                for x in stride(from: 0, to: document.width, by: tileSide) {
                    let width = min(tileSide, document.width - x)
                    try autoreleasepool {
                        let tile = try BrushRaster.context(width: width, height: height, mask: false)
                        tile.translateBy(x: -CGFloat(x), y: -CGFloat(y))
                        drawLiveComposite(document, in: tile)
                        guard let tileData = tile.data else { throw ExportError.render }
                        let source = tileData.assumingMemoryBound(to: UInt8.self)
                        BrushRaster.inBands(count: width * height) { firstPixel, pixelCount in
                            var position = firstPixel
                            let end = firstPixel + pixelCount
                            while position < end {
                                let row = position / width, column = position % width
                                let count = min(end - position, width - column)
                                let input = source + row * tile.bytesPerRow + column * 4 + byte
                                let output = destination + (y + row) * mask.bytesPerRow + x + column
                                for offset in 0..<count { output[offset] = input[offset * 4] }
                                position += count
                            }
                        }
                    }
                }
            }
            guard let outline = MaskTracing.whitePixels(in: mask) else { NSSound.beep(); return false }
            applySelection(outline, mode: mode, name: "Load \(channel.titleKey) Channel Selection")
            return true
        } catch {
            brushError = error.localizedDescription
            return false
        }
    }
}
