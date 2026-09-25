import CoreGraphics
import Foundation
import Testing
@testable import Compositor

@MainActor
struct PSBImportTests {
    private func colorImage(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func grayImage(width: Int, height: Int, value: CGFloat) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                             bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: value, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                             bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self),
                                         count: image.width * image.height * 4))
    }

    @Test func PSBRoundTripMatchesPSDLayerContent() throws {
        let red = try colorImage(width: 3, height: 2, red: 1, green: 0, blue: 0)
        let green = try colorImage(width: 2, height: 3, red: 0, green: 1, blue: 0)
        let blue = try colorImage(width: 2, height: 2, red: 0, green: 0, blue: 1)
        let mask = try grayImage(width: 2, height: 2, value: 0.5)
        let composite = try colorImage(width: 5, height: 5, red: 0, green: 0, blue: 0)
        var bottom = PSDRecord(id: UUID(), name: "Red")
        bottom.bounds = CGRect(x: 0, y: 0, width: 3, height: 2)
        bottom.image = red
        var middle = PSDRecord(id: UUID(), name: "Green")
        middle.bounds = CGRect(x: 1, y: 1, width: 2, height: 3)
        middle.image = green
        var top = PSDRecord(id: UUID(), name: "Blue mask")
        top.bounds = CGRect(x: 2, y: 2, width: 2, height: 2)
        top.image = blue
        top.mask = mask
        let source = PSDDocument(width: 5, height: 5, resolution: 144, layers: [bottom, middle, top])

        let psd = try PSDReader.read(PSDFixture.data(source, composite: composite))
        let psb = try PSDReader.read(PSDFixture.data(source, composite: composite, largeDocument: true))

        #expect(psb.layers.count == psd.layers.count)
        #expect(psb.layers.map(\.name) == psd.layers.map(\.name))
        #expect(psb.layers.map(\.bounds) == psd.layers.map(\.bounds))
        for index in psd.layers.indices {
            #expect(try pixels(#require(psb.layers[index].image)) == pixels(#require(psd.layers[index].image)))
        }
        #expect(try pixels(#require(psb.layers[2].mask)) == pixels(#require(psd.layers[2].mask)))
    }

    @Test func PSBExceedingCanvasLimitIsRejected() throws {
        let image = try colorImage(width: 2, height: 2, red: 1, green: 0, blue: 0)
        var layer = PSDRecord(id: UUID(), name: "Large")
        layer.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        layer.image = image
        var data = try PSDFixture.data(PSDDocument(width: 2, height: 2, resolution: 72, layers: [layer]), composite: image, largeDocument: true)
        data.replaceSubrange(18..<22, with: [0, 0, 0x75, 0x31])
        #expect(throws: ImageImportError.tooLarge) { try PSDReader.read(data) }
    }

    @Test func PSBLargeAdditionalInfoBlockDoesNotHideUnicodeName() throws {
        let image = try colorImage(width: 2, height: 2, red: 1, green: 0, blue: 0)
        var layer = PSDRecord(id: UUID(), name: "Caf\u{00E9} layer")
        layer.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        layer.image = image
        let info = PSDFixture.AdditionalLayerInfo(key: "LMsk", payload: Data([1, 2, 3]))
        let data = try PSDFixture.data(PSDDocument(width: 2, height: 2, resolution: 72, layers: [layer]), composite: image,
                                       largeDocument: true, additionalLayerInfo: info)
        #expect(try PSDReader.read(data).layers.map(\.name) == ["Caf\u{00E9} layer"])
    }
}
