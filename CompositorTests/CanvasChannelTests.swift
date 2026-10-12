import CoreGraphics
import Testing
@testable import Compositor

struct CanvasChannelTests {
    @Test func isolatesTheRequestedPremultipliedChannel() throws {
        for (channel, expected): (CanvasChannel, UInt8) in [(.red, 23), (.green, 117), (.blue, 241)] {
            let context = try BrushRaster.context(width: 2, height: 1, mask: false)
            let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
            for pixel in 0..<2 {
                bytes[pixel * 4] = 23
                bytes[pixel * 4 + 1] = 117
                bytes[pixel * 4 + 2] = 241
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
}
