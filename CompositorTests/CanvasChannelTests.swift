import AppKit
import CoreGraphics
import Testing
@testable import Compositor

@MainActor struct CanvasChannelTests {
    @Test func isolatesTheRequestedPremultipliedChannel() throws {
        for (channel, expected): (CanvasChannel, UInt8) in [(.red, 23), (.green, 117), (.blue, 181)] {
            let context = try BrushRaster.context(width: 2, height: 1, mask: false)
            let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
            for pixel in 0..<2 {
                bytes[pixel * 4] = 23
                bytes[pixel * 4 + 1] = 117
                bytes[pixel * 4 + 2] = 181
                bytes[pixel * 4 + 3] = UInt8(200 + pixel)
            }

            channel.isolate(in: context)

            for pixel in 0..<2 {
                #expect(bytes[pixel * 4] == expected)
                #expect(bytes[pixel * 4 + 1] == expected)
                #expect(bytes[pixel * 4 + 2] == expected)
                #expect(bytes[pixel * 4 + 3] == UInt8(200 + pixel), "channel preview preserves transparency")
            }
        }
    }

    @Test func rgbLeavesTheCompositeUntouched() throws {
        let context = try BrushRaster.context(width: 1, height: 1, mask: false)
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        bytes[0] = 12; bytes[1] = 34; bytes[2] = 56; bytes[3] = 78
        CanvasChannel.rgb.isolate(in: context)
        #expect(Array(UnsafeBufferPointer(start: bytes, count: 4)) == [12, 34, 56, 78])
    }

    @Test func wideCPUPreviewHasNoTileSeam() throws {
        let width = CanvasView.channelPreviewTilePixels + 128, height = 64
        let image = try BrushRaster.context(width: width, height: height, mask: false)
        let source = image.data!.assumingMemoryBound(to: UInt8.self)
        for pixel in 0..<(width * height) {
            source[pixel * 4] = 20
            source[pixel * 4 + 1] = 120
            source[pixel * 4 + 2] = 60
            source[pixel * 4 + 3] = 255
        }
        let session = EditorSession()
        let size = CGSize(width: CGFloat(width), height: CGFloat(height))
        session.viewport.resize(to: size, backingScale: 1, documentSize: nil)
        session.createDocument(width: width, height: height)
        let rendered = try #require(image.makeImage())
        session.insert(ImportedImage(image: rendered, thumbnail: rendered, name: "Wide"))
        session.canvasChannel = .green
        session.zoom(to: 1)

        let canvas = CanvasView(session: session)
        canvas.frame = CGRect(origin: .zero, size: size)
        session.viewport.resize(to: canvas.bounds.size, backingScale: 1, documentSize: session.document?.size)
        canvas.synchronizeDisplay()
        let output = try BrushRaster.context(width: width, height: height, mask: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: output, flipped: true)
        canvas.allowsGPU = false
        canvas.draw(canvas.bounds)
        NSGraphicsContext.restoreGraphicsState()

        let pixels = output.data!.assumingMemoryBound(to: UInt8.self)
        for x in (CanvasView.channelPreviewTilePixels - 2)...(CanvasView.channelPreviewTilePixels + 2) {
            let offset = (height / 2 * output.bytesPerRow) + x * 4
            #expect(abs(Int(pixels[offset]) - 120) <= 1)
            #expect(abs(Int(pixels[offset + 1]) - 120) <= 1)
            #expect(abs(Int(pixels[offset + 2]) - 120) <= 1)
        }
    }
}
