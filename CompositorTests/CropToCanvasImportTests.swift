import CoreGraphics
import Foundation
import Testing
@testable import Compositor

@MainActor
struct CropToCanvasImportTests {
    private func rgbaImage(width: Int, height: Int) throws -> CGImage {
        var pixels = [UInt8]()
        pixels.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                pixels.append(UInt8(x * 30 + y))
                pixels.append(UInt8(y * 50))
                pixels.append(UInt8(255 - x * 20))
                pixels.append(255)
            }
        }
        return try PSDChannelCoder.image(width: width, height: height, rgba: pixels)
    }

    private func grayImage(width: Int, height: Int) throws -> CGImage {
        let pixels = (0..<(width * height)).map { UInt8($0 * 10) }
        return try PSDChannelCoder.maskImage(width: width, height: height, gray: pixels)
    }

    private func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                             bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self),
                                         count: image.width * image.height * 4))
    }

    private func grayPixels(_ image: CGImage) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                             bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
                                             bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self),
                                         count: image.width * image.height))
    }

    private func document() throws -> (source: PSDDocument, composite: CGImage) {
        let image = try rgbaImage(width: 6, height: 3)
        let composite = try rgbaImage(width: 4, height: 4)
        var layer = PSDRecord(id: UUID(), name: "Overhang")
        layer.bounds = CGRect(x: -2, y: 1, width: 6, height: 3)
        layer.image = image
        layer.mask = try grayImage(width: 6, height: 3)
        return (PSDDocument(width: 4, height: 4, resolution: 72, layers: [layer]), composite)
    }

    @Test func fittingDocumentKeepsOversizedLayerPixels() throws {
        let fixture = try document()
        let parsed = try PSDReader.read(PSDFixture.data(fixture.source, composite: fixture.composite), remainingPixels: 100)
        let layer = try #require(parsed.layers.first)
        #expect(layer.bounds == CGRect(x: -2, y: 1, width: 6, height: 3))
        #expect(!layer.croppedToCanvas)
        #expect(try rgbaPixels(#require(layer.image)) == rgbaPixels(#require(fixture.source.layers[0].image)))
        #expect(!(try PSDDocumentBuilder.makeImport(parsed)).conversions.contains { $0.message.contains("Cropped to the canvas") })
    }

    @Test func overBudgetDocumentCropsImageAndMaskToCanvas() throws {
        let fixture = try document()
        let parsed = try PSDReader.read(PSDFixture.data(fixture.source, composite: fixture.composite), remainingPixels: 12)
        let layer = try #require(parsed.layers.first)
        #expect(layer.bounds == CGRect(x: 0, y: 1, width: 4, height: 3))
        #expect(layer.croppedToCanvas)
        let image = try #require(layer.image)
        #expect(image.width == 4 && image.height == 3)
        let sourcePixels = try rgbaPixels(#require(fixture.source.layers[0].image))
        var expectedPixels: [UInt8] = []
        for row in 0..<3 { expectedPixels.append(contentsOf: sourcePixels[(row * 6 + 2) * 4..<(row * 6 + 6) * 4]) }
        #expect(try rgbaPixels(image) == expectedPixels)
        let mask = try #require(layer.mask)
        #expect(mask.width == 4 && mask.height == 3)
        let sourceMask = try grayPixels(#require(fixture.source.layers[0].mask))
        var expectedMask: [UInt8] = []
        for row in 0..<3 { expectedMask.append(contentsOf: sourceMask[row * 6 + 2..<row * 6 + 6]) }
        #expect(try grayPixels(mask) == expectedMask)
        let cropNotes = try PSDDocumentBuilder.makeImport(parsed).conversions.filter { $0.message.contains("Cropped to the canvas") }
        #expect(cropNotes.map(\.layerName) == ["Overhang"])
    }

    @Test func croppedDocumentStillOverBudgetIsRejected() throws {
        let fixture = try document()
        #expect(throws: ImageImportError.tooLarge) {
            try PSDReader.read(PSDFixture.data(fixture.source, composite: fixture.composite), remainingPixels: 11)
        }
    }

    @Test func offCanvasLayerIsKeptWithoutPixelsWhenCropping() throws {
        let composite = try rgbaImage(width: 4, height: 4)
        var layer = PSDRecord(id: UUID(), name: "Outside")
        layer.bounds = CGRect(x: 5, y: 0, width: 2, height: 2)
        layer.image = try rgbaImage(width: 2, height: 2)
        let source = PSDDocument(width: 4, height: 4, resolution: 72, layers: [layer])
        let parsed = try PSDReader.read(PSDFixture.data(source, composite: composite), remainingPixels: 1)
        let imported = try #require(parsed.layers.first)
        #expect(imported.image == nil)
        #expect(imported.croppedToCanvas)
        #expect((try PSDDocumentBuilder.makeImport(parsed)).conversions.contains { $0.layerName == "Outside" && $0.message.contains("Cropped to the canvas") })
    }

    @Test func channelCropsMatchFullDecodes() throws {
        let width = 5, height = 4
        let source = Data((0..<(width * height)).map { UInt8($0) })
        let crop = PSDCrop(x: 1, y: 1, width: 3, height: 2)
        let rawFull = try PSDChannelCoder.decode(compression: 0, width: width, height: height, data: source)
        #expect(try PSDChannelCoder.decode(compression: 0, width: width, height: height, data: source, crop: crop) == sliced(rawFull, width: width, crop: crop))
        for largeDocument in [false, true] {
            let packed = packBits(source, width: width, height: height, largeDocument: largeDocument)
            let full = try PSDChannelCoder.decode(compression: 1, width: width, height: height, data: packed, largeDocument: largeDocument)
            let cropped = try PSDChannelCoder.decode(compression: 1, width: width, height: height, data: packed,
                                                      largeDocument: largeDocument, crop: crop)
            #expect(cropped == sliced(full, width: width, crop: crop))
        }
    }

    private func sliced(_ plane: [UInt8], width: Int, crop: PSDCrop) -> [UInt8] {
        var result: [UInt8] = []
        for row in 0..<crop.height { result.append(contentsOf: plane[(crop.y + row) * width + crop.x..<(crop.y + row) * width + crop.x + crop.width]) }
        return result
    }

    private func packBits(_ plane: Data, width: Int, height: Int, largeDocument: Bool) -> Data {
        var counts = Data()
        var rows = Data()
        for row in 0..<height {
            let bytes = plane[row * width..<(row + 1) * width]
            var packed = Data([UInt8(width - 1)])
            packed.append(bytes)
            if largeDocument { counts.append(contentsOf: [0, 0]) }
            counts.append(UInt8(packed.count >> 8))
            counts.append(UInt8(packed.count))
            rows.append(packed)
        }
        return counts + rows
    }
}
