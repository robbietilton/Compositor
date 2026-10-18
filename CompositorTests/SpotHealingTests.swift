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

    /// A sky over a curved hilltop, and the same with a red disc on the curve: the scene to heal and the answer.
    private func ridge(disc: Bool) throws -> CGImage {
        let context = try BrushRaster.context(width: 320, height: 200, mask: false)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var seed: UInt32 = 7
        for y in 0..<200 {
            for x in 0..<320 {
                seed = seed &* 1664525 &+ 1013904223
                let grain = Double(Int(seed >> 28) - 8) * 2
                let sky = Double(y) < 110 + 28 * sin(Double(x) / 37)
                let dx = Double(x) - 160, dy = Double(y) - (110 + 28 * sin(160.0 / 37))
                let red = disc && dx * dx + dy * dy < 22 * 22
                let color = red ? [220.0, 30, 30] : sky ? [120 + Double(y) * 0.5, 160 + Double(y) * 0.3, 230]
                                                        : [60 + grain, 110 + grain, 50 + grain]
                let index = y * context.bytesPerRow + x * 4
                for c in 0..<3 { bytes[index + c] = UInt8(max(0, min(255, color[c]))) }
                bytes[index + 3] = 255
            }
        }
        return try #require(context.makeImage())
    }

    /// Content-Aware rebuilds a spot pixel by pixel from patches all around it (PatchPixels.c), so the edge of a hill
    /// carries on through it as a curve. Proximity Match, which copies one nearby patch, can't follow it.
    @Test func contentAwareCarriesACurvedEdgeThroughTheSpot() async throws {
        var errors: [SpotHealingMode: Double] = [:]
        let truth = try pixels(try ridge(disc: false))
        for mode in [SpotHealingMode.contentAware, .proximityMatch] {
            let session = EditorSession()
            session.createDocument(width: 320, height: 200)
            let damaged = try ridge(disc: true)
            session.insert(ImportedImage(image: damaged, thumbnail: damaged, name: "Ridge"))
            session.selectTool(.spotHealing)
            session.spotHealingMode = mode
            session.brushSettings = BrushSettings(diameter: 56, hardness: 1, red: 0, green: 0, blue: 0)
            let center = CGPoint(x: 160, y: 110 + 28 * sin(160.0 / 37))
            session.beginBrush(at: center)
            session.continueBrush(at: CGPoint(x: center.x + 0.5, y: center.y))
            await session.finishBrush()
            let after = try pixels(try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image)
            var sum = 0.0, count = 0.0
            for y in 0..<200 {
                for x in 0..<320 {
                    let dx = Double(x) - center.x, dy = Double(y) - center.y
                    guard dx * dx + dy * dy < 22 * 22 else { continue }
                    let healed = after(x, y), real = truth(x, y)
                    for c in 0..<3 { sum += Double(abs(healed[c] - real[c])); count += 1 }
                }
            }
            errors[mode] = sum / count
        }
        let contentAware = try #require(errors[.contentAware])
        let proximity = try #require(errors[.proximityMatch])
        #expect(contentAware < 12, "Content-Aware is close to what the disc hid: off by \(contentAware) levels")
        #expect(contentAware < proximity / 2, "and far closer than one copied patch: \(contentAware) against \(proximity)")
    }
}
