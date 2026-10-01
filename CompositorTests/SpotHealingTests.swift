import CoreGraphics
import Foundation
import Testing
@testable import Compositor

@MainActor
struct SpotHealingTests {
    /// Vertical gray stripes, 2 px wide, with a 10 × 10 red blemish in the middle.
    private func blemished() throws -> CGImage {
        let context = try BrushRaster.context(width: 120, height: 80, mask: false)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<80 {
            for x in 0..<120 {
                let red = (55..<65).contains(x) && (35..<45).contains(y)
                let gray: UInt8 = x % 4 < 2 ? 100 : 112
                let index = y * context.bytesPerRow + x * 4
                bytes[index] = red ? 230 : gray
                bytes[index + 1] = red ? 20 : gray
                bytes[index + 2] = red ? 20 : gray
                bytes[index + 3] = 255
            }
        }
        return try #require(context.makeImage())
    }
    private func pixels(_ image: CGImage) throws -> (Int, Int) -> [Int] {
        let read = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        read.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = Array(UnsafeBufferPointer(start: try #require(read.data).assumingMemoryBound(to: UInt8.self),
                                              count: image.width * image.height * 4))
        let width = image.width
        return { x, y in (0..<4).map { Int(bytes[(y * width + x) * 4 + $0]) } }
    }

    @Test(arguments: SpotHealingMode.allCases)
    func healsTheBlemishUnderTheBrushAndNothingElse(mode: SpotHealingMode) async throws {
        let session = EditorSession()
        session.createDocument(width: 120, height: 80)
        let original = try blemished()
        session.insert(ImportedImage(image: original, thumbnail: original, name: "Surface"))
        session.selectTool(.spotHealing)
        session.spotHealingMode = mode
        session.brushSettings = BrushSettings(diameter: 24, hardness: 1, red: 0, green: 0, blue: 0)
        let count = session.history.undoCount
        session.beginBrush(at: CGPoint(x: 60, y: 40))
        session.continueBrush(at: CGPoint(x: 60.5, y: 40))
        await session.finishBrush()
        #expect(session.brushError == nil && session.history.undoCount == count + 1)
        let before = try pixels(original)
        let after = try pixels(try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image)
        for (x, y) in [(60, 40), (56, 36), (64, 44)] {
            let healed = after(x, y)
            #expect(healed[0] - healed[1] < 30 && (80...130).contains(healed[1]) && healed[3] == 255,
                    "\(mode): (\(x), \(y)) is \(healed), not healed into the gray surface")
        }
        // Away from the brush, nothing moves.
        for (x, y) in [(10, 10), (90, 40), (30, 40), (60, 10), (60, 70)] {
            #expect(after(x, y) == before(x, y), "\(mode): (\(x), \(y)) changed outside the brush")
        }
    }
}
