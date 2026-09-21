import AppKit
import Testing
@testable import Compositor

@MainActor
@Suite(.serialized)
struct FilterTests {
    @Test func gaussianBlurSoftensAHardEdgeWithoutFadingTheBordersAsOneUndoStep() async throws {
        let session = EditorSession()
        session.createDocument(width: 40, height: 20)
        // Left half opaque white, right half transparent.
        let context = try BrushRaster.context(width: 40, height: 20, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Half"))
        session.beginFilter(.gaussianBlur)
        #expect(session.filterEdit != nil && !session.canEditLayers)
        session.updateFilter(FilterSettings(radius: 3), preview: true)
        let count = session.history.undoCount
        await session.commitFilter()
        #expect(session.filterEdit == nil && session.history.undoCount == count + 1)
        #expect(session.filterSettings.radius == 3)
        let result = try #require(session.activeLayer?.asset?.image)
        let pixels = try #require(CGContext(data: nil, width: result.width, height: result.height, bitsPerComponent: 8,
            bytesPerRow: result.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        pixels.draw(result, in: CGRect(x: 0, y: 0, width: result.width, height: result.height))
        let bytes = try #require(pixels.data).assumingMemoryBound(to: UInt8.self)
        func alpha(_ x: Int) -> Int { Int(bytes[(10 * result.width + x) * 4 + 3]) }
        #expect(alpha(0) == 255)                  // the layer's own border doesn't fade
        #expect((0..<result.width).contains { (20..<235).contains(alpha($0)) }) // the hard edge is now soft
        #expect(alpha(result.width - 1) < 20)      // transparent content remains transparent at the far edge
    }

    @Test func gaussianBlurKeepsAnOpaqueLayerEdgeAndSpreadsPastItsOriginalBounds() async throws {
        let session = EditorSession()
        session.createDocument(width: 40, height: 20)
        let context = try BrushRaster.context(width: 40, height: 20, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Opaque"))
        session.beginFilter(.gaussianBlur)
        session.updateFilter(FilterSettings(radius: 3), preview: true)
        await session.commitFilter()
        let result = try #require(session.activeLayer?.asset?.image)
        #expect(result.width > 40 && result.height > 20)
        let pixels = try #require(CGContext(data: nil, width: result.width, height: result.height, bitsPerComponent: 8,
            bytesPerRow: result.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        pixels.draw(result, in: CGRect(x: 0, y: 0, width: result.width, height: result.height))
        let bytes = try #require(pixels.data).assumingMemoryBound(to: UInt8.self)
        #expect(bytes[3] == 255 && bytes[(result.width - 1) * 4 + 3] == 255)
    }

    @Test func motionBlurStreaksAlongItsAngleCounterclockwiseFromHorizontal() throws {
        // One opaque white dot in the middle of a transparent image.
        let context = try BrushRaster.context(width: 41, height: 41, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 20, y: 20, width: 1, height: 1))
        let dot = try #require(context.makeImage())
        func streak(angle: Double) throws -> (Int, Int) -> Int {
            let settings = FilterSettings(angle: angle, distance: 16)
            let image = try PixelFilter.run(FilterJob(kind: .motionBlur, image: dot, settings: settings, scale: 1,
                                                      selection: nil, mapping: .identity))
            let read = try #require(CGContext(data: nil, width: 41, height: 41, bitsPerComponent: 8, bytesPerRow: 164,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            read.draw(image, in: CGRect(x: 0, y: 0, width: 41, height: 41))
            let bytes = Array(UnsafeBufferPointer(start: try #require(read.data).assumingMemoryBound(to: UInt8.self), count: 41 * 41 * 4))
            return { x, y in Int(bytes[(y * 41 + x) * 4 + 3]) } // rows top-down
        }
        let horizontal = try streak(angle: 0)
        #expect(horizontal(24, 20) > 0 && horizontal(16, 20) > 0 && horizontal(20, 24) == 0)
        let vertical = try streak(angle: 90)
        #expect(vertical(20, 24) > 0 && vertical(20, 16) > 0 && vertical(24, 20) == 0)
        // 45° runs up-right and down-left on screen, never up-left.
        let diagonal = try streak(angle: 45)
        #expect(diagonal(23, 17) > 0 && diagonal(17, 23) > 0 && diagonal(17, 17) == 0)
    }

    @Test func addNoiseChangesColorButNeverAlphaAndMonochromaticKeepsGrays() throws {
        // Left half opaque mid gray, right half transparent.
        let context = try BrushRaster.context(width: 32, height: 8, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 8))
        let gray = try #require(context.makeImage())
        func pixels(_ settings: FilterSettings) throws -> [UInt8] {
            let image = try PixelFilter.run(FilterJob(kind: .addNoise, image: gray, settings: settings, scale: 1,
                                                      selection: nil, mapping: .identity, seed: 7))
            let read = try #require(CGContext(data: nil, width: 32, height: 8, bitsPerComponent: 8, bytesPerRow: 128,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            read.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 8))
            return Array(UnsafeBufferPointer(start: try #require(read.data).assumingMemoryBound(to: UInt8.self), count: 32 * 8 * 4))
        }
        let offsets = Array(stride(from: 0, to: 32 * 8 * 4, by: 4))
        let opaque = offsets.filter { $0 / 4 % 32 < 16 }, clear = offsets.filter { $0 / 4 % 32 >= 16 }
        let color = try pixels(FilterSettings(amount: 10))
        #expect(try pixels(FilterSettings(amount: 10)) == color) // the same seed gives the same grain
        #expect(opaque.allSatisfy { color[$0 + 3] == 255 && (112...144).contains(Int(color[$0])) })
        #expect(Set(opaque.map { color[$0] }).count > 5)
        #expect(opaque.contains { color[$0] != color[$0 + 1] }) // color noise differs per channel
        #expect(clear.allSatisfy { color[$0] == 0 && color[$0 + 3] == 0 })
        let mono = try pixels(FilterSettings(amount: 10, gaussian: true, monochromatic: true))
        #expect(opaque.allSatisfy { mono[$0] == mono[$0 + 1] && mono[$0 + 1] == mono[$0 + 2] && mono[$0 + 3] == 255 })
    }

    @Test func removeDistortionBendsAboutTheCenterAndOnlyPincushionCorrectionOpensTheCorners() throws {
        // An opaque image with a distinct color in each quadrant.
        let context = try BrushRaster.context(width: 40, height: 30, mask: false)
        for (index, rect) in [CGRect(x: 0, y: 0, width: 20, height: 15), CGRect(x: 20, y: 0, width: 20, height: 15),
                              CGRect(x: 0, y: 15, width: 20, height: 15), CGRect(x: 20, y: 15, width: 20, height: 15)].enumerated() {
            context.setFillColor(CGColor(srgbRed: CGFloat(index) / 3, green: 0.5, blue: 1 - CGFloat(index) / 3, alpha: 1))
            context.fill(rect)
        }
        let source = try #require(context.makeImage())
        func pixels(_ distortion: Double) throws -> [UInt8] {
            let image = try PixelFilter.run(FilterJob(kind: .lensCorrection, image: source, settings: FilterSettings(distortion: distortion),
                                                      scale: 1, selection: nil, mapping: .identity))
            let read = try #require(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 160,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            read.draw(image, in: CGRect(x: 0, y: 0, width: 40, height: 30))
            return Array(UnsafeBufferPointer(start: try #require(read.data).assumingMemoryBound(to: UInt8.self), count: 40 * 30 * 4))
        }
        func alpha(_ bytes: [UInt8], _ x: Int, _ y: Int) -> UInt8 { bytes[(y * 40 + x) * 4 + 3] }
        let original = try pixels(0)
        #expect(original.count == 40 * 30 * 4 && (0..<(40 * 30)).allSatisfy { original[$0 * 4 + 3] == 255 })
        // Straightening barrel distortion stretches the edges outward: nothing opens up.
        let barrel = try pixels(100)
        #expect(alpha(barrel, 0, 0) == 255 && alpha(barrel, 39, 29) == 255)
        // Straightening pincushion pulls the edges in: the corners turn transparent, the middle stays put.
        let pincushion = try pixels(-100)
        #expect(alpha(pincushion, 0, 0) == 0 && alpha(pincushion, 39, 29) == 0)
        #expect(Array(pincushion[((15 * 40 + 20) * 4)..<((15 * 40 + 20) * 4 + 4)]) == Array(original[((15 * 40 + 20) * 4)..<((15 * 40 + 20) * 4 + 4)]))
    }
}
