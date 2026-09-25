import AppKit
import Testing
@testable import Compositor

@MainActor
struct DistortTests {
    private let shape = [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 10), CGPoint(x: 30, y: 30), CGPoint(x: 10, y: 30)]

    /// Was perspectiveMappingHitsTheCornersAndTwistedShapesAreRefused, which asserted that a
    /// folded shape is refused. Folding a layer over itself became a supported distortion in 1.1:
    /// such a shape has no single perspective, so each half is warped as its own triangle
    /// (`warpFolded`). What is still refused is a shape with nothing to draw.
    @Test func perspectiveMappingHitsTheCornersAndDegenerateShapesAreRefused() {
        let map = DistortWarp.homography(shape)
        for (unit, corner) in zip([CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)], shape) {
            let mapped = map(unit)
            #expect(abs(mapped.x - corner.x) < 1e-6 && abs(mapped.y - corner.y) < 1e-6, "\(unit) went to \(mapped)")
        }
        #expect(DistortWarp.isUsable(shape))
        #expect(DistortWarp.isConvex(shape))
        // A bow-tie is usable — it draws folded — but it is not a perspective, so it isn't convex.
        #expect(DistortWarp.isUsable([shape[0], shape[2], shape[1], shape[3]]))
        #expect(!DistortWarp.isConvex([shape[0], shape[2], shape[1], shape[3]]))
        // A collapsed corner leaves one half with nothing to draw, so neither accepts it.
        #expect(!DistortWarp.isUsable([shape[0], shape[0], shape[2], shape[3]]))
        #expect(!DistortWarp.isConvex([shape[0], shape[0], shape[2], shape[3]]))
    }

    @Test func distortingWarpsTheLayerIntoTheShapeAsOneUndoStep() async throws {
        let session = EditorSession()
        session.createDocument(width: 100, height: 60)
        let context = try BrushRaster.context(width: 20, height: 20, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Red"))
        let index = try #require(session.document?.layers.firstIndex { $0.id == session.activeLayerID })
        session.document?.layers[index].transform = LayerTransform(origin: CGPoint(x: 10, y: 10), size: CGSize(width: 20, height: 20))
        session.selectTool(.move)
        session.beginTransform(persistent: false)
        session.beginDistort()
        #expect(session.transformEdit?.corners?.count == 4 && session.transformEdit?.persistent == true)
        // A folded shape is a distortion in its own right since 1.1, so the preview takes it.
        session.previewCorners([shape[0], shape[2], shape[1], shape[3]])
        #expect(session.transformEdit?.corners?[1] == shape[2])
        session.previewCorners(shape)
        let count = session.history.undoCount
        session.commitTransform()
        #expect(session.transformEdit == nil && session.history.undoCount == count + 1)
        let transform = try #require(session.activeLayer?.transform)
        #expect(transform.origin == CGPoint(x: 10, y: 10) && transform.size == CGSize(width: 50, height: 20) && transform.rotation == 0)

        let result = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let read = try #require(CGContext(data: nil, width: result.width, height: result.height, bitsPerComponent: 8,
            bytesPerRow: result.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        read.draw(result, in: CGRect(x: 0, y: 0, width: result.width, height: result.height))
        let bytes = try #require(read.data).assumingMemoryBound(to: UInt8.self)
        func alpha(_ x: Int, _ y: Int) -> Int { Int(bytes[(y * result.width + x) * 4 + 3]) }
        #expect(alpha(50, 12) == 255)  // inside the stretched top-right
        #expect(alpha(15, 25) == 255)
        #expect(alpha(50, 28) == 0)    // outside the slanted right edge
        #expect(alpha(80, 12) == 0)

        session.undo()
        #expect(session.activeLayer?.transform.size == CGSize(width: 20, height: 20))
    }

    /// A stroke or cutout rarely fills its shape; after Apply the layer hugs its visible pixels.
    @Test func distortedLayerIsTrimmedToItsVisiblePixels() async throws {
        let session = EditorSession()
        session.createDocument(width: 100, height: 60)
        // A 40 × 20 layer that is transparent except for a 10 × 10 red square.
        let context = try BrushRaster.context(width: 40, height: 20, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 15, y: 5, width: 10, height: 10))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Stroke"))
        let index = try #require(session.document?.layers.firstIndex { $0.id == session.activeLayerID })
        session.document?.layers[index].transform = LayerTransform(origin: CGPoint(x: 10, y: 10), size: CGSize(width: 40, height: 20))
        session.selectTool(.move)
        session.beginTransform(persistent: false)
        session.beginDistort()
        session.previewCorners([CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 10), CGPoint(x: 50, y: 30), CGPoint(x: 10, y: 30)])
        session.commitTransform()
        let transform = try #require(session.activeLayer?.transform)
        // The shape's bounds are 50 × 20; the square's warp is far smaller.
        #expect(transform.size.width < 20 && transform.size.height <= 12, "layer bounds \(transform)")
        #expect(transform.origin.x >= 20 && transform.origin.y >= 14)
        let result = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let read = try #require(CGContext(data: nil, width: result.width, height: result.height, bitsPerComponent: 8,
            bytesPerRow: result.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        read.draw(result, in: CGRect(x: 0, y: 0, width: result.width, height: result.height))
        let bytes = try #require(read.data).assumingMemoryBound(to: UInt8.self)
        #expect(bytes[(20 * result.width + 30) * 4 + 3] == 255) // the square stays where the warp put it
    }
}
