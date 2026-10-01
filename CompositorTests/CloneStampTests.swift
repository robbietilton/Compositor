import CoreGraphics
import Foundation
import Testing
@testable import Compositor

@MainActor
struct CloneStampTests {
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
    private func stroke(_ session: EditorSession, at point: CGPoint) async {
        session.beginBrush(at: point)
        session.continueBrush(at: CGPoint(x: point.x + 0.5, y: point.y))
        await session.finishBrush()
    }

    @Test func copiesTheSourceUnderTheBrushKeepingAlignmentUntilItIsTurnedOff() async throws {
        let session = EditorSession()
        session.createDocument(width: 80, height: 40)
        // Left half red with a green square (x 10–19, y 15–24), right half blue.
        let context = try BrushRaster.context(width: 80, height: 40, mask: false)
        for (color, rect) in [((1.0, 0.0, 0.0), CGRect(x: 0, y: 0, width: 40, height: 40)),
                              ((0.0, 0.0, 1.0), CGRect(x: 40, y: 0, width: 40, height: 40)),
                              ((0.0, 1.0, 0.0), CGRect(x: 10, y: 15, width: 10, height: 10))] {
            context.setFillColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1))
            context.fill(rect)
        }
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Colors"))
        session.selectTool(.cloneStamp)
        session.brushSettings = BrushSettings(diameter: 6, hardness: 1, red: 0, green: 0, blue: 0)
        // Nothing to copy until a source is set.
        session.beginBrush(at: CGPoint(x: 60, y: 20))
        #expect(session.brushStroke == nil && session.brushError != nil)
        session.brushError = nil

        session.setCloneSource(CGPoint(x: 15, y: 20))
        let count = session.history.undoCount
        await stroke(session, at: CGPoint(x: 60, y: 20))
        #expect(session.brushError == nil && session.history.undoCount == count + 1)
        var after = try pixels(try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image)
        #expect(after(60, 20) == [0, 255, 0, 255])  // the green source, under the brush
        #expect(after(70, 5) == [0, 0, 255, 255])   // untouched elsewhere

        // Aligned: the next stroke keeps the offset (−45, 0), so (66, 20) copies red from (21, 20).
        await stroke(session, at: CGPoint(x: 66, y: 20))
        after = try pixels(try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image)
        #expect(after(66, 20) == [255, 0, 0, 255])

        // Not aligned: every stroke starts at the source again.
        session.cloneSettings.aligned = false
        await stroke(session, at: CGPoint(x: 50, y: 10))
        after = try pixels(try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image)
        #expect(after(50, 10) == [0, 255, 0, 255])
    }

    @Test func cloneStampKeepsItsOwnSoftBrushTip() {
        let session = EditorSession()
        session.createDocument(width: 40, height: 20)
        session.selectTool(.brush)
        session.brushSettings.diameter = 30
        #expect(session.brushSettings.hardness == 1)
        session.selectTool(.cloneStamp)
        #expect(session.brushSettings.hardness == 0 && session.brushSettings.diameter == 40)
        session.brushSettings.hardness = 0.5
        // Brush and Spot Healing get their own tip back; Clone Stamp remembers its change.
        session.selectTool(.spotHealing)
        #expect(session.brushSettings.hardness == 1 && session.brushSettings.diameter == 30)
        session.selectTool(.cloneStamp)
        #expect(session.brushSettings.hardness == 0.5 && session.brushSettings.diameter == 40)
    }
}
