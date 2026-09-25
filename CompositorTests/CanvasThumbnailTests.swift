import AppKit
import Testing
@testable import Compositor

@MainActor
struct CanvasThumbnailTests {
    private func image(width: Int, height: Int, fill: CGColor) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(fill)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
    /// A thumbnail's pixel width and a reader for one pixel's RGBA bytes, top row first.
    private func pixels(_ thumbnail: NSImage) throws -> (width: Int, read: (Int, Int) -> [Int]) {
        let image = try #require(thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        let bytes = Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self),
                                              count: image.width * image.height * 4))
        let width = image.width
        return (width, { x, y in (0..<4).map { Int(bytes[(y * width + x) * 4 + $0]) } })
    }

    @Test func thumbnailsTakeTheCanvasShape() {
        #expect(CanvasThumbnail.fittedSize(canvas: CGSize(width: 400, height: 200), box: 36) == CGSize(width: 36, height: 18))
        #expect(CanvasThumbnail.fittedSize(canvas: CGSize(width: 300, height: 600), box: 36) == CGSize(width: 18, height: 36))
        #expect(CanvasThumbnail.fittedSize(canvas: .zero, box: 30) == CGSize(width: 30, height: 30))
    }

    @Test func layerPixelsSitWhereTheyAreOnTheCanvas() throws {
        let red = try image(width: 100, height: 100, fill: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        let thumbnail = CanvasThumbnail.layer(red, transform: LayerTransform(origin: .zero, size: CGSize(width: 100, height: 100)),
                                              canvas: CGSize(width: 400, height: 200), box: 36)
        #expect(thumbnail.size == CGSize(width: 36, height: 18))
        let picture = try pixels(thumbnail)
        #expect(picture.width == 72)
        #expect(picture.read(4, 4) == [255, 0, 0, 255], "the layer sits in the canvas's top-left quarter")
        #expect(picture.read(12, 12)[0] == 255)
        #expect(picture.read(60, 30)[0] < 200, "the rest of the canvas shows the checkerboard")
        #expect(picture.read(4, 30)[0] < 200, "not flipped: the bottom-left is empty")
        let blank = try pixels(CanvasThumbnail.layer(nil, transform: LayerTransform(origin: .zero, size: CGSize(width: 400, height: 200)),
                                                     canvas: CGSize(width: 400, height: 200), box: 36))
        #expect(blank.read(4, 4)[3] == 255, "an empty layer is all checkerboard")
    }

    @Test func masksFillTheCanvasWithTheirEdgeTone() throws {
        let transform = LayerTransform(origin: CGPoint(x: 100, y: 50), size: CGSize(width: 100, height: 100))
        let canvas = CGSize(width: 400, height: 200)
        let hideAll = try #require(LayerMask.solid(revealing: false)).asset.thumbnail
        let hidden = try pixels(CanvasThumbnail.mask(hideAll, transform: transform, canvas: canvas, box: 30))
        #expect(hidden.read(1, 1)[0] < 10, "a hide-all mask reads all black")
        #expect(hidden.read(55, 25)[0] < 10)
        // White edges round a black middle: white around the layer, black where the middle sits.
        let context = try #require(CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 20,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 5, y: 5, width: 10, height: 10))
        let framed = try #require(context.makeImage())
        #expect(LayerMask.background(of: framed) == 1)
        let shown = try pixels(CanvasThumbnail.mask(framed, transform: transform, canvas: canvas, box: 30))
        #expect(shown.read(2, 2)[0] > 245, "outside the layer the edge tone carries on")
        #expect(shown.read(22, 15)[0] < 10, "the black middle sits where the layer is")
        // A stroke reaching the mask's edge: the rest still reads white, as the canvas treats it, not gray.
        context.fill(CGRect(x: 0, y: 8, width: 20, height: 4))
        let stroked = try #require(context.makeImage())
        let beyond = try pixels(CanvasThumbnail.mask(stroked, transform: transform, canvas: canvas, box: 30))
        #expect(beyond.read(2, 2)[0] > 245, "the background is white or black, never a gray average")
    }
}
