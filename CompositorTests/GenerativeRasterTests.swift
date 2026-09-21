import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Compositor

struct GenerativeRasterTests {
    /// Red on the left half, blue on the right, as the model might answer.
    private func halves(width: Int, height: Int, alpha: CGFloat = 1) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: alpha))
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return try #require(context.makeImage())
    }
    /// Top rows green, the rest black: tells a vertical flip from a correct mapping.
    private func topBand(width: Int, height: Int, band: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: band))
        return try #require(context.makeImage())
    }
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [Int] {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self) + y * context.bytesPerRow + x * 4
        return (0..<4).map { Int(bytes[$0]) }
    }
    private func gray(_ image: CGImage, x: Int, y: Int) throws -> Int {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: true)
        context.interpolationQuality = .none
        context.translateBy(x: 0, y: CGFloat(image.height)); context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Int((try #require(context.data).assumingMemoryBound(to: UInt8.self) + y * context.bytesPerRow + x)[0])
    }
    private let canvas = CGRect(x: 0, y: 0, width: 4000, height: 4000)

    @Test func theAnswerIsReadAtTheLayersPlaceInTheRegion() throws {
        // A 2000 px region answered at 1000 px: document x 1000 is the answer's red/blue boundary at 500.
        let plan = try #require(GenerativePlan.make(target: CGRect(x: 500, y: 500, width: 1000, height: 1000), bounds: canvas, fixed: .k1))
        #expect(plan.region == CGRect(x: 0, y: 0, width: 2000, height: 2000))
        let rect = CGRect(x: 900, y: 600, width: 200, height: 100) // Straddles the boundary.
        let layer = try GenerativeRaster.layerImage(from: halves(width: 1000, height: 1000), plan: plan, rect: rect)
        #expect(layer.width == 200 && layer.height == 100)
        #expect(try pixel(layer, x: 90, y: 50) == [255, 0, 0, 255])
        #expect(try pixel(layer, x: 110, y: 50) == [0, 0, 255, 255])
    }

    @Test func rowsAreNotFlippedOnTheWayBack() throws {
        let plan = try #require(GenerativePlan.make(target: CGRect(x: 500, y: 500, width: 1000, height: 1000), bounds: canvas, fixed: .k1))
        // The answer's top tenth is green: document rows 0..<200 of the 2000 px region.
        let answer = try topBand(width: 1000, height: 1000, band: 100)
        let upper = try GenerativeRaster.layerImage(from: answer, plan: plan, rect: CGRect(x: 100, y: 0, width: 50, height: 100))
        #expect(try pixel(upper, x: 25, y: 50) == [0, 255, 0, 255])
        let lower = try GenerativeRaster.layerImage(from: answer, plan: plan, rect: CGRect(x: 100, y: 1800, width: 50, height: 100))
        #expect(try pixel(lower, x: 25, y: 50) == [0, 0, 0, 255])
    }

    @Test func anAnswerInAnotherShapeIsReadFromItsMiddle() throws {
        let plan = try #require(GenerativePlan.make(target: CGRect(x: 500, y: 500, width: 1000, height: 1000), bounds: canvas, fixed: .k1))
        // 1500 × 1000 instead of square: the middle 1000 columns stand for the region, so its boundary sits at 750.
        let layer = try GenerativeRaster.layerImage(from: halves(width: 1500, height: 1000), plan: plan, rect: CGRect(x: 900, y: 600, width: 200, height: 100))
        #expect(try pixel(layer, x: 90, y: 50) == [255, 0, 0, 255])
        #expect(try pixel(layer, x: 110, y: 50) == [0, 0, 255, 255])
    }

    @Test func theMaskShowsTheSelectionGrownAndStaysInsideItsLimit() throws {
        let selection = DocumentSelection(path: CGPath(rect: CGRect(x: 100, y: 100, width: 40, height: 40), transform: nil), antialiased: false)
        let hard = try #require(try GenerativeMask.make(selection, grow: 0, feather: 0, limit: canvas))
        #expect(hard.rect == CGRect(x: 99, y: 99, width: 42, height: 42) && LayerMask.isValid(hard.coverage))
        #expect(try gray(hard.coverage, x: 20, y: 20) == 255) // White shows the generated pixels: inside the selection.
        #expect(try gray(hard.coverage, x: 0, y: 0) == 0)
        let grown = try #require(try GenerativeMask.make(selection, grow: 10, feather: 0, limit: canvas))
        #expect(grown.rect == CGRect(x: 89, y: 89, width: 62, height: 62))
        #expect(try gray(grown.coverage, x: 5, y: 30) == 255) // Document x 94: outside the selection, inside the growth.
        let limited = try #require(try GenerativeMask.make(selection, grow: 10, feather: 0, limit: CGRect(x: 95, y: 0, width: 200, height: 200)))
        #expect(limited.rect.minX == 95 && limited.rect.maxX == 151)
        let soft = try #require(try GenerativeMask.make(selection, grow: 0, feather: 8, limit: canvas))
        let edge = try gray(soft.coverage, x: Int(100 - soft.rect.minX), y: Int(120 - soft.rect.minY))
        #expect(edge > 64 && edge < 192) // Half covered on the outline, as a feathered selection is.
    }

    @Test func nothingSelectedMakesNoMask() throws {
        let empty = DocumentSelection(path: CGMutablePath())
        #expect(try GenerativeMask.make(empty, grow: 4, feather: 4, limit: canvas) == nil)
        let outside = DocumentSelection(path: CGPath(rect: CGRect(x: 5000, y: 0, width: 10, height: 10), transform: nil))
        #expect(try GenerativeMask.make(outside, grow: 0, feather: 0, limit: canvas) == nil)
    }

    @Test func solidPicturesTravelAsJPEGAndTransparentOnesAsPNG() throws {
        let solid = try GenerativeRaster.encoded(halves(width: 64, height: 64))
        #expect(solid.mimeType == "image/jpeg" && solid.data.starts(with: [0xFF, 0xD8]))
        let clear = try GenerativeRaster.encoded(halves(width: 64, height: 64, alpha: 0.5))
        #expect(clear.mimeType == "image/png" && clear.data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func generatedBytesDecodeToDocumentPixels() async throws {
        let png = try GenerativeRaster.encode(halves(width: 40, height: 20), as: .png)
        let decoded = try await ImageImporter.shared.decode(png, name: "Generated")
        #expect(decoded.name == "Generated" && decoded.image.width == 40 && decoded.image.height == 20)
        #expect(try pixel(decoded.image, x: 5, y: 10) == [255, 0, 0, 255])
        #expect(try pixel(decoded.image, x: 35, y: 10) == [0, 0, 255, 255])
        await #expect(throws: ImageImportError.self) { try await ImageImporter.shared.decode(Data([1, 2, 3]), name: "Broken") }
    }

    @Test func theHintIsWhiteWhereTheChangeIsWanted() throws {
        let plan = try #require(GenerativePlan.make(target: CGRect(x: 500, y: 500, width: 1000, height: 1000), bounds: canvas, fixed: .k1))
        let selection = DocumentSelection(path: CGPath(rect: CGRect(x: 500, y: 500, width: 1000, height: 1000), transform: nil))
        let hint = try GenerativeRaster.hint(for: selection, plan: plan)
        // A 2000 px region sent at 1024: the selection's 500...1500 lands on 256...768.
        #expect(hint.width == 1024 && hint.height == 1024)
        #expect(try gray(hint, x: 512, y: 512) == 255 && gray(hint, x: 100, y: 512) == 0 && gray(hint, x: 512, y: 900) == 0)
    }
}
